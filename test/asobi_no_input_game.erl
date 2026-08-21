-module(asobi_no_input_game).
-moduledoc """
A world module that exports neither `handle_input/3` nor `handle_input_batch/2`.

Both are optional, so this compiles without a missing-callback warning - which
is exactly why the runtime has to say something. A world that takes no player
input is legal; one that RECEIVES input with no handler will never process any.
""".
-behaviour(asobi_world).

-export([init/1, join/2, leave/2, spawn_position/2]).
-export([zone_tick/2, post_tick/2]).

-spec init(map()) -> {ok, map()}.
init(_Config) -> {ok, #{}}.

-spec join(binary(), map()) -> {ok, map()}.
join(_PlayerId, State) -> {ok, State}.

-spec leave(binary(), map()) -> {ok, map()}.
leave(_PlayerId, State) -> {ok, State}.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(_PlayerId, _State) -> {ok, {0.0, 0.0}}.

-spec zone_tick(map(), term()) -> {map(), term()}.
zone_tick(Entities, ZoneState) -> {Entities, ZoneState}.

-spec post_tick(non_neg_integer(), map()) -> {ok, map()}.
post_tick(_TickN, State) -> {ok, State}.
