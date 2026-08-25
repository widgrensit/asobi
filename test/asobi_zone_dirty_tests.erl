-module(asobi_zone_dirty_tests).
-include_lib("eunit/include/eunit.hrl").

%% widgrensit/asobi#557: a zone used to round-trip its whole entity map through
%% zone_tick every tick whatever changed, and the rebuilt map destroyed the
%% structural sharing every downstream diff depends on. A game may now say what
%% it changed instead.

setup() ->
    case ets:info(asobi_world_state) of
        undefined -> ets:new(asobi_world_state, [named_table, public, set]);
        _ -> ok
    end,
    case pg:start(nova_scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    ok.

start_zone(Dirty) ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"dirty-world",
        coords => {1, 1},
        ticker_pid => self(),
        zone_size => 1000,
        grid_size => 5,
        game_module => asobi_zone_dirty_game,
        zone_state => #{dirty => Dirty}
    }),
    Pid.

npc(X) ->
    #{type => ~"npc", x => 1000.0 + X, y => 1000.0, hp => 100}.

tick(Pid) ->
    asobi_zone:tick(Pid, 1),
    _ = sys:get_state(Pid),
    ok.

add(Pid, Id, E) ->
    asobi_zone:add_entity(Pid, Id, E),
    _ = sys:get_state(Pid),
    ok.

dirty_test_() ->
    {foreach, fun setup/0, fun(_) -> ok end, [
        {"a declared change lands", fun changed_lands/0},
        {"a declared removal lands", fun removed_lands/0},
        {"an undeclared entity keeps its identity", fun untouched_is_shared/0},
        {"a malformed declaration is ignored, not fatal", fun malformed_is_ignored/0},
        {"a non-binary id in changed is dropped", fun bad_id_dropped/0},
        {"no declaration keeps today's semantics", fun no_declaration/0}
    ]}.

changed_lands() ->
    Pid = start_zone(#{changed => #{~"a" => npc(9.0)}, removed => []}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assertMatch(#{~"a" := #{x := 1009.0}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

removed_lands() ->
    Pid = start_zone(#{changed => #{}, removed => [~"b"]}),
    add(Pid, ~"a", npc(1.0)),
    add(Pid, ~"b", npc(2.0)),
    tick(Pid),
    Entities = asobi_zone:get_entities(Pid),
    ?assert(maps:is_key(~"a", Entities)),
    ?assertNot(maps:is_key(~"b", Entities)),
    gen_server:stop(Pid).

%% The point of the whole contract: an entity nobody named is the SAME TERM it
%% was before the callback, so compute_deltas/2 and sync_spatial_grid/3 settle
%% it with a pointer comparison instead of walking its fields.
%%
%% Both halves of the comparison have to be read INSIDE the zone: a
%% `get_entities/1` call copies the map out, and copying a term does not
%% preserve sharing within it - two calls would compare two independent copies
%% and the assertion would be vacuously false whatever the tick did.
untouched_is_shared() ->
    Pid = start_zone(#{changed => #{~"a" => npc(9.0)}, removed => []}),
    add(Pid, ~"a", npc(1.0)),
    add(Pid, ~"b", npc(2.0)),
    _ = sys:replace_state(Pid, fun stash_probe/1),
    tick(Pid),
    _ = sys:replace_state(Pid, fun compare_probe/1),
    ?assertMatch(#{probe_same := true}, sys:get_state(Pid)),
    gen_server:stop(Pid).

-spec stash_probe(term()) -> map().
stash_probe(#{entities := #{~"b" := B}} = State) when is_map(State) ->
    State#{probe => B}.

-spec compare_probe(term()) -> map().
compare_probe(#{entities := #{~"b" := B}, probe := Probe} = State) when is_map(State) ->
    State#{probe_same => erts_debug:same(Probe, B)}.

malformed_is_ignored() ->
    Pid = start_zone(not_a_map),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assert(is_process_alive(Pid)),
    ?assertMatch(#{~"a" := #{x := 1001.0}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

bad_id_dropped() ->
    Pid = start_zone(#{changed => #{not_a_binary => npc(9.0)}, removed => [also_not]}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    Entities = asobi_zone:get_entities(Pid),
    ?assertEqual([~"a"], maps:keys(Entities)),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

no_declaration() ->
    Pid = start_zone(#{}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assertMatch(#{~"a" := #{x := 1001.0}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).
