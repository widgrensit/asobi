-module(asobi_lua_match).
-moduledoc """
An `asobi_match` implementation that delegates all callbacks to Lua scripts
via Luerl.

Game developers write their match logic in Lua. This module bridges the
`asobi_match` behaviour to Luerl function calls.

## Configuration

In game_modes config, use `{lua, ScriptPath}` instead of a module name:

```erlang
{asobi, [
    {game_modes, #{
        ~"arena" => #{module => {lua, "priv/lua/match.lua"}, match_size => 4}
    }}
]}
```

The Lua script must define these functions:

```lua
function init(config)        -- return initial game state table
function join(player_id, state, ctx)  -- return updated state, or nil[, reason] to refuse
function leave(player_id, state)      -- return updated state
function handle_input(player_id, input, state) -- return updated state
function tick(state)         -- return state, or state + finished flag
function get_state(player_id, state)  -- return state visible to player
-- Optional:
function vote_requested(state)        -- return vote config or nil
function vote_resolved(template, result, state) -- return updated state
function phases(config)                      -- return list of phase definitions
function on_phase_started(phase_name, state) -- return updated state
function on_phase_ended(phase_name, state)   -- return updated state
```
""".

-behaviour(asobi_match).

-include_lib("kernel/include/logger.hrl").

-export([init/1, join/2, join/3, leave/2, handle_input/3, tick/1, get_state/2]).
-export([vote_requested/1, vote_resolved/3]).

-ifdef(TEST).
-export([normalise_vote_config/1]).
-endif.
-export([phases/1, on_phase_started/2, on_phase_ended/2]).

