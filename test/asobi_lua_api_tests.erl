-module(asobi_lua_api_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(
        filename:join([LibDir, "test", "fixtures", "lua", Name])
    ).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- Tests ---

api_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"game.id returns binary", fun game_id/0},
        {"game.broadcast forwards to match server", fun game_broadcast/0},
        {"game.send forwards to presence", fun game_send/0},
        {"game.send preserves a plain string message", fun game_send_string/0},
        {"game.economy.grant calls engine", fun game_economy_grant/0},
        {"game.economy.debit calls engine", fun game_economy_debit/0},
        {"game.economy.balance returns wallets", fun game_economy_balance/0},
        {"game.economy.purchase returns ok", fun game_economy_purchase/0},
        {"game.leaderboard.submit calls server", fun game_lb_submit/0},
        {"game.leaderboard.top returns entries", fun game_lb_top/0},
        {"game.leaderboard.rank returns rank", fun game_lb_rank/0},
        {"game.leaderboard.around returns entries", fun game_lb_around/0},
        {"game.notify sends notification", fun game_notify/0},
        {"game.notify_many forwards ids", fun game_notify_many/0},
        {"game.storage.get reads doc", fun game_storage_get/0},
        {"game.storage.set writes doc", fun game_storage_set/0},
        {"game.storage.player_get reads player doc", fun game_storage_player_get/0},
        {"game.storage.player_set writes player doc", fun game_storage_player_set/0},
        {"game.storage.set upserts on a second write (asobi#296)",
            fun game_storage_set_upserts_second_write/0},
        {"game.storage.set scopes global vs player rows independently (asobi#296 follow-up)",
            fun game_storage_isolates_global_and_player_writes/0},
        {"game.chat.send sends message", fun game_chat_send/0},
        {"api installed in match init", fun api_in_match_init/0},
        {"game api callable from lua script", fun game_api_from_script/0},
        {"game.spatial.query_radius returns results", fun spatial_query_radius/0},
        {"game.spatial.query_radius opts filter by type", fun spatial_query_radius_with_opts/0},
        {"game.spatial.nearest returns closest", fun spatial_nearest/0},
        {"game.spatial.nearest opts forwards max_results", fun spatial_nearest_with_opts/0},
        {"game.spatial.query_radius accepts an empty entities table",
            fun spatial_query_radius_empty_entities/0},
        {"game.spatial.nearest accepts an empty entities table",
            fun spatial_nearest_empty_entities/0},
        {"game.spatial.in_range checks distance", fun spatial_in_range/0},
        {"game.spatial.distance returns distance", fun spatial_distance/0},
        {"game.zone.spawn calls zone", fun zone_spawn/0},
        {"game.zone.spawn with overrides forwards them", fun zone_spawn_with_overrides/0},
        {"game.zone.spawn with a known template_id returns true", fun zone_spawn_known_template/0},
        {"game.zone.spawn with a typo'd template_id returns false, not true",
            fun zone_spawn_unknown_template/0},
        {"game.zone.spawn with overrides and a typo'd template_id returns false",
            fun zone_spawn_unknown_template_with_overrides/0},
        {"game.zone.despawn calls zone", fun zone_despawn/0},
        {"game.spatial.query_radius zone-based", fun spatial_zone_query_radius/0},
        {"game.spatial.query_rect zone-based", fun spatial_zone_query_rect/0},
        {"game.spatial.query_rect errors without zone", fun spatial_query_rect_no_zone/0},
        {"game.terrain.get_chunk returns data", fun terrain_get_chunk/0},
        {"game.terrain.get_chunk errors without store", fun terrain_get_chunk_no_store/0},
        {"game.terrain.preload forwards coords", fun terrain_preload/0},
        {"to_storage_value preserves scalars", fun to_storage_value_scalars/0},
        {"to_storage_value preserves maps", fun to_storage_value_maps/0},
        {"to_storage_value preserves arrays", fun to_storage_value_arrays/0},
        {"to_storage_value preserves nested structures", fun to_storage_value_nested/0},
        {"player_set forwards a scalar number", fun storage_player_set_scalar/0},
        {"player_set forwards a binary", fun storage_player_set_binary/0},
        {"player_set forwards an array", fun storage_player_set_array/0},
        {"probe ctx: game.economy.grant is inert", fun probe_economy_grant_inert/0},
        {"probe ctx: game.economy.debit is inert", fun probe_economy_debit_inert/0},
        {"probe ctx: game.economy.purchase is inert", fun probe_economy_purchase_inert/0},
        {"probe ctx: game.economy.balance still runs for real", fun probe_economy_balance_live/0},
        {"probe ctx: game.broadcast is inert", fun probe_broadcast_inert/0},
        {"probe ctx: game.send is inert", fun probe_send_inert/0},
        {"probe ctx: game.leaderboard.submit is inert", fun probe_lb_submit_inert/0},
        {"probe ctx: game.leaderboard.top still runs for real", fun probe_lb_top_live/0},
        {"probe ctx: game.notify is inert", fun probe_notify_inert/0},
        {"probe ctx: game.notify_many is inert", fun probe_notify_many_inert/0},
        {"probe ctx: game.storage.set is inert", fun probe_storage_set_inert/0},
        {"probe ctx: game.storage.get still runs for real", fun probe_storage_get_live/0},
        {"probe ctx: game.chat.send is inert", fun probe_chat_send_inert/0},
        {"install creates exactly the reserved namespaces", fun install_creates_reserved/0},
        {"probe install creates the same namespaces", fun probe_install_creates_reserved/0}
    ]}.

