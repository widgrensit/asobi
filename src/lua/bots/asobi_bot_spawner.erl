-module(asobi_bot_spawner).
-moduledoc """
Watches the matchmaker queue and fills with bots when players are waiting.
Also starts bot AI processes when bots join matches.

Bot names are read from the bot script's `names` global. If not defined,
falls back to default generated names.

`add_bot/2` and `remove_bot/2` are the other route in: a match script placing
a bot itself, rather than a mode opting in to queue fill. Queue fill answers
"not enough humans are waiting"; a script answers "this match wants a bot,
now", which is a question only the game can answer. They share the
`?MAX_BOT_FILL` ceiling, so a script cannot spawn processes without bound.

Both run here rather than in the match server because `asobi_bot` joins its
match from its own `init/1`: starting one from inside the match process would
block that process in `supervisor:start_child/2` while the new bot waited on
it to answer the join.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("asobi_lua_bots.hrl").

-export([start_link/0]).
-export([add_bot/2, remove_bot/2, validate_bot_name/1]).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).
-ifdef(TEST).
-export([fill_mode/2, do_add_bot/2, do_remove_bot/2]).
-endif.

%% Same shape as a broadcast event name, and deliberately excludes `.`: the id
%% reaches a client in the match roster and is used as a pg group key.
-define(MAX_BOT_NAME, 32).

-define(CHECK_INTERVAL, 8000).
-define(SCAN_INTERVAL, 2000).
-define(PG_SCOPE, nova_scope).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Place a bot in a live match. `Name` is bare - the `bot_` prefix every bot id
carries is added here, so a script never has to know about it.

Silently does nothing if the match is gone, full, already holds a bot by that
name, or is already at the bot ceiling; a script calling this on every tick
must not turn into an error stream.
""".
-spec add_bot(pid(), binary()) -> ok.
add_bot(MatchPid, Name) when is_pid(MatchPid), is_binary(Name) ->
    gen_server:cast(?MODULE, {add_bot, MatchPid, Name}).

-doc """
Remove a bot from a live match, by bare name or by full `bot_`-prefixed id -
the roster a script reads holds the prefixed form, and a script that passes
back what it read should not have to strip it.

Stopping the bot process is what removes it: `asobi_bot:terminate/2` leaves
the match on the way out.
""".
-spec remove_bot(pid(), binary()) -> ok.
remove_bot(MatchPid, BotId) when is_pid(MatchPid), is_binary(BotId) ->
    gen_server:cast(?MODULE, {remove_bot, MatchPid, BotId}).

-doc "Whether `Name` is usable as a bot name, with the reason when it is not.".
-spec validate_bot_name(binary()) -> ok | {error, binary()}.
validate_bot_name(<<>>) ->
    {error, ~"bot name must not be empty"};
validate_bot_name(Name) when byte_size(Name) > ?MAX_BOT_NAME ->
    {error, ~"bot name must be at most 32 bytes"};
validate_bot_name(Name) when is_binary(Name) ->
    case lists:all(fun is_bot_name_char/1, binary_to_list(Name)) of
        true -> ok;
        false -> {error, ~"bot name must be [A-Za-z0-9_-]"}
    end.

is_bot_name_char(C) when C >= $a, C =< $z -> true;
is_bot_name_char(C) when C >= $A, C =< $Z -> true;
is_bot_name_char(C) when C >= $0, C =< $9 -> true;
is_bot_name_char(C) when C =:= $_; C =:= $- -> true;
is_bot_name_char(_) -> false.

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
handle_cast({add_bot, MatchPid, Name}, State) when is_pid(MatchPid), is_binary(Name) ->
    do_add_bot(MatchPid, Name),
    {noreply, State};
handle_cast({remove_bot, MatchPid, BotId}, State) when is_pid(MatchPid), is_binary(BotId) ->
    do_remove_bot(MatchPid, BotId),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

%% --- Script-driven bots ---

