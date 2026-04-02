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
    get_storage/1,
    list_storage/1,
    delete_storage/1,
    storage_owner_permission/1
]).

all() -> [{group, cloud_saves}, {group, generic_storage}].

groups() ->
    [
        {cloud_saves, [sequence], [
            list_saves_empty, create_save, get_save, update_save, save_version_conflict
        ]},
        {generic_storage, [sequence], [
            put_storage, get_storage, list_storage, delete_storage, storage_owner_permission
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
    #{~"player_id" := P1Id, ~"session_token" := P1Token} = B1,
    #{~"session_token" := P2Token} = B2,
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
