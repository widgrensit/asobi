-module(asobi_lua_storage_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([
    set_then_get/1,
    set_twice_updates_the_row/1,
    player_set_then_player_get/1,
    global_write_does_not_clobber_player_row/1,
    player_write_does_not_clobber_global_row/1
]).

all() ->
    [
        set_then_get,
        set_twice_updates_the_row,
        player_set_then_player_get,
        global_write_does_not_clobber_player_row,
        player_write_does_not_clobber_global_row
    ].

%% Real Postgres, no meck: `game.storage.*` is the one bridge path whose
%% mocked coverage encoded a wrong belief about the driver (#296 -
%% update_all/2 rejected a raw jsonb map, so a second set never landed and
%% the mock happily agreed). Everything here goes through asobi_repo to the
%% database `docker compose up -d` provides.
init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    {ok, LibDir} = safe_lib_dir(),
    Script = filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", "test_match.lua"])
    ),
    [{script, Script} | Config0].

end_per_suite(_Config) ->
    ok.

%% --- Cases ---

set_then_get(Config) ->
    St = install_api(Config),
    Collection = asobi_test_helpers:unique_id(~"settings"),
    {[true], _} = eval(
        [
            "local w = game.storage.set('",
            Collection,
            "', 'theme', { mode = 'dark', size = 14 })\n",
            "local r = game.storage.get('",
            Collection,
            "', 'theme')\n",
            "return w.ok ~= nil and r.ok.mode == 'dark' and r.ok.size == 14\n"
        ],
        St
    ),
    [Row] = storage_rows(Collection, ~"theme"),
    ?assertEqual(#{~"mode" => ~"dark", ~"size" => 14}, maps:get(value, Row)),
    ?assertEqual(undefined, maps:get(player_id, Row, undefined)).

%% #296: the second write is the one that used to be silently dropped.
set_twice_updates_the_row(Config) ->
    St = install_api(Config),
    Collection = asobi_test_helpers:unique_id(~"saves"),
    {[true], St1} = eval(
        ["return game.storage.set('", Collection, "', 'slot1', { n = 1 }).ok ~= nil\n"], St
    ),
    {[true], _} = eval(
        [
            "local w = game.storage.set('",
            Collection,
            "', 'slot1', { n = 2 })\n",
            "local r = game.storage.get('",
            Collection,
            "', 'slot1')\n",
            "return w.ok ~= nil and r.ok.n == 2\n"
        ],
        St1
    ),
    [Row] = storage_rows(Collection, ~"slot1"),
    ?assertEqual(#{~"n" => 2}, maps:get(value, Row)),
    ?assertEqual(2, maps:get(version, Row)).

player_set_then_player_get(Config) ->
    St = install_api(Config),
    Collection = asobi_test_helpers:unique_id(~"inventory"),
    PlayerId = create_player(),
    {[true], _} = eval(
        [
            "local w = game.storage.player_set('",
            PlayerId,
            "', '",
            Collection,
            "', 'gold', 50)\n",
            "local r = game.storage.player_get('",
            PlayerId,
            "', '",
            Collection,
            "', 'gold')\n",
            "return w.ok ~= nil and r.ok == 50\n"
        ],
        St
    ),
    [Row] = storage_rows(Collection, ~"gold"),
    ?assertEqual(PlayerId, maps:get(player_id, Row)).

%% #296 follow-up: global rows (player_id IS NULL) and player rows are
%% separate namespaces sharing a collection+key. A write to one must never
%% match the other's row - the class of bug an unscoped UPDATE reintroduces.
%% The player row is written first on purpose: a lookup that forgets its
%% `player_id IS NULL` predicate resolves to that row, so the global write
%% below updates it instead of inserting its own.
global_write_does_not_clobber_player_row(Config) ->
    St = install_api(Config),
    Collection = asobi_test_helpers:unique_id(~"save"),
    PlayerId = create_player(),
    {[true], St1} = eval(
        [
            "return game.storage.player_set('",
            PlayerId,
            "', '",
            Collection,
            "', 'flag', { owner = 'player' }).ok ~= nil\n"
        ],
        St
    ),
    {[true], _} = eval(
        [
            "local w = game.storage.set('",
            Collection,
            "', 'flag', { owner = 'global' })\n",
            "local g = game.storage.get('",
            Collection,
            "', 'flag')\n",
            "local p = game.storage.player_get('",
            PlayerId,
            "', '",
            Collection,
            "', 'flag')\n",
            "return w.ok ~= nil and g.ok.owner == 'global' and p.ok.owner == 'player'\n"
        ],
        St1
    ),
    ?assertEqual(2, length(storage_rows(Collection, ~"flag"))).

%% Mirror image, and the update path: the second player_set updates an
%% existing row. An update scoped only by collection+key (the bulk
%% update_all/2 #296 replaced) rewrites the global row too.
player_write_does_not_clobber_global_row(Config) ->
    St = install_api(Config),
    Collection = asobi_test_helpers:unique_id(~"save"),
    PlayerId = create_player(),
    {[true], St1} = eval(
        [
            "local g = game.storage.set('",
            Collection,
            "', 'flag', { owner = 'global' })\n",
            "local p = game.storage.player_set('",
            PlayerId,
            "', '",
            Collection,
            "', 'flag', { owner = 'player' })\n",
            "return g.ok ~= nil and p.ok ~= nil\n"
        ],
        St
    ),
    {[true], _} = eval(
        [
            "local w = game.storage.player_set('",
            PlayerId,
            "', '",
            Collection,
            "', 'flag', { owner = 'player', n = 2 })\n",
            "local g = game.storage.get('",
            Collection,
            "', 'flag')\n",
            "local p = game.storage.player_get('",
            PlayerId,
            "', '",
            Collection,
            "', 'flag')\n",
            "return w.ok ~= nil and g.ok.owner == 'global' and g.ok.n == nil\n",
            "  and p.ok.owner == 'player' and p.ok.n == 2\n"
        ],
        St1
    ),
    ?assertEqual(2, length(storage_rows(Collection, ~"flag"))).

%% --- Helpers ---

install_api(Config) ->
    {ok, St0} = asobi_lua_loader:new(?config(script, Config)),
    asobi_lua_api:install(#{match_id => ~"storage-suite", match_pid => self()}, St0).

eval(Code, St) ->
    {ok, Results, St1} = luerl:do(unicode:characters_to_list(Code), St),
    {Results, St1}.

storage_rows(Collection, Key) ->
    Q0 = kura_query:from(asobi_storage),
    Q1 = kura_query:where(Q0, {collection, Collection}),
    {ok, Rows} = asobi_repo:all(kura_query:where(Q1, {key, Key})),
    Rows.

create_player() ->
    Now = calendar:universal_time(),
    Params = #{
        username => asobi_test_helpers:unique_id(~"p"), inserted_at => Now, updated_at => Now
    },
    CS = kura_changeset:cast(asobi_player, #{}, Params, maps:keys(Params)),
    {ok, #{id := Id}} = asobi_repo:insert(CS),
    Id.

safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.
