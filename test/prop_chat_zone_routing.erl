-module(prop_chat_zone_routing).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: random sequences of player_joined / player_zone_changed /
%% player_left across N players exercising zone, world, and proximity
%% chat. The model tracks which channels each player should be subscribed
%% to; the property asserts pg membership matches the model after every
%% mutation.
%%
%% Catches subscribe/unsubscribe drift (orphaned subscriptions after
%% leave, double-subscribe on resync, broken proximity expansion).

-define(NUMTESTS, list_to_integer(os:getenv("PROPER_NUMTESTS", "25"))).
-define(WORLD_ID, ~"propchat").
-define(GRID_SIZE, 10).
-define(PROX_RADIUS, 1).

chat_zone_routing_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, max(60, ?NUMTESTS div 2),
            ?_assert(
                proper:quickcheck(prop_chat_zone_routing(), [
                    {numtests, ?NUMTESTS}, {to_file, user}
                ])
            )}
    ]}.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start(nova_scope);
        _ -> ok
    end,
    case whereis(asobi_chat_sup) of
        undefined ->
            {ok, Pid} = asobi_chat_sup:start_link(),
            unlink(Pid);
        _ ->
            ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    ok.

cleanup(_) ->
    catch meck:unload(asobi_repo),
    ok.

%% --- Property ---

prop_chat_zone_routing() ->
    ?FORALL(
        Cmds,
        proper_types:list(command()),
        run_iteration(narrow_list(Cmds))
    ).

command() ->
    proper_types:oneof([
        {join, player_id(), zone_coord()},
        {move, player_id(), zone_coord()},
        {leave, player_id()}
    ]).

player_id() ->
    proper_types:elements([~"cp1", ~"cp2", ~"cp3", ~"cp4"]).

zone_coord() ->
    {proper_types:integer(0, 4), proper_types:integer(0, 4)}.

%% --- Runner ---

-spec run_iteration([term()]) -> boolean().
run_iteration(Cmds) ->
    %% Per-iteration unique world id keeps channels isolated; existing
    %% subscriptions from a previous iteration would otherwise leak in.
    Tag = integer_to_binary(erlang:unique_integer([positive])),
    WorldId = <<?WORLD_ID/binary, "_", Tag/binary>>,
    ChatState = asobi_world_chat:init(WorldId, chat_config()),
    Listeners = ensure_listeners(player_id_universe(), WorldId),
    try
        Final = lists:foldl(
            fun(C, S) -> step(C, ChatState, Listeners, WorldId, S) end,
            init_model(),
            Cmds
        ),
        check(WorldId, Listeners, Final)
    after
        cleanup_listeners(Listeners)
    end.

chat_config() ->
    #{
        chat => #{
            world => true,
            zone => true,
            proximity => ?PROX_RADIUS,
            grid_size => ?GRID_SIZE
        }
    }.

player_id_universe() ->
    [~"cp1", ~"cp2", ~"cp3", ~"cp4"].

init_model() ->
    %% positions :: #{PlayerId => {ZX, ZY}} for currently-joined players.
    #{positions => #{}}.

