-module(asobi_storage_controller).

%% This controller is the worked example for the shared error object: it
%% returns `{asobi_error, Code}` rather than a flat `#{error => Binary}` body
%% or a bare `{status, N}` with no body at all. The other controllers still
%% use their own shapes and are converted in a follow-up. See `asobi_error`.

-include_lib("kernel/include/logger.hrl").

-export([list_saves/1, get_save/1, put_save/1]).
-export([get_storage/1, put_storage/1, delete_storage/1, list_storage/1]).

%% F-13: cap cloud-save body size and per-player slot count so a single
%% authenticated user can't exhaust postgres jsonb storage.
-define(MAX_SAVE_DATA_BYTES, 262144).
-define(MAX_SLOTS_PER_PLAYER, 10).

%% F-14: only these literals are honoured by get_storage/put_storage; any
%% other value made the row self-DoS unreachable. Whitelist + reject.
-define(VALID_PERMS, [~"public", ~"owner"]).

-type response() ::
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

%% Storage can be switched off for the whole release (asobi_storage:enabled/0).
%% When it is, each route short-circuits ahead of its DB and handler work and
%% answers the 404 it would give for a genuine miss - save.not_found on the
%% slot-keyed /saves routes, storage.not_found on the /storage routes - so the
%% off-state cannot be told apart from an enabled but empty deployment. Auth is
%% an upstream Nova plugin that has already run by the time a handler is
%% reached, so the guard precedes the DB work, not the authentication. One
%% guard serves all seven routes, given the family's miss-response - kept a
%% literal at each call site so the error-code contract scanner sees it.
-spec guarded(response(), fun(() -> response())) -> response().
guarded(Disabled, Handler) ->
    case asobi_storage:enabled() of
        true -> Handler();
        false -> Disabled
    end.

%% --- Cloud Saves ---

-spec list_saves(cowboy_req:req()) -> response().
list_saves(Req) ->
    guarded({asobi_error, ~"save.not_found"}, fun() -> do_list_saves(Req) end).

