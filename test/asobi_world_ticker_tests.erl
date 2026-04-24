-module(asobi_world_ticker_tests).
-include_lib("eunit/include/eunit.hrl").

start_ticker() ->
    start_ticker(#{}).

start_ticker(Overrides) ->
    Config = maps:merge(#{tick_rate => 100}, Overrides),
    {ok, Pid} = asobi_world_ticker:start_link(Config),
    Pid.

-spec get_state_map(pid()) -> map().
get_state_map(Pid) ->
    case sys:get_state(Pid) of
        S when is_map(S) -> S
    end.

ticker_test_() ->
    {foreach, fun() -> ok end, fun(_) -> ok end, [
        {"get_tick starts at 0", fun get_tick_starts_at_zero/0},
        {"set_zones puts all zones in hot", fun set_zones_all_hot/0},
        {"promote_zone adds to hot", fun promote_zone_adds_to_hot/0},
        {"demote_zone moves to cold", fun demote_zone_moves_to_cold/0},
        {"remove_zone removes from both", fun remove_zone_removes/0},
        {"promote is idempotent", fun promote_idempotent/0},
        {"demote is idempotent", fun demote_idempotent/0},
        {"cold_tick_divisor defaults to 10", fun cold_divisor_default/0},
        {"cold_tick_divisor is configurable", fun cold_divisor_configurable/0}
    ]}.

get_tick_starts_at_zero() ->
    Pid = start_ticker(),
    ?assertEqual(0, asobi_world_ticker:get_tick(Pid)).

set_zones_all_hot() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Z2 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:set_zones(Pid, [Z1, Z2], self()),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertEqual([Z1, Z2], maps:get(hot_zones, State)),
    ?assertEqual([], maps:get(cold_zones, State)).

promote_zone_adds_to_hot() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assert(lists:member(Z1, maps:get(hot_zones, State))),
    ?assertNot(lists:member(Z1, maps:get(cold_zones, State))).

demote_zone_moves_to_cold() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertNot(lists:member(Z1, maps:get(hot_zones, State))),
    ?assert(lists:member(Z1, maps:get(cold_zones, State))).

remove_zone_removes() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:remove_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    ?assertNot(lists:member(Z1, maps:get(hot_zones, State))),
    ?assertNot(lists:member(Z1, maps:get(cold_zones, State))).

promote_idempotent() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:promote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    Hot = maps:get(hot_zones, State),
    ?assertEqual(1, length([Z || Z <- Hot, Z =:= Z1])).

demote_idempotent() ->
    Pid = start_ticker(),
    Z1 = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    asobi_world_ticker:demote_zone(Pid, Z1),
    timer:sleep(10),
    State = get_state_map(Pid),
    Cold = maps:get(cold_zones, State),
    ?assertEqual(1, length([Z || Z <- Cold, Z =:= Z1])).

cold_divisor_default() ->
    Pid = start_ticker(),
    State = get_state_map(Pid),
    ?assertEqual(10, maps:get(cold_tick_divisor, State)).

cold_divisor_configurable() ->
    Pid = start_ticker(#{cold_tick_divisor => 5}),
    State = get_state_map(Pid),
    ?assertEqual(5, maps:get(cold_tick_divisor, State)).