setup() ->
    meck:new(asobi_id, [no_link]),
    meck:expect(asobi_id, generate, fun() -> ~"test-uuid-v7" end),
    meck:new(asobi_match_server, [no_link]),
    meck:expect(asobi_match_server, broadcast_event, fun(_, _, _) -> ok end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_, _) -> ok end),
    meck:new(asobi_economy, [no_link]),
    meck:expect(asobi_economy, grant, fun(_, _, _, _) ->
        {ok, #{~"currency" => ~"gold", ~"balance" => 500}}
    end),
    meck:expect(asobi_economy, debit, fun(_, _, _, _) ->
        {ok, #{~"currency" => ~"gold", ~"balance" => 450}}
    end),
    meck:expect(asobi_economy, get_wallets, fun(_) ->
        {ok, [#{currency => ~"gold", balance => 500}]}
    end),
    meck:expect(asobi_economy, purchase, fun(_, _) ->
        {ok, #{~"item" => ~"sword"}}
    end),
    meck:new(asobi_leaderboard_server, [no_link]),
    meck:expect(asobi_leaderboard_server, submit, fun(_, _, _) -> ok end),
    meck:expect(asobi_leaderboard_server, top, fun(_, _) ->
        [{~"p1", 100, 1}, {~"p2", 80, 2}]
    end),
    meck:expect(asobi_leaderboard_server, rank, fun(_, _) -> {ok, 3} end),
    meck:expect(asobi_leaderboard_server, around, fun(_, _, _) ->
        [{~"p1", 100, 1}]
    end),
    meck:new(asobi_notify, [no_link]),
    meck:expect(asobi_notify, send, fun(_, _, _, _) -> {ok, #{}} end),
    meck:expect(asobi_notify, send_many, fun(Ids, _, _, _) -> Ids end),
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, all, fun(_) -> {ok, []} end),
    meck:expect(asobi_repo, insert, fun(_) -> {ok, #{value => #{}}} end),
    meck:expect(asobi_repo, insert, fun(_, _) -> {ok, #{value => #{}}} end),
    meck:expect(asobi_repo, update, fun(_) -> {ok, #{value => #{}}} end),
    meck:new(asobi_chat_channel, [no_link]),
    meck:expect(asobi_chat_channel, send_message, fun(_, _, _) -> ok end),
    meck:new(asobi_zone, [no_link]),
    meck:expect(asobi_zone, spawn_entity, fun(_, _, _) -> ok end),
    meck:expect(asobi_zone, spawn_entity, fun(_, _, _, _) -> ok end),
    meck:expect(asobi_zone, despawn_entity, fun(_, _) -> ok end),
    meck:expect(asobi_zone, query_radius, fun(_, _, _) ->
        [{~"e1", {5.0, 5.0}}, {~"e2", {3.0, 4.0}}]
    end),
    meck:expect(asobi_zone, query_rect, fun(_, _, _) ->
        [{~"e1", {5.0, 5.0}}]
    end),
    meck:new(asobi_terrain_store, [no_link]),
    meck:expect(asobi_terrain_store, get_chunk, fun(_, _) ->
        {ok, #{~"tiles" => [1, 2, 3]}}
    end),
    meck:expect(asobi_terrain_store, preload_chunks, fun(_, _) -> ok end),
    ok.

cleanup(_) ->
    meck:unload([
        asobi_id,
        asobi_match_server,
        asobi_presence,
        asobi_economy,
        asobi_leaderboard_server,
        asobi_notify,
        asobi_repo,
        asobi_chat_channel,
        asobi_zone,
        asobi_terrain_store
    ]).

%% --- Test cases ---

game_id() ->
    St = install_api(),
    {ok, [Id | _], _} = asobi_lua_loader:call([~"game", ~"id"], [], St),
    ?assertEqual(~"test-uuid-v7", Id).

game_broadcast() ->
    St = install_api(),
    Code = "return game.broadcast('hello', { msg = 'world' })",
    {ok, [true | _], _} = eval(Code, St),
    %% broadcast uses the live match_pid (self() in the test fixture),
    %% not the match_id binary.
    ?assert(meck:called(asobi_match_server, broadcast_event, [self(), ~"hello", '_'])).

game_send() ->
    St = install_api(),
    Code = "return game.send('p1', { kind = 'hello' })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_presence, send, [~"p1", '_'])).

%% A plain string message must reach the player as-is, not silently
%% collapse to an empty map (asobi#233 - game.send's message previously
%% went through to_map/1, which drops anything that isn't a table).
game_send_string() ->
    St = install_api(),
    Code = "return game.send('p1', 'jij bent speler nummer 3')",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(
        meck:called(asobi_presence, send, [~"p1", {game_message, ~"jij bent speler nummer 3"}])
    ).

game_economy_balance() ->
    St = install_api(),
    Code = "local r = game.economy.balance('p1')\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_economy, get_wallets, [~"p1"])).

game_economy_purchase() ->
    St = install_api(),
    Code = "local r = game.economy.purchase('p1', 'sword')\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_economy, purchase, [~"p1", ~"sword"])).

game_lb_top() ->
    St = install_api(),
    Code =
        "local r = game.leaderboard.top('kills', 10)\n"
        "return #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_leaderboard_server, top, [~"kills", 10])).

game_lb_rank() ->
    St = install_api(),
    Code = "local r = game.leaderboard.rank('kills', 'p1')\nreturn r.ok",
    {ok, [Rank | _], _} = eval(Code, St),
    ?assertEqual(3, trunc(Rank)).

game_lb_around() ->
    St = install_api(),
    Code = "local r = game.leaderboard.around('kills', 'p1', 5)\nreturn #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)).

game_notify_many() ->
    St = install_api(),
    Code = "local r = game.notify_many({'p1','p2'}, 'reward', 'gg')\nreturn #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_notify, send_many, '_')).

game_storage_get() ->
    St = install_api(),
    Code =
        "local r = game.storage.get('settings', 'theme')\n"
        "return r.error ~= nil",
    %% mocked asobi_repo:all returns {ok, []} which the bridge treats as
    %% not_found; the wrap_result helper turns that into {error, ...}
    {ok, [true | _], _} = eval(Code, St).

game_storage_set() ->
    St = install_api(),
    Code =
        "local r = game.storage.set('settings', 'theme', { value = 'dark' })\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St).

game_storage_player_get() ->
    St = install_api(),
    Code = "local r = game.storage.player_get('p1', 'inventory', 'gold')\nreturn r.error ~= nil",
    {ok, [true | _], _} = eval(Code, St).

game_storage_player_set() ->
    St = install_api(),
    Code =
        "local r = game.storage.player_set('p1', 'inventory', 'gold', { count = 50 })\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St).

%% asobi/#296: a second game.storage.set for the same key used to hand
%% update_all/2 a raw jsonb map, which a real driver rejects with
%% `{error, badarg}` - the row's value never changed after the first
%% write. The fix routes updates through asobi_repo:update/1 on a
%% changeset fetched by identity instead, so the fake update/1 here just
%% round-trips the cast value into the fake row, proving the second
%% write actually lands.
game_storage_set_upserts_second_write() ->
    St = install_api(),
    erase(storage_probe_value),
    meck:expect(asobi_repo, all, fun(_Q) ->
        case get(storage_probe_value) of
            undefined -> {ok, []};
            V -> {ok, [#{id => ~"row-1", value => V, version => 1}]}
        end
    end),
    meck:expect(asobi_repo, insert, fun(CS) ->
        Value = kura_changeset:get_change(CS, value),
        put(storage_probe_value, Value),
        {ok, #{value => Value}}
    end),
    meck:expect(asobi_repo, update, fun(CS) ->
        Value = kura_changeset:get_change(CS, value),
        put(storage_probe_value, Value),
        {ok, #{value => Value}}
    end),
    Code1 = "local a = game.storage.set('t', 'probe', { n = 1 })\nreturn a.ok ~= nil",
    {ok, [true | _], _} = eval(Code1, St),
    Code2 =
        "local b = game.storage.set('t', 'probe', { n = 2 })\n"
        "local c = game.storage.get('t', 'probe')\n"
        "return b.ok ~= nil and c.ok.n == 2",
    {ok, [true | _], _} = eval(Code2, St).

%% widgrensit/asobi#296 follow-up (CRITICAL): storage_update/2 must scope
%% its write to the exact row storage_find/3 resolved by primary key, not
%% a bare collection+key match with no player_id predicate - otherwise a
%% global game.storage.set can overwrite a player's row (or vice versa).
%%
%% The fake asobi_repo:all/1 below derives its lookup key from the
%% *actual* WHERE conditions the query carries (query_scope_key/1 only
%% matches a query with exactly `{player_id, is_nil}` or
%% `{player_id, PlayerId}` as its third condition) - it does not accept
%% any query shape. Against the pre-fix code path (no player_id
%% predicate on the global branch) this crashes with a function_clause
%% instead of silently matching the wrong row, so the test fails loudly
%% without the fix and passes with it.
game_storage_isolates_global_and_player_writes() ->
    St = install_api(),
    erase(storage_probe_rows),
    put(storage_probe_rows, #{}),
    meck:expect(asobi_repo, all, fun(Q) ->
        Scope = query_scope_key(Q),
        Rows = get_storage_rows(),
        case maps:get(Scope, Rows, undefined) of
            undefined -> {ok, []};
            Row -> {ok, [Row]}
        end
    end),
    meck:expect(asobi_repo, insert, fun(CS) ->
        Collection = kura_changeset:get_field(CS, collection),
        Key = kura_changeset:get_field(CS, key),
        PlayerId = kura_changeset:get_field(CS, player_id),
        Value = kura_changeset:get_field(CS, value),
        Scope = storage_scope_key(Collection, Key, PlayerId),
        Row = #{id => Scope, value => Value, version => 1},
        put_storage_rows((get_storage_rows())#{Scope => Row}),
        {ok, Row}
    end),
    meck:expect(asobi_repo, update, fun(CS) ->
        Doc = CS#kura_changeset.data,
        Scope = maps:get(id, Doc),
        Value = kura_changeset:get_field(CS, value),
        Version = kura_changeset:get_field(CS, version),
        Row = Doc#{value => Value, version => Version},
        put_storage_rows((get_storage_rows())#{Scope => Row}),
        {ok, Row}
    end),

    %% Seed a global row and a player-scoped row under the SAME
    %% collection+key. player_id is a `uuid` schema field, so use a
    %% valid 36-char UUID string rather than a bare name.
    Alice = "11111111-1111-1111-1111-111111111111",
    Code1 =
        "local g1 = game.storage.set('save', 'flag', { owner = 'global' })\n"
        "local p1 = game.storage.player_set('" ++ Alice ++
            "', 'save', 'flag', { owner = 'alice' })\n"
            "return g1.ok ~= nil and p1.ok ~= nil",
    {ok, [true | _], _} = eval(Code1, St),

    %% Writing the player's row a second time must not touch the global
    %% row.
    Code2 =
        "local p2 = game.storage.player_set('" ++ Alice ++
            "', 'save', 'flag', { owner = 'alice', n = 2 })\n"
            "local g2 = game.storage.get('save', 'flag')\n"
            "local pg2 = game.storage.player_get('" ++ Alice ++
            "', 'save', 'flag')\n"
            "return p2.ok ~= nil and g2.ok.owner == 'global' and pg2.ok.owner == 'alice' and pg2.ok.n == 2",
    {ok, [true | _], _} = eval(Code2, St),

    %% ...and writing the global row a second time must not touch the
    %% player's row. Both survive independent second writes.
    Code3 =
        "local g3 = game.storage.set('save', 'flag', { owner = 'global', n = 3 })\n"
        "local pg3 = game.storage.player_get('" ++ Alice ++
            "', 'save', 'flag')\n"
            "local g4 = game.storage.get('save', 'flag')\n"
            "return g3.ok ~= nil and pg3.ok.owner == 'alice' and pg3.ok.n == 2"
            " and g4.ok.owner == 'global' and g4.ok.n == 3",
    {ok, [true | _], _} = eval(Code3, St).

%% Collection/Key/PlayerId arrive as `term()` from
%% kura_changeset:get_field/2 and kura_query's untyped wheres list - keep
%% the spec honest rather than asserting a narrower type eqwalizer can't
%% verify.
-spec storage_scope_key(term(), term(), term()) -> term().
storage_scope_key(Collection, Key, undefined) -> {Collection, Key, global};
storage_scope_key(Collection, Key, PlayerId) -> {Collection, Key, PlayerId}.

-spec get_storage_rows() -> #{term() => term()}.
get_storage_rows() ->
    case get(storage_probe_rows) of
        Rows when is_map(Rows) -> Rows;
        _ -> #{}
    end.

-spec put_storage_rows(#{term() => term()}) -> ok.
put_storage_rows(Rows) ->
    put(storage_probe_rows, Rows),
    ok.

-spec query_scope_key(#kura_query{}) -> term().
query_scope_key(#kura_query{wheres = [{collection, Collection}, {key, Key}, {player_id, is_nil}]}) ->
    storage_scope_key(Collection, Key, undefined);
query_scope_key(#kura_query{wheres = [{collection, Collection}, {key, Key}, {player_id, PlayerId}]}) ->
    storage_scope_key(Collection, Key, PlayerId).

game_economy_grant() ->
    St = install_api(),
    %% Call via Lua code to get proper arg encoding
    Code = "return game.economy.grant('p1', 'gold', 100, 'reward')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_economy, grant, [~"p1", ~"gold", 100, '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_economy_debit() ->
    St = install_api(),
    Code = "return game.economy.debit('p1', 'gold', 50, 'cost')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_economy, debit, [~"p1", ~"gold", 50, '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_lb_submit() ->
    St = install_api(),
    Code = "return game.leaderboard.submit('kills', 'p1', 42)",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_leaderboard_server, submit, [~"kills", ~"p1", 42])).

game_notify() ->
    St = install_api(),
    Code = "return game.notify('p1', 'reward', 'You won!')",
    {ok, [Result | _], St1} = eval(Code, St),
    ?assert(meck:called(asobi_notify, send, [~"p1", ~"reward", ~"You won!", '_'])),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"ok", 1, Decoded)).

game_chat_send() ->
    St = install_api(),
    Code = "return game.chat.send('match_123', 'p1', 'gg')",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_chat_channel, send_message, [~"match_123", ~"p1", ~"gg"])).

api_in_match_init() ->
    Config = #{lua_script => fixture("test_match.lua"), match_id => ~"test-match-1"},
    {ok, State} = asobi_lua_match:init(Config),
    ?assert(is_map(State)),
    #{lua_state := LuaSt} = State,
    {ok, [Id | _], _} = asobi_lua_loader:call([~"game", ~"id"], [], LuaSt),
    ?assertEqual(~"test-uuid-v7", Id).

game_api_from_script() ->
    St = install_api(),
    %% Test multiple API calls from Lua
    Code =
        "local id = game.id()\n"
        "game.leaderboard.submit('test', 'p1', 99)\n"
        "return id",
    {ok, [Id | _], _} = eval(Code, St),
    ?assertEqual(~"test-uuid-v7", Id),
    ?assert(meck:called(asobi_leaderboard_server, submit, [~"test", ~"p1", 99])).

spatial_query_radius() ->
    St = install_api(),
    Code =
        "local entities = {\n"
        "  a = { x = 0.0, y = 0.0, type = 'npc' },\n"
        "  b = { x = 3.0, y = 4.0, type = 'npc' },\n"
        "  c = { x = 100.0, y = 100.0, type = 'npc' }\n"
        "}\n"
        "local results = game.spatial.query_radius(entities, 0.0, 0.0, 6.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)).

spatial_nearest() ->
    St = install_api(),
    Code =
        "local entities = {\n"
        "  a = { x = 10.0, y = 10.0, type = 'npc' },\n"
        "  b = { x = 1.0, y = 1.0, type = 'npc' }\n"
        "}\n"
        "local results = game.spatial.nearest(entities, 0.0, 0.0, 1)\n"
        "return results[1].id",
    {ok, [Id | _], _} = eval(Code, St),
    ?assertEqual(~"b", Id).

spatial_in_range() ->
    St = install_api(),
    Code =
        "local a = { x = 0.0, y = 0.0 }\n"
        "local b = { x = 3.0, y = 4.0 }\n"
        "return game.spatial.in_range(a, b, 5.0)",
    {ok, [true | _], _} = eval(Code, St).

spatial_distance() ->
    St = install_api(),
    Code =
        "local a = { x = 0.0, y = 0.0 }\n"
        "local b = { x = 3.0, y = 4.0 }\n"
        "return game.spatial.distance(a, b)",
    {ok, [D | _], _} = eval(Code, St),
    ?assert(abs(D - 5.0) < 0.001).

zone_spawn() ->
    St = install_api_with_zone(),
    Code = "return game.zone.spawn('goblin', 10.0, 20.0)",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, spawn_entity, '_')).

zone_despawn() ->
    St = install_api_with_zone(),
    Code = "return game.zone.despawn('entity-123')",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, despawn_entity, '_')).

spatial_zone_query_radius() ->
    St = install_api_with_zone(),
    Code =
        "local results = game.spatial.query_radius(0.0, 0.0, 10.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_zone, query_radius, '_')).

spatial_zone_query_rect() ->
    St = install_api_with_zone(),
    Code =
        "local results = game.spatial.query_rect(0.0, 0.0, 10.0, 10.0)\n"
        "local count = 0\n"
        "for _ in pairs(results) do count = count + 1 end\n"
        "return count",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_zone, query_rect, '_')).

spatial_query_rect_no_zone() ->
    St = install_api(),
    Code = "return game.spatial.query_rect(0.0, 0.0, 10.0, 10.0)",
    {ok, [Result | _], St1} = eval(Code, St),
    Decoded = luerl:decode(Result, St1),
    ?assert(lists:keymember(~"error", 1, Decoded)).

spatial_query_radius_with_opts() ->
    St = install_api(),
    %% A regression that drops the opts arg would break entity-type
    %% filtering — meck_history confirms the 4-arg variant fires.
    meck:expect(asobi_spatial, query_radius, fun(_, _, _, _) ->
        [{~"e1", #{type => ~"npc"}, 4.0}]
    end),
    Code =
        "local entities = { a = { x = 0.0, y = 0.0, type = 'npc' } }\n"
        "local r = game.spatial.query_radius(entities, 0.0, 0.0, 10.0, { type = 'npc' })\n"
        "return #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_spatial, query_radius, '_')).

spatial_nearest_with_opts() ->
    St = install_api(),
    meck:expect(asobi_spatial, nearest, fun(_, _, _, _) ->
        [{~"e1", #{type => ~"npc"}, 1.0}]
    end),
    Code =
        "local entities = { a = { x = 0.0, y = 0.0, type = 'npc' } }\n"
        "local r = game.spatial.nearest(entities, 0.0, 0.0, 1, { max_results = 1 })\n"
        "return #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(1, trunc(Count)),
    ?assert(meck:called(asobi_spatial, nearest, '_')).

%% asobi#108: an empty Lua table `{}` decodes to `[]`, not `#{}` - a zone
%% with no entities yet must not be rejected outright.
spatial_query_radius_empty_entities() ->
    St = install_api(),
    Code = "local r = game.spatial.query_radius({}, 1.0, 1.0, 3.0)\nreturn #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(0, trunc(Count)).

spatial_nearest_empty_entities() ->
    St = install_api(),
    Code = "local r = game.spatial.nearest({}, 1.0, 1.0, 3)\nreturn #r",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(0, trunc(Count)).

zone_spawn_with_overrides() ->
    St = install_api_with_zone(),
    Code = "return game.zone.spawn('goblin', 10.0, 20.0, { hp = 50 })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, spawn_entity, [self(), ~"goblin", '_', '_'])).

%% asobi_lua#110: a live known-template set (as init_zone_state/2 stashes
%% in the process dictionary for a real per-zone VM) still spawns and
%% returns true for a declared template_id.
zone_spawn_known_template() ->
    St = install_api_with_zone_templates(#{~"goblin" => #{type => ~"npc"}}),
    Code = "return game.zone.spawn('goblin', 10.0, 20.0)",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_zone, spawn_entity, '_')).

%% asobi_lua#110: a typo'd template_id must return false synchronously
%% instead of true - and must never reach asobi_zone:spawn_entity at all.
zone_spawn_unknown_template() ->
    St = install_api_with_zone_templates(#{~"goblin" => #{type => ~"npc"}}),
    Code = "return game.zone.spawn('gobiln', 10.0, 20.0)",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_zone, spawn_entity, '_')).

zone_spawn_unknown_template_with_overrides() ->
    St = install_api_with_zone_templates(#{~"goblin" => #{type => ~"npc"}}),
    Code = "return game.zone.spawn('gobiln', 10.0, 20.0, { hp = 50 })",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_zone, spawn_entity, '_')).

terrain_get_chunk() ->
    St = install_api_with_terrain(),
    Code = "local r = game.terrain.get_chunk(0, 0)\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_terrain_store, get_chunk, '_')).

terrain_get_chunk_no_store() ->
    St = install_api(),
    Code = "local r = game.terrain.get_chunk(0, 0)\nreturn r.error ~= nil",
    {ok, [true | _], _} = eval(Code, St).

terrain_preload() ->
    St = install_api_with_terrain(),
    Code = "return game.terrain.preload({ { cx = 0, cy = 0 }, { cx = 1, cy = 0 } })",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_terrain_store, preload_chunks, '_')).

%% --- to_storage_value coercion ---

to_storage_value_scalars() ->
    ?assertEqual(5, asobi_lua_api:to_storage_value(5)),
    ?assertEqual(3.14, asobi_lua_api:to_storage_value(3.14)),
    ?assertEqual(~"hello", asobi_lua_api:to_storage_value(~"hello")),
    ?assertEqual(true, asobi_lua_api:to_storage_value(true)),
    ?assertEqual(false, asobi_lua_api:to_storage_value(false)),
    ?assertEqual(nil, asobi_lua_api:to_storage_value(nil)).

to_storage_value_maps() ->
    ?assertEqual(
        #{~"k" => ~"v", ~"n" => 5},
        asobi_lua_api:to_storage_value(#{~"k" => ~"v", ~"n" => 5})
    ),
    %% Luerl decodes maps to string-keyed proplists. The coercer must
    %% turn that into an Erlang map so kura's jsonb encoder can serialise.
    ?assertEqual(
        #{~"k" => ~"v"},
        asobi_lua_api:to_storage_value([{~"k", ~"v"}])
    ).

to_storage_value_arrays() ->
    %% Luerl decodes Lua arrays to integer-keyed proplists.
    ?assertEqual(
        [~"a", ~"b", ~"c"],
        asobi_lua_api:to_storage_value([{1, ~"a"}, {2, ~"b"}, {3, ~"c"}])
    ),
    %% Out-of-order pairs still produce a stable ordering by key.
    ?assertEqual(
        [~"a", ~"b", ~"c"],
        asobi_lua_api:to_storage_value([{3, ~"c"}, {1, ~"a"}, {2, ~"b"}])
    ).

to_storage_value_nested() ->
    %% { position = { x = 1, y = 2 }, tags = { "rare", "shiny" } }
    Input = [
        {~"position", [{~"x", 1}, {~"y", 2}]},
        {~"tags", [{1, ~"rare"}, {2, ~"shiny"}]}
    ],
    Expected = #{
        ~"position" => #{~"x" => 1, ~"y" => 2},
        ~"tags" => [~"rare", ~"shiny"]
    },
    ?assertEqual(Expected, asobi_lua_api:to_storage_value(Input)).

%% --- Storage round-trip: scalar values must reach the changeset ---

storage_player_set_scalar() ->
    storage_player_set_roundtrip("5", 5).

storage_player_set_binary() ->
    storage_player_set_roundtrip("\"dark\"", ~"dark").

storage_player_set_array() ->
    storage_player_set_roundtrip("{1, 2, 3}", [1, 2, 3]).

-spec storage_player_set_roundtrip(string(), term()) -> ok.
storage_player_set_roundtrip(LuaValueExpr, Expected) ->
    St = install_api(),
    meck:reset(asobi_repo),
    meck:expect(asobi_repo, all, fun(_) -> {ok, []} end),
    Code =
        "local r = game.storage.player_set('p1', 'inv', 'k', " ++
            LuaValueExpr ++
            ")\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    %% kura_changeset:cast/4 receives the params map; meck:history captures
    %% every call to asobi_repo:insert/1. Pull the most recent insert and
    %% verify the value field round-trips intact.
    History = meck:history(asobi_repo),
    [{_, {asobi_repo, insert, [Changeset]}, _} | _] =
        lists:reverse([H || H <- History, element(2, element(2, H)) =:= insert]),
    ?assertEqual(Expected, changeset_param(Changeset, value)).

%% Pull a named field out of a kura_changeset record. Position 5 holds
%% the (normalised) params map per kura.hrl.
-spec changeset_param(term(), atom()) -> term().
changeset_param(CS, Field) when is_tuple(CS) ->
    Params = element(5, CS),
    maps:get(Field, Params).

%% --- Probe ctx: effectful functions must be inert (widgrensit/asobi_lua#109/#117) ---
%%
%% A probe VM (Ctx carrying `probe => true`) exists only to ask a script a
%% question by re-running its whole top-level body - see
%% asobi_lua_match:boot_throwaway_lua_state/2 and
%% asobi_lua_world:boot_throwaway_lua_state/2. Every game.* function that
%% mutates persistent state, broadcasts an event, or grants/deducts a
%% resource must therefore be stubbed out (install_pure/2 + inert/1) instead
%% of hitting the real engine a second time. Read-only/query functions still
%% run for real - calling them twice is safe.

probe_economy_grant_inert() ->
    St = install_api_probe(),
    Code = "return game.economy.grant('p1', 'gold', 100, 'reward')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_economy, grant, '_')).

probe_economy_debit_inert() ->
    St = install_api_probe(),
    Code = "return game.economy.debit('p1', 'gold', 50, 'cost')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_economy, debit, '_')).

probe_economy_purchase_inert() ->
    St = install_api_probe(),
    Code = "return game.economy.purchase('p1', 'sword')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_economy, purchase, '_')).

probe_economy_balance_live() ->
    St = install_api_probe(),
    Code = "local r = game.economy.balance('p1')\nreturn r.ok ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_economy, get_wallets, [~"p1"])).

probe_broadcast_inert() ->
    St = install_api_probe(),
    Code = "return game.broadcast('hello', { msg = 'world' })",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_match_server, broadcast_event, '_')).

probe_send_inert() ->
    St = install_api_probe(),
    Code = "return game.send('p1', { kind = 'hello' })",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_presence, send, '_')).

probe_lb_submit_inert() ->
    St = install_api_probe(),
    Code = "return game.leaderboard.submit('kills', 'p1', 42)",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_leaderboard_server, submit, '_')).

probe_lb_top_live() ->
    St = install_api_probe(),
    Code = "local r = game.leaderboard.top('kills', 10)\nreturn #r.ok",
    {ok, [Count | _], _} = eval(Code, St),
    ?assertEqual(2, trunc(Count)),
    ?assert(meck:called(asobi_leaderboard_server, top, [~"kills", 10])).

probe_notify_inert() ->
    St = install_api_probe(),
    Code = "return game.notify('p1', 'reward', 'You won!')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_notify, send, '_')).

probe_notify_many_inert() ->
    St = install_api_probe(),
    Code = "return game.notify_many({'p1','p2'}, 'reward', 'gg')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_notify, send_many, '_')).

probe_storage_set_inert() ->
    St = install_api_probe(),
    Code = "return game.storage.set('settings', 'theme', { value = 'dark' })",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_repo, insert, '_')),
    ?assertNot(meck:called(asobi_repo, update, '_')).

probe_storage_get_live() ->
    St = install_api_probe(),
    Code = "local r = game.storage.get('settings', 'theme')\nreturn r.error ~= nil",
    {ok, [true | _], _} = eval(Code, St),
    ?assert(meck:called(asobi_repo, all, '_')).

probe_chat_send_inert() ->
    St = install_api_probe(),
    Code = "return game.chat.send('match_123', 'p1', 'gg')",
    {ok, [false | _], _} = eval(Code, St),
    ?assertNot(meck:called(asobi_chat_channel, send_message, '_')).

%% --- Reserved namespaces (asobi_lua_surface) ---
%%
%% asobi_lua_surface:reserved_namespaces/0 is the single source of truth for
%% the `game.*` tables the library owns - the list a later game-declared
%% namespace gets validated against. Both assertions read an installed VM
%% back rather than trusting the list: the tables install/2 created, and the
%% namespaces its function surface actually wired something into. A namespace
%% added to the list but populated by nothing, or a function installed under
%% a namespace the list never declared, breaks the second one.

install_creates_reserved() ->
    St = install_api_with_terrain(),
    Reserved = lists:sort(asobi_lua_surface:reserved_namespaces()),
    ?assertEqual(Reserved, lists:sort(namespace_tables(St))),
    ?assertEqual(Reserved, lists:sort(populated_namespaces(St))).

probe_install_creates_reserved() ->
    St = install_api_probe(),
    Reserved = lists:sort(asobi_lua_surface:reserved_namespaces()),
    ?assertEqual(Reserved, lists:sort(namespace_tables(St))),
    ?assertEqual(Reserved, lists:sort(populated_namespaces(St))).

%% `game` itself plus every table-valued field on it.
namespace_tables(St) ->
    Code =
        "local names = {}\n"
        "for k, v in pairs(game) do\n"
        "  if type(v) == 'table' then names[#names + 1] = k end\n"
        "end\n"
        "return names",
    [[~"game"] | [[~"game", Name] || Name <- lua_strings(Code, St)]].

%% Every namespace holding at least one installed function, named the way
%% Lua sees it (`game`, `game.economy`, ...).
populated_namespaces(St) ->
    Code =
        "local seen = {}\n"
        "for k, v in pairs(game) do\n"
        "  if type(v) == 'function' then\n"
        "    seen['game'] = true\n"
        "  elseif type(v) == 'table' then\n"
        "    for _, nested in pairs(v) do\n"
        "      if type(nested) == 'function' then seen['game.' .. k] = true end\n"
        "    end\n"
        "  end\n"
        "end\n"
        "local names = {}\n"
        "for name in pairs(seen) do names[#names + 1] = name end\n"
        "return names",
    [binary:split(Name, ~".", [global]) || Name <- lua_strings(Code, St)].

lua_strings(Code, St) ->
    {ok, [Table | _], St1} = eval(Code, St),
    [Value || {_Index, Value} <- luerl:decode(Table, St1)].

%% --- Helpers ---

install_api_probe() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self(), probe => true},
    asobi_lua_api:install(Ctx, St0).

install_api() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self()},
    asobi_lua_api:install(Ctx, St0).

install_api_with_zone() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{match_id => ~"test-match", match_pid => self(), zone_pid => self()},
    asobi_lua_api:install(Ctx, St0).

%% asobi_lua#110 + asobi#253: known_template/2 reads the live template set
%% from a `templates_tab` ETS table reference in Ctx (see
%% asobi_lua_world:zone_ctx/2 and its ?TEMPLATES_KEY), not a map value
%% snapshotted directly into Ctx - mirror that shape here.
install_api_with_zone_templates(Templates) ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Tab = ets:new(test_templates, [set, protected]),
    ets:insert(Tab, {known, Templates}),
    Ctx = #{
        match_id => ~"test-match",
        match_pid => self(),
        zone_pid => self(),
        templates_tab => Tab
    },
    asobi_lua_api:install(Ctx, St0).

install_api_with_terrain() ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    Ctx = #{
        match_id => ~"test-match",
        match_pid => self(),
        zone_pid => self(),
        terrain_store_pid => self()
    },
    asobi_lua_api:install(Ctx, St0).

-spec eval(string(), dynamic()) -> {ok, [term()], dynamic()} | {error, term()}.
eval(Code, St) ->
    case luerl:do(Code, St) of
        {ok, Results, St1} -> {ok, Results, St1};
        Other -> Other
    end.
