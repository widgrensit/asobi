-module(asobi_bot_spawner).
-moduledoc """
Watches the matchmaker queue and fills with bots when players are waiting.
Also starts bot AI processes when bots join matches.

Configuration per game mode:
```erlang
#{
    ~"arena" => #{
        module => {lua, "priv/lua/match.lua"},
        bots => #{
            enabled => true,
            fill_after_ms => 8000,
            min_players => 4,
            script => "priv/lua/bots/chaser.lua",
            names => [~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"]
        }
    }
}
```
""".

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).

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
    case asobi_matchmaker:get_queue_stats() of
        {ok, #{by_mode := ByMode}} when map_size(ByMode) > 0 ->
            maps:foreach(fun fill_mode/2, ByMode);
        _ ->
            ok
    end.

fill_mode(Mode, Count) when is_binary(Mode), Count > 0 ->
    BotConfig = bot_config(Mode),
    case maps:get(enabled, BotConfig, false) of
        true ->
            MinPlayers = maps:get(min_players, BotConfig, 4),
            case Count < MinPlayers of
                true ->
                    Names = maps:get(names, BotConfig, default_names()),
                    BotsNeeded = MinPlayers - Count,
                    lists:foreach(
                        fun(N) ->
                            BotId = bot_name(N, Names),
                            asobi_matchmaker:add(BotId, #{mode => Mode})
                        end,
                        lists:seq(1, BotsNeeded)
                    );
                false ->
                    ok
            end;
        false ->
            ok
    end;
fill_mode(_, _) ->
    ok.

%% --- Match Scanning ---

scan_for_bot_players(Known) ->
    Groups = pg:which_groups(?PG_SCOPE),
    lists:foldl(
        fun
            ({asobi_match_server, MatchId}, Acc) when is_binary(MatchId) ->
                case maps:is_key(MatchId, Acc) of
                    true ->
                        Acc;
                    false ->
                        start_bots_for_match(MatchId),
                        Acc#{MatchId => true}
                end;
            (_, Acc) ->
                Acc
        end,
        Known,
        Groups
    ).

start_bots_for_match(MatchId) ->
    case pg:get_members(?PG_SCOPE, {asobi_match_server, MatchId}) of
        [MatchPid | _] ->
            try asobi_match_server:get_info(MatchPid) of
                #{players := Players, mode := Mode} when is_list(Players) ->
                    BotScript = bot_script(Mode),
                    BotPlayers = [Id || Id <- Players, is_bot(Id)],
                    lists:foreach(
                        fun(BotId) ->
                            case asobi_bot_sup:start_bot(MatchPid, BotId, BotScript) of
                                {ok, _} ->
                                    logger:info(#{msg => ~"bot AI started", bot_id => BotId});
                                {error, _} ->
                                    ok
                            end
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

bot_config(Mode) ->
    Modes =
        case application:get_env(asobi, game_modes, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    case maps:get(Mode, Modes, #{}) of
        #{bots := Bots} when is_map(Bots) -> Bots;
        _ -> #{}
    end.

bot_script(Mode) ->
    case bot_config(Mode) of
        #{script := Script} when is_binary(Script); is_list(Script) -> Script;
        _ -> undefined
    end.

is_bot(<<"bot_", _/binary>>) -> true;
is_bot(_) -> false.

bot_name(N, Names) when is_list(Names), N =< length(Names) ->
    Name = lists:nth(N, Names),
    <<"bot_", Name/binary>>;
bot_name(N, _) ->
    <<"bot_", (integer_to_binary(N))/binary>>.

default_names() ->
    [~"Spark", ~"Blitz", ~"Volt", ~"Neon", ~"Pulse"].
