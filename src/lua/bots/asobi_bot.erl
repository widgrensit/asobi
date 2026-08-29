-module(asobi_bot).
-moduledoc """
Generic bot process that runs a Lua AI script each tick.

The bot joins a match as a player, receives game state updates,
and sends input decisions based on the Lua `think(bot_id, state)` function.

Also handles auto boon picking and auto voting.

A bot is tracked through `asobi_presence:track_bot/2`, so it is a delivery
target for `asobi_presence:send/2` like any player session but is never
counted by `asobi_presence:online_count/0`. The messages it consumes are the
public `t:asobi_presence:message/0` contract, not an ad-hoc shape.

Both state strategies arrive as `{match_state, map()}`. Under
`state_strategy = "shared"` the match server still encodes once for the whole
roster, and `asobi_presence:send_match_state/3` hands the bot the term behind
that frame rather than the frame, so a bot decodes nothing per tick.

The Luerl state is threaded across ticks, so a bot script's globals persist
between `think` calls the way a match script's do. A bot therefore pays the same
per-tick copy a match bridge does, and `asobi_lua_loader:collect_state/1` runs
before each call on the same adaptive schedule.

Collection bounds garbage, not what a script keeps live, and Luerl's mark phase
is quadratic in the live set - so a script that hoards drives the collector past
its budget until it gives up on that state entirely. `?MAX_STATE_WORDS` is the
backstop: past it the script is reloaded and its globals are gone. A bot is the
one Lua bridge where that is affordable, because nothing a player can see lives
in its state.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/3]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, format_status/1]).

-define(TICK_INTERVAL, 100).

%% 10 MB at 8 bytes a word. The per-bot cooldown table guides/lua-bots.md
%% describes is three orders of magnitude under this; a bot past it is holding
%% something it should not, and would otherwise sit at ~100 ms a tick copying it
%% into every bounded call for the rest of the match. Override with
%% `{asobi, [{max_bot_state_words, N}]}`.
-define(DEFAULT_MAX_STATE_WORDS, 1_250_000).

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
    asobi_presence:track_bot(BotId, self()),
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
        script => LuaScript,
        lua_bridge => #{kind => bot, bot_id => BotId, match_id => match_id(MatchPid)},
        game_state => #{},
        phase => playing
    }}.

%% Groups a bot's telemetry with the match it plays in. `bot_id` alone joins to
%% nothing: it carries a random discriminator per bot instance and is never
%% reused, so it is a correlation aid in a trace and never a label.
match_id(MatchPid) ->
    try asobi_match_server:get_info(MatchPid) of
        #{match_id := MatchId} -> MatchId;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, term(), map()}.
handle_info(tick, #{phase := playing} = State) ->
    State1 = send_input(State),
    erlang:send_after(?TICK_INTERVAL, self(), tick),
    {noreply, State1};
handle_info(tick, State) ->
    erlang:send_after(?TICK_INTERVAL, self(), tick),
    {noreply, State};
handle_info({asobi_message, Message}, State) ->
    handle_presence_message(Message, State);
handle_info({'DOWN', _, process, MatchPid, _}, #{match_pid := MatchPid} = State) ->
    {stop, normal, State};
handle_info(_, State) ->
    {noreply, State}.

%% `dynamic()` because a gen_server mailbox is a boundary: what arrives is
%% `term()` and only the clause heads below decide what it was. The shapes those
%% heads match are `t:asobi_presence:message/0` - named shapes core has to keep,
%% not an ad-hoc guess at an internal protocol - and the contract is still
%% enforced on the producing side, at the `asobi_presence:send/2` call.
-spec handle_presence_message(dynamic(), map()) ->
    {noreply, map()} | {stop, term(), map()}.
handle_presence_message({match_state, GameState}, State) when is_map(GameState) ->
    Phase = extract_phase(GameState),
    State1 = State#{game_state => GameState, phase => Phase},
    State2 = maybe_auto_pick_boon(State1),
    {noreply, State2};
handle_presence_message({match_event, vote_start, VotePayload}, State) when
    is_map(VotePayload)
->
    handle_vote_start(VotePayload, State);
handle_presence_message({match_event, finished, _}, State) ->
    {stop, normal, State};
handle_presence_message(Message, #{bot_id := BotId} = State) when is_tuple(Message) ->
    %% A bot ignores most of what a match broadcasts, so this is debug and
    %% not a warning. It exists because a delivery shape no clause here
    %% matches is otherwise indistinguishable from a bot with nothing to
    %% do: turn debug on for this module to see what a stalled bot is
    %% being sent. Only the tag is logged, never the payload.
    ?LOG_DEBUG(#{
        msg => ~"bot_unhandled_presence_message",
        bot_id => BotId,
        message => element(1, Message)
    }),
    {noreply, State};
handle_presence_message(_, State) ->
    {noreply, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_, State) ->
    {noreply, State}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_, _From, State) ->
    {reply, ok, State}.

%% The Luerl state runs to megabytes, and a crash report or a `sys:get_status`
%% would format the whole of it on the logger's process. Nothing reading a bot's
%% status needs it.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(#{state := State} = Status) when is_map(State) ->
    Status#{state => State#{lua_state => '#luerl{}'}};
format_status(Status) ->
    Status.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{bot_id := BotId, match_pid := MatchPid}) ->
    asobi_presence:untrack_bot(BotId, self()),
    try
        asobi_match_server:leave(MatchPid, BotId)
    catch
        _:_ -> ok
    end,
    ok;
terminate(_, _) ->
    ok.

%% --- AI Decision ---

%% I-6: when `think/2` errors the bot silently falls back to the
%% built-in default AI. That hides bugs in operator scripts. Emit a
%% rate-limited warning (one log line per bot per minute) so a
%% persistently-broken script is visible without spamming logs.
-define(THINK_LOG_INTERVAL_MS, 60000).

send_input(
    #{lua_state := undefined, bot_id := BotId, match_pid := MatchPid, game_state := GS} = State
) ->
    Input = default_ai(BotId, GS),
    asobi_match_server:handle_input(MatchPid, BotId, Input),
    State;
send_input(#{lua_state := _} = State0) ->
    State = collect_lua_state(State0),
    #{lua_state := LuaSt, bot_id := BotId, match_pid := MatchPid, game_state := GS} = State,
    {Input, LuaSt1, State1} = run_think(BotId, GS, LuaSt, State),
    asobi_match_server:handle_input(MatchPid, BotId, Input),
    State1#{lua_state => LuaSt1}.

run_think(BotId, GS, LuaSt, State) ->
    {EncGS, LuaSt1} = asobi_lua_loader:encode(GS, LuaSt),
    case asobi_lua_loader:call(think, [BotId, EncGS], LuaSt1, 50) of
        {ok, [Result | _], LuaSt2} ->
            {decode_result(Result, LuaSt2), LuaSt2, State};
        %% A `think` that returns nothing still ran, and may have written a
        %% counter this bot needs on the next call. Keep its state; only the
        %% input falls back.
        {ok, [], LuaSt2} ->
            {default_ai(BotId, GS), LuaSt2, State};
        %% `LuaSt`, not `LuaSt1`: a failed call is rolled back past the encode
        %% too, so a bot that fails every tick cannot grow the state it is
        %% failing on. Under `copy` the worker mutated its own copy and this one
        %% was never touched - if bots ever move to an owned VM (ADR 0015) a
        %% timeout kills that VM and this handle needs rebuilding, not keeping.
        {error, Reason} ->
            {default_ai(BotId, GS), LuaSt, note_think_error(Reason, State)}
    end.

%% No anchor: unlike a match or a zone, `game_state` on a bot is an Erlang term
%% re-encoded every tick rather than a Luerl reference held across calls, and
%% handing it to the collector would root a non-Luerl value in `_G`.
collect_lua_state(State) ->
    #{lua_state := LuaSt, lua_gc := Gc} =
        asobi_lua_loader:collect_state(maps:without([game_state], State)),
    reload_if_oversized(State#{lua_state => LuaSt, lua_gc => Gc}).

reload_if_oversized(#{lua_gc := #{words := Words}} = State) when is_integer(Words) ->
    reload_if_oversized(Words, max_state_words(), State);
reload_if_oversized(State) ->
    State.

reload_if_oversized(Words, Ceiling, #{script := Path, bot_id := BotId} = State) when
    Words > Ceiling
->
    ?LOG_WARNING(#{
        event => bot_lua_state_reloaded,
        bot_id => BotId,
        state_words => Words,
        ceiling_words => Ceiling,
        msg =>
            ~"A bot script kept more alive across think calls than the ceiling allows. Its Lua state was reloaded from disk, so its globals are gone and any cooldown it was tracking has reset. Keep less between calls."
    }),
    %% Remove rather than reset to `#{}`: `collect_state/1` seeds its bookkeeping
    %% only when the key is absent, and an empty map matches no `maybe_gc/4`
    %% clause.
    maps:remove(lua_gc, State#{lua_state => reload(Path)});
reload_if_oversized(_Words, _Ceiling, State) ->
    State.

max_state_words() ->
    case asobi_lua_env:get_env(max_bot_state_words, ?DEFAULT_MAX_STATE_WORDS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_MAX_STATE_WORDS
    end.

reload(Path) when is_binary(Path); is_list(Path) ->
    case asobi_lua_loader:new(Path) of
        {ok, St} -> St;
        {error, _} -> undefined
    end;
reload(_) ->
    undefined.

%% Throttled in the bot's own state rather than in `persistent_term`: a bot id
%% carries a random discriminator and is never reused, so a global key per bot
%% would be a table that only ever grows, and every write scans the literal area
%% across all processes.
-spec note_think_error(term(), map()) -> map().
note_think_error(Reason, #{bot_id := BotId} = State) ->
    Now = erlang:system_time(millisecond),
    case Now - maps:get(last_think_error, State, 0) >= ?THINK_LOG_INTERVAL_MS of
        true ->
            ?LOG_WARNING(#{
                event => bot_think_error_falling_back_to_default_ai,
                bot_id => BotId,
                reason => bounded(Reason, 4)
            }),
            State#{last_think_error => Now};
        false ->
            State
    end.

%% A script chooses the value it raises with, and it can raise with megabytes -
%% which the logger would then format on its own process. `binary:part/3` on a
%% refc binary is O(1), so the bound costs nothing. The `[H | T]` clause rather
%% than an `is_list/1` guard: `is_list/1` admits an improper list, and a
%% comprehension over one raises inside this function.
bounded(B, _Depth) when is_binary(B), byte_size(B) > 256 ->
    <<(binary:part(B, 0, 256))/binary, "...">>;
bounded(T, Depth) when is_tuple(T), Depth > 0 ->
    list_to_tuple([bounded(E, Depth - 1) || E <- tuple_to_list(T)]);
bounded([H | T], Depth) when Depth > 0 ->
    [bounded(H, Depth - 1) | bounded(T, Depth - 1)];
bounded(Other, _Depth) ->
    Other.

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
    _ =
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

-spec pick_random_option([map()]) -> term().
pick_random_option([]) ->
    undefined;
pick_random_option(Options) ->
    Idx = rand:uniform(length(Options)),
    Opt = lists:nth(Idx, Options),
    case is_map(Opt) of
        true -> maps:get(id, Opt, maps:get(~"id", Opt, undefined));
        false -> undefined
    end.

-spec decode_result(term(), term()) -> map().
decode_result(Result, LuaSt) ->
    try
        do_decode_result(Result, LuaSt)
    catch
        %% `luerl:decode/2` raises on a table that references itself, which a
        %% script can return by accident. That costs this tick's input, not the
        %% bot: an uncaught raise here kills a `temporary` child, so the match
        %% would silently lose a player for the rest of its life.
        _:_ ->
            #{}
    end.

do_decode_result(Result, _LuaSt) when is_map(Result) ->
    Result;
do_decode_result(Result, LuaSt) ->
    case asobi_lua_loader:decode(Result, LuaSt) of
        L when is_list(L) -> props_to_map(L, #{});
        M when is_map(M) -> M;
        _ -> #{}
    end.

-spec props_to_map(list(), map()) -> map().
props_to_map([], Acc) ->
    Acc;
props_to_map([{K, V} | T], Acc) when is_binary(K) ->
    case sendable(V) of
        true -> props_to_map(T, Acc#{K => V});
        false -> props_to_map(T, Acc)
    end;
props_to_map([_ | T], Acc) ->
    props_to_map(T, Acc).

%% An input crosses into the match script's own Luerl state and is broadcast
%% from there, so it carries only what a client could have sent. A `think`
%% returning a function decodes to a callable: not JSON-encodable, and no
%% business in another bridge's state. Nested tables are kept - a bot may send
%% the same shaped input a player can.
sendable(V) when is_function(V); is_pid(V); is_port(V); is_reference(V) ->
    false;
sendable([H | T]) ->
    sendable(H) andalso sendable(T);
sendable({K, V}) ->
    sendable(K) andalso sendable(V);
sendable(_) ->
    true.

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
