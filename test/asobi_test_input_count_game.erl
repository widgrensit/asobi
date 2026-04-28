-module(asobi_test_input_count_game).
-behaviour(asobi_world).

%% Test fixture for prop_input_never_dropped: every player_input call lands
%% on handle_input/3 and bumps the per-player `inputs_seen` counter on the
%% entity. Allows the property to assert "inputs sent == inputs observed".

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, post_tick/2]).
-export([get_state/2]).

-spec init(map()) -> {ok, map()}.
init(_Config) ->
    {ok, #{tick => 0}}.

-spec join(binary(), map()) -> {ok, map()}.
join(_PlayerId, State) ->
    {ok, State}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(_PlayerId, State) ->
    {ok, State}.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(_PlayerId, _State) ->
    {ok, {0.0, 0.0}}.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(PlayerId, _Input, Entities) ->
    Existing = maps:get(PlayerId, Entities, #{inputs_seen => 0}),
    Seen = maps:get(inputs_seen, Existing, 0),
    {ok, Entities#{PlayerId => Existing#{inputs_seen => Seen + 1}}}.

-spec post_tick(non_neg_integer(), map()) -> {ok, map()}.
post_tick(TickN, State) ->
    {ok, State#{tick => TickN}}.

-spec get_state(binary(), map()) -> map().
get_state(_PlayerId, State) ->
    State.
