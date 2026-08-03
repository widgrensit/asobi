-module(asobi_lua_config_watcher).
-moduledoc """
Keeps the game-mode registry (`game_modes`) in sync with its Lua source.

Mode-shape config (`match_size`, `strategy`, `max_players`, the `config.lua`
mode manifest) is read into the `asobi` `game_modes` app-env once at boot by
`asobi_lua_config:maybe_load_game_config/0`. The in-match hot-reload
(`asobi_lua_reload`) re-evaluates a script body inside already-running match and
world servers, but the reported bug is at match *formation* - before any server
exists for the new config - so that path is structurally blind to it. Without a
refresh, editing `match_size` and hot-reloading leaves the matchmaker on the
boot-time value (asobi#232).

This watcher polls the manifest and each registered mode's script on an interval
and re-runs the config loader when an mtime moves, so new matches pick up the
change. Running matches are untouched (they consumed their `match_size` at
formation). It shares the hot-reload dial: with `asobi_lua_reload:reload_mode()`
`off` (a sealed prod bundle whose mtimes never change) it is a pure no-op.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-ifdef(TEST).
-export([scan/0]).
-endif.

-define(DEFAULT_INTERVAL, 1500).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, map()}.
init([]) ->
    Interval = interval(),
    erlang:send_after(Interval, self(), tick),
    %% Don't even scan on a sealed/off node: reload_mode=off means zero polling.
    Mtimes =
        case asobi_lua_reload:reload_mode() of
            off -> #{};
            auto -> scan()
        end,
    {ok, #{interval => Interval, mtimes => Mtimes}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(tick, #{interval := Interval, mtimes := Old} = State) ->
    New =
        case asobi_lua_reload:reload_mode() of
            off ->
                Old;
            auto ->
                Current = scan(),
                case Current =:= Old of
                    true -> Old;
                    false -> reload(Current)
                end
        end,
    erlang:send_after(Interval, self(), tick),
    {noreply, State#{mtimes => New}};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

-spec interval() -> pos_integer().
interval() ->
    case asobi_lua_env:get_env(config_watch_interval) of
        {ok, I} when is_integer(I), I > 0 -> I;
        _ -> ?DEFAULT_INTERVAL
    end.

%% path => mtime for every watched file. Missing files map to 0, so a
%% create/delete registers as a change too.
-spec scan() -> map().
scan() ->
    #{F => filelib:last_modified(F) || F <- watched_files()}.

watched_files() ->
    GameDir = to_string(application:get_env(asobi, game_dir, ~"/app/game")),
    Manifest = [
        filename:join(GameDir, "config.lua"),
        filename:join(GameDir, "match.lua")
    ],
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    %% Fail soft on a hand-written game_modes with a non-string script path: skip
    %% the bad entry rather than crash the watcher (and, via the sup, the app).
    Scripts = [
        P
     || {_Mode, Cfg} <- maps:to_list(Modes),
        is_map(Cfg),
        {lua, Path} <- [maps:get(module, Cfg, undefined)],
        P <- [to_path(Path)],
        P =/= undefined
    ],
    lists:usort(Manifest ++ Scripts).

%% Re-run the whole config load (idempotent merge). On failure keep last-good
%% game_modes (the loader is all-or-nothing) and adopt the new mtimes anyway, so
%% a broken file is not retried every tick - we wait for the next edit. Mirrors
%% asobi_lua_reload's failure discipline.
-spec reload(map()) -> map().
reload(Current) ->
    case asobi_lua_config:reload_game_modes() of
        ok ->
            ?LOG_NOTICE(#{msg => ~"game config reloaded (mode-shape change)"});
        {error, Reason} ->
            ?LOG_WARNING(#{
                msg => ~"game config reload failed; keeping last-good",
                error => Reason
            })
    end,
    Current.

to_string(B) when is_binary(B) -> binary_to_list(B);
to_string(L) when is_list(L) -> L.

to_path(B) when is_binary(B) -> binary_to_list(B);
to_path(L) when is_list(L) -> L;
to_path(_) -> undefined.

-spec ensure_map(term()) -> map().
ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.
