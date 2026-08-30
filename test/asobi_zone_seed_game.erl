-module(asobi_zone_seed_game).
-behaviour(asobi_world).

%% A world game module that seeds every lazily-loaded zone from
%% `on_zone_loaded/2` and reports both lifecycle hooks to whichever process
%% registered itself as ?PROBE. Used by asobi_zone_lifecycle_hooks_tests.

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, post_tick/2, on_zone_loaded/2, on_zone_unloaded/2]).

-define(PROBE, asobi_zone_seed_probe).

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{loaded => [], unloaded => []}}.

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
    {Entities, ZoneState}.

-spec post_tick(non_neg_integer(), map()) -> {ok, map()}.
post_tick(_TickN, State) ->
    {ok, State}.

-spec on_zone_loaded({integer(), integer()}, map()) -> {ok, map(), map()}.
on_zone_loaded({CX, CY} = Coords, #{loaded := Loaded} = State) ->
    probe({on_zone_loaded, Coords}),
    ZoneState = #{biome => ~"plains", cx => CX, cy => CY},
    {ok, ZoneState, State#{loaded => [Coords | Loaded]}}.

-spec on_zone_unloaded({integer(), integer()}, map()) -> {ok, map()}.
on_zone_unloaded(Coords, #{unloaded := Unloaded} = State) ->
    probe({on_zone_unloaded, Coords}),
    {ok, State#{unloaded => [Coords | Unloaded]}}.

probe(Msg) ->
    case whereis(?PROBE) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.
