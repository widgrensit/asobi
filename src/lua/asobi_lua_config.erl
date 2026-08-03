-module(asobi_lua_config).
-moduledoc """
Loads game configuration from Lua files in the game directory.

Supports two modes:

1. **Single mode** — a `match.lua` in the game directory. The script declares
   its config as globals (`match_size`, `max_players`, `strategy`, `bots`).
   The mode name defaults to `"default"`.

2. **Multi-mode** — a `config.lua` that returns a table mapping mode names to
   script paths:

   ```lua
   return {
       arena = "arena/match.lua",
       ctf   = "ctf/match.lua"
   }
   ```

   Each match script declares its own config as globals.

If neither file exists, the loader is a no-op (Erlang OTP projects that
configure via `sys.config` are unaffected).

## Match script globals

```lua
match_size     = 4                          -- required, positive integer
max_players    = 10                         -- optional, defaults to match_size
strategy       = "fill"                     -- optional, "fill" | "skill_based"
bots           = { script = "bots/ai.lua", min_players = 4 } -- optional; min_players defaults to match_size, enabled defaults to true
game_type      = "world"                    -- optional, "match" (default) or "world"
state_strategy = "shared"                   -- optional, "shared" picks asobi_lua_match_shared (encode-once broadcast)
guest_auth     = true                       -- optional, offer anonymous no-account play (needs an operator pepper; ADR 0004)

-- World mode config (large session games, game_type = "world"):
tick_rate               = 50              -- optional, ms per world tick (default 50 = 20 Hz)
grid_size               = 1               -- optional, zones per dimension (default 10)
zone_size               = 1200            -- optional, world units per zone (default 200)
view_radius             = 0               -- optional, zone radius a player subscribes to (default 1)
persistent              = false           -- optional, snapshot zones to DB across restarts
lazy_zones              = true            -- optional, on-demand zone loading
zone_idle_timeout       = 30000           -- optional, ms before idle zone is reaped
max_active_zones        = 10000           -- optional, cap on concurrent zones
spatial_grid_cell_size  = 64              -- optional, cell size for spatial grid indexing
cold_tick_divisor       = 10              -- optional, tick rate divisor for cold (unoccupied) zones
empty_grace_ms          = 60000           -- optional, ms to keep an empty world alive before finishing
player_ttl_ms           = 0               -- optional, 0=remove on disconnect, -1=keep forever, N=grace ms
```

Setting `game_type = "world"` routes the script through the `asobi_lua_world`
bridge (zone_tick/2 + handle_input/3 returning entities). Defaults to "match",
which uses the `asobi_lua_match` bridge (tick/1 + wrapped-state callbacks).

`guest_auth` is read from `match.lua` in single-mode and from `config.lua` (the
manifest) in multi-mode. It only *declares* intent; guest auth is on iff the
operator also supplies a >= 32-byte pepper (ADR 0004).

Bot scripts can export a `names` list that the platform reads after loading:

```lua
names = {"Spark", "Blitz", "Volt"}
```
""".

-include_lib("kernel/include/logger.hrl").
-include("asobi_lua_bots.hrl").

-export([maybe_load_game_config/0, reload_game_modes/0, apply_guest_auth/1]).
-ifdef(TEST).
-export([safe_join/2]).
-endif.

-spec maybe_load_game_config() -> ok | {error, term()}.
maybe_load_game_config() ->
    GameDirStr = to_string(application:get_env(asobi, game_dir, ~"/app/game")),
    _ = apply_guest_auth(GameDirStr),
    reload_game_modes().

