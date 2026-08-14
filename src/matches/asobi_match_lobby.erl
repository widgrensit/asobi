-module(asobi_match_lobby).
-moduledoc """
Discovery for live matches.

`GET /api/v1/matches` reads the `asobi_match_record` table: finished
matches, an audit trail, nothing a player can join. This module enumerates
the running `asobi_match_server` processes instead, which is what a client
choosing a match actually needs.

Matches are **unlisted by default**. A match spawned by the matchmaker is
already assigned to its players and has no reason to appear in a browser,
so a mode opts in with `listed = true` (a Lua global, or `listed => true` in
the operator's `game_modes` config). This is the inverse of worlds, which
default to listed because their browser already shipped.
""".

-export([list_matches/0, list_matches/1, list_matches_cached/1]).
-export([find_or_create/2, find_or_create_unsafe/2, live_match_count/0]).

-define(LIST_CACHE_TTL_MS, 500).
-define(PG_SCOPE, nova_scope).
-define(DEFAULT_MAX_MATCHES, 1000).
-define(LIVE_MATCHES_GROUP, asobi_live_matches_global).

-doc "List live matches. Unfiltered - callers that serve clients want `list_matches/1`.".
-spec list_matches() -> [map()].
list_matches() ->
    list_matches(#{}).

-doc """
List live matches with optional filters: `mode`, `has_capacity`, `listed`,
`joinable`.

Only `waiting` and `running` matches are returned; a `finished` match is
history and a `paused` one cannot be joined.

`has_capacity` and `joinable` are separate questions and both have to be
asked to find a match that will actually take a player: a match with room
can still have closed itself to new joins, and a full match is not locked -
it may free a slot on the next leave.
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
`has_capacity` and `joinable` only - both are bounded, so the table stays
small, while `mode` is client-controlled and unbounded and keying on it
would miss on every request and grow the table without bound.
""".
-spec list_matches_cached(map()) -> [map()].
list_matches_cached(Filters) ->
    HasCapacity = maps:get(has_capacity, Filters, false),
    Joinable = maps:get(joinable, Filters, undefined),
    Now = erlang:monotonic_time(millisecond),
    Key = {asobi_match_server, HasCapacity, Joinable},
    Base = #{has_capacity => HasCapacity, listed => true},
    Inner =
        case Joinable of
            undefined -> Base;
            _ -> Base#{joinable => Joinable}
        end,
    All =
        case asobi_discovery:cache_lookup(Key, Now) of
            {hit, Matches} ->
                Matches;
            miss ->
                Matches = list_matches(Inner),
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
    JoinableOk =
        case maps:find(joinable, Filters) of
            {ok, WantJoin} -> maps:get(joinable, Info, true) =:= WantJoin;
            error -> true
        end,
    Status = maps:get(status, Info, undefined),
    StatusOk = Status =:= waiting orelse Status =:= running,
    ModeOk andalso CapOk andalso ListedOk andalso JoinableOk andalso StatusOk.

-doc """
Get this player into a live match of `Mode`, spawning one if there is none.

The match twin of `asobi_world_lobby:find_or_create/2`, and the reason it
exists: the matchmaker groups co-queued tickets and spawns - it never joins a
player into a running match (see `asobi_matchmaker_fill`, whose `match/2` only
ever sees the ticket queue). So before this the only route into a live match was
`match.list` then `match.join`, a browse-then-join with the same TOCTOU
`asobi_world_lobby_server` was built to close, and worse here because a split
leaves two half-empty matches that may both fail to reach `min_players`.

Serialized through `asobi_world_lobby_server`, which already owns the shared
listing cache for both worlds and matches. Calling `find_or_create_unsafe/2`
directly is racy.

Only `listed` modes participate, which is the opt-in and needs no new flag:
matches are unlisted by default, so a ranked mode the matchmaker owns is
unreachable here by construction.
""".
-spec find_or_create(binary(), binary() | undefined) -> {ok, pid(), map()} | {error, term()}.
find_or_create(Mode, PlayerId) ->
    asobi_world_lobby_server:find_or_create_match(Mode, PlayerId).

-doc """
The inner sequence. Public only so the serializing server can call it - every
other caller wants `find_or_create/2`.
""".
-spec find_or_create_unsafe(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
find_or_create_unsafe(Mode, _PlayerId) ->
    ModeConfig = asobi_game_modes:mode_config(Mode),
    case eligible(Mode, ModeConfig) of
        {error, _} = Err ->
            Err;
        ok ->
            Filters = #{mode => Mode, has_capacity => true, joinable => true},
            %% Fullest first, via decorate-sort-undecorate then reverse:
            %% lists:sort/2 is specced fun((term(), term()) -> boolean()), which
            %% erases the element type, while lists:sort/1 is polymorphic and
            %% keeps it.
            %%
            %% list_matches/1 order comes from pg:which_groups/1,
            %% i.e. ETS iteration order, which is arbitrary and reshuffles as
            %% groups churn - so without this, concurrent callers can flip to a
            %% different match mid-fill and leave two half-filled waiting
            %% matches that each die at ?WAITING_TIMEOUT without reaching
            %% min_players. That is the exact failure this verb exists to
            %% prevent. Fullest-first consolidates: a waiting match at 1/2 is
            %% the one most worth completing.
            case fullest(list_matches(Filters)) of
                Info when is_map(Info) ->
                    %% A listing entry can name a match that died between the
                    %% enumeration and here, so resolve it again and fall
                    %% through to a spawn rather than handing back a dead pid.
                    case asobi_match_server:whereis(maps:get(match_id, Info, ~"")) of
                        {ok, Pid} -> {ok, Pid, Info};
                        error -> spawn_match(Mode, ModeConfig)
                    end;
                none ->
                    spawn_match(Mode, ModeConfig)
            end
    end.

%% Concrete integer key: maps:get/3 hands back a dynamic, and negating or
%% sorting on that widens the decorated tuple enough to erase the map type of
%% its second element.
%% Only the top entry is ever used, so this picks the maximum rather than
%% sorting - which also sidesteps lists:sort/2 being specced to return
%% [term()], erasing the element type.
-spec fullest([map()]) -> map() | none.
fullest([]) ->
    none;
fullest([H | T]) ->
    fullest(T, H).

-spec fullest([map()], map()) -> map().
fullest([], Best) ->
    Best;
fullest([H | T], Best) ->
    case player_count_of(H) > player_count_of(Best) of
        true -> fullest(T, H);
        false -> fullest(T, Best)
    end.

-spec player_count_of(map()) -> integer().
player_count_of(Info) ->
    case maps:get(player_count, Info, 0) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%% asobi#482: `quick_play` is the eligibility axis, NOT `listed`.
%%
%% They are deliberately independent (guides/world-server.md#visibility):
%% `listed` is browser visibility, `quick_play` is "may a player be dropped into
%% an existing instance of this mode". Filtering on `listed` would collapse them
%% and remove the operator's ability to express "auto-filled but hidden".
%%
%% It defaults to FALSE for matches, where worlds default true. Worlds shipped
%% with find_or_create so their modes were always opted in; match modes have
%% been matchmaker-only until now, and defaulting them open would silently
%% expose every existing operator's ranked mode the moment they upgrade - a
%% client could spawn and join a ranked match having never been rated or queued.
%% guides/configuration.md already promised that `quick_play = false` on a match
%% mode is "protective rather than inert"; this is the path that makes it true.
-spec eligible(binary(), map()) -> ok | {error, term()}.
eligible(_Mode, ModeConfig) when map_size(ModeConfig) =:= 0 ->
    {error, not_found};
eligible(_Mode, #{type := world}) ->
    {error, wrong_mode_type};
eligible(_Mode, ModeConfig) ->
    case maps:get(quick_play, ModeConfig, false) of
        true -> ok;
        _ -> {error, quick_play_disabled}
    end.

-doc """
Live matches, counted from the pg group rather than by asking each one.

Counted from the flat `asobi_live_matches_global` group that `asobi_match_server`
joins alongside its per-id one, mirroring `asobi_owned_worlds_global` on the
world side. Note the per-id group is keyed `{asobi_match_server, MatchId}`, a
tuple, so there is no bare-atom group to count - that mistake reads as a cap
that never fires.

Counting via `list_matches/0` instead would issue a `gen_statem:call` per live
match on every create, the amplification the listing cache exists to avoid.
""".
-spec live_match_count() -> non_neg_integer().
live_match_count() ->
    length(pg:get_members(?PG_SCOPE, ?LIVE_MATCHES_GROUP)).

-spec spawn_match(binary(), map()) -> {ok, pid(), map()} | {error, term()}.
spawn_match(Mode, ModeConfig) ->
    Max = application:get_env(asobi, match_max, ?DEFAULT_MAX_MATCHES),
    case live_match_count() >= Max of
        true ->
            {error, match_capacity_reached};
        false ->
            do_spawn(Mode, ModeConfig)
    end.

-spec do_spawn(binary(), map()) -> {ok, pid(), map()} | {error, term()}.
do_spawn(Mode, ModeConfig) ->
    case asobi_game_modes:resolve_game_module(Mode) of
        {ok, GameMod, ExtraConfig} ->
            MatchSize = maps:get(match_size, ModeConfig, 2),
            Config = #{
                mode => Mode,
                game_module => GameMod,
                game_config => ExtraConfig,
                min_players => maps:get(min_players, ModeConfig, MatchSize),
                max_players => maps:get(max_players, ModeConfig, MatchSize),
                listed => maps:get(listed, ModeConfig, false),
                quick_play => maps:get(quick_play, ModeConfig, false)
            },
            case asobi_match_sup:start_match(Config) of
                {ok, Pid} when is_pid(Pid) ->
                    %% Both branches return the listing projection. The find
                    %% branch already does; returning the full get_info here
                    %% would hand the next caller a roster and server-side flags
                    %% the other branch never provides.
                    {ok, Pid,
                        asobi_match_server:listing_info(
                            asobi_match_server:get_info(Pid, listing)
                        )};
                {error, _} = Err ->
                    Err;
                Other ->
                    {error, {start_match_failed, Other}}
            end;
        {error, _} = Err ->
            Err
    end.
