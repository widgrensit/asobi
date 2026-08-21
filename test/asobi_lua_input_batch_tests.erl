-module(asobi_lua_input_batch_tests).
-moduledoc """
Bridge-level tests for `asobi_lua_world:handle_input_batch/2`.

Two things are checked here that the zone-level tests cannot see.

The first is that a script cannot collect the entity map out from under the
batch. The batch carries one encoded map across every input, and a script
declaring fewer parameters than it was passed drops it from its call frame, so a
collection at that moment would free it and the next input's encode would recycle
the slot. `gc_hostile_input.lua` is that script, and it tries.
`collectgarbage` is stripped from the sandbox so the call raises instead;
the anchor that makes the reference survive a collection regardless is covered
in `asobi_lua_loader_tests`.

The second is that exporting the batch shadows `handle_input/3` for every Lua
zone, so the two must agree. The hostile-return corpus is aimed at the per-input
path by every existing test; here it is driven through both.
""".
-include_lib("eunit/include/eunit.hrl").

-define(PD_KEY, {asobi_lua_world, zone_state}).

fixture(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:absname(filename:join([Dir, "test", "fixtures", "lua", Name]))
    end.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    ok.

cleanup(_) ->
    erlang:erase(?PD_KEY),
    ok.

zone_state(Script) ->
    Config = #{
        world_id => ~"lua_batch",
        coords => {0, 0},
        game_config => #{lua_script => fixture(Script)},
        grid_size => 1,
        zone_size => 500
    },
    asobi_lua_world:init_zone_state(Config, #{}).

%% Atom-keyed, which is what a zone actually holds: zone_tick/2 runs
%% asobi_lua_api:atomize_entities/1 on everything coming back from Lua so the
%% shared tick path can pattern-match on it (asobi#270).
entities() ->
    #{
        ~"p1" => #{type => ~"pilot", x => 1.0, hp => 100},
        ~"p2" => #{type => ~"pilot", x => 2.0, hp => 100}
    }.

batch_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a script that raises leaves the zone's entities alone",
            fun raising_script_leaves_entities_alone/0},
        {"a Lua exception is not reported as a module rejection",
            fun lua_error_is_not_an_error_outcome/0},
        {"the batch and the per-input path agree", fun batch_agrees_with_per_input/0},
        {"a script clearing the anchor loses its own inputs, not the zone's entities",
            fun clearing_the_anchor_fails_closed/0},
        {"clearing the anchor does not bury an earlier input's reported seq",
            fun anchor_loss_keeps_earlier_outcomes/0},
        {"an empty return discards the mutation, on both paths",
            fun in_place_mutation_is_discarded/0},
        {"an empty return cannot write another player's entity",
            fun empty_return_is_not_a_cross_player_write/0}
    ]}.