%% Refresh only the game_modes registry from the mode scripts, WITHOUT
%% re-deriving guest_auth. The config watcher (asobi#232) calls this on a live
%% mode-shape edit, so guest-auth posture (ADR 0004's two-key AND) stays a
%% boot-only decision that a bundle write cannot flip at runtime.
-spec reload_game_modes() -> ok | {error, term()}.
reload_game_modes() ->
    GameDirStr = to_string(application:get_env(asobi, game_dir, ~"/app/game")),
    ConfigPath = filename:join(GameDirStr, "config.lua"),
    MatchPath = filename:join(GameDirStr, "match.lua"),
    case {filelib:is_regular(ConfigPath), filelib:is_regular(MatchPath)} of
        {true, _} ->
            load_multi_mode(GameDirStr, ConfigPath);
        {false, true} ->
            load_single_mode(GameDirStr, MatchPath);
        {false, false} ->
            ok
    end.

%% The game opts into anonymous guest auth by declaring `guest_auth = true` in
%% its config script (config.lua for multi-mode, else match.lua). We read that
%% global and flip the asobi app-env flag; the operator still has to supply a
%% >= 32-byte guest_verifier_pepper, so guest auth is on iff BOTH agree (ADR
%% 0004). Best-effort: any error just leaves the flag at its `false` default.
%% Shared with asobi_engine's bundle loader so managed cloud behaves the same.
-spec apply_guest_auth(string() | binary()) -> ok.
apply_guest_auth(GameDir) ->
    GameDirStr = to_string(GameDir),
    ConfigPath = filename:join(GameDirStr, "config.lua"),
    MatchPath = filename:join(GameDirStr, "match.lua"),
    Script =
        case filelib:is_regular(ConfigPath) of
            true -> ConfigPath;
            false -> MatchPath
        end,
    Declared =
        case filelib:is_regular(Script) of
            false ->
                false;
            true ->
                St0 = asobi_lua_loader:init_sandboxed(),
                case do_file(Script, St0) of
                    {ok, _Results, St1} -> read_global_bool(~"guest_auth", St1) =:= true;
                    {error, _} -> false
                end
        end,
    application:set_env(asobi, guest_auth, Declared).

%% --- Multi-mode: config.lua maps mode names to script paths ---

load_multi_mode(GameDir, ConfigPath) ->
    St0 = asobi_lua_loader:init_sandboxed(),
    case do_file(ConfigPath, St0) of
        {ok, [Table | _], St1} ->
            Decoded = luerl:decode(Table, St1),
            case build_modes_from_manifest(GameDir, Decoded) of
                {ok, Modes} ->
                    apply_game_modes(Modes);
                {error, _} = Err ->
                    Err
            end;
        {ok, [], _} ->
            {error, {config_error, ~"config.lua must return a table"}};
        {error, Reason} ->
            {error, {config_error, Reason}}
    end.

build_modes_from_manifest(GameDir, PropList) when is_list(PropList) ->
    Results = lists:map(
        fun
            ({ModeName, ScriptRel}) when is_binary(ModeName), is_binary(ScriptRel) ->
                %% H1 (2026-05-19): config.lua is operator-trusted but its
                %% values flow through unmodified to file:read_file +
                %% Lua eval. Anchor every mode->script entry inside GameDir
                %% so a stray "../" cannot trick the runtime into loading
                %% an arbitrary readable file as Lua.
                case safe_join(GameDir, ScriptRel) of
                    {ok, ScriptAbs} ->
                        case load_match_config(ScriptAbs) of
                            {ok, ModeConfig} ->
                                {ok, {ModeName, ModeConfig}};
                            {error, Reason} ->
                                {error, {ModeName, Reason}}
                        end;
                    {error, Reason} ->
                        {error, {ModeName, Reason}}
                end;
            ({ModeName, _}) ->
                {error, {ModeName, ~"value must be a script path string"}}
        end,
        PropList
    ),
    case collect_results(Results) of
        {ok, Pairs} ->
            {ok, maps:from_list(Pairs)};
        {error, _} = Err ->
            Err
    end;
build_modes_from_manifest(_, _) ->
    {error, {config_error, ~"config.lua must return a table of mode_name = \"script.lua\""}}.

%% --- Single-mode: just match.lua in the game dir ---

load_single_mode(_GameDir, MatchPath) ->
    case load_match_config(MatchPath) of
        {ok, ModeConfig} ->
            Modes = #{~"default" => ModeConfig},
            apply_game_modes(Modes);
        {error, _} = Err ->
            Err
    end.

%% --- Load a match script and read its config globals ---

load_match_config(ScriptPath) ->
    case asobi_lua_loader:new(ScriptPath) of
        {ok, St} ->
            read_match_globals(ScriptPath, St);
        {error, Reason} ->
            {error, {script_load_failed, ScriptPath, Reason}}
    end.

read_match_globals(ScriptPath, St) ->
    MatchSize = read_global_int(~"match_size", St),
    MaxPlayers = read_global_int(~"max_players", St),
    Strategy = read_global_string(~"strategy", St),
    Bots = read_global_table(~"bots", St),
    GameType = read_global_string(~"game_type", St),
    StateStrategy = read_global_string(~"state_strategy", St),
    TickRate = read_global_int(~"tick_rate", St),
    GridSize = read_global_int(~"grid_size", St),
    ZoneSize = read_global_int(~"zone_size", St),
    ViewRadius = read_global_int(~"view_radius", St),
    Persistent = read_global_bool(~"persistent", St),
    LazyZones = read_global_bool(~"lazy_zones", St),
    ZoneIdleTimeout = read_global_int(~"zone_idle_timeout", St),
    MaxActiveZones = read_global_int(~"max_active_zones", St),
    SpatialGridCellSize = read_global_int(~"spatial_grid_cell_size", St),
    ColdTickDivisor = read_global_int(~"cold_tick_divisor", St),
    EmptyGraceMs = read_global_int(~"empty_grace_ms", St),
    PlayerTtlMs = read_global_int(~"player_ttl_ms", St),
    case MatchSize of
        undefined ->
            {error, {ScriptPath, ~"match_size global is required"}};
        N when is_integer(N), N > 0 ->
            Config0 = #{
                module => {lua, ScriptPath},
                match_size => N,
                max_players =>
                    case MaxPlayers of
                        MP when is_integer(MP), MP > 0 -> MP;
                        _ -> N
                    end
            },
            Config1 = maybe_add_game_type(Config0, GameType),
            Config2 = maybe_add_strategy(Config1, Strategy),
            Config2a = maybe_add_state_strategy(Config2, StateStrategy),
            Config3 = maybe_add_bots(Config2a, Bots, ScriptPath),
            Config4 = maybe_add_zone_config(Config3, LazyZones, ZoneIdleTimeout, MaxActiveZones),
            Config5 = maybe_add_int(Config4, spatial_grid_cell_size, SpatialGridCellSize),
            Config6 = maybe_add_int(Config5, cold_tick_divisor, ColdTickDivisor),
            Config7 = maybe_add_int(Config6, empty_grace_ms, EmptyGraceMs),
            Config8 = maybe_add_player_ttl(Config7, PlayerTtlMs),
            Config9 = maybe_add_int(Config8, tick_rate, TickRate),
            Config10 = maybe_add_int(Config9, grid_size, GridSize),
            Config11 = maybe_add_int(Config10, zone_size, ZoneSize),
            Config12 = maybe_add_non_neg_int(Config11, view_radius, ViewRadius),
            Config13 = maybe_add_bool(Config12, persistent, Persistent),
            {ok, Config13};
        _ ->
            {error, {ScriptPath, ~"match_size must be a positive integer"}}
    end.

maybe_add_game_type(Config, ~"world") ->
    Config#{type => world};
maybe_add_game_type(Config, _) ->
    Config.

maybe_add_strategy(Config, undefined) ->
    Config;
maybe_add_strategy(Config, Strategy) ->
    case Strategy of
        ~"fill" -> Config#{strategy => fill};
        ~"skill_based" -> Config#{strategy => skill_based};
        Other -> Config#{strategy => Other}
    end.

%% A shared `get_state(state)` payload is broadcast pre-encoded once per
%% tick instead of re-encoded per player. Set `state_strategy = "shared"`
%% in the match script when every player sees the same world (the
%% common case for action games / shared-arena modes).
maybe_add_state_strategy(Config, ~"shared") ->
    Config#{state_strategy => shared};
maybe_add_state_strategy(Config, _) ->
    Config.

maybe_add_zone_config(Config, LazyZones, ZoneIdleTimeout, MaxActiveZones) ->
    Config1 =
        case LazyZones of
            true -> Config#{lazy_zones => true};
            false -> Config#{lazy_zones => false};
            undefined -> Config
        end,
    Config2 =
        case ZoneIdleTimeout of
            ZIT when is_integer(ZIT), ZIT > 0 -> Config1#{zone_idle_timeout => ZIT};
            _ -> Config1
        end,
    case MaxActiveZones of
        MAZ when is_integer(MAZ), MAZ > 0 -> Config2#{max_active_zones => MAZ};
        _ -> Config2
    end.

maybe_add_int(Config, _Key, undefined) ->
    Config;
maybe_add_int(Config, Key, Val) when is_integer(Val), Val > 0 ->
    Config#{Key => Val};
maybe_add_int(Config, _Key, _Val) ->
    Config.

%% Like maybe_add_int/3 but accepts 0 — used for view_radius, where 0 is a
%% legitimate value (subscribe only to your own zone).
maybe_add_non_neg_int(Config, _Key, undefined) ->
    Config;
maybe_add_non_neg_int(Config, Key, Val) when is_integer(Val), Val >= 0 ->
    Config#{Key => Val};
maybe_add_non_neg_int(Config, _Key, _Val) ->
    Config.

maybe_add_bool(Config, _Key, undefined) ->
    Config;
maybe_add_bool(Config, Key, Val) when is_boolean(Val) ->
    Config#{Key => Val}.

%% player_ttl_ms accepts 0 (remove on disconnect, default), -1 (keep forever),
%% or a positive grace window in ms. Any integer is a valid override.
maybe_add_player_ttl(Config, undefined) ->
    Config;
maybe_add_player_ttl(Config, Val) when is_integer(Val) ->
    Config#{player_ttl_ms => Val}.

maybe_add_bots(Config, undefined, _ScriptPath) ->
    Config;
maybe_add_bots(Config, BotProps, ScriptPath) when is_list(BotProps) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    case proplists:get_value(~"script", BotProps) of
        undefined ->
            Config;
        BotScript when is_binary(BotScript) ->
            %% H1 (2026-05-19): the same anchoring applies here. match.lua
            %% is operator-controlled but its bots.script string is what
            %% the runtime hands to file:read_file; reject any segment that
            %% escapes the match's own directory.
            case safe_join(BaseDir, BotScript) of
                {ok, AbsBot} ->
                    #{match_size := MatchSize} = Config,
                    Config#{
                        bots => #{
                            enabled => bots_enabled(BotProps),
                            min_players => bots_min_players(BotProps, MatchSize),
                            script => unicode:characters_to_binary(AbsBot)
                        }
                    };
                {error, _} ->
                    logger:warning(#{
                        msg => ~"bots.script rejected: path escapes match dir",
                        base_dir => unicode:characters_to_binary(BaseDir),
                        script => BotScript
                    }),
                    Config
            end
    end;
