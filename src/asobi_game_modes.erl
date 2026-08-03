-module(asobi_game_modes).

-export([mode_config/1, resolve_game_module/1, world_config/1, global_chat_channels/0]).

-spec mode_config(binary()) -> map().
mode_config(Mode) ->
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    case Modes of
        #{Mode := Config} when is_map(Config) -> Config;
        #{Mode := Mod} when is_atom(Mod) -> #{module => Mod};
        _ -> #{}
    end.

-spec resolve_game_module(binary()) -> {ok, module(), map()} | {error, not_found}.
resolve_game_module(Mode) ->
    case mode_config(Mode) of
        #{type := world, module := {lua, Script}} ->
            {ok, asobi_lua_world, #{lua_script => Script}};
        #{module := {lua, Script}, state_strategy := shared} ->
            {ok, asobi_lua_match_shared, #{lua_script => Script}};
        #{module := {lua, Script}} ->
            {ok, asobi_lua_match, #{lua_script => Script}};
        #{module := Mod} when is_atom(Mod) ->
            {ok, Mod, #{}};
        _ ->
            {error, not_found}
    end.

-doc "Build a world server config map from a mode's game_modes config.".
-spec world_config(binary()) -> {ok, map()} | {error, not_found}.
world_config(Mode) ->
    ModeConfig = mode_config(Mode),
    case resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            Base = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                max_players => maps:get(max_players, ModeConfig, 500),
                grid_size => maps:get(grid_size, ModeConfig, 10),
                zone_size => maps:get(zone_size, ModeConfig, 200),
                tick_rate => maps:get(tick_rate, ModeConfig, 50),
                view_radius => maps:get(view_radius, ModeConfig, 1),
                persistent => maps:get(persistent, ModeConfig, false),
                listed => maps:get(listed, ModeConfig, true),
                quick_play => maps:get(quick_play, ModeConfig, true)
            },
            {ok, forward_optional(ModeConfig, [empty_grace_ms, player_ttl_ms, chat], Base)};
        {error, _} = Err ->
            Err
    end.

-doc """
Every game-wide chat channel name declared by any configured game mode.

#299: `global:<Name>` is the one channel scheme that outlives a single world,
so the set of legal names cannot come from the joining client. It is the union
of the `chat => #{global => [...]}` declarations across `game_modes`, which is
what `asobi_chat_acl` authorises against.
""".
-spec global_chat_channels() -> [binary()].
global_chat_channels() ->
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    lists:usort([
        Name
     || Config <- maps:values(Modes),
        is_map(Config),
        Name <- asobi_world_chat:global_channels(maps:get(chat, Config, #{}))
    ]).

-spec forward_optional(map(), [atom()], map()) -> map().
forward_optional(_Src, [], Acc) ->
    Acc;
forward_optional(Src, [Key | Rest], Acc) ->
    case Src of
        #{Key := Val} -> forward_optional(Src, Rest, Acc#{Key => Val});
        _ -> forward_optional(Src, Rest, Acc)
    end.

-spec ensure_map(term()) -> #{term() => term()}.
ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.
