-module(asobi_lua_reload).
-moduledoc """
Shared hot-reload primitive for Lua-backed match and world states.

Both `asobi_lua_match` and `asobi_lua_world` (per-world and per-zone) keep a
Luerl state alongside the path of the script that produced it. On every tick
we stat the file; if its mtime has moved, we re-execute the script body
against the current Luerl state — re-declaring globals and functions in
place — preserving in-flight game state.

Behaviour:
- Lua-side state (players, counters, tables) lives inside the Luerl state and
  survives reload, because the script body only reassigns globals and
  redefines functions; existing locals and table fields are not touched
  unless the script explicitly re-runs `init()`.
- Erlang-side state (the wrapper map) is otherwise untouched, except for one
  output field: a successful reload stamps `just_reloaded => true` for
  exactly the tick that reloaded, cleared on every other call (including a
  live `reload_mode` flip to `off`). `asobi_lua_world` reads this to drive
  `spawn_templates_hint/1` (asobi#253); `asobi_lua_match` ignores it.
- A syntax error in the new script logs a warning, remembers the new mtime
  (so we don't keep retrying the same broken file), and keeps running the
  old code until the file is fixed.
- The `_ASOBI_LOADED` require cache is cleared so transitive `require()`d
  modules also re-read from disk.

## Deployment-mode notes

This is a **filesystem-mtime** primitive. It assumes the script lives at a
path the BEAM can `stat()`, and that "the script has changed" can be
expressed as a new mtime. Two real-world deployment models fit that:

- **Local dev** — Lua files mounted via a Docker bind mount or sitting under
  `/app/game/` directly. Edit-save triggers a reload on the next tick.
- **Self-hosted prod with a host-volume mount** — operator's CI/CD writes
  new files into the mounted directory (best practice: write to a temp file
  and `mv` for atomic swap). The next tick picks them up.

Two deployment models do NOT use this primitive at runtime, by design:

- **Sealed-bundle prod** (e.g. asobi managed cloud) — the bundle is
  extracted once at boot to an immutable directory; mtime never changes
  within a container's lifetime. New deploys are container restarts on a
  new generation. The per-tick `stat()` is a no-op in this model.
- **Custom script sources** (DB, S3, git, etc.) — these belong behind the
  planned `asobi_lua_source` behaviour, which will dispatch to either this
  filesystem implementation or an alternative loader. Until then, custom
  sources should arrange for files to land on disk and use this primitive,
  or implement reload outside it.

Operators running self-hosted with high zone counts who want to suppress
per-tick stat overhead can set `asobi_lua.reload_mode` (or the
`ASOBI_LUA_RELOAD` env var the release script reads) to:

- `auto` (default) — mtime-poll, at most once per
  `asobi_lua.reload_poll_interval_ms` (default 200) per bridge. Suitable for
  dev and self-hosted volume-mount setups.
- `off` — never reload. Suitable for sealed-bundle prod where code
  changes are container restarts. The `stat()` is skipped entirely.

The poll interval is what decouples reload cost from tick rate. At 80 Hz the
per-tick stat was 80 `stat()` calls per second **per zone**, which on a 225-zone
grid is 18,000 a second to notice an edit a developer makes every few minutes;
the interval makes that 5 per zone with reload latency no human can perceive
(widgrensit/asobi#543). Set it to 0 for the old per-tick behaviour.
""".

-include_lib("kernel/include/logger.hrl").

-export([maybe_hot_reload/1, reload_mode/0]).

%% Reload runs script-author code under a wall-clock budget. A `while true do
%% end` in the file body would otherwise hang the calling gen_server forever
%% the moment its mtime ticked.
-define(RELOAD_TIMEOUT_MS, 5000).

%% Smallest gap between two `stat()` calls on one bridge's script.
-define(DEFAULT_POLL_INTERVAL_MS, 200).

