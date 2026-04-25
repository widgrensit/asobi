-module(asobi_zone_snapshotter).
-behaviour(gen_server).

%% Batched async DB writer for zone entity snapshots.
%% Deduplicates per zone key, flushes every 1s.

-export([start_link/0]).
-export([snapshot/1, snapshot_sync/1, delete_world/1]).
-export([load_snapshots/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(FLUSH_INTERVAL, 1000).

%% --- Public API ---

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec snapshot(map()) -> ok.
snapshot(Data) ->
    gen_server:cast(?MODULE, {snapshot, Data}).

-spec snapshot_sync(map()) -> ok.
snapshot_sync(Data) ->
    ok = gen_server:call(?MODULE, {snapshot_sync, Data}, 10000).

-spec delete_world(binary()) -> ok.
delete_world(WorldId) ->
    gen_server:cast(?MODULE, {delete_world, WorldId}).

-spec load_snapshots(binary()) -> {ok, map()} | {error, term()}.
load_snapshots(WorldId) ->
    Q = kura_query:where(kura_query:from(asobi_zone_snapshot), {world_id, WorldId}),
    case asobi_repo:all(Q) of
        {ok, Rows} ->
            {ok, rows_to_map(Rows, #{})};
        {error, _} = Err ->
            Err
    end.

-spec rows_to_map([map()], map()) -> map().
rows_to_map([], Acc) ->
    Acc;
rows_to_map([#{zone_x := ZX, zone_y := ZY} = Row | Rest], Acc) ->
    rows_to_map(Rest, Acc#{{ZX, ZY} => Row}).

%% --- gen_server callbacks ---

-spec init([]) -> {ok, map()}.
init([]) ->
    erlang:send_after(?FLUSH_INTERVAL, self(), flush),
    {ok, #{pending => #{}}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({snapshot_sync, Data}, _From, State) ->
    write_snapshot(Data),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({snapshot, Data}, #{pending := Pending} = State) when is_map(Data) ->
    Key = {maps:get(world_id, Data), maps:get(coords, Data)},
    {noreply, State#{pending => Pending#{Key => Data}}};
handle_cast({delete_world, WorldId}, State) ->
    do_delete_world(WorldId),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(flush, #{pending := Pending} = State) ->
    maps:foreach(fun(_Key, Data) -> write_snapshot(Data) end, Pending),
    erlang:send_after(?FLUSH_INTERVAL, self(), flush),
    {noreply, State#{pending => #{}}};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

write_snapshot(#{world_id := WorldId, coords := {ZX, ZY}} = Data) ->
    Entities = maps:get(entities, Data, #{}),
    ZoneState = maps:get(zone_state, Data, #{}),
    EntityTimers = maps:get(entity_timers, Data, #{}),
    SpawnerState = maps:get(spawner_state, Data, #{}),
    Tick = maps:get(tick, Data, 0),
    %% kura's `utc_datetime` cast wants a calendar:datetime() tuple, not a
    %% raw millisecond integer; passing an integer rejects the changeset
    %% with `cannot cast to utc_datetime` and the row is silently dropped.
    Now = calendar:system_time_to_universal_time(
        erlang:system_time(millisecond), millisecond
    ),
    Fields = #{
        id => asobi_id:generate(),
        world_id => WorldId,
        zone_x => ZX,
        zone_y => ZY,
        entities => Entities,
        zone_state => ZoneState,
        entity_timers => EntityTimers,
        spawner_state => SpawnerState,
        tick => Tick,
        snapshot_at => Now
    },
    AllFields = [
        id,
        world_id,
        zone_x,
        zone_y,
        entities,
        zone_state,
        entity_timers,
        spawner_state,
        tick,
        snapshot_at
    ],
    CS = kura_changeset:cast(asobi_zone_snapshot, #{}, Fields, AllFields),
    ConflictFields = [entities, zone_state, entity_timers, spawner_state, tick, snapshot_at],
    %% kura's `create_index ... unique => true` emits a unique INDEX,
    %% not a CONSTRAINT — so postgres accepts `ON CONFLICT (cols)` but
    %% not `ON CONFLICT ON CONSTRAINT name`. Match by column list.
    Opts = #{
        on_conflict => {
            {columns, [world_id, zone_x, zone_y]}, {replace, ConflictFields}
        }
    },
    case asobi_repo:insert(CS, Opts) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{msg => ~"zone snapshot write failed", reason => Reason}),
            ok
    end.

do_delete_world(WorldId) ->
    Q = kura_query:where(kura_query:from(asobi_zone_snapshot), {world_id, WorldId}),
    case asobi_repo:delete_all(Q) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{msg => ~"zone snapshot cleanup failed", reason => Reason}),
            ok
    end.
