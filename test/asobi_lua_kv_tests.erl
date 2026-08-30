-module(asobi_lua_kv_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#572: `game.kv` is the node-local tier for state that has to
%% outlive the zone holding it, at tick rate; `game.storage.update` is the
%% atomic version of the storage read-modify-write for the writes that must
%% survive a restart.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

setup() ->
    {ok, Pid} = asobi_kv:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    ok.

install(Ctx) ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    asobi_lua_api:install(Ctx, St0).

install_world() ->
    install(#{vm => world, match_id => ~"test-world", match_pid => self()}).

eval(Code, St) ->
    case luerl:do(Code, St) of
        {ok, Results, St1} -> {ok, Results, St1};
        {error, Reason, _} -> {error, Reason}
    end.

lua_kv_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> {"kv.set then kv.get", fun kv_set_get/0} end,
        fun(_) -> {"kv.get of an absent key answers nil, not an error", fun kv_get_absent/0} end,
        fun(_) -> {"kv.merge returns the merged value", fun kv_merge_returns/0} end,
        fun(_) -> {"kv.merge accumulates across calls", fun kv_merge_accumulates/0} end,
        fun(_) -> {"a bad operator is an error the script can see", fun kv_merge_bad_op/0} end,
        fun(_) -> {"kv.delete removes the key", fun kv_delete/0} end,
        fun(_) -> {"kv.set refuses a scalar value", fun kv_set_scalar/0} end,
        fun(_) -> {"kv rows are scoped to the calling VM's world", fun kv_scoped_to_world/0} end,
        fun(_) -> {"kv without a scope errors rather than colliding", fun kv_no_scope/0} end
    ]}.

kv_set_get() ->
    St = install_world(),
    {ok, [_ | _], St1} = eval("return game.kv.set('ships', 's1', { hull = 100 })", St),
    {ok, [Result | _], _} = eval("return game.kv.get('ships', 's1').ok.hull", St1),
    ?assertEqual(100, Result).

kv_get_absent() ->
    St = install_world(),
    {ok, [Result | _], _} = eval("return game.kv.get('ships', 'nope').ok", St),
    ?assertEqual(nil, Result).

kv_merge_returns() ->
    St = install_world(),
    Code =
        "local r = game.kv.merge('ships', 's1', { hull = { incr = -40 }, dead = { latch = false } })\n"
        "return r.ok.hull",
    {ok, [Result | _], _} = eval(Code, St),
    ?assertEqual(-40, Result).

kv_merge_accumulates() ->
    St = install_world(),
    Code =
        "game.kv.set('ships', 's1', { hull = 100 })\n"
        "game.kv.merge('ships', 's1', { hull = { incr = -40 } })\n"
        "local r = game.kv.merge('ships', 's1', { hull = { incr = -40 } })\n"
        "return r.ok.hull",
    {ok, [Result | _], _} = eval(Code, St),
    ?assertEqual(20, Result).

kv_merge_bad_op() ->
    St = install_world(),
    {ok, [Error | _], _} = eval("return game.kv.merge('ships', 's1', { hull = 4 }).error", St),
    ?assert(is_binary(Error)).

kv_delete() ->
    St = install_world(),
    Code =
        "game.kv.set('ships', 's1', { hull = 100 })\n"
        "game.kv.delete('ships', 's1')\n"
        "return game.kv.get('ships', 's1').ok",
    {ok, [Result | _], _} = eval(Code, St),
    ?assertEqual(nil, Result).

kv_set_scalar() ->
    St = install_world(),
    {ok, [Error | _], _} = eval("return game.kv.set('ships', 's1', 42).error", St),
    ?assert(is_binary(Error)).

