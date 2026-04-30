-module(asobi_storage_controller).

-export([list_saves/1, get_save/1, put_save/1]).
-export([get_storage/1, put_storage/1, delete_storage/1, list_storage/1]).

%% F-13: cap cloud-save body size and per-player slot count so a single
%% authenticated user can't exhaust postgres jsonb storage.
-define(MAX_SAVE_DATA_BYTES, 262144).
-define(MAX_SLOTS_PER_PLAYER, 10).

%% F-14: only these literals are honoured by get_storage/put_storage; any
%% other value made the row self-DoS unreachable. Whitelist + reject.
-define(VALID_PERMS, [~"public", ~"owner"]).

%% --- Cloud Saves ---

-spec list_saves(cowboy_req:req()) -> {json, map()}.
list_saves(#{auth_data := #{player_id := PlayerId}} = _Req) ->
    Q = kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
    {ok, Saves} = asobi_repo:all(Q),
    {json, #{saves => [maps:with([slot, version, updated_at], S) || S <- Saves]}}.

-spec get_save(cowboy_req:req()) -> {json, map()} | {status, integer()}.
get_save(#{bindings := #{~"slot" := Slot}, auth_data := #{player_id := PlayerId}} = _Req) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
        {slot, Slot}
    ),
    case asobi_repo:all(Q) of
        {ok, [Save]} -> {json, Save};
        {ok, []} -> {status, 404}
    end.

-spec put_save(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
put_save(
    #{bindings := #{~"slot" := Slot}, json := Params, auth_data := #{player_id := PlayerId}} = _Req
) when is_map(Params), is_binary(PlayerId) ->
    Data = maps:get(~"data", Params, #{}),
    case data_within_limit(Data) of
        false ->
            {json, 413, #{}, #{error => ~"save_data_too_large"}};
        true ->
            ClientVersion = maps:get(~"version", Params, undefined),
            Q = kura_query:where(
                kura_query:where(kura_query:from(asobi_cloud_save), {player_id, PlayerId}),
                {slot, Slot}
            ),
            case asobi_repo:all(Q) of
                {ok, [#{version := V}]} when ClientVersion =/= undefined, ClientVersion =/= V ->
                    {json, 409, #{}, #{error => ~"version_conflict", current_version => V}};
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
                            {json, 409, #{}, #{error => ~"slot_limit_reached"}};
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

-spec get_storage(cowboy_req:req()) -> {json, map()} | {status, integer()}.
get_storage(
    #{bindings := #{~"collection" := Col, ~"key" := Key}, auth_data := #{player_id := PlayerId}} =
        _Req
) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
        {key, Key}
    ),
    case asobi_repo:all(Q) of
        {ok, [#{read_perm := ~"public"} = Obj]} -> {json, Obj};
        {ok, [#{read_perm := ~"owner", player_id := PlayerId} = Obj]} -> {json, Obj};
        {ok, [_]} -> {status, 403};
        {ok, []} -> {status, 404}
    end.

-spec put_storage(cowboy_req:req()) ->
    {json, map()} | {json, integer(), map(), map()} | {status, integer()}.
put_storage(
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
    case valid_perm(ReadPerm) andalso valid_perm(WritePerm) of
        false ->
            {json, 400, #{}, #{error => ~"invalid_perm"}};
        true ->
            Q = kura_query:where(
                kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
                {key, Key}
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
                    {status, 403};
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
                    {json, 200, #{}, Created}
            end
    end.

-spec delete_storage(cowboy_req:req()) -> {json, map()} | {status, integer()}.
delete_storage(
    #{bindings := #{~"collection" := Col, ~"key" := Key}, auth_data := #{player_id := PlayerId}} =
        _Req
) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
        {key, Key}
    ),
    case asobi_repo:all(Q) of
        {ok, [#{write_perm := ~"owner", player_id := PlayerId} = Obj]} ->
            _ = asobi_repo:delete(asobi_storage, Obj),
            {json, #{success => true}};
        {ok, [#{write_perm := ~"public"} = Obj]} ->
            _ = asobi_repo:delete(asobi_storage, Obj),
            {json, #{success => true}};
        {ok, [_]} ->
            {status, 403};
        {ok, []} ->
            {status, 404}
    end.

-spec list_storage(cowboy_req:req()) -> {json, map()}.
list_storage(
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

-spec data_within_limit(dynamic()) -> boolean().
data_within_limit(Data) ->
    try iolist_size(json:encode(Data)) =< ?MAX_SAVE_DATA_BYTES of
        Result -> Result
    catch
        _:_ -> false
    end.

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
