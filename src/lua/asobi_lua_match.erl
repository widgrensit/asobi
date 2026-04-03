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
function join(player_id, state)       -- return updated state
function leave(player_id, state)      -- return updated state
function handle_input(player_id, input, state) -- return updated state
function tick(state)         -- return state, or state + finished flag
function get_state(player_id, state)  -- return state visible to player
-- Optional:
function vote_requested(state)        -- return vote config or nil
function vote_resolved(template, result, state) -- return updated state
```
""".

-behaviour(asobi_match).

-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).
-export([vote_requested/1, vote_resolved/3]).

-define(TICK_TIMEOUT, 500).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath = maps:get(lua_script, Config, undefined),
    GameConfig = maps:get(game_config, Config, #{}),
    case asobi_lua_loader:new(ScriptPath) of
        {ok, LuaSt0} ->
            case asobi_lua_loader:call(init, [GameConfig], LuaSt0) of
                {ok, [GameState | _], LuaSt1} ->
                    {ok, #{lua_state => LuaSt1, game_state => GameState, script => ScriptPath}};
                {ok, [], _} ->
                    {error, {lua_error, ~"init() must return a table"}};
                {error, Reason} ->
                    {error, {lua_init_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {lua_load_failed, ScriptPath, Reason}}
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(join, [PlayerId, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{msg => ~"lua join error", player_id => PlayerId, reason => Reason}),
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{msg => ~"lua leave error", player_id => PlayerId, reason => Reason}),
            {ok, State}
    end.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(PlayerId, Input, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(handle_input, [PlayerId, Input, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            logger:warning(#{
                msg => ~"lua input error", player_id => PlayerId, reason => Reason
            }),
            {ok, State}
    end.

-spec tick(map()) -> {ok, map()} | {finished, map(), map()}.
tick(#{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(tick, [GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            case is_finished(GS1) of
                {true, Result} ->
                    GS2 = remove_finished_flag(GS1),
                    {finished, Result, State#{lua_state => LuaSt1, game_state => GS2}};
                false ->
                    {ok, State#{lua_state => LuaSt1, game_state => GS1}}
            end;
        {error, timeout} ->
            logger:error(#{msg => ~"lua tick timeout", script => maps:get(script, State)}),
            {ok, State};
        {error, Reason} ->
            logger:error(#{msg => ~"lua tick error", reason => Reason}),
            {ok, State}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS} = _State) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt) of
        {ok, [PlayerState | _], _LuaSt1} when is_map(PlayerState) ->
            PlayerState;
        {ok, [PlayerState | _], _LuaSt1} ->
            ensure_map(PlayerState);
        {error, _} ->
            #{}
    end.

-spec vote_requested(map()) -> {ok, map()} | none.
vote_requested(#{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(vote_requested, [GS], LuaSt) of
        {ok, [nil | _], _} -> none;
        {ok, [false | _], _} -> none;
        {ok, [Config | _], _} when is_map(Config) -> {ok, Config};
        _ -> none
    end.

-spec vote_resolved(binary(), map(), map()) -> {ok, map()}.
vote_resolved(Template, Result, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(vote_resolved, [Template, Result, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

is_finished(GS) when is_map(GS) ->
    case maps:get(~"_finished", GS, maps:get(<<"_finished">>, GS, false)) of
        true ->
            Result = maps:get(~"_result", GS, maps:get(<<"_result">>, GS, #{})),
            {true, ensure_map(Result)};
        _ ->
            false
    end;
is_finished(_) ->
    false.

remove_finished_flag(GS) when is_map(GS) ->
    maps:without([~"_finished", <<"_finished">>, ~"_result", <<"_result">>], GS);
remove_finished_flag(GS) ->
    GS.

ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.
