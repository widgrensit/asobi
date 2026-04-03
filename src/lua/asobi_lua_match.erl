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
            {EncConfig, LuaSt1} = luerl:encode(GameConfig, LuaSt0),
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{lua_state => LuaSt2, game_state => GameState, script => ScriptPath}};
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
    {EncInput, LuaSt1} = luerl:encode(Input, LuaSt),
    case asobi_lua_loader:call(handle_input, [PlayerId, EncInput, GS], LuaSt1) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
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
            case is_finished(GS1, LuaSt1) of
                {true, Result} ->
                    {finished, Result, State#{lua_state => LuaSt1, game_state => GS1}};
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
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

-spec vote_requested(map()) -> {ok, map()} | none.
vote_requested(#{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(vote_requested, [GS], LuaSt) of
        {ok, [nil | _], _} ->
            none;
        {ok, [false | _], _} ->
            none;
        {ok, [Config | _], LuaSt1} ->
            Decoded = decode_to_map(Config, LuaSt1),
            case map_size(Decoded) of
                0 -> none;
                _ -> {ok, Decoded}
            end;
        _ ->
            none
    end.

-spec vote_resolved(binary(), map(), map()) -> {ok, map()}.
vote_resolved(Template, Result, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncResult, LuaSt1} = luerl:encode(Result, LuaSt),
    case asobi_lua_loader:call(vote_resolved, [Template, EncResult, GS], LuaSt1) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

is_finished(GS, LuaSt) ->
    try
        {ok, FinVal, LuaSt1} = luerl:get_table_key(GS, <<"_finished">>, LuaSt),
        case FinVal of
            true ->
                case luerl:get_table_key(GS, <<"_result">>, LuaSt1) of
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
    case luerl:decode(Term, LuaSt) of
        [{K, _} | _] = PropList when is_binary(K) ->
            maps:from_list(PropList);
        M when is_map(M) ->
            M;
        _ ->
            #{}
    end.
