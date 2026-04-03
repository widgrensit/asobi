-module(asobi_bot).
-moduledoc """
Generic bot process that runs a Lua AI script each tick.

The bot joins a match as a player, receives game state updates,
and sends input decisions based on the Lua `think(bot_id, state)` function.

Also handles auto boon picking and auto voting.
""".

-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2]).

-define(PG_SCOPE, nova_scope).
-define(TICK_INTERVAL, 100).

-spec start_link(pid(), binary(), binary() | undefined) -> gen_server:start_ret().
start_link(MatchPid, BotId, LuaScript) ->
    gen_server:start_link(
        ?MODULE,
        #{
            match_pid => MatchPid,
            bot_id => BotId,
            lua_script => LuaScript
        },
        []
    ).

-spec init(map()) -> {ok, map()} | {stop, term()}.
init(#{match_pid := MatchPid, bot_id := BotId, lua_script := LuaScript}) ->
    pg:join(?PG_SCOPE, {player, BotId}, self()),
    monitor(process, MatchPid),
    _ = asobi_match_server:join(MatchPid, BotId),
    erlang:send_after(?TICK_INTERVAL, self(), tick),
    LuaSt =
        case LuaScript of
            undefined ->
                undefined;
            Path ->
                case asobi_lua_loader:new(Path) of
                    {ok, St} ->
                        St;
                    {error, Reason} ->
                        logger:warning(#{
                            msg => ~"bot lua load failed",
                            bot_id => BotId,
                            reason => Reason
                        }),
                        undefined
                end
        end,
    {ok, #{
        match_pid => MatchPid,
        bot_id => BotId,
        lua_state => LuaSt,
        game_state => #{},
        phase => playing
    }}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, term(), map()}.
