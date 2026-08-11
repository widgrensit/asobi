-module(asobi_bot_spawner).
-moduledoc """
Watches the matchmaker queue and fills with bots when players are waiting.
Also starts bot AI processes when bots join matches.

Bot names are read from the bot script's `names` global. If not defined,
falls back to default generated names.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("asobi_lua_bots.hrl").

-export([start_link/0]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).
-ifdef(TEST).
-export([fill_mode/2]).
-endif.

-define(CHECK_INTERVAL, 8000).
-define(SCAN_INTERVAL, 2000).
-define(PG_SCOPE, nova_scope).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, map()}.
init([]) ->
    erlang:send_after(?CHECK_INTERVAL, self(), check_queue),
    erlang:send_after(?SCAN_INTERVAL, self(), scan_matches),
    {ok, #{known => #{}}}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(check_queue, State) ->
    fill_queue_with_bots(),
    erlang:send_after(?CHECK_INTERVAL, self(), check_queue),
    {noreply, State};
handle_info(scan_matches, #{known := Known} = State) ->
    Known1 = scan_for_bot_players(Known),
    erlang:send_after(?SCAN_INTERVAL, self(), scan_matches),
    {noreply, State#{known => Known1}};
handle_info(_, State) ->
    {noreply, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_, State) -> {noreply, State}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_, _From, State) -> {reply, ok, State}.

%% --- Queue Filling ---

fill_queue_with_bots() ->
    try asobi_matchmaker:get_queue_stats() of
        {ok, #{by_mode := ByMode}} when map_size(ByMode) > 0 ->
            maps:foreach(fun fill_mode/2, ByMode);
        _ ->
            ok
    catch
        exit:{timeout, _} ->
            ok
    end.

fill_mode(Mode, Count) when is_binary(Mode), Count > 0 ->
    ModeConfig = mode_config(Mode),
    BotConfig = maps:get(bots, ModeConfig, #{}),
    case maps:get(enabled, BotConfig, false) of
        true ->
            MinPlayers = bot_min_players(BotConfig),
            %% Never fill past max_players: a match_size=2/max_players=2
            %% mode with 1 human queued must add at most 1 bot, not
            %% MinPlayers - Count bots that spill into a second match.
            MaxPlayers = mode_max_players(ModeConfig, MinPlayers),
            RawTarget =
                case MinPlayers =< MaxPlayers of
                    true -> MinPlayers;
                    false -> MaxPlayers
                end,
            %% Defense in depth against ?MAX_BOT_FILL: asobi_lua_config
            %% already clamps min_players from Lua, but sys.config-declared
            %% game modes set min_players/max_players directly and bypass
            %% that check entirely (#79 follow-up, HIGH severity DoS fix).
            Target = clamp_fill_target(RawTarget),
            case Count < Target of
                true ->
                    Names = load_bot_names(BotConfig),
                    fill_until(Mode, Count, Target, Names);
                false ->
                    ok
            end;
        false ->
            ok
    end;
fill_mode(_, _) ->
    ok.

clamp_fill_target(Target) when Target > ?MAX_BOT_FILL ->
    ?LOG_WARNING(#{
        msg => ~"bot fill target exceeds ceiling, clamping",
        requested => Target,
        ceiling => ?MAX_BOT_FILL
    }),
    ?MAX_BOT_FILL;
clamp_fill_target(Target) ->
    Target.

%% Adds bots one at a time (rather than building the full
%% lists:seq(1, Target - Count) up front) and stops as soon as the
%% matchmaker reports its queue is full, instead of discarding that error
%% and letting ?CHECK_INTERVAL retry the same unreachable target forever.
%% The name index restarts at 1 each cycle, so low-numbered bots get re-offered
%% while still queued from the last one; `add' hands back their existing ticket
%% and nobody joins. Counting those as progress left the queue permanently short
%% of Target. Skip them and keep walking.
%%
%% At most `Count' of the ids probed can already be queued, so probing
%% Needed + Count of them always reaches Needed free ones. Bounding on Needed
%% alone is what made the original bug: with three bots live and one slot to
%% fill, the walk gives up on the two taken ids before reaching a free one.
fill_until(Mode, Count, Target, Names) ->
    Needed = Target - Count,
    fill_until_loop(Mode, 1, 0, Needed + min(Count, ?MAX_BOT_FILL), Needed, Names).

fill_until_loop(_Mode, _Index, Added, _Limit, Needed, _Names) when Added >= Needed ->
    ok;
fill_until_loop(_Mode, Index, _Added, Limit, _Needed, _Names) when Index > Limit ->
    ok;
fill_until_loop(Mode, Index, Added, Limit, Needed, Names) ->
    BotId = bot_name(Index, Names),
    case asobi_matchmaker:add(BotId, #{mode => Mode}) of
        {error, queue_full} ->
            ?LOG_WARNING(#{
                msg => ~"bot fill stopped: matchmaker queue full",
                mode => Mode,
                bots_added => Added
            });
        {ok, _TicketId, #{already_queued := true}} ->
            fill_until_loop(Mode, Index + 1, Added, Limit, Needed, Names);
        _ ->
            fill_until_loop(Mode, Index + 1, Added + 1, Limit, Needed, Names)
    end.

%% --- Match Scanning ---

-spec scan_for_bot_players(map()) -> map().
scan_for_bot_players(Known) ->
    Groups = pg:which_groups(?PG_SCOPE),
    scan_groups(Groups, Known).

-spec scan_groups(list(), map()) -> map().
scan_groups([], Acc) ->
    Acc;
scan_groups([{asobi_match_server, MatchId} | Rest], Acc) when is_binary(MatchId) ->
    case maps:is_key(MatchId, Acc) of
        true ->
            scan_groups(Rest, Acc);
        false ->
            start_bots_for_match(MatchId),
            scan_groups(Rest, Acc#{MatchId => true})
    end;
scan_groups([_ | Rest], Acc) ->
    scan_groups(Rest, Acc).

start_bots_for_match(MatchId) ->
    case pg:get_members(?PG_SCOPE, {asobi_match_server, MatchId}) of
        [MatchPid | _] ->
            try asobi_match_server:get_info(MatchPid) of
                #{players := Players, mode := Mode} when is_list(Players) ->
                    BotScript = bot_script(Mode),
                    BotPlayers = [Id || Id <- Players, is_bot(Id)],
                    lists:foreach(
                        fun
                            (BotId) when is_binary(BotId) ->
                                case asobi_bot_sup:start_bot(MatchPid, BotId, BotScript) of
                                    {ok, _} ->
                                        logger:info(#{
                                            msg => ~"bot AI started", bot_id => BotId
                                        });
                                    {error, _} ->
                                        ok
                                end;
                            (_) ->
                                ok
                        end,
                        BotPlayers
                    );
                _ ->
                    ok
            catch
                _:_ -> ok
            end;
        [] ->
            ok
    end.

%% --- Config Helpers ---

load_bot_names(#{names := Names}) when is_list(Names) ->
    Names;
load_bot_names(#{script := Script}) when is_binary(Script); is_list(Script) ->
    case asobi_lua_loader:new(Script) of
        {ok, St} ->
            case luerl:get_table_keys([~"names"], St) of
                {ok, Val, St1} when Val =/= nil, Val =/= false ->
                    case luerl:decode(Val, St1) of
                        Props when is_list(Props) ->
                            [V || {_, V} <- Props, is_binary(V)];
                        _ ->
                            default_names()
                    end;
                _ ->
                    default_names()
            end;
        {error, _} ->
            default_names()
    end;
load_bot_names(_) ->
    default_names().

mode_config(Mode) ->
    maps:get(Mode, asobi_game_config:modes(), #{}).

bot_config(Mode) ->
    case mode_config(Mode) of
        #{bots := Bots} when is_map(Bots) -> Bots;
        _ -> #{}
    end.

bot_min_players(BotConfig) ->
    case maps:get(min_players, BotConfig, 4) of
        MP when is_integer(MP), MP > 0 -> MP;
        _ -> 4
    end.

mode_max_players(ModeConfig, Default) ->
    case maps:get(max_players, ModeConfig, Default) of
        MP when is_integer(MP), MP > 0 -> MP;
        _ -> Default
    end.

bot_script(Mode) ->
    case bot_config(Mode) of
        #{script := Script} when is_binary(Script); is_list(Script) -> Script;
        _ -> undefined
    end.

is_bot(<<"bot_", _/binary>>) -> true;
is_bot(_) -> false.

bot_name(N, Names) when is_list(Names), N =< length(Names) ->
    case lists:nth(N, Names) of
        Name when is_binary(Name) -> <<"bot_", Name/binary>>;
        _ -> <<"bot_", (integer_to_binary(N))/binary>>
    end;
bot_name(N, _) ->
    <<"bot_", (integer_to_binary(N))/binary>>.

default_names() ->
    [~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"].
