-module(asobi_lua_match_shared).
-moduledoc """
Variant of `asobi_lua_match` for matches where every player sees the same
world state. The match server calls `get_state/1` once per tick and
broadcasts a single pre-encoded payload to every subscriber, instead of
re-encoding once per player.

Selected by declaring `state_strategy = "shared"` in the match script's
config globals. The Lua script must define `get_state(state)` (one
argument). All other callbacks are identical to `asobi_lua_match` and are
delegated to it directly.
""".

-behaviour(asobi_match).

-export([init/1, join/2, join/3, leave/2, handle_input/3, tick/1, get_state/1]).
-export([vote_requested/1, vote_resolved/3]).

-define(GET_STATE_TIMEOUT, 100).

-spec init(map()) -> {ok, map()}.
init(Config) -> asobi_lua_match:init(Config).

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, State) -> asobi_lua_match:join(PlayerId, State).

-spec join(binary(), map(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, Ctx, State) -> asobi_lua_match:join(PlayerId, Ctx, State).

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, State) -> asobi_lua_match:leave(PlayerId, State).

-spec handle_input(binary(), map(), map()) -> {ok, map()}.
handle_input(PlayerId, Input, State) -> asobi_lua_match:handle_input(PlayerId, Input, State).

-spec tick(map()) -> {ok, map()} | {finished, map(), map()}.
tick(State) -> asobi_lua_match:tick(State).

-spec get_state(map()) -> map().
get_state(#{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(get_state, [GS], LuaSt, ?GET_STATE_TIMEOUT) of
        {ok, [SharedState | _], LuaSt1} ->
            asobi_lua_api:decode_to_map(SharedState, LuaSt1);
        {error, _} ->
            #{}
    end.

-spec vote_requested(map()) -> {ok, map()} | none.
vote_requested(State) -> asobi_lua_match:vote_requested(State).

-spec vote_resolved(binary(), map(), map()) -> {ok, map()}.
vote_resolved(Template, Result, State) -> asobi_lua_match:vote_resolved(Template, Result, State).
