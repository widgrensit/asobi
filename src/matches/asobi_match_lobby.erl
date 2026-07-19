-module(asobi_match_lobby).
-moduledoc """
Discovery for live matches.

`GET /api/v1/matches` reads the `asobi_match_record` table: finished
matches, an audit trail, nothing a player can join. This module enumerates
the running `asobi_match_server` processes instead, which is what a client
choosing a match actually needs.

Matches are **unlisted by default**. A match spawned by the matchmaker is
already assigned to its players and has no reason to appear in a browser,
so a mode opts in with `listed => true`. This is the inverse of worlds,
which default to listed because their browser already shipped.
""".

-export([list_matches/0, list_matches/1, list_matches_cached/1]).

-define(LIST_CACHE_TTL_MS, 500).

-doc "List live matches. Unfiltered - callers that serve clients want `list_matches/1`.".
-spec list_matches() -> [map()].
list_matches() ->
    list_matches(#{}).

-doc """
List live matches with optional filters: `mode`, `has_capacity`, `listed`.

Only `waiting` and `running` matches are returned; a `finished` match is
history and a `paused` one cannot be joined.
""".
-spec list_matches(map()) -> [map()].
list_matches(Filters) ->
    asobi_discovery:enumerate(asobi_match_server, Filters, fun matches_filters/2).

-doc """
Cached `list_matches/1` for request paths, mirroring
`asobi_world_lobby:list_worlds_cached/1`.

Each uncached call issues one `gen_statem:call` per live match. That cost
is paid even when every match is unlisted and the result is empty, so a
flood of `match.list` messages would stall every match's mailbox. Keyed on
`has_capacity` only - `mode` is client-controlled and unbounded, so keying
on it would miss on every request and grow the table without bound.
""".
-spec list_matches_cached(map()) -> [map()].
list_matches_cached(Filters) ->
    HasCapacity = maps:get(has_capacity, Filters, false),
    Now = erlang:monotonic_time(millisecond),
    Key = {asobi_match_server, HasCapacity},
    All =
        case asobi_discovery:cache_lookup(Key, Now) of
            {hit, Matches} ->
                Matches;
            miss ->
                Matches = list_matches(#{has_capacity => HasCapacity, listed => true}),
                asobi_world_lobby_server:cache_listing(Key, Matches, Now + ?LIST_CACHE_TTL_MS),
                Matches
        end,
    case maps:get(mode, Filters, undefined) of
        undefined -> All;
        Mode -> [M || M <- All, maps:get(mode, M, undefined) =:= Mode]
    end.

-spec matches_filters(map(), map()) -> boolean().
matches_filters(Info, Filters) ->
    ModeOk =
        case maps:find(mode, Filters) of
            {ok, Mode} -> maps:get(mode, Info, undefined) =:= Mode;
            error -> true
        end,
    CapOk =
        case maps:get(has_capacity, Filters, false) of
            true -> maps:get(player_count, Info, 0) < maps:get(max_players, Info, 0);
            false -> true
        end,
    ListedOk =
        case maps:find(listed, Filters) of
            {ok, Want} -> maps:get(listed, Info, false) =:= Want;
            error -> true
        end,
    Status = maps:get(status, Info, undefined),
    StatusOk = Status =:= waiting orelse Status =:= running,
    ModeOk andalso CapOk andalso ListedOk andalso StatusOk.