maybe_add_bots(Config, _, _) ->
    Config.

%% `bots.enabled` defaults to true (setting a `bots` table at all is the
%% opt-in); an explicit `enabled = false` lets a game keep the table around
%% (e.g. to declare min_players) while turning bot-fill off.
bots_enabled(BotProps) ->
    proplists:get_value(~"enabled", BotProps) =/= false.

%% `bots.min_players` mirrors the sys.config knob documented in
%% guides/lua-bots.md; a Lua game defaults to match_size, same as the
%% spawner's own fallback. Clamped at ?MAX_BOT_FILL: an unbounded value
%% here is a DoS vector (asobi_bot_spawner:fill_mode/2 would otherwise
%% build an equally unbounded bot-add list; see #79 follow-up).
bots_min_players(BotProps, MatchSize) ->
    case proplists:get_value(~"min_players", BotProps) of
        MP when is_number(MP), MP > 0 -> clamp_bot_fill(trunc(MP));
        _ -> clamp_bot_fill(MatchSize)
    end.

clamp_bot_fill(MP) when MP > ?MAX_BOT_FILL ->
    ?LOG_WARNING(#{
        msg => ~"bots.min_players exceeds ceiling, clamping",
        requested => MP,
        ceiling => ?MAX_BOT_FILL
    }),
    ?MAX_BOT_FILL;
