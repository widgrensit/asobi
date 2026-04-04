-module(asobi_config).
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
match_size   = 4                          -- required, positive integer
max_players  = 10                         -- optional, defaults to match_size
strategy     = "fill"                     -- optional, "fill" | "skill_based"
bots         = { script = "bots/ai.lua" } -- optional
```

Bot scripts can export a `names` list that the platform reads after loading:

```lua
names = {"Spark", "Blitz", "Volt"}
```
""".

-export([maybe_load_game_config/0]).

-spec maybe_load_game_config() -> ok | {error, term()}.
maybe_load_game_config() ->
    GameDir = application:get_env(asobi, game_dir, ~"/app/game"),
    GameDirStr = to_string(GameDir),
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

%% --- Multi-mode: config.lua maps mode names to script paths ---

load_multi_mode(GameDir, ConfigPath) ->
    St0 = luerl:init(),
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
                ScriptAbs = filename:join(GameDir, binary_to_list(ScriptRel)),
                case load_match_config(ScriptAbs) of
                    {ok, ModeConfig} ->
                        {ok, {ModeName, ModeConfig}};
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
            Config1 = maybe_add_strategy(Config0, Strategy),
            Config2 = maybe_add_bots(Config1, Bots, ScriptPath),
            {ok, Config2};
        _ ->
            {error, {ScriptPath, ~"match_size must be a positive integer"}}
    end.

maybe_add_strategy(Config, undefined) ->
    Config;
maybe_add_strategy(Config, Strategy) ->
    case Strategy of
        ~"fill" -> Config#{strategy => fill};
        ~"skill_based" -> Config#{strategy => skill_based};
        Other -> Config#{strategy => Other}
    end.

maybe_add_bots(Config, undefined, _ScriptPath) ->
    Config;
maybe_add_bots(Config, BotProps, ScriptPath) when is_list(BotProps) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    case proplists:get_value(~"script", BotProps) of
        undefined ->
            Config;
        BotScript when is_binary(BotScript) ->
            AbsBot = filename:join(BaseDir, binary_to_list(BotScript)),
            Config#{
                bots => #{
                    enabled => true,
                    script => unicode:characters_to_binary(AbsBot)
                }
            }
    end;
maybe_add_bots(Config, _, _) ->
    Config.

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

do_file(Path, St) ->
    case file:read_file(Path) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            try luerl:do(CodeStr, St) of
                {ok, Results, St1} -> {ok, Results, St1};
                {error, Errors, _St1} -> {error, {lua_error, Errors}};
                {lua_error, Reason, _St1} -> {error, {lua_error, Reason}}
            catch
                error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
                error:Reason -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {file_error, Path, Reason}}
    end.

read_global_int(Name, St) ->
    case luerl:get_table_keys([Name], St) of
        {ok, Val, _} when is_number(Val) -> trunc(Val);
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