%% Two worlds running the same mode script write the same collection and key.
kv_scoped_to_world() ->
    StA = install(#{vm => world, match_id => ~"world-a", match_pid => self()}),
    StB = install(#{vm => world, match_id => ~"world-b", match_pid => self()}),
    {ok, _, _} = eval("return game.kv.set('ships', 's1', { hull = 100 })", StA),
    {ok, _, _} = eval("return game.kv.set('ships', 's1', { hull = 50 })", StB),
    {ok, [A | _], _} = eval("return game.kv.get('ships', 's1').ok.hull", StA),
    {ok, [B | _], _} = eval("return game.kv.get('ships', 's1').ok.hull", StB),
    ?assertEqual(100, A),
    ?assertEqual(50, B).

kv_no_scope() ->
    St = install(#{vm => world, match_pid => self()}),
    {ok, [Error | _], _} = eval("return game.kv.get('ships', 's1').error", St),
    ?assert(is_binary(Error)).

%% --- game.storage.update ---

lua_storage_update_test_() ->
    {foreach, fun storage_setup/0, fun storage_cleanup/1, [
        fun(_) -> {"update inserts when the row is absent", fun update_inserts/0} end,
        fun(_) -> {"update merges into the row it read", fun update_merges/0} end,
        fun(_) ->
            {"a racing writer is retried, not overwritten", fun update_retries_on_stale/0}
        end,
        fun(_) -> {"a hot key gives up rather than spinning", fun update_gives_up/0} end,
        fun(_) -> {"a bad operator never reaches the database", fun update_bad_op/0} end
    ]}.

storage_setup() ->
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, all, fun(_) -> {ok, []} end),
    meck:expect(asobi_repo, insert, fun(_) -> {ok, #{value => #{}}} end),
    meck:expect(asobi_repo, update_all, fun(_, _) -> {ok, 1} end),
    ok.

storage_cleanup(_) ->
    meck:unload(asobi_repo),
    ok.

storage_st() ->
    install(#{vm => world, match_id => ~"test-world", match_pid => self()}).

update_inserts() ->
    Code = "return game.storage.update('ships', 's1', { kills = { incr = 1 } }).ok.kills",
    {ok, [Result | _], _} = eval(Code, storage_st()),
    ?assertEqual(1, Result),
    ?assert(meck:called(asobi_repo, insert, '_')).

update_merges() ->
    meck:expect(asobi_repo, all, fun(_) ->
        {ok, [#{id => ~"row1", value => #{~"hull" => 100}, version => 3}]}
    end),
    Code = "return game.storage.update('ships', 's1', { hull = { incr = -40 } }).ok.hull",
    {ok, [Result | _], _} = eval(Code, storage_st()),
    ?assertEqual(60, Result),
    %% The UPDATE is conditional on the version that was read - that is what
    %% makes this safe for two zones writing the same entity.
    ?assert(meck:called(asobi_repo, update_all, '_')),
    ?assertNot(meck:called(asobi_repo, insert, '_')).

update_retries_on_stale() ->
    Versions = counters:new(1, []),
    meck:expect(asobi_repo, all, fun(_) ->
        N = counters:get(Versions, 1),
        counters:add(Versions, 1, 1),
        {ok, [#{id => ~"row1", value => #{~"hull" => 100 - N * 10}, version => N}]}
    end),
    meck:expect(asobi_repo, update_all, fun(_, _) ->
        case counters:get(Versions, 1) of
            1 -> {ok, 0};
            _ -> {ok, 1}
        end
    end),
    Code = "return game.storage.update('ships', 's1', { hull = { incr = -40 } }).ok.hull",
    {ok, [Result | _], _} = eval(Code, storage_st()),
    %% Re-read the newer value and re-applied to it, rather than writing over
    %% the other writer's damage.
    ?assertEqual(50, Result).

update_gives_up() ->
    meck:expect(asobi_repo, all, fun(_) ->
        {ok, [#{id => ~"row1", value => #{~"hull" => 100}, version => 3}]}
    end),
    meck:expect(asobi_repo, update_all, fun(_, _) -> {ok, 0} end),
    Code = "return game.storage.update('ships', 's1', { hull = { incr = -40 } }).error",
    {ok, [Error | _], _} = eval(Code, storage_st()),
    ?assert(is_binary(Error)).

update_bad_op() ->
    Code = "return game.storage.update('ships', 's1', { hull = { nope = 1 } }).error",
    {ok, [Error | _], _} = eval(Code, storage_st()),
    ?assert(is_binary(Error)),
    ?assertNot(meck:called(asobi_repo, insert, '_')),
    ?assertNot(meck:called(asobi_repo, update_all, '_')).
