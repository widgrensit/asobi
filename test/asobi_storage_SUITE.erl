-module(asobi_storage_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    %% Cloud saves
    list_saves_empty/1,
    create_save/1,
    get_save/1,
    update_save/1,
    save_version_conflict/1,
    %% Generic storage
    put_storage/1,
    put_storage_rejects_oversized_value/1,
    get_storage/1,
    list_storage/1,
    list_storage_filters_owner_perm/1,
    delete_storage/1,
    storage_owner_permission/1,
    put_storage_per_player_keys_dont_collide/1
]).

all() -> [{group, cloud_saves}, {group, generic_storage}].

groups() ->
    [
        {cloud_saves, [sequence], [
            list_saves_empty, create_save, get_save, update_save, save_version_conflict
        ]},
        {generic_storage, [sequence], [
            put_storage,
            put_storage_rejects_oversized_value,
            get_storage,
            list_storage,
            list_storage_filters_owner_perm,
            delete_storage,
            storage_owner_permission,
            put_storage_per_player_keys_dont_collide
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"storage_p1"),
    U2 = asobi_test_helpers:unique_username(~"storage_p2"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    B2 = nova_test:json(R2),
    #{~"player_id" := P1Id, ~"access_token" := P1Token} = B1,
    #{~"access_token" := P2Token} = B2,
    [
        {player1_id, P1Id},
        {player1_token, P1Token},
        {player2_token, P2Token}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    {Key, Token} = lists:keyfind(Key, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

%% --- Cloud Saves ---

list_saves_empty(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/saves",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"saves" := []}, Resp),
    Config.

create_save(Config) ->
    {ok, Resp} = nova_test:put(
        "/api/v1/saves/slot1",
        #{
            headers => auth(Config, player1),
            json => #{~"data" => #{~"level" => 5, ~"items" => [~"sword"]}}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"version" := 1, ~"slot" := ~"slot1"}, Body),
    Config.

get_save(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/saves/slot1",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"data" := #{~"level" := 5}}, Body),
    Config.

update_save(Config) ->
    {ok, Resp} = nova_test:put(
        "/api/v1/saves/slot1",
        #{
            headers => auth(Config, player1),
            json => #{~"data" => #{~"level" => 10}, ~"version" => 1}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"version" := 2}, Body),
    Config.

save_version_conflict(Config) ->
    {ok, Resp} = nova_test:put(
        "/api/v1/saves/slot1",
        #{
            headers => auth(Config, player1),
            json => #{~"data" => #{~"level" => 99}, ~"version" => 1}
        },
        Config
    ),
    ?assertStatus(409, Resp),
    Config.

%% --- Generic Storage ---

put_storage(Config) ->
    {ok, Resp} = nova_test:put(
        "/api/v1/storage/settings/theme",
        #{
            headers => auth(Config, player1),
            json => #{~"value" => #{~"color" => ~"dark"}}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"version" := 1, ~"collection" := ~"settings"}, Body),
    Config.

%% M5 (#169/#170): the generic-storage path now mirrors the save-data cap.
%% The 413 is returned before any DB query, so this exercises the cap itself.
put_storage_rejects_oversized_value(Config) ->
    Big = binary:copy(~"x", 300000),
    {ok, Resp} = nova_test:put(
        "/api/v1/storage/settings/huge",
        #{
            headers => auth(Config, player1),
            json => #{~"value" => #{~"blob" => Big}}
        },
        Config
    ),
    ?assertStatus(413, Resp),
    ?assertMatch(#{~"error" := ~"storage_value_too_large"}, nova_test:json(Resp)),
    Config.

get_storage(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/storage/settings/theme",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    Body = nova_test:json(Resp),
    ?assertMatch(#{~"value" := #{~"color" := ~"dark"}}, Body),
    Config.

list_storage(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/storage/settings",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"objects" := Objects} = nova_test:json(Resp),
    true = is_list(Objects),
    ?assert(length(Objects) >= 1),
    Config.

%% Regression for F-4: list_storage must filter by read_perm. Player1's
%% owner-restricted object must be invisible to player2 even when listing
%% the same collection.
list_storage_filters_owner_perm(Config) ->
    %% Unique collection/key per run so the asserts aren't polluted by
    %% leftover rows from previous test runs (the storage table persists
    %% across runs).
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Col = <<"private_listing_", Suffix/binary>>,
    Key = <<"p1_secret_", Suffix/binary>>,
    {ok, PutResp} = nova_test:put(
        binary_to_list(<<"/api/v1/storage/", Col/binary, "/", Key/binary>>),
        #{
            headers => auth(Config, player1),
            json => #{~"value" => #{~"data" => ~"player1_only"}}
        },
        Config
    ),
    ?assertStatus(200, PutResp),
    {ok, P1Resp} = nova_test:get(
        binary_to_list(<<"/api/v1/storage/", Col/binary>>),
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, P1Resp),
    #{~"objects" := P1ObjectsRaw} = nova_test:json(P1Resp),
    P1Objects = ensure_list(P1ObjectsRaw),
    ?assert(lists:any(fun(O) -> object_has_key(O, Key) end, P1Objects)),
    {ok, P2Resp} = nova_test:get(
        binary_to_list(<<"/api/v1/storage/", Col/binary>>),
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(200, P2Resp),
    #{~"objects" := P2ObjectsRaw} = nova_test:json(P2Resp),
    P2Objects = ensure_list(P2ObjectsRaw),
    %% Either empty list or no objects bearing the key — but never the
    %% private one.
    ?assertNot(lists:any(fun(O) -> object_has_key(O, Key) end, P2Objects)),
    Config.

-spec ensure_list(dynamic()) -> [dynamic()].
ensure_list(L) when is_list(L) -> L.

-spec object_has_key(dynamic(), binary()) -> boolean().
object_has_key(#{~"key" := K}, K) -> true;
object_has_key(_, _) -> false.

delete_storage(Config) ->
    {ok, Resp} = nova_test:delete(
        "/api/v1/storage/settings/theme",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    {ok, Resp2} = nova_test:get(
        "/api/v1/storage/settings/theme",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(404, Resp2),
    Config.

storage_owner_permission(Config) ->
    {ok, _} = nova_test:put(
        "/api/v1/storage/private/secret",
        #{
            headers => auth(Config, player1),
            json => #{~"value" => #{~"data" => ~"private"}}
        },
        Config
    ),
    {ok, Resp} = nova_test:get(
        "/api/v1/storage/private/secret",
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(403, Resp),
    Config.

%% Regression for https://github.com/widgrensit/asobi/issues/122:
%% the storage unique index used to be `(collection, key)` without
%% `player_id`, so two players writing the same (collection, key) with
%% different player_id values would silently collide on insert. The
%% HTTP /storage path is single-row-per-(collection, key) by design
%% (it uses ownership-perm semantics), so this test exercises the
%% schema directly via kura — that's the path `asobi_lua_api`'s
%% `game.storage.player_set` follows for per-player rows.
put_storage_per_player_keys_dont_collide(Config) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Col = <<"shared_", Suffix/binary>>,
    Key = <<"counter_", Suffix/binary>>,
    {player1_id, P1} = lists:keyfind(player1_id, 1, Config),
    %% Register a fresh second player whose id we can capture here.
    U2 = asobi_test_helpers:unique_username(~"index_collide_p2"),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := P2} = nova_test:json(R2),
    Insert = fun(PlayerId, Value) ->
        Params = #{
            collection => Col,
            key => Key,
            player_id => PlayerId,
            value => Value,
            version => 1,
            read_perm => ~"owner",
            write_perm => ~"owner",
            updated_at => calendar:universal_time()
        },
        CS = kura_changeset:cast(asobi_storage, #{}, Params, maps:keys(Params)),
        asobi_repo:insert(CS)
    end,
    ?assertMatch({ok, _}, Insert(P1, #{~"n" => 1})),
    ?assertMatch({ok, _}, Insert(P2, #{~"n" => 2})),
    %% Read each back via a player-scoped query and verify isolation.
    Read = fun(PlayerId) ->
        Q0 = kura_query:from(asobi_storage),
        Q1 = kura_query:where(Q0, {collection, Col}),
        Q2 = kura_query:where(Q1, {key, Key}),
        Q3 = kura_query:where(Q2, {player_id, PlayerId}),
        {ok, [Doc]} = asobi_repo:all(Q3),
        maps:get(value, Doc)
    end,
    ?assertEqual(#{~"n" => 1}, Read(P1)),
    ?assertEqual(#{~"n" => 2}, Read(P2)),
    Config.
