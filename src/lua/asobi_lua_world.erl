-module(asobi_lua_world).
-moduledoc """
An `asobi_world` implementation that delegates all callbacks to Lua scripts
via Luerl.

The Lua script must define these functions:

```lua
function init(config)                        -- return initial game state
function join(player_id, state)              -- return updated state
function leave(player_id, state)             -- return updated state
function spawn_position(player_id, state)    -- return {x, y}
function zone_tick(entities, zone_state)     -- return entities, zone_state
function handle_input(player_id, input, entities) -- return entities
function post_tick(tick, state)              -- return state (or state + vote/finished)
-- Optional:
function generate_world(seed, config)        -- return zone_states table
function get_state(player_id, state)         -- return state visible to player
function vote_resolved(template, result, state) -- return updated state
```
""".

-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([generate_world/2, get_state/2]).

-define(TICK_TIMEOUT, 500).

-spec init(map()) -> {ok, map()} | {error, term()}.
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
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(spawn_position, [PlayerId, GS], LuaSt) of
        {ok, [PosTable | _], LuaSt1} ->
            Pos = decode_position(PosTable, LuaSt1),
            {ok, Pos};
        {error, _} ->
            {ok, {0.0, 0.0}}
    end.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) ->
    %% Zone tick runs per-zone, not with the global lua state.
    %% Entities and ZoneState are plain Erlang maps at this level.
    %% The game module wrapping must handle Lua encoding per-zone.
    {Entities, ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(_PlayerId, _Input, Entities) ->
    {ok, Entities}.

-spec post_tick(non_neg_integer(), map()) ->
    {ok, map()} | {vote, map(), map()} | {finished, map(), map()}.
post_tick(TickN, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(post_tick, [TickN, GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            State1 = State#{lua_state => LuaSt1, game_state => GS1},
            case check_post_tick_result(GS1, LuaSt1) of
                ok ->
                    {ok, State1};
                {vote, VoteConfig} ->
                    {vote, VoteConfig, State1};
                {finished, Result} ->
                    {finished, Result, State1}
            end;
        {error, timeout} ->
            logger:error(#{msg => ~"lua post_tick timeout", script => maps:get(script, State)}),
            {ok, State};
        {error, Reason} ->
            logger:error(#{msg => ~"lua post_tick error", reason => Reason}),
            {ok, State}
    end.

-spec generate_world(integer(), map()) -> {ok, map()}.
generate_world(Seed, #{lua_state := LuaSt} = _Config) ->
    case asobi_lua_loader:call(generate_world, [Seed, #{}], LuaSt) of
        {ok, [ZoneStates | _], LuaSt1} ->
            {ok, decode_zone_states(ZoneStates, LuaSt1)};
        {error, _} ->
            {ok, #{}}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

%% --- Internal ---

decode_position(PosTable, LuaSt) ->
    Decoded = luerl:decode(PosTable, LuaSt),
    X = proplists:get_value(~"x", Decoded, 0.0),
    Y = proplists:get_value(~"y", Decoded, 0.0),
    {to_number(X), to_number(Y)}.

check_post_tick_result(GS, LuaSt) ->
    try
        case luerl:get_table_key(GS, ~"_finished", LuaSt) of
            {ok, true, LuaSt1} ->
                case luerl:get_table_key(GS, ~"_result", LuaSt1) of
                    {ok, ResRef, LuaSt2} -> {finished, decode_to_map(ResRef, LuaSt2)};
                    _ -> {finished, #{}}
                end;
            _ ->
                case luerl:get_table_key(GS, ~"_vote", LuaSt) of
                    {ok, VoteRef, LuaSt1} when VoteRef =/= nil, VoteRef =/= false ->
                        {vote, decode_to_map(VoteRef, LuaSt1)};
                    _ ->
                        ok
                end
        end
    catch
        _:_ -> ok
    end.

decode_zone_states(ZoneStatesRef, LuaSt) ->
    Decoded = luerl:decode(ZoneStatesRef, LuaSt),
    lists:foldl(
        fun
            ({Key, Val}, Acc) when is_binary(Key) ->
                case parse_coords(Key) of
                    {ok, Coords} -> Acc#{Coords => deep_decode(Val)};
                    error -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        #{},
        Decoded
    ).

parse_coords(Bin) ->
    case binary:split(Bin, ~",") of
        [XBin, YBin] ->
            try
                X = binary_to_integer(XBin),
                Y = binary_to_integer(YBin),
                {ok, {X, Y}}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

decode_to_map(Term, LuaSt) ->
    deep_decode(luerl:decode(Term, LuaSt)).

deep_decode([{K, _} | _] = PropList) when is_binary(K) ->
    maps:from_list(deep_decode_pairs(PropList));
deep_decode([{N, _} | _] = NumList) when is_integer(N) ->
    [deep_decode(Val) || {_, Val} <- lists:sort(NumList)];
deep_decode(M) when is_map(M) ->
    maps:map(fun(_, V) -> deep_decode(V) end, M);
deep_decode(L) when is_list(L) ->
    [deep_decode(E) || E <- L];
deep_decode(V) ->
    V.

deep_decode_pairs([{Key, Val} | Rest]) ->
    [{Key, deep_decode(Val)} | deep_decode_pairs(Rest)];
deep_decode_pairs([]) ->
    [].

to_number(N) when is_number(N) -> N;
to_number(_) -> 0.0.