clamp_bot_fill(MP) ->
    MP.

%% H1 (2026-05-19): anchor a Lua-supplied relative path inside Base. Reject
%% absolute paths, `..` segments, and anything whose `filename:absname/1`
%% normalisation escapes the base directory. Returns the absolute path on
%% success.
-spec safe_join(string() | binary(), binary()) ->
    {ok, string()} | {error, binary()}.
safe_join(Base, RelBin) when is_binary(RelBin) ->
    case is_safe_relative(RelBin) of
        false ->
            {error, ~"script path must be relative and may not contain '..'"};
        true ->
            BaseStr = to_string(Base),
            BaseAbs = to_chars(filename:absname(BaseStr)),
            Joined = to_chars(
                filename:absname(filename:join(BaseAbs, binary_to_list(RelBin)))
            ),
            case lists:prefix(BaseAbs ++ "/", Joined) of
                true -> {ok, Joined};
                false -> {error, ~"script path escapes game directory"}
            end
    end.

-spec to_chars(file:filename_all()) -> string().
to_chars(B) when is_binary(B) -> binary_to_list(B);
to_chars(L) when is_list(L) -> L.

-spec is_safe_relative(binary()) -> boolean().
is_safe_relative(<<>>) ->
    false;
is_safe_relative(<<"/", _/binary>>) ->
    false;