-spec do_list_saves(cowboy_req:req()) -> {json, map()}.
do_list_saves(#{auth_data := #{player_id := PlayerId}} = _Req) ->
    Q = kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
    {ok, Saves} = asobi_repo:all(Q),
    {json, #{saves => [maps:with([slot, version, updated_at], S) || S <- Saves]}}.

-spec get_save(cowboy_req:req()) -> response().
get_save(Req) ->
    guarded({asobi_error, ~"save.not_found"}, fun() -> do_get_save(Req) end).

-spec do_get_save(cowboy_req:req()) -> {json, map()} | {asobi_error, asobi_error:code()}.
do_get_save(#{bindings := #{~"slot" := Slot}, auth_data := #{player_id := PlayerId}} = _Req) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
        {slot, Slot}
    ),
    case asobi_repo:all(Q) of
        {ok, [Save]} -> {json, Save};
        {ok, []} -> {asobi_error, ~"save.not_found"}
    end.

-spec put_save(cowboy_req:req()) -> response().
put_save(Req) ->
    guarded({asobi_error, ~"save.not_found"}, fun() -> do_put_save(Req) end).

-spec do_put_save(cowboy_req:req()) ->
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.
do_put_save(
    #{bindings := #{~"slot" := Slot}, json := Params, auth_data := #{player_id := PlayerId}} = _Req
) when is_map(Params), is_binary(PlayerId) ->
    Data = maps:get(~"data", Params, #{}),
    case data_within_limit(Data) of
        false ->
            {asobi_error, ~"save.too_large"};
        true ->
            ClientVersion = maps:get(~"version", Params, undefined),
            Q = kura_query:where(
                kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
                {slot, Slot}
            ),
            case asobi_repo:all(Q) of
                {ok, [#{version := V}]} when ClientVersion =/= undefined, ClientVersion =/= V ->
                    {asobi_error, ~"save.version_conflict", #{current_version => V}};
                {ok, [#{version := V} = Existing]} ->
                    CS = kura_changeset:cast(
                        asobi_cloud_save,
                        Existing,
                        #{data => Data, version => V + 1},
                        [data, version]
                    ),
                    {ok, Updated} = asobi_repo:update(CS),
                    {json, Updated};
                {ok, []} ->
                    case slots_under_cap(PlayerId) of
                        false ->
                            {asobi_error, ~"save.slot_limit_reached"};
                        true ->
                            CS = kura_changeset:cast(
                                asobi_cloud_save,
                                #{},
                                #{
                                    player_id => PlayerId,
                                    slot => Slot,
                                    data => Data,
                                    version => 1
                                },
                                [player_id, slot, data, version]
                            ),
                            {ok, Created} = asobi_repo:insert(CS),
                            {json, 200, #{}, Created}
                    end
            end
    end.

%% --- Generic Storage ---

%% asobi#307: `asobi_storage:indexes/0` maintains two distinct partial-unique
%% namespaces - a global row (`player_id IS NULL`, written by Lua's
%% `game.storage.set`) and per-player rows (`player_id IS NOT NULL`). The
%% HTTP `/storage/:collection/:key` endpoints only ever create and act on
%% per-player rows (see put_storage_checked/6's insert, and the SUITE
%% comment on put_storage_per_player_keys_dont_collide/1) - a shared object
%% owned by whoever wrote it first, gated by the owner/public
%% read_perm/write_perm ACL. Every query below must exclude the global
%% namespace explicitly, or a global Lua row and a player's HTTP row can
%% both match the same collection+key and the result stops being the single
%% row these ACL-based case clauses assume.
-define(PLAYER_SCOPE, {player_id, is_not_nil}).

-spec get_storage(cowboy_req:req()) -> response().
get_storage(Req) ->
    guarded({asobi_error, ~"storage.not_found"}, fun() -> do_get_storage(Req) end).

-spec do_get_storage(cowboy_req:req()) -> {json, map()} | {asobi_error, asobi_error:code()}.
do_get_storage(
    #{bindings := #{~"collection" := Col, ~"key" := Key}, auth_data := #{player_id := PlayerId}} =
        _Req
) when is_binary(Col), is_binary(Key) ->
    Q = kura_query:where(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
            {key, Key}
        ),
        ?PLAYER_SCOPE
    ),
    case asobi_repo:all(Q) of
        {ok, [#{read_perm := ~"public"} = Obj]} ->
            {json, Obj};
        {ok, [#{read_perm := ~"owner", player_id := PlayerId} = Obj]} ->
            {json, Obj};
        {ok, [_]} ->
            {asobi_error, ~"storage.forbidden"};
        {ok, []} ->
            {asobi_error, ~"storage.not_found"};
        {ok, [_, _ | _] = Rows} ->
            log_storage_invariant_violation(Col, Key, length(Rows)),
            {asobi_error, ~"storage.conflict"};
        {error, Reason} ->
            log_storage_query_failed(Col, Key, Reason),
            {asobi_error, ~"storage.query_failed"}
    end;
do_get_storage(_Req) ->
    %% A binding that is not a binary is not a key this collection can hold.
    %% Answering not_found keeps the shape the unguarded version produced by
    %% querying for it and finding nothing; guarded/2 does not catch, so a bare
    %% guard would have turned that 404 into a 500.
    {asobi_error, ~"storage.not_found"}.

-spec put_storage(cowboy_req:req()) -> response().
put_storage(Req) ->
    guarded({asobi_error, ~"storage.not_found"}, fun() -> do_put_storage(Req) end).

-spec do_put_storage(cowboy_req:req()) ->
    {json, map()} | {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
do_put_storage(
    #{
        bindings := #{~"collection" := Col, ~"key" := Key},
        json := Params,
        auth_data := #{player_id := PlayerId}
    } = _Req
) when is_map(Params) ->
    Value = maps:get(~"value", Params, #{}),
    ReadPerm0 = maps:get(~"read_perm", Params, ~"owner"),
    WritePerm0 = maps:get(~"write_perm", Params, ~"owner"),
    ReadPerm = ensure_binary_perm(ReadPerm0),
    WritePerm = ensure_binary_perm(WritePerm0),
    %% M5: the generic-storage path had no per-row cap, only the 1 MiB global
    %% body cap. Mirror the save-data limit so one row cannot persist an
    %% arbitrary blob under the global ceiling.
    case data_within_limit(Value) of
        false ->
            {asobi_error, ~"storage.value_too_large"};
        true ->
            put_storage_checked(Col, Key, PlayerId, Value, ReadPerm, WritePerm)
    end;
do_put_storage(_Req) ->
    {asobi_error, ~"storage.invalid_request"}.

-spec put_storage_checked(
    dynamic(), dynamic(), dynamic(), dynamic(), binary(), binary()
) -> {json, map()} | {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
put_storage_checked(Col, Key, PlayerId, Value, ReadPerm, WritePerm) ->
    case valid_perm(ReadPerm) andalso valid_perm(WritePerm) of
        false ->
            {asobi_error, ~"storage.invalid_perm"};
        true ->
            Q = kura_query:where(
                kura_query:where(
                    kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
                    {key, Key}
                ),
                ?PLAYER_SCOPE
            ),
            case asobi_repo:all(Q) of
                {ok, [#{write_perm := ~"owner", player_id := PlayerId, version := V} = Existing]} ->
                    CS = kura_changeset:cast(
                        asobi_storage,
                        Existing,
                        #{
                            value => Value,
                            version => V + 1,
                            read_perm => ReadPerm,
                            write_perm => WritePerm
                        },
                        [value, version, read_perm, write_perm]
                    ),
                    {ok, Updated} = asobi_repo:update(CS),
                    {json, Updated};
                {ok, [#{write_perm := ~"public", version := V} = Existing]} ->
                    CS = kura_changeset:cast(
                        asobi_storage,
                        Existing,
                        #{value => Value, version => V + 1},
                        [value, version]
                    ),
                    {ok, Updated} = asobi_repo:update(CS),
                    {json, Updated};
                {ok, [_]} ->
                    {asobi_error, ~"storage.forbidden"};
                {ok, []} ->
                    CS = kura_changeset:cast(
                        asobi_storage,
                        #{},
                        #{
                            collection => Col,
                            key => Key,
                            player_id => PlayerId,
                            value => Value,
                            version => 1,
                            read_perm => ReadPerm,
                            write_perm => WritePerm
                        },
                        [collection, key, player_id, value, version, read_perm, write_perm]
                    ),
                    {ok, Created} = asobi_repo:insert(CS),
                    {json, 200, #{}, Created};
                {ok, [_, _ | _] = Rows} ->
                    log_storage_invariant_violation(Col, Key, length(Rows)),
                    {asobi_error, ~"storage.conflict"};
                {error, Reason} ->
                    log_storage_query_failed(Col, Key, Reason),
                    {asobi_error, ~"storage.query_failed"}
            end
    end.

-spec delete_storage(cowboy_req:req()) -> response().
delete_storage(Req) ->
    guarded({asobi_error, ~"storage.not_found"}, fun() -> do_delete_storage(Req) end).

-spec do_delete_storage(cowboy_req:req()) -> {json, map()} | {asobi_error, asobi_error:code()}.
do_delete_storage(
    #{bindings := #{~"collection" := Col, ~"key" := Key}, auth_data := #{player_id := PlayerId}} =
        _Req
) when is_binary(Col), is_binary(Key) ->
    Q = kura_query:where(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
            {key, Key}
        ),
        ?PLAYER_SCOPE
    ),
    case asobi_repo:all(Q) of
        {ok, [#{write_perm := ~"owner", player_id := PlayerId} = Obj]} ->
            _ = asobi_repo:delete(asobi_storage, Obj),
            {json, #{success => true}};
        {ok, [#{write_perm := ~"public"} = Obj]} ->
            _ = asobi_repo:delete(asobi_storage, Obj),
            {json, #{success => true}};
        {ok, [_]} ->
            {asobi_error, ~"storage.forbidden"};
        {ok, []} ->
            {asobi_error, ~"storage.not_found"};
        {ok, [_, _ | _] = Rows} ->
            log_storage_invariant_violation(Col, Key, length(Rows)),
            {asobi_error, ~"storage.conflict"};
        {error, Reason} ->
            log_storage_query_failed(Col, Key, Reason),
            {asobi_error, ~"storage.query_failed"}
    end;
do_delete_storage(_Req) ->
    %% Same reasoning as do_get_storage/1: a binding that is not a binary is not
    %% a key this collection can hold, and guarded/2 does not catch, so without
    %% this the guard above turns a 404 into a 500.
    {asobi_error, ~"storage.not_found"}.

-spec list_storage(cowboy_req:req()) -> response().
list_storage(Req) ->
    guarded({asobi_error, ~"storage.not_found"}, fun() -> do_list_storage(Req) end).

-spec do_list_storage(cowboy_req:req()) -> {json, map()}.
do_list_storage(
    #{bindings := #{~"collection" := Col}, qs := Qs, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(Qs), is_binary(PlayerId) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    %% Mirror get_storage's ACL: only return rows the caller is allowed
    %% to read (public objects, or owner-restricted objects they own).
    Q = kura_query:limit(
        kura_query:where(
            kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
            {'or', [
                {read_perm, ~"public"},
                {'and', [{read_perm, ~"owner"}, {player_id, PlayerId}]}
            ]}
        ),
        Limit
    ),
    {ok, Objects} = asobi_repo:all(Q),
    {json, #{objects => Objects}}.

%% --- Internal ---

%% Should be unreachable now that every query above carries ?PLAYER_SCOPE
%% (at most one player-owned row can match a given collection+key), but
%% must not crash the process if it somehow still happens - log it as the
%% invariant violation it is instead.
-spec log_storage_invariant_violation(binary(), binary(), pos_integer()) -> ok.
log_storage_invariant_violation(Col, Key, RowCount) ->
    ?LOG_ERROR(#{
        event => storage_multi_row_invariant_violation,
        collection => Col,
        key => Key,
        row_count => RowCount
    }),
    ok.

-spec log_storage_query_failed(binary(), binary(), term()) -> ok.
log_storage_query_failed(Col, Key, Reason) ->
    ?LOG_ERROR(#{
        event => storage_query_failed,
        collection => Col,
        key => Key,
        reason => Reason
    }),
    ok.

-spec data_within_limit(dynamic()) -> boolean().
data_within_limit(Data) ->
    asobi_jsonb:within_limit(Data, ?MAX_SAVE_DATA_BYTES).

-spec slots_under_cap(binary()) -> boolean().
slots_under_cap(PlayerId) ->
    Q = kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
    case asobi_repo:all(Q) of
        {ok, Saves} when is_list(Saves) -> length(Saves) < ?MAX_SLOTS_PER_PLAYER;
        _ -> false
    end.

-spec valid_perm(binary()) -> boolean().
valid_perm(P) -> lists:member(P, ?VALID_PERMS).

-spec ensure_binary_perm(term()) -> binary().
ensure_binary_perm(B) when is_binary(B) -> B;
ensure_binary_perm(_) -> ~"invalid".