%% `gc_hostile_input.lua` calls `collectgarbage`, which the sandbox strips, so the
%% call raises and this is the end-to-end check on the strip: the entities the
%% zone handed over come back untouched. The anchor that would ALSO have caught
%% it, had the collection happened, is covered directly in
%% `asobi_lua_loader_tests`.
raising_script_leaves_entities_alone() ->
    erlang:put(?PD_KEY, zone_state("gc_hostile_input.lua")),
    Inputs = [
        {~"p1", #{~"tag" => ~"first", ~"n" => 1}},
        {~"p2", #{~"tag" => ~"second", ~"n" => 2}}
    ],
    {ok, Out, Outcomes} = asobi_lua_world:handle_input_batch(Inputs, entities()),
    ?assertEqual([~"p1", ~"p2"], lists:sort(maps:keys(Out))),
    ?assertEqual([ok, ok], Outcomes),
    ?assertEqual(100, maps:get(hp, maps:get(~"p1", Out))),
    erlang:erase(?PD_KEY).

%% handle_input/3 maps a Lua exception to {ok, Entities} after a rate-limited
%% log, so the batch must not turn one into {error, _}: that is asobi_zone's
%% "the game module refused this input" channel, and a script that throws has
%% not refused anything.
lua_error_is_not_an_error_outcome() ->
    erlang:put(?PD_KEY, zone_state("error_world.lua")),
    Inputs = [{~"p1", #{~"action" => ~"boom"}}],
    {ok, _Out, Outcomes} = asobi_lua_world:handle_input_batch(Inputs, entities()),
    ?assertEqual([ok], Outcomes),
    erlang:erase(?PD_KEY).

%% Same script, same inputs, both paths, comparing entities AND outcomes. The
%% batch shadows handle_input/3 in production, so a divergence here is one
%% nothing else would catch - which means the corpus has to be scripts that
%% reach `batch_result/3` at all. A script that raises agrees trivially on both
%% paths and hides drift, so the raising cases live in their own tests and this
%% is the hostile-RETURN corpus: the malformed shapes, the empty return, a
%% script that applies its input, and one that reports a seq.
batch_agrees_with_per_input() ->
    Cases = [
        {"config_move_world.lua", [{~"p1", #{~"kind" => ~"move", ~"x" => 5, ~"y" => 6}}]},
        {"config_ack_world.lua", [{~"p1", #{~"x" => 1, ~"y" => 2, ~"consumed" => 9}}]},
        {"config_ack_world.lua", [{~"p1", #{~"x" => 1, ~"y" => 2, ~"consumed" => -3}}]},
        {"config_silent_input_world.lua", [{~"p1", #{~"kind" => ~"move"}}]},
        {"config_hostile_input_world.lua", [{~"p1", #{~"kind" => ~"cyclic"}}]},
        {"config_hostile_input_world.lua", [{~"p1", #{~"kind" => ~"huge"}}]},
        {"config_hostile_input_world.lua", [{~"p1", #{~"kind" => ~"scalar"}}]},
        {"mutate_then_reject_input.lua", [{~"p1", #{~"target" => ~"p2"}}]},
        %% Two inputs whose outcomes DIFFER. Every other case is a single input,
        %% so a reversed outcome list would pair one player's watermark with
        %% another player's seq and no test would notice.
        {"config_ack_world.lua", [
            {~"p1", #{~"x" => 1, ~"y" => 1, ~"consumed" => 9}},
            {~"p2", #{~"x" => 2, ~"y" => 2}}
        ]}
    ],
    [
        begin
            erlang:put(?PD_KEY, zone_state(Script)),
            {ok, Batched, BatchedOutcomes} = asobi_lua_world:handle_input_batch(
                Inputs, entities()
            ),
            erlang:erase(?PD_KEY),
            erlang:put(?PD_KEY, zone_state(Script)),
            Sequential = per_input(Inputs, entities()),
            erlang:erase(?PD_KEY),
            ?assertEqual({Script, Sequential}, {Script, {Batched, BatchedOutcomes}})
        end
     || {Script, Inputs} <- Cases
    ].

%% _G is script-writable, so a script can drop asobi's root with one assignment.
%% Everything the batch holds is then a collection away from aliasing a recycled
%% slot, so the batch has to fail closed rather than decode it.
clearing_the_anchor_fails_closed() ->
    erlang:put(?PD_KEY, zone_state("anchor_clearing_input.lua")),
    Inputs = [
        {~"p1", #{~"clear" => true}},
        {~"p2", #{~"clear" => true}}
    ],
    {ok, Out, Outcomes} = asobi_lua_world:handle_input_batch(Inputs, entities()),
    %% The fixture mutates and returns entities, so honouring its return would
    %% show hp = 0. The original map is what proves the batch bailed out.
    ?assertEqual(entities(), Out),
    ?assertEqual(100, maps:get(hp, maps:get(~"p1", Out))),
    ?assertEqual([ok, ok], Outcomes),
    erlang:erase(?PD_KEY).

%% The empty return is the reject idiom, and it has to mean the same thing on
%% both paths. It does not come free on the batch: the script holds the table, so
%% parity is restored by reverting the Luerl state, which is functional.
in_place_mutation_is_discarded() ->
    Inputs = [{~"p1", #{~"tag" => ~"first"}}],
    ?assertEqual(100, hp_after_batch("mutate_then_reject_input.lua", Inputs, ~"p1")),
    ?assertEqual(100, hp_after_per_input("mutate_then_reject_input.lua", Inputs, ~"p1")).

%% The exploit the revert closes: `entities[input.target]` is a client-chosen
%% key, so without it a rejecting handler could zero any entity in the zone.
empty_return_is_not_a_cross_player_write() ->
    Inputs = [{~"p1", #{~"target" => ~"p2"}}],
    ?assertEqual(100, hp_after_batch("mutate_then_reject_input.lua", Inputs, ~"p2")),
    ?assertEqual(100, hp_after_per_input("mutate_then_reject_input.lua", Inputs, ~"p2")).

hp_after_batch(Script, Inputs, PlayerId) ->
    erlang:put(?PD_KEY, zone_state(Script)),
    {ok, Out, _} = asobi_lua_world:handle_input_batch(Inputs, entities()),
    erlang:erase(?PD_KEY),
    maps:get(hp, maps:get(PlayerId, Out)).

hp_after_per_input(Script, Inputs, PlayerId) ->
    erlang:put(?PD_KEY, zone_state(Script)),
    {Out, _Outcomes} = per_input(Inputs, entities()),
    erlang:erase(?PD_KEY),
    maps:get(hp, maps:get(PlayerId, Out)).

%% Returns outcomes as well as entities, in handle_input_batch/2's own
%% vocabulary. Comparing only the entities leaves batch_result/3's consumed-seq
%% classification - the half that feeds a monotonic, permanently-poisonable ack -
%% with no cross-check at all.
%% A reporting input AHEAD of the tampering one. The bail-out must carry the
%% {consumed, 9} it already produced: replacing it with a frame stamp would bury
%% that watermark permanently, since the session ack gate is monotonic.
anchor_loss_keeps_earlier_outcomes() ->
    erlang:put(?PD_KEY, zone_state("anchor_clearing_input.lua")),
    Inputs = [
        {~"p1", #{~"consumed" => 9}},
        {~"p2", #{~"clear" => true}}
    ],
    {ok, Out, Outcomes} = asobi_lua_world:handle_input_batch(Inputs, entities()),
    ?assertEqual([{consumed, 9}, ok], Outcomes),
    ?assertEqual(entities(), Out),
    erlang:erase(?PD_KEY).

per_input(Inputs, Entities) ->
    per_input(Inputs, Entities, []).

per_input([], Entities, Acc) ->
    {Entities, lists:reverse(Acc)};
per_input([{PlayerId, Input} | Rest], Entities, Acc) ->
    {Entities1, Outcome} =
        case asobi_lua_world:handle_input(PlayerId, Input, Entities) of
            {ok, E} -> {E, ok};
            {ok, E, Seq} -> {E, {consumed, Seq}};
            {error, _} -> {Entities, ok}
        end,
    per_input(Rest, Entities1, [Outcome | Acc]).