handle_info(tick, #{phase := playing} = State) ->
    send_input(State),
    erlang:send_after(?TICK_INTERVAL, self(), tick),
    {noreply, State};
handle_info(tick, State) ->
    erlang:send_after(?TICK_INTERVAL, self(), tick),
    {noreply, State};
handle_info({asobi_message, {match_state, GameState}}, State) when is_map(GameState) ->
    Phase = extract_phase(GameState),
    State1 = State#{game_state => GameState, phase => Phase},
    State2 = maybe_auto_pick_boon(State1),
    {noreply, State2};
handle_info({asobi_message, {match_event, vote_start, VotePayload}}, State) when
    is_map(VotePayload)
->
    handle_vote_start(VotePayload, State);
handle_info({asobi_message, {match_event, finished, _}}, State) ->
    {stop, normal, State};
handle_info({asobi_message, _}, State) ->
    {noreply, State};
handle_info({'DOWN', _, process, MatchPid, _}, #{match_pid := MatchPid} = State) ->
    {stop, normal, State};
handle_info(_, State) ->
    {noreply, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_, State) ->
    {noreply, State}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_, _From, State) ->
    {reply, ok, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{bot_id := BotId, match_pid := MatchPid}) ->
    pg:leave(?PG_SCOPE, {player, BotId}, self()),
    try
        asobi_match_server:leave(MatchPid, BotId)
    catch
        _:_ -> ok
    end,
    ok;
terminate(_, _) ->
    ok.

%% --- AI Decision ---

send_input(#{lua_state := undefined, bot_id := BotId, match_pid := MatchPid, game_state := GS}) ->
    Input = default_ai(BotId, GS),
    asobi_match_server:handle_input(MatchPid, BotId, Input);
send_input(#{lua_state := LuaSt, bot_id := BotId, match_pid := MatchPid, game_state := GS}) ->
    Input =
        case asobi_lua_loader:call(think, [BotId, GS], LuaSt, 50) of
            {ok, [Result | _], _} when is_map(Result) -> Result;
            _ -> default_ai(BotId, GS)
        end,
    asobi_match_server:handle_input(MatchPid, BotId, Input).

default_ai(BotId, GameState) ->
    Players = maps:get(players, GameState, maps:get(~"players", GameState, #{})),
    case maps:find(BotId, Players) of
        {ok, Me} ->
            MyX = maps:get(x, Me, maps:get(~"x", Me, 400)),
            MyY = maps:get(y, Me, maps:get(~"y", Me, 300)),
            Target = find_nearest(BotId, MyX, MyY, Players),
            chase_and_shoot(MyX, MyY, Target);
        error ->
            #{}
    end.

find_nearest(BotId, MyX, MyY, Players) ->
    maps:fold(
        fun
            (Id, _, Best) when Id =:= BotId -> Best;
            (_, P, Best) ->
                Hp = maps:get(hp, P, maps:get(~"hp", P, 0)),
                case Hp > 0 of
                    false ->
                        Best;
                    true ->
                        Ex = maps:get(x, P, maps:get(~"x", P, 0)),
                        Ey = maps:get(y, P, maps:get(~"y", P, 0)),
                        Dist = math:sqrt((Ex - MyX) * (Ex - MyX) + (Ey - MyY) * (Ey - MyY)),
                        case Best of
                            undefined -> {Ex, Ey, Dist};
                            {_, _, BestDist} when Dist < BestDist -> {Ex, Ey, Dist};
                            _ -> Best
                        end
                end
        end,
        undefined,
        Players
    ).

chase_and_shoot(_MyX, _MyY, undefined) ->
    #{
        ~"right" => rand:uniform(2) =:= 1,
        ~"left" => rand:uniform(2) =:= 1,
        ~"down" => rand:uniform(2) =:= 1,
        ~"up" => rand:uniform(2) =:= 1,
        ~"shoot" => false
    };
chase_and_shoot(MyX, MyY, {Tx, Ty, Dist}) ->
    #{
        ~"right" => Tx > MyX,
        ~"left" => Tx < MyX,
        ~"down" => Ty > MyY,
        ~"up" => Ty < MyY,
        ~"shoot" => Dist < 200,
        ~"aim_x" => Tx + (rand:uniform(20) - 10),
        ~"aim_y" => Ty + (rand:uniform(20) - 10)
    }.

%% --- Auto Boon Pick ---

maybe_auto_pick_boon(
    #{phase := boon_pick, game_state := GS, match_pid := MatchPid, bot_id := BotId} = State
) ->
    Offers = maps:get(boon_offers, GS, maps:get(~"boon_offers", GS, [])),
    case Offers of
        [Offer | _] when is_map(Offer) ->
            PickId = maps:get(id, Offer, maps:get(~"id", Offer, undefined)),
            case PickId of
                undefined ->
                    State;
                _ ->
                    asobi_match_server:handle_input(
                        MatchPid,
                        BotId,
                        #{~"type" => ~"boon_pick", ~"boon_id" => PickId}
                    ),
                    State#{phase => waiting_vote}
            end;
        _ ->
            State
    end;
maybe_auto_pick_boon(State) ->
    State.

%% --- Auto Vote ---

handle_vote_start(VotePayload, #{match_pid := MatchPid, bot_id := BotId} = State) ->
    VoteId = maps:get(vote_id, VotePayload, maps:get(~"vote_id", VotePayload, undefined)),
    Options = maps:get(options, VotePayload, maps:get(~"options", VotePayload, [])),
    case pick_random_option(Options) of
        undefined ->
            ok;
        OptionId when is_binary(VoteId), is_binary(OptionId) ->
            timer:apply_after(
                1000 + rand:uniform(3000),
                asobi_match_server,
                cast_vote,
                [MatchPid, BotId, VoteId, OptionId]
            );
        _ ->
            ok
    end,
    {noreply, State#{phase => voting}}.

pick_random_option([]) ->
    undefined;
pick_random_option(Options) ->
    Idx = rand:uniform(length(Options)),
    Opt = lists:nth(Idx, Options),
    maps:get(id, Opt, maps:get(~"id", Opt, undefined)).

%% --- Helpers ---

extract_phase(GS) ->
    case maps:get(phase, GS, maps:get(~"phase", GS, playing)) of
        ~"playing" -> playing;
        ~"boon_pick" -> boon_pick;
        ~"voting" -> voting;
        ~"vote_pending" -> voting;
        A when is_atom(A) -> A;
        _ -> playing
    end.