-spec do_add_bot(pid(), binary()) -> ok.
do_add_bot(MatchPid, Name) ->
    BotId = <<"bot_", Name/binary>>,
    try asobi_match_server:get_info(MatchPid) of
        #{players := Players, mode := Mode, max_players := Max} when is_list(Players) ->
            case add_bot_refusal(BotId, Players, Max) of
                ok ->
                    start_bot(MatchPid, BotId, bot_script(Mode));
                {refused, Reason} ->
                    ?LOG_INFO(#{
                        msg => ~"bot not added", bot_id => BotId, reason => Reason
                    }),
                    ok
            end;
        _ ->
            ok
    catch
        %% The match ended between the script's call and this cast. Nothing to
        %% add a bot to, and nothing worth logging.
        _:_ ->
            ok
    end.

-spec add_bot_refusal(binary(), [binary()], pos_integer()) -> ok | {refused, atom()}.
add_bot_refusal(BotId, Players, Max) ->
    Bots = length([Id || Id <- Players, is_bot(Id)]),
    case lists:member(BotId, Players) of
        true ->
            {refused, already_in_match};
        false when length(Players) >= Max ->
            {refused, match_full};
        false when Bots >= ?MAX_BOT_FILL ->
            {refused, bot_ceiling_reached};
        false ->
            ok
    end.

-spec start_bot(pid(), binary(), binary() | undefined) -> ok.
start_bot(MatchPid, BotId, Script) ->
    %% A bot with no script still plays - asobi_bot falls back to its built-in
    %% AI - but that is nearly always an unconfigured mode rather than a
    %% choice, so it is worth one line in the log.
    case Script of
        undefined ->
            ?LOG_INFO(#{msg => ~"bot added with no script, using default AI", bot_id => BotId});
        _ ->
            ok
    end,
    case asobi_bot_sup:start_bot(MatchPid, BotId, Script) of
        {ok, _} ->
            ?LOG_INFO(#{msg => ~"bot AI started", bot_id => BotId});
        {error, Reason} ->
            ?LOG_WARNING(#{msg => ~"bot start failed", bot_id => BotId, reason => Reason})
    end,
    ok.

%% Stopping the process is the removal: asobi_bot:terminate/2 leaves the match.
%% Killing it instead would leave the roster to the match server's monitor,
%% which under a reconnect policy holds the slot open for the grace window -
%% a bot the script removed would linger.
-spec do_remove_bot(pid(), binary()) -> ok.
do_remove_bot(MatchPid, BotId0) ->
    BotId =
        case is_bot(BotId0) of
            true -> BotId0;
            false -> <<"bot_", BotId0/binary>>
        end,
    case asobi_presence:bot_pids(BotId) of
        [] ->
            %% A bot id in the roster with no live process (its AI crashed,
            %% say) is still the script's to remove, so fall through to a
            %% plain leave.
            asobi_match_server:leave(MatchPid, BotId);
        Pids ->
            lists:foreach(fun(Pid) when is_pid(Pid) -> stop_bot(Pid) end, Pids)
    end.

%% Bots on the roster with no AI process yet. Skipping the ones that have one
%% matters because a script can place a bot (add_bot/2) before this match is
%% scanned for the first time, and starting a second process for the same id
%% would put two AIs on one roster slot.
-spec bots_needing_ai([term()]) -> [binary()].
bots_needing_ai(Players) ->
    [
        Id
     || Id <- Players,
        is_binary(Id),
        is_bot(Id),
        asobi_presence:bot_pids(Id) =:= []
    ].

-spec stop_bot(pid()) -> ok.
stop_bot(Pid) ->
    try
        gen_server:stop(Pid, normal, 5000)
    catch
        _:_ -> ok
    end.

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
fill_until(Mode, Count, Target, Names) ->
    fill_until_loop(Mode, 1, Target - Count, Names).

fill_until_loop(_Mode, N, Needed, _Names) when N > Needed ->
    ok;
fill_until_loop(Mode, N, Needed, Names) ->
    BotId = bot_name(N, Names),
    case asobi_matchmaker:add(BotId, #{mode => Mode}) of
        {error, queue_full} ->
            ?LOG_WARNING(#{
                msg => ~"bot fill stopped: matchmaker queue full",
                mode => Mode,
                bots_added => N - 1
            });
        _ ->
            fill_until_loop(Mode, N + 1, Needed, Names)
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
                    lists:foreach(
                        fun(BotId) when is_binary(BotId) ->
                            start_bot(MatchPid, BotId, BotScript)
                        end,
                        bots_needing_ai(Players)
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