is_safe_relative(Bin) ->
    Parts = binary:split(Bin, ~"/", [global]),
    lists:all(
        fun
            (<<>>) -> false;
            (~"..") -> false;
            (~".") -> false;
            (_) -> true
        end,
        Parts
    ).

%% --- Apply to app env ---

apply_game_modes(Modes) ->
    Existing =
        case application:get_env(asobi, game_modes, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Merged = maps:merge(Existing, Modes),
    application:set_env(asobi, game_modes, Merged),
    logger:notice(#{
        msg => ~"lua game config loaded",
        modes => maps:keys(Merged)
    }),
    ok.

%% --- Lua helpers ---

%% M-3: a malicious or buggy config.lua could otherwise hang application
%% start. The wrapper kills runaway scripts after CONFIG_TIMEOUT_MS so a
%% bad manifest never blocks the boot process, and caps heap so an
%% allocation bomb in an untrusted bundle cannot exhaust node memory.
-define(CONFIG_TIMEOUT_MS, 2000).
-define(CONFIG_MAX_HEAP_WORDS, 5_000_000).

do_file(Path, St) ->
    case file:read_file(Path) of
        {ok, Code} ->
            do_with_timeout_results(Code, St, ?CONFIG_TIMEOUT_MS);
        {error, Reason} ->
            {error, {file_error, Path, Reason}}
    end.

%% Like asobi_lua_loader:do_with_timeout/3 but preserves the script's
%% return values — config.lua returns a table that the caller decodes.
do_with_timeout_results(Code, St, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    SpawnOpts = [
        monitor,
        {max_heap_size, #{
            size => ?CONFIG_MAX_HEAP_WORDS,
            kill => true,
            error_logger => true,
            include_shared_binaries => false
        }}
    ],
    {Pid, MonRef} = spawn_opt(
        fun() ->
            Result =
                try luerl:do(binary_to_list(Code), St) of
                    {ok, Results, St1} -> {ok, Results, St1};
                    {error, Errors, _} -> {error, {lua_error, Errors}};
                    {lua_error, Reason, _} -> {error, {lua_error, Reason}}
                catch
                    error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
                    error:Reason -> {error, Reason}
                end,
            Self ! {Ref, Result}
        end,
        SpawnOpts
    ),
    receive
        {Ref, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, killed} ->
            {error, heap_exhausted};
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {worker_exit, Reason}}
    after TimeoutMs ->
        exit(Pid, kill),
        receive
            {Ref, _} ->
                erlang:demonitor(MonRef, [flush]),
                {error, timeout};
            {'DOWN', MonRef, process, Pid, _} ->
                {error, timeout}
        after 0 ->
            erlang:demonitor(MonRef, [flush]),
            {error, timeout}
        end
    end.

read_global_int(Name, St) ->
    case luerl:get_table_keys([Name], St) of
        {ok, Val, _} when is_number(Val) -> trunc(Val);
        _ -> undefined
    end.

read_global_bool(Name, St) ->
    case luerl:get_table_keys([Name], St) of
        {ok, true, _} -> true;
        {ok, false, _} -> false;
        _ -> undefined
    end.

read_global_string(Name, St) ->
    case luerl:get_table_keys([Name], St) of
        {ok, Val, _} when is_binary(Val) -> Val;
        _ -> undefined
    end.

read_global_table(Name, St) ->
    case luerl:get_table_keys([Name], St) of
        {ok, Val, St1} when Val =/= nil, Val =/= false ->
            case luerl:decode(Val, St1) of
                Props when is_list(Props) -> Props;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% --- Utilities ---

collect_results(Results) ->
    {Oks, Errs} = lists:partition(
        fun
            ({ok, _}) -> true;
            (_) -> false
        end,
        Results
    ),
    case Errs of
        [] ->
            {ok, [V || {ok, V} <- Oks]};
        _ ->
            ErrDetails = [{N, R} || {error, {N, R}} <- Errs],
            lists:foreach(
                fun({Name, Reason}) ->
                    logger:error(#{
                        msg => ~"game mode config error",
                        mode => Name,
                        reason => Reason
                    })
                end,
                ErrDetails
            ),
            {error, {config_errors, ErrDetails}}
    end.

to_string(B) when is_binary(B) -> binary_to_list(B);
to_string(L) when is_list(L) -> L.