-spec maybe_hot_reload(map()) -> map().
maybe_hot_reload(State) ->
    %% just_reloaded is a one-tick signal, not a state field - clear it
    %% unconditionally on every call so it can never survive past the tick
    %% that actually reloaded the script, regardless of which branch below
    %% runs next (including a live reload_mode flip to `off` mid-flight).
    State0 = maps:remove(just_reloaded, State),
    case reload_mode() of
        off -> State0;
        auto -> maybe_poll(State0)
    end.

%% The stamp lives in the bridge's own state map rather than in the process
%% dictionary because a match bridge and a zone bridge can share a process in
%% tests, and a per-process stamp would have one starve the other.
-spec maybe_poll(map()) -> map().
maybe_poll(State) ->
    case poll_interval_ms() of
        0 ->
            do_maybe_reload(State);
        Interval ->
            Now = erlang:monotonic_time(millisecond),
            %% Defaulting the deadline to `Now` makes the first call poll:
            %% monotonic time has an arbitrary origin and is routinely
            %% negative, so 0 would be a deadline in the future on a fresh node.
            case Now >= maps:get(reload_poll_at, State, Now) of
                true -> do_maybe_reload(State#{reload_poll_at => Now + Interval});
                false -> State
            end
    end.

-spec poll_interval_ms() -> non_neg_integer().
poll_interval_ms() ->
    case asobi_lua_env:get_env(reload_poll_interval_ms) of
        {ok, N} when is_integer(N), N >= 0 -> N;
        _ -> ?DEFAULT_POLL_INTERVAL_MS
    end.

-spec do_maybe_reload(map()) -> map().
do_maybe_reload(#{script := Path, script_mtime := OldMtime, lua_state := LuaSt} = State) ->
    case filelib:last_modified(Path) of
        0 ->
            State;
        OldMtime ->
            State;
        NewMtime ->
            case reload_script(Path, LuaSt) of
                {ok, NewLuaSt} ->
                    ?LOG_NOTICE(#{
                        msg => ~"lua hot reload", script => Path, mtime => NewMtime
                    }),
                    State#{
                        lua_state => NewLuaSt,
                        script_mtime => NewMtime,
                        just_reloaded => true
                    };
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        msg => ~"lua hot reload failed",
                        script => Path,
                        reason => Reason
                    }),
                    State#{script_mtime => NewMtime}
            end
    end;
do_maybe_reload(State) ->
    %% Legacy state from before hot-reload shipped — nothing to compare.
    State.

%% Reads `asobi_lua.reload_mode` first; falls back to the `ASOBI_LUA_RELOAD`
%% OS env var so operators can flip the dial without editing sys.config in a
%% container deploy. Anything we don't recognise is treated as `auto` so a
%% typo doesn't silently disable reload.
-spec reload_mode() -> auto | off.
reload_mode() ->
    case asobi_lua_env:get_env(reload_mode) of
        {ok, off} -> off;
        {ok, auto} -> auto;
        _ -> from_os_env()
    end.

-spec from_os_env() -> auto | off.
from_os_env() ->
    case os:getenv("ASOBI_LUA_RELOAD") of
        "off" -> off;
        "OFF" -> off;
        _ -> auto
    end.

-spec reload_script(file:filename_all(), dynamic()) -> {ok, dynamic()} | {error, term()}.
reload_script(Path, LuaSt) ->
    case file:read_file(Path) of
        {ok, Code} ->
            CleanLuaSt = clear_require_cache(LuaSt),
            asobi_lua_loader:do_with_timeout(Code, CleanLuaSt, ?RELOAD_TIMEOUT_MS);
        {error, FileReason} ->
            {error, {file_error, FileReason}}
    end.

-spec clear_require_cache(dynamic()) -> dynamic().
clear_require_cache(LuaSt) ->
    {Empty, LuaSt1} = asobi_lua_loader:encode(#{}, LuaSt),
    {ok, LuaSt2} = asobi_lua_loader:set_table_keys([~"_ASOBI_LOADED"], Empty, LuaSt1),
    LuaSt2.
