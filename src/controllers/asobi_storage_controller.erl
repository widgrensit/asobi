-module(asobi_storage_controller).

-export([list_saves/1, get_save/1, put_save/1]).
-export([get_storage/1, put_storage/1, delete_storage/1, list_storage/1]).

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
) ->
    Data = maps:get(~"data", Params, #{}),
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
            CS = kura_changeset:cast(
                asobi_cloud_save,
                #{},
                #{player_id => PlayerId, slot => Slot, data => Data, version => 1},
                [player_id, slot, data, version]
            ),
            {ok, Created} = asobi_repo:insert(CS),
            {json, 200, #{}, Created}
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
) ->
    Value = maps:get(~"value", Params, #{}),
    ReadPerm = maps:get(~"read_perm", Params, ~"owner"),
    WritePerm = maps:get(~"write_perm", Params, ~"owner"),
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
        {key, Key}
    ),
    case asobi_repo:all(Q) of
        {ok, [#{write_perm := ~"owner", player_id := PlayerId, version := V} = Existing]} ->
            CS = kura_changeset:cast(
                asobi_storage,
                Existing,
                #{value => Value, version => V + 1, read_perm => ReadPerm, write_perm => WritePerm},
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
list_storage(#{bindings := #{~"collection" := Col}, qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"50")),
    Q = kura_query:limit(
        kura_query:where(kura_query:from(asobi_storage), {collection, Col}),
        Limit
    ),
    {ok, Objects} = asobi_repo:all(Q),
    {json, #{objects => Objects}}.