%% A sandboxed Lua callback runs in a child process so the parent
%% gen_server stays responsive. These wall-clock budgets cap how long a
%% misbehaving script can hold the channel — `init` gets the most slack
%% because game state may be expensive to build, the per-tick callbacks
%% get the least because they run hundreds of times per second.
-define(INIT_TIMEOUT, 1000).
-define(TICK_TIMEOUT, 500).
-define(JOIN_TIMEOUT, 200).
-define(LEAVE_TIMEOUT, 200).
-define(GET_STATE_TIMEOUT, 100).
-define(VOTE_TIMEOUT, 200).
-define(PHASE_TIMEOUT, 200).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath =
        case maps:get(lua_script, Config, undefined) of
            P when is_binary(P); is_list(P) ->
                P;
            undefined ->
                ?LOG_ERROR(#{msg => ~"asobi_lua_match init: missing lua_script", config => Config}),
                erlang:error({missing_lua_script, Config})
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    Ctx = #{
        vm => match,
        match_id => maps:get(match_id, Config, undefined),
        match_pid => self(),
        script => ScriptPath
    },
    PreInstall = fun(St) -> asobi_lua_api:install(Ctx, St) end,
    case asobi_lua_loader:new(ScriptPath, ?INIT_TIMEOUT, PreInstall) of
        {ok, LuaSt0} ->
            {EncConfig, LuaSt1} = luerl:encode(GameConfig, LuaSt0),
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1, ?INIT_TIMEOUT) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{
                        lua_state => LuaSt2,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath)
                    }};
                {ok, [], _} ->
                    %% asobi_match:init/1 doesn't allow an error return; log and
                    %% crash so the supervisor handles it with full context.
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_match init: lua init() returned no value",
                        script => ScriptPath
                    }),
                    erlang:error({lua_error, ~"init() must return a table"});
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_match init: lua init() failed",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    erlang:error({lua_init_failed, Reason})
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"asobi_lua_match init: lua_loader:new/1 failed",
                script => ScriptPath,
                reason => Reason
            }),
            erlang:error({lua_load_failed, ScriptPath, Reason})
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, State) ->
    join(PlayerId, #{}, State).

-doc """
Join carrying the client-supplied join context (asobi's optional `join/3`).

The context is passed to the Lua `join` as a third argument, so a script
declaring `function join(player_id, state)` keeps working unchanged - Lua
discards extra arguments - and one declaring
`function join(player_id, state, ctx)` receives it.

Without this, `ctx` would reach asobi, find no `join/3` on the Lua bridge,
fall back to `join/2` and be silently discarded - so every Lua game would
be unable to implement join codes, invites or passwords despite the docs
saying otherwise.

Returning `nil` refuses the join, optionally with a reason string:

```lua
function join(player_id, state, ctx)
    if state.locked then return nil, "match_locked" end
    if ctx.code ~= state.join_code then return nil, "wrong_code" end
    state.players[player_id] = { hp = 100 }
    return state
end
```

A refused player is never added to the roster and the Lua state is left
exactly as it was before the call, so a refusal leaves no trace in the game
state. The reason reaches the client; it is game vocabulary, so it travels
in `details` and never becomes an asobi error code (see `m:asobi_error`).
""".
-spec join(binary(), map(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, Ctx, #{lua_state := LuaSt, game_state := GS} = State) when is_map(Ctx) ->
    %% Erlang maps must be encoded before they cross into Luerl - GS is
    %% already a Lua value, but Ctx arrives raw from the client.
    {EncCtx, LuaSt0} = luerl:encode(Ctx, LuaSt),
    case asobi_lua_loader:call(join, [PlayerId, GS, EncCtx], LuaSt0, ?JOIN_TIMEOUT) of
        {ok, [Falsey | Rest], LuaSt1} when Falsey =:= nil; Falsey =:= false ->
            {error, {join_refused, refusal_reason(Rest, LuaSt1)}};
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        %% A `join` that falls off its end returns no values at all. Before
        %% refusal existed this was a case_clause that killed the match
        %% server and with it every player already in the roster; a script
        %% bug must cost the author their own join, not the whole match.
        {ok, [], _LuaSt1} ->
            log_match_lua_error(
                warning, join, join_returned_no_state, State, #{player_id => PlayerId}
            ),
            {error, {join_refused, undefined}};
        {error, Reason} ->
            log_match_lua_error(warning, join, Reason, State, #{player_id => PlayerId}),
            {error, Reason}
    end.

%% The refusal reason is author-written and reaches a client, so it is bounded
%% the same way a broadcast event name is: short, ASCII, no control bytes. An
%% out-of-shape reason is dropped rather than rejected - the refusal itself is
%% what matters, and failing it over a bad label would be worse.
-define(MAX_REFUSAL_REASON, 64).

-spec refusal_reason([dynamic()], dynamic()) -> binary() | undefined.
refusal_reason([Value | _], LuaSt) ->
    case luerl:decode(Value, LuaSt) of
        Reason when is_binary(Reason), byte_size(Reason) =< ?MAX_REFUSAL_REASON, Reason =/= <<>> ->
            case is_printable_ascii(Reason) of
                true -> Reason;
                false -> undefined
            end;
        _ ->
            undefined
    end;
refusal_reason([], _LuaSt) ->
    undefined.

-spec is_printable_ascii(binary()) -> boolean().
is_printable_ascii(Bin) ->
    lists:all(fun(B) -> B >= 32 andalso B =< 126 end, binary_to_list(Bin)).

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt, ?LEAVE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            log_match_lua_error(warning, leave, Reason, State, #{player_id => PlayerId}),
            {ok, State}
    end.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(PlayerId, Input, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncInput, LuaSt1} = luerl:encode(Input, LuaSt),
    %% No bounded_eval: the per-input spawn dominates real Lua work at
    %% high input rates. tick/1 still spawn-isolates. See ADR 0002.
    case asobi_lua_loader:call(handle_input, [PlayerId, EncInput, GS], LuaSt1) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, Reason} ->
            %% The raw reason can embed player input via Lua error()/assert()
            %% and is unbounded - log a classified, capped rendering so a
            %% failing handler under input load cannot amplify into the logs.
            log_match_lua_error(warning, handle_input, Reason, State, #{player_id => PlayerId}),
            State1 = asobi_lua_dev_errors:maybe_notify(handle_input, Reason, PlayerId, State),
            {ok, State1}
    end.

-spec tick(map()) -> {ok, map()} | {finished, map(), map()}.
tick(State0) ->
    #{lua_state := LuaSt, game_state := GS} = State = asobi_lua_reload:maybe_hot_reload(State0),
    case asobi_lua_loader:call(tick, [GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            Finished = is_finished(GS1, LuaSt1),
            %% #426: same per-tick Luerl leak as the zone path.
            State1 = asobi_lua_loader:collect_state(State#{
                lua_state => LuaSt1, game_state => GS1
            }),
            case Finished of
                {true, Result} -> {finished, Result, State1};
                false -> {ok, State1}
            end;
        {error, timeout} ->
            log_match_lua_error(error, tick, timeout, State),
            {ok, State};
        {error, Reason} ->
            log_match_lua_error(error, tick, Reason, State),
            {ok, State}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS} = _State) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt, ?GET_STATE_TIMEOUT) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

-spec vote_requested(map()) -> {ok, map()} | none.
vote_requested(#{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(vote_requested, [GS], LuaSt, ?VOTE_TIMEOUT) of
        {ok, [nil | _], _} ->
            none;
        {ok, [false | _], _} ->
            none;
        {ok, [Config | _], LuaSt1} ->
            Decoded = normalise_vote_config(decode_to_map(Config, LuaSt1)),
            case map_size(Decoded) of
                0 -> none;
                _ -> {ok, Decoded}
            end;
        _ ->
            none
    end.

%% asobi#489: a Lua table decodes with binary keys, and asobi_vote_server reads
%% atom ones - `maps:get(options, Merged)` has no default, so a binary-keyed
%% config raised badkey, the vote server failed to start, and do_start_vote/3
%% matched `{error, _} -> State`. The vote silently never happened: no
%% vote_start frame, no log line naming the script. guides/voting.md called it
%% "the one feature you cannot reach" from Lua.
%%
%% Translated against a fixed whitelist rather than binary_to_atom/2 on whatever
%% the script wrote: script-supplied keys are untrusted input and converting
%% them wholesale is an atom-table exhaustion vector. A key not on the list is
%% left as the script wrote it, so it reaches the vote server as a binary key it
%% ignores, which is the same outcome as not setting it.
-define(VOTE_CONFIG_KEYS, [
    template,
    vote_id,
    options,
    window_ms,
    method,
    visibility,
    tie_breaker,
    veto_enabled,
    max_revotes,
    window_type,
    min_window_ms,
    supermajority,
    require_supermajority,
    quorum,
    default_votes,
    delegation,
    spectator_weight
]).

-define(VOTE_OPTION_KEYS, [id, label]).

-spec normalise_vote_config(map()) -> map().
normalise_vote_config(Config) ->
    Atomised = atomise_keys(?VOTE_CONFIG_KEYS, Config),
    case maps:get(options, Atomised, undefined) of
        Options when is_list(Options) ->
            Atomised#{options => [atomise_option(O) || O <- Options]};
        _ ->
            Atomised
    end.

-spec atomise_option(term()) -> term().
atomise_option(Option) when is_map(Option) ->
    atomise_keys(?VOTE_OPTION_KEYS, Option);
atomise_option(Other) ->
    Other.

-spec atomise_keys([atom()], map()) -> map().
atomise_keys([], Map) ->
    Map;
atomise_keys([Key | Rest], Map) ->
    Bin = atom_to_binary(Key, utf8),
    case Map of
        #{Bin := Value} ->
            atomise_keys(Rest, maps:put(Key, Value, maps:remove(Bin, Map)));
        _ ->
            atomise_keys(Rest, Map)
    end.

-spec vote_resolved(binary(), map(), map()) -> {ok, map()}.
vote_resolved(Template, Result, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncResult, LuaSt1} = luerl:encode(Result, LuaSt),
    case asobi_lua_loader:call(vote_resolved, [Template, EncResult, GS], LuaSt1, ?VOTE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Phase callbacks ---
%%
%% widgrensit/asobi_lua#109: asobi_match_server:init/1 gates on
%% `erlang:function_exported(GameMod, phases, 1)` before calling
%% `GameMod:phases(GameConfig)` - same pattern asobi_world_server uses. This
%% module simply never exported phases/1 (or the on_phase_* hooks), so
%% function_exported was always false and phases were silently unreachable
%% from every Lua match script, despite asobi_match:phases/1 documenting
%% support for "Erlang match games and Lua world games" alike.

-spec phases(map()) -> [map()].
phases(#{lua_state := LuaSt} = State) ->
    %% Optional callback - asobi_lua_loader:call/4 cannot tell "never defined"
    %% apart from "defined and raised", both surface as {error, {lua_error, _}}
    %% - so probe first. Only a script that DOES define it and then fails gets
    %% logged. Mirrors asobi_lua_world:phases/1's is_defined guard.
    case asobi_lua_loader:is_defined(phases, LuaSt) of
        false ->
            [];
        true ->
            case asobi_lua_loader:call(phases, [#{}], LuaSt, ?INIT_TIMEOUT) of
                {ok, [PhasesRef | _], LuaSt1} ->
                    decode_phases(PhasesRef, LuaSt1);
                {error, Reason} ->
                    log_match_lua_error(warning, phases, Reason, State),
                    []
            end
    end;
phases(Config) when is_map(Config) ->
    %% Called by asobi_match_server:init/1 with GameConfig directly - the same
    %% map GameMod:init/1 itself receives (asobi_match_server passes the
    %% identical `GameConfig0#{match_id => MatchId}` map to both calls), so
    %% lua_script lives at this map's top level and no lua_state has been
    %% threaded through yet. Mirrors asobi_lua_world:phases/1's raw-config
    %% clause.
    case boot_throwaway_lua_state(Config, phases) of
        {ok, DelegateState} -> phases(DelegateState);
        {error, _} -> []
    end.
%% No catch-all `phases(_) -> []` clause: the -spec restricts the domain to
%% map(), and the two clauses above already cover every map (the first
%% matches any map carrying lua_state, the second - `is_map(Config)` -
%% catches every other map), so a third clause would be unreachable dead code.

-spec on_phase_started(binary(), map()) -> {ok, map()}.
on_phase_started(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_started, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec on_phase_ended(binary(), map()) -> {ok, map()}.
on_phase_ended(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_ended, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

%% asobi#252: a script failing on every tick (or every join/leave/input)
%% would otherwise log once per call forever. Rate-limited per
%% {Script, Callback} via asobi_script_log_limiter (shared with
%% asobi_lua_world:log_lua_error/3 and asobi's own log_spawn_failed/3);
%% telemetry emit stays unconditional so dashboards/alerts see the true
%% failure rate. Level is caller-chosen: a broken tick/1 is worse than a
%% broken join/2 (one player vs. the whole match), so it stays ?LOG_ERROR
%% while join/leave/handle_input stay ?LOG_WARNING, matching each site's
%% severity before this rate limit was added.
-spec log_match_lua_error(logger:level(), atom(), term(), map()) -> ok.
log_match_lua_error(Level, Callback, Reason, State) ->
    log_match_lua_error(Level, Callback, Reason, State, #{}).

-spec log_match_lua_error(logger:level(), atom(), term(), map(), map()) -> ok.
log_match_lua_error(Level, Callback, Reason, State, ExtraMeta) ->
    Script = maps:get(script, State, ~"<unknown>"),
    case asobi_script_log_limiter:allow({Script, Callback}) of
        {true, SuppressedSinceLast} ->
            Report = maps:merge(ExtraMeta, #{
                msg => ~"lua callback failed",
                callback => Callback,
                script => Script,
                reason_class => asobi_lua_game_error:reason_class(Reason),
                detail => asobi_lua_game_error:format_reason(Reason),
                suppressed_since_last => SuppressedSinceLast
            }),
            case Level of
                warning -> ?LOG_WARNING(Report);
                error -> ?LOG_ERROR(Report)
            end;
        false ->
            ok
    end,
    asobi_lua_game_error:emit(Callback, Reason, Script).

is_finished(GS, LuaSt) ->
    try
        {ok, FinVal, LuaSt1} = luerl:get_table_key(GS, ~"_finished", LuaSt),
        case FinVal of
            true ->
                case luerl:get_table_key(GS, ~"_result", LuaSt1) of
                    {ok, ResRef, LuaSt2} -> {true, decode_to_map(ResRef, LuaSt2)};
                    _ -> {true, #{}}
                end;
            _ ->
                false
        end
    catch
        _:_ -> false
    end.

decode_to_map(Term, LuaSt) ->
    asobi_lua_api:decode_to_map(Term, LuaSt).

%% phases/1 (the raw-config clause) is invoked by asobi_match_server:init/1
%% before the match's own lua_state exists - GameMod:init/1 has already run
%% by then, but its result was never threaded through to this call, only the
%% original GameConfig. Boot a throwaway VM just to ask the script the one
%% question, then let it get GC'd. Mirrors asobi_lua_world's
%% boot_throwaway_lua_state/2.
%%
%% `probe => true` in Ctx tells asobi_lua_api:install/2 to stub out every
%% effectful game.* function (economy/leaderboard/notify/storage/chat/
%% broadcast) - booting this VM re-runs the script's whole top-level body,
%% and without this marker any top-level side-effecting call would fire a
%% second time per match creation (see security review on #109/#117).
-spec boot_throwaway_lua_state(map(), atom()) -> {ok, map()} | {error, term()}.
boot_throwaway_lua_state(Config, Caller) ->
    case maps:get(lua_script, Config, undefined) of
        ScriptPath when is_binary(ScriptPath); is_list(ScriptPath) ->
            Ctx = #{
                vm => match,
                match_id => maps:get(match_id, Config, undefined),
                match_pid => self(),
                script => ScriptPath,
                probe => true
            },
            PreInstall = fun(St) -> asobi_lua_api:install(Ctx, St) end,
            case asobi_lua_loader:new(ScriptPath, ?INIT_TIMEOUT, PreInstall) of
                {ok, LuaSt} ->
                    {ok, #{lua_state => LuaSt, script => ScriptPath}};
                {error, Reason} ->
                    log_match_lua_error(warning, Caller, Reason, #{script => ScriptPath}),
                    {error, Reason}
            end;
        _ ->
            {error, missing_lua_script}
    end.

%% --- Phase decoding ---

decode_phases(PhasesRef, LuaSt) ->
    asobi_lua_phases:decode_phases(PhasesRef, LuaSt).
