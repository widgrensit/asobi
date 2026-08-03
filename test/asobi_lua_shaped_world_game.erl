%% Mirrors what the Lua bridge hands a zone: every entity map that comes back
%% out of a game callback is binary-keyed, because it round-tripped through
%% Luerl. See widgrensit/asobi#269.
-module(asobi_lua_shaped_world_game).
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{}}.

-spec join(binary(), map()) -> {ok, map()}.
join(_PlayerId, State) ->
    {ok, State}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(_PlayerId, State) ->
    {ok, State}.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(_PlayerId, _State) ->
    {ok, {100.0, 100.0}}.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) ->
    {binarise_entities(Entities), ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()} | {error, term()}.
handle_input(PlayerId, #{~"action" := ~"move", ~"x" := X, ~"y" := Y}, Entities) ->
    Entity = maps:get(PlayerId, Entities, #{~"type" => ~"player"}),
    Entity1 = (binarise(Entity))#{~"x" => X, ~"y" => Y},
    {ok, (binarise_entities(Entities))#{PlayerId => Entity1}};
handle_input(_PlayerId, _Input, Entities) ->
    {ok, binarise_entities(Entities)}.

-spec post_tick(non_neg_integer(), map()) -> {ok, map()}.
post_tick(_TickN, State) ->
    {ok, State}.

binarise_entities(Entities) ->
    maps:map(
        fun
            (_Id, E) when is_map(E) -> binarise(E);
            (_Id, V) -> V
        end,
        Entities
    ).

binarise(Entity) ->
    maps:from_list([{key(K), V} || {K, V} <- maps:to_list(Entity)]).

key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) -> K.
