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
    %% The malformed-declaration tests assert on `[asobi, error]` rather than on
    %% a log line, so the handler table has to exist.
    {ok, _} = application:ensure_all_started(telemetry),
    ok.

start_zone(Dirty) ->
    start_zone_with(#{dirty => Dirty}).

start_zone_with(ZoneState) ->
    {ok, Pid} = asobi_zone:start_link(#{
        world_id => ~"dirty-world",
        coords => {1, 1},
        ticker_pid => self(),
        zone_size => 1000,
        grid_size => 5,
        game_module => asobi_zone_dirty_game,
        zone_state => ZoneState
    }),
    Pid.

%% asobi_telemetry routes game errors through the `[asobi, error]` event.
attach_game_error_handler(Id) ->
    Self = self(),
    telemetry:attach(
        Id,
        [asobi, error],
        fun(_Event, _Measure, Meta, _Cfg) -> Self ! {game_error, Meta} end,
        undefined
    ).

await_game_error(Kind) ->
    receive
        {game_error, #{kind := Kind}} -> ok;
        {game_error, _Other} -> await_game_error(Kind)
    after 1_000 ->
        error({no_game_error, Kind})
    end.

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
        {"a two-tuple return keeps today's semantics", fun two_tuple_no_declaration/0},
        {"a three-tuple return keeps today's semantics", fun three_tuple_no_declaration/0},
        {"an unknown key in the declaration is reported", fun unknown_dirty_key_reported/0},
        {"a non-binary removed id is reported", fun bad_removed_id_reported/0},
        {"a non-map declaration is reported", fun non_map_declaration_reported/0},
        {"a 4-tuple with a bad busy keeps the zone hot and still merges", fun bad_busy_with_dirty/0}
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

%% The `changed` half is the discriminating one: an atom sorts before a binary,
%% so without narrow_changed/2 the keys would come back `[not_a_binary, <<"a">>]`.
%% `removed` is tested separately in bad_removed_id_reported/0 - asserting it
%% here would be vacuous, because maps:without/2 on an id that is not in the map
%% is a no-op whether or not it was filtered.
bad_id_dropped() ->
    Pid = start_zone(#{changed => #{not_a_binary => npc(9.0)}, removed => []}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    Entities = asobi_zone:get_entities(Pid),
    ?assertEqual([~"a"], maps:keys(Entities)),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

%% ADR 0022's headline compatibility claim: a game that never declares behaves
%% exactly as before. The empty declaration is NOT this case - it goes through
%% apply_dirty/3 - so both arities need their own test.
two_tuple_no_declaration() ->
    Pid = start_zone_with(#{}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assertMatch(#{~"a" := #{x := 1001.0}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

three_tuple_no_declaration() ->
    Pid = start_zone_with(#{arity => 3, busy => false}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assertMatch(#{~"a" := #{x := 1001.0}}, asobi_zone:get_entities(Pid)),
    gen_server:stop(Pid).

%% The worst failure this contract can produce: a typo'd key reads as an empty
%% declaration, which means "nothing changed" - and because the base map is
%% what asobi handed in, every entity in the zone freezes for as long as it
%% lives. It has to be loud.
unknown_dirty_key_reported() ->
    ok = attach_game_error_handler(?FUNCTION_NAME),
    Pid = start_zone(#{chnaged => #{~"a" => npc(9.0)}}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ok = await_game_error(bad_zone_dirty),
    telemetry:detach(?FUNCTION_NAME),
    gen_server:stop(Pid).

%% ADR 0022 decision 4 promises both halves are narrowed AND logged. narrow_ids
%% dropped silently until widgrensit/asobi#557's review.
bad_removed_id_reported() ->
    ok = attach_game_error_handler(?FUNCTION_NAME),
    Pid = start_zone(#{changed => #{}, removed => [also_not]}),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ok = await_game_error(bad_zone_dirty),
    telemetry:detach(?FUNCTION_NAME),
    gen_server:stop(Pid).

non_map_declaration_reported() ->
    ok = attach_game_error_handler(?FUNCTION_NAME),
    Pid = start_zone(not_a_map),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ok = await_game_error(bad_zone_dirty),
    telemetry:detach(?FUNCTION_NAME),
    gen_server:stop(Pid).

%% The four-element twin of bad_zone_busy_fails_safe/0: a non-boolean third
%% element keeps the zone hot, and the declaration is still applied.
bad_busy_with_dirty() ->
    Pid = start_zone(#{changed => #{~"a" => npc(9.0)}, removed => []}),
    _ = sys:replace_state(Pid, fun set_bad_busy/1),
    add(Pid, ~"a", npc(1.0)),
    tick(Pid),
    ?assertMatch(#{~"a" := #{x := 1009.0}}, asobi_zone:get_entities(Pid)),
    ?assertMatch(#{cold := false}, sys:get_state(Pid)),
    gen_server:stop(Pid).

-spec set_bad_busy(term()) -> map().
set_bad_busy(#{zone_state := ZS} = State) when is_map(State), is_map(ZS) ->
    State#{zone_state => ZS#{busy => not_a_boolean, arity => 4}}.