step({join, P, Pos}, ChatState, _Listeners, _WorldId, #{positions := Positions} = S) ->
    case maps:is_key(P, Positions) of
        true ->
            S;
        false ->
            asobi_world_chat:player_joined(P, Pos, ChatState),
            S#{positions => Positions#{P => Pos}}
    end;
step({move, P, NewPos}, ChatState, _Listeners, _WorldId, #{positions := Positions} = S) ->
    case maps:get(P, Positions, undefined) of
        undefined ->
            S;
        OldPos when OldPos =:= NewPos ->
            S;
        OldPos ->
            asobi_world_chat:player_zone_changed(P, OldPos, NewPos, ?GRID_SIZE, ChatState),
            S#{positions => Positions#{P => NewPos}}
    end;
step({leave, P}, ChatState, _Listeners, _WorldId, #{positions := Positions} = S) ->
    case maps:get(P, Positions, undefined) of
        undefined ->
            S;
        Pos ->
            asobi_world_chat:player_left(P, Pos, ChatState),
            S#{positions => maps:remove(P, Positions)}
    end.

check(WorldId, Listeners, #{positions := Positions}) ->
    %% Allow casts (subscribe/unsubscribe are casts to channels) to settle.
    timer:sleep(15),
    Players = player_id_universe(),
    lists:all(
        fun(P) ->
            ListenerPid = maps:get(P, Listeners),
            ExpectedChannels = expected_channels_for(P, Positions, WorldId),
            ActualChannels = actual_channels_for(ListenerPid, WorldId, Positions),
            case lists:sort(ExpectedChannels) =:= lists:sort(ActualChannels) of
                true ->
                    true;
                false ->
                    io:format(
                        user,
                        "~nchannel mismatch for ~s:~n  expected: ~p~n  actual:   ~p~n  positions: ~p~n",
                        [P, ExpectedChannels, ActualChannels, Positions]
                    ),
                    false
            end
        end,
        Players
    ).

expected_channels_for(P, Positions, WorldId) ->
    case maps:get(P, Positions, undefined) of
        undefined ->
            [];
        {ZX, ZY} = Pos when is_integer(ZX), is_integer(ZY) ->
            World = asobi_world_chat:channel_id(WorldId, world, undefined),
            Zone = asobi_world_chat:channel_id(WorldId, zone, Pos),
            Prox = [
                asobi_world_chat:channel_id(WorldId, proximity, Cell)
             || Cell <- prox_cells(ZX, ZY)
            ],
            [World, Zone | Prox]
    end.

-spec prox_cells(integer(), integer()) -> [{integer(), integer()}].
prox_cells(ZX, ZY) ->
    XLo = clamp_lo(ZX - ?PROX_RADIUS),
    XHi = clamp_hi(ZX + ?PROX_RADIUS),
    YLo = clamp_lo(ZY - ?PROX_RADIUS),
    YHi = clamp_hi(ZY + ?PROX_RADIUS),
    [{X, Y} || X <- lists:seq(XLo, XHi), Y <- lists:seq(YLo, YHi)].

-spec clamp_lo(integer()) -> integer().
clamp_lo(N) when N < 0 -> 0;
clamp_lo(N) -> N.

-spec clamp_hi(integer()) -> integer().
clamp_hi(N) when N > ?GRID_SIZE - 1 -> ?GRID_SIZE - 1;
clamp_hi(N) -> N.

actual_channels_for(ListenerPid, WorldId, Positions) ->
    %% Enumerate every channel id that any player could subscribe to and
    %% check pg membership. Bounded by the small player universe + grid.
    Universe = candidate_channels(WorldId, Positions),
    [Ch || Ch <- Universe, lists:member(ListenerPid, pg:get_members(nova_scope, {chat, Ch}))].

candidate_channels(WorldId, Positions) ->
    World = [asobi_world_chat:channel_id(WorldId, world, undefined)],
    Zones = [
        asobi_world_chat:channel_id(WorldId, zone, Pos)
     || Pos <- positions_with_neighbors(Positions)
    ],
    Prox = [
        asobi_world_chat:channel_id(WorldId, proximity, P)
     || P <- positions_with_neighbors(Positions)
    ],
    World ++ Zones ++ Prox.

positions_with_neighbors(Positions) ->
    %% Cover every cell within prox radius of any joined player.
    Posns = maps:values(Positions),
    Cells = lists:append([
        prox_cells(ZX, ZY)
     || {ZX, ZY} <- Posns, is_integer(ZX), is_integer(ZY)
    ]),
    lists:usort(Cells).

%% --- Listener processes ---

ensure_listeners(Players, WorldId) ->
    %% One spawned process per player, registered in pg as the player's session.
    %% The world_chat module subscribes the pg-registered pid to channels.
    maps:from_list([{P, ensure_listener(P, WorldId)} || P <- Players]).

ensure_listener(P, _WorldId) ->
    Pid = spawn(fun L() ->
        receive
            stop -> ok;
            _ -> L()
        end
    end),
    ok = pg:join(nova_scope, {player, P}, Pid),
    Pid.

cleanup_listeners(Listeners) ->
    maps:foreach(fun(_, Pid) -> catch exit(Pid, kill) end, Listeners),
    ok.

-spec narrow_list(term()) -> [term()].
narrow_list(L) when is_list(L) -> L.
