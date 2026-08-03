-module(asobi_game_modes).
-moduledoc """
Game-mode configuration, and the registry that maps a mode kind to the module
that provides it.

A mode declaring `module => {lua, "game/match.lua"}` needs a scripting runtime
to run it. That runtime lives outside this library (`asobi_lua`), so the
provider module is registered here at boot rather than named in core - core
depends on no bridge module.
""".

-export([
    register_game_mode/2,
    unregister_game_mode/1,
    mode_config/1,
    resolve_game_module/1,
    world_config/1,
    global_chat_channels/0
]).

-export_type([game_mode_kind/0]).

-type game_mode_kind() :: lua_world | lua_match | lua_match_shared.

%% persistent_term, not an ETS table owned by a supervised process: the table is
%% written once per provider at application start and read on every mode
%% resolution (each matchmaker add, each match/world spawn). persistent_term
%% reads are lock-free and copy-free, and - decisively - the table cannot be lost
%% by a restart. An owner process that dies takes its registrations with it, and
%% nothing would re-register them: the writer is a *different* application that
%% only registers when it starts, so every lua mode would fail permanently after
%% one unrelated crash. The usual persistent_term caveat (a write triggers a
%% global scan) does not bite here because writes only happen at boot.
-define(PROVIDER(Kind), {?MODULE, provider, Kind}).
-define(IS_KIND(K),
    (K =:= lua_world orelse K =:= lua_match orelse K =:= lua_match_shared)
).

-doc """
Register `Module` as the provider for a game-mode kind.

Call this once, at application start - a `persistent_term` write is not a
hot-path operation. `asobi_lua` registers its bridge modules this way; a release
built without a scripting runtime simply leaves the table empty, and every
`{lua, _}` mode then fails with `{error, lua_runtime_unavailable}` rather than
calling a module that is not in the release.
""".
-spec register_game_mode(game_mode_kind(), module()) -> ok.
register_game_mode(Kind, Module) when ?IS_KIND(Kind), is_atom(Module) ->
    persistent_term:put(?PROVIDER(Kind), Module).

-doc "Drop a registration. Mainly for tests; releases register once and keep it.".
-spec unregister_game_mode(game_mode_kind()) -> ok.
unregister_game_mode(Kind) when ?IS_KIND(Kind) ->
    _ = persistent_term:erase(?PROVIDER(Kind)),
    ok.

-spec mode_config(binary()) -> map().
mode_config(Mode) ->
    Modes = ensure_map(application:get_env(asobi, game_modes, #{})),
    case Modes of
        #{Mode := Config} when is_map(Config) -> Config;
        #{Mode := Mod} when is_atom(Mod) -> #{module => Mod};
        _ -> #{}
    end.

-doc """
Resolve a mode to the module that runs it, plus the extra game config it needs.

`{error, not_found}` means the mode declares no usable module.
`{error, lua_runtime_unavailable}` means it declares a Lua script but no
runtime registered a provider for that kind - a release built without
`asobi_lua`. That case used to be an unenforced convention that failed later
and obscurely; it is now a named error at the point of resolution.
""".
-spec resolve_game_module(binary()) ->
    {ok, module(), map()} | {error, not_found | lua_runtime_unavailable}.
resolve_game_module(Mode) ->
    case mode_config(Mode) of
        #{type := world, module := {lua, Script}} ->
            lua_provider(lua_world, Script);
        #{module := {lua, Script}, state_strategy := shared} ->
            lua_provider(lua_match_shared, Script);
        #{module := {lua, Script}} ->
            lua_provider(lua_match, Script);
        #{module := Mod} when is_atom(Mod) ->
            {ok, Mod, #{}};
        _ ->
            {error, not_found}
    end.

-spec lua_provider(game_mode_kind(), term()) ->
    {ok, module(), map()} | {error, lua_runtime_unavailable}.
lua_provider(Kind, Script) ->
    case persistent_term:get(?PROVIDER(Kind), undefined) of
        Module when is_atom(Module), Module =/= undefined ->
            {ok, Module, #{lua_script => Script}};
        _ ->
            {error, lua_runtime_unavailable}
    end.

-doc "Build a world server config map from a mode's game_modes config.".
-spec world_config(binary()) -> {ok, map()} | {error, not_found | lua_runtime_unavailable}.
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
