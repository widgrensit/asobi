-module(asobi_world_lobby).

-export([
    list_worlds/0, list_worlds/1, find_or_create/1, find_or_create/2, create_world/1, create_world/2
]).
-export([list_worlds_cached/0, list_worlds_cached/1]).
-export([find_or_create_unsafe/1, find_or_create_unsafe/2]).
-export([player_owned_world_count/1, world_capacity_state/1]).

-define(PG_SCOPE, nova_scope).
-define(DEFAULT_MAX_WORLDS_PER_PLAYER, 5).
-define(DEFAULT_MAX_WORLDS, 1000).
-define(LIST_CACHE_TAB, asobi_world_lobby_cache).
-define(LIST_CACHE_TTL_MS, 500).

-doc "List all running worlds.".
-spec list_worlds() -> [map()].
list_worlds() ->
    list_worlds(#{}).

-doc "List running worlds with optional filters: mode, has_capacity.".
-spec list_worlds(map()) -> [map()].
list_worlds(Filters) ->
    Groups = pg:which_groups(?PG_SCOPE),
    WorldGroups = [
        {WorldId, Pid}
     || {asobi_world_server, WorldId} = Group <- Groups,
        Pid <- take_first(pg:get_members(?PG_SCOPE, Group))
    ],
    Worlds = lists:filtermap(
        fun({_WorldId, Pid}) ->
            try asobi_world_server:get_info(Pid) of
                Info when is_map(Info) ->
                    case matches_filters(Info, Filters) of
                        true -> {true, Info};
                        false -> false
                    end
            catch
                _:_ -> false
            end
        end,
        WorldGroups
    ),
    Worlds.

-doc """
H3 (2026-05-19): cached variant of `list_worlds/1` for request paths that
do not need a fresh enumeration on every call. Each `list_worlds/1` call
issues one synchronous `gen_server:call` per running world (`get_info/1`);
WS `world.list` at 60 msg/sec x 1000 worlds = 60k calls/sec/attacker. The
cache (500 ms TTL, backed by the ETS table owned by
`asobi_world_lobby_server`) absorbs that fan-out without changing the
serialization story for `find_or_create_unsafe` which stays uncached.

The cache key is the `has_capacity` boolean only, never the raw filter
map: `mode` is attacker-controlled and unbounded, so keying on it would
let a client cycle distinct modes to force a miss on every request
(defeating the cache) and grow the table without bound. Instead the full
enumeration is cached under at most two keys and `mode` is applied
in-memory on the cached list.
""".
-spec list_worlds_cached() -> [map()].
list_worlds_cached() ->
    list_worlds_cached(#{}).

-spec list_worlds_cached(map()) -> [map()].
list_worlds_cached(Filters) ->
    HasCapacity = maps:get(has_capacity, Filters, false),
    Now = erlang:monotonic_time(millisecond),
    All =
        case cache_lookup(HasCapacity, Now) of
            {hit, Worlds} ->
                Worlds;
            miss ->
                Worlds = list_worlds(#{has_capacity => HasCapacity, listed => true}),
                asobi_world_lobby_server:cache_worlds(
                    HasCapacity, Worlds, Now + ?LIST_CACHE_TTL_MS
                ),
                Worlds
        end,
    case maps:get(mode, Filters, undefined) of
        undefined -> All;
        Mode -> [W || W <- All, maps:get(mode, W, undefined) =:= Mode]
    end.

-spec cache_lookup(boolean(), integer()) -> {hit, [map()]} | miss.
cache_lookup(Key, Now) ->
    try ets:lookup(?LIST_CACHE_TAB, Key) of
        [{_, Worlds, ExpiresAt}] when ExpiresAt > Now -> {hit, Worlds};
        _ -> miss
    catch
        error:badarg -> miss
    end.

-doc """
Find a running world with capacity for the given mode, or create one.

Calls go through `asobi_world_lobby_server` to serialize concurrent
requests. The naive list-then-create sequence has a TOCTOU race:
two callers both see `list_worlds = []`, both call `create_world`,
and both clients end up in different worlds despite asking for the
same mode. Serializing closes the window.
""".
-spec find_or_create(binary()) -> {ok, pid(), map()} | {error, term()}.
find_or_create(Mode) ->
    find_or_create(Mode, undefined).

-spec find_or_create(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
find_or_create(Mode, PlayerId) ->
    asobi_world_lobby_server:find_or_create(Mode, PlayerId).

-doc """
The non-serialized implementation. Only `asobi_world_lobby_server`
should call this — direct callers race. Exposed because the
serializer holds no state and just delegates back here.
""".
-spec find_or_create_unsafe(binary()) -> {ok, pid(), map()} | {error, term()}.
find_or_create_unsafe(Mode) ->
    find_or_create_unsafe(Mode, undefined).

-spec find_or_create_unsafe(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
find_or_create_unsafe(Mode, PlayerId) ->
    case mode_quick_play(Mode) of
        true -> do_find_or_create(Mode, PlayerId);
        false -> {error, quick_play_disabled}
    end.

%% Without this guard a `quick_play => false` mode would never match the
%% filter below and so would spawn a fresh world on every call, up to the
%% global cap.
-spec mode_quick_play(binary()) -> boolean().
mode_quick_play(Mode) ->
    case asobi_game_modes:world_config(Mode) of
        {ok, Config} -> maps:get(quick_play, Config, true);
        {error, _} -> true
    end.

-spec do_find_or_create(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
do_find_or_create(Mode, PlayerId) ->
    Worlds = list_worlds(#{mode => Mode, has_capacity => true, quick_play => true}),
    case Worlds of
        [#{world_id := WorldId} = First | _] ->
            case asobi_world_server:whereis(WorldId) of
                {ok, Pid} -> {ok, Pid, First};
                error -> create_world(Mode, PlayerId)
            end;
        [] ->
            create_world(Mode, PlayerId)
    end.

-doc "Create a new world for the given mode (no owner — anonymous create).".
-spec create_world(binary()) -> {ok, pid(), map()} | {error, term()}.
create_world(Mode) ->
    create_world(Mode, undefined).

-doc """
Create a new world for the given mode and tag the player as owner.

Refuses with `{error, world_capacity_reached}` when the global cap
(`asobi:world_max`, default 1000) is hit, and `{error, player_world_limit_reached}`
when the player is already at the per-player cap (`asobi:world_max_per_player`,
default 5). The cap is enforced via a pg group joined on creation so it
naturally clears when the world process dies.
""".
-spec create_world(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
create_world(Mode, PlayerId) ->
    case check_world_capacity(PlayerId) of
        ok ->
            do_create_world(Mode, PlayerId);
        {error, _} = Err ->
            Err
    end.

-spec do_create_world(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
do_create_world(Mode, PlayerId) ->
    case asobi_game_modes:world_config(Mode) of
        {ok, Config0} ->
            %% Pre-allocate the world_id so the zone_manager (started before
            %% the world_server by asobi_world_instance) has a real id from
            %% the start. Otherwise zones spawn with world_id=undefined and
            %% their snapshot writes collide on the
            %% zone_snapshots_world_id_zone_x_zone_y_index unique constraint.
            WorldId = asobi_id:generate(),
            Config = Config0#{world_id => WorldId},
            case asobi_world_instance_sup:start_world(Config) of
                {ok, InstancePid} when is_pid(InstancePid) ->
                    case wait_for_world_server(InstancePid, 10) of
                        undefined ->
                            {error, world_server_not_started};
                        WorldPid ->
                            register_world_owner(WorldPid, PlayerId),
                            Info = asobi_world_server:get_info(WorldPid),
                            {ok, WorldPid, Info}
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% F-9: track per-player and global concurrent-world caps via pg.
%% Joining the world pid into `{asobi_owned_worlds, PlayerId}` and
%% `asobi_owned_worlds_global` ties the count to the world process
%% lifetime — when the world dies the pg group entry vanishes
%% automatically.
-spec check_world_capacity(binary() | undefined) -> ok | {error, term()}.
check_world_capacity(PlayerId) ->
    GlobalCount = global_world_count(),
    GlobalMax = application:get_env(asobi, world_max, ?DEFAULT_MAX_WORLDS),
    case GlobalCount >= GlobalMax of
        true ->
            {error, world_capacity_reached};
        false ->
            check_per_player_cap(PlayerId)
    end.

-spec check_per_player_cap(binary() | undefined) -> ok | {error, term()}.
check_per_player_cap(undefined) ->
    %% Anonymous creates (internal callers, not request-driven) bypass
    %% the per-player cap. The global cap above still applies.
    ok;
check_per_player_cap(PlayerId) when is_binary(PlayerId) ->
    PlayerCount = player_owned_world_count(PlayerId),
    PlayerMax =
        application:get_env(asobi, world_max_per_player, ?DEFAULT_MAX_WORLDS_PER_PLAYER),
    case PlayerCount >= PlayerMax of
        true -> {error, player_world_limit_reached};
        false -> ok
    end.

-spec register_world_owner(pid(), binary() | undefined) -> ok.
register_world_owner(WorldPid, undefined) ->
    pg:join(?PG_SCOPE, asobi_owned_worlds_global, WorldPid),
    ok;
register_world_owner(WorldPid, PlayerId) when is_binary(PlayerId) ->
    pg:join(?PG_SCOPE, asobi_owned_worlds_global, WorldPid),
    pg:join(?PG_SCOPE, {asobi_owned_worlds, PlayerId}, WorldPid),
    ok.

-spec player_owned_world_count(binary()) -> non_neg_integer().
player_owned_world_count(PlayerId) when is_binary(PlayerId) ->
    length(pg:get_members(?PG_SCOPE, {asobi_owned_worlds, PlayerId})).

-spec global_world_count() -> non_neg_integer().
global_world_count() ->
    length(pg:get_members(?PG_SCOPE, asobi_owned_worlds_global)).

-spec world_capacity_state(binary() | undefined) -> map().
world_capacity_state(PlayerId) ->
    Per =
        case PlayerId of
            undefined -> 0;
            _ -> player_owned_world_count(PlayerId)
        end,
    #{
        global => global_world_count(),
        global_max => application:get_env(asobi, world_max, ?DEFAULT_MAX_WORLDS),
        player => Per,
        player_max =>
            application:get_env(asobi, world_max_per_player, ?DEFAULT_MAX_WORLDS_PER_PLAYER)
    }.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec matches_filters(map(), map()) -> boolean().
matches_filters(Info, Filters) ->
    ModeOk =
        case maps:find(mode, Filters) of
            {ok, Mode} -> maps:get(mode, Info, undefined) =:= Mode;
            error -> true
        end,
    CapOk =
        case maps:get(has_capacity, Filters, false) of
            true ->
                maps:get(player_count, Info, 0) < maps:get(max_players, Info, 500);
            false ->
                true
        end,
    %% Include `loading` worlds: a freshly-created world is briefly in this state,
    %% and joins arriving during loading are postponed by the world_server until
    %% running. Excluding loading worlds caused races where two clients each
    %% spawned their own world because neither saw the in-flight one.
    Status = maps:get(status, Info, undefined),
    StatusOk = Status =:= running orelse Status =:= loading,
    ModeOk andalso CapOk andalso StatusOk andalso flag_ok(listed, Info, Filters) andalso
        flag_ok(quick_play, Info, Filters).

%% A visibility flag only constrains the paths that ask for it: the browser
%% filters on `listed`, quick-play on `quick_play`. Neither filters on the
%% other, so a world can be browsable but out of quick-play rotation, or
%% reachable by quick-play while hidden from the browser.
-spec flag_ok(atom(), map(), map()) -> boolean().
flag_ok(Flag, Info, Filters) ->
    case maps:find(Flag, Filters) of
        {ok, Want} -> maps:get(Flag, Info, true) =:= Want;
        error -> true
    end.

-spec take_first([pid()]) -> [pid()].
take_first([Pid | _]) -> [Pid];
take_first([]) -> [].

-spec wait_for_world_server(pid(), non_neg_integer()) -> pid() | undefined.
wait_for_world_server(_InstancePid, 0) ->
    undefined;
wait_for_world_server(InstancePid, Retries) ->
    case asobi_world_instance:get_child(InstancePid, asobi_world_server) of
        undefined ->
            timer:sleep(50),
            wait_for_world_server(InstancePid, Retries - 1);
        Pid ->
            Pid
    end.
