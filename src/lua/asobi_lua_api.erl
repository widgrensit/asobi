-module(asobi_lua_api).
-moduledoc """
Installs the `game.*` Lua API into a Luerl state, giving Lua scripts
access to engine features like economy, leaderboards, notifications,
storage, messaging, spatial queries, and zone spawning.

Called from `asobi_lua_match:init/1` and `asobi_lua_world:init/1`
before the Lua script's `init()` runs.

## Available API

```lua
-- IDs
game.id()                                        -- generate UUIDv7

-- Logging
game.log(level, message)                         -- structured log line ("debug"|"info"|"warning"|"error")
game.log(level, message, meta)                   -- with a metadata table

-- Messaging
game.broadcast(event, payload)                   -- broadcast to all match players
game.send(player_id, message)                    -- send to specific player

-- Economy
game.economy.grant(player_id, currency, amount, reason)
game.economy.debit(player_id, currency, amount, reason)
game.economy.balance(player_id)
game.economy.purchase(player_id, listing_id)

-- Leaderboards
game.leaderboard.submit(board_id, player_id, score)
game.leaderboard.top(board_id, count)
game.leaderboard.rank(board_id, player_id)
game.leaderboard.around(board_id, player_id, count)

-- Notifications
game.notify(player_id, type, subject, data)
game.notify_many(player_ids, type, subject, data)

-- Key-Value Storage
game.storage.get(collection, key)
game.storage.set(collection, key, value)
game.storage.player_get(player_id, collection, key)
game.storage.player_set(player_id, collection, key, value)

-- Chat
game.chat.send(channel_id, sender_id, content)

-- Spatial queries (operate on entity tables)
game.spatial.query_radius(entities, x, y, radius)
game.spatial.query_radius(entities, x, y, radius, opts)
game.spatial.query_radius(x, y, radius)              -- zone-based (requires zone_pid)
game.spatial.query_rect(x1, y1, x2, y2)              -- zone-based (requires zone_pid)
game.spatial.nearest(entities, x, y, n)
game.spatial.nearest(entities, x, y, n, opts)
game.spatial.in_range(entity_a, entity_b, range)
game.spatial.distance(entity_a, entity_b)

-- Zone spawning (world mode only, requires zone_pid in context)
game.zone.spawn(template_id, x, y)              -- false if template_id is unknown
game.zone.spawn(template_id, x, y, overrides)   -- false if template_id is unknown
game.zone.despawn(entity_id)

-- Terrain (world mode only, requires terrain_store_pid in context)
game.terrain.get_chunk(cx, cy)                   -- get compressed chunk data
game.terrain.preload(coords_list)                -- preload chunks async
```

## Result envelope

The persistence-style calls (`economy.*`, `storage.*`, `leaderboard.top/rank/around`,
`terrain.get_chunk`, `notify`) return a wrapped result: `{ ok = Value }` on
success, `{ error = "reason" }` on failure (`ok_result/2` / `error_result/2` via
`wrap_result/2`). Read `result.ok`. The plain calls (`broadcast`, `send`,
`chat.send`, `zone.spawn`/`despawn`, `leaderboard.submit`, `spatial.*`) return
their value directly.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([install/2]).
-export([deep_decode/1, decode_to_map/2]).
-export([to_storage_value/1]).
-export([atomize_entities/1]).

-spec install(map(), dynamic()) -> dynamic().
install(#{probe := true} = Ctx, St0) ->
    %% A probe VM exists only to ask the script a question (e.g. does it
    %% define phases()) by re-running the whole file body - see
    %% asobi_lua_match:boot_throwaway_lua_state/2 and
    %% asobi_lua_world:boot_throwaway_lua_state/2. Re-running the file body
    %% must not re-fire economy/leaderboard/notify/storage/chat/broadcast
    %% side effects a second time, so every effectful function is stubbed
    %% out here. Read-only/query functions (balance, top/rank/around,
    %% get/player_get, spatial.*) run for real - calling them twice is safe.
    install_pure(Ctx, St0);
install(Ctx, St0) ->
    St1 = create_tables(St0),
    install_fns(api_fns(Ctx, live), St1).

-spec install_pure(map(), dynamic()) -> dynamic().
install_pure(Ctx, St0) ->
    St1 = create_tables(St0),
    install_fns(api_fns(Ctx, probe), St1).

create_tables(St0) ->
    %% Pre-create namespace tables
    St1 = create_table([~"game"], St0),
    St2 = create_table([~"game", ~"economy"], St1),
    St3 = create_table([~"game", ~"leaderboard"], St2),
    St4 = create_table([~"game", ~"storage"], St3),
    St5a = create_table([~"game", ~"chat"], St4),
    St5b = create_table([~"game", ~"spatial"], St5a),
    St5c = create_table([~"game", ~"zone"], St5b),
    create_table([~"game", ~"terrain"], St5c).

%% Builds the {LuaPath, Fun} table install/2 and install_pure/2 both wire up.
%% `zone.*`/`terrain.*` are omitted from the probe/live distinction below:
%% they already gate on `zone_pid`/`terrain_store_pid` being present in Ctx
%% (see fun_zone_spawn/1, fun_terrain_get_chunk/1 etc.), and a probe VM's Ctx
%% never carries those keys, so they are already inert in probe mode without
%% help from `pick/3`.
api_fns(Ctx, Mode) ->
    [
        %% Core
        {[~"game", ~"id"], fun_id()},
        {[~"game", ~"log"], fun_log(Ctx)},
        {[~"game", ~"broadcast"], pick(Mode, ~"game.broadcast", fun_broadcast(Ctx))},
        {[~"game", ~"send"], pick(Mode, ~"game.send", fun_send())},
        %% Economy
        {[~"game", ~"economy", ~"grant"], pick(Mode, ~"game.economy.grant", fun_economy_grant())},
        {[~"game", ~"economy", ~"debit"], pick(Mode, ~"game.economy.debit", fun_economy_debit())},
        {[~"game", ~"economy", ~"balance"], fun_economy_balance()},
        {
            [~"game", ~"economy", ~"purchase"],
            pick(Mode, ~"game.economy.purchase", fun_economy_purchase())
        },
        %% Leaderboard
        {
            [~"game", ~"leaderboard", ~"submit"],
            pick(Mode, ~"game.leaderboard.submit", fun_lb_submit())
        },
        {[~"game", ~"leaderboard", ~"top"], fun_lb_top()},
        {[~"game", ~"leaderboard", ~"rank"], fun_lb_rank()},
        {[~"game", ~"leaderboard", ~"around"], fun_lb_around()},
        %% Notifications
        {[~"game", ~"notify"], pick(Mode, ~"game.notify", fun_notify())},
        {[~"game", ~"notify_many"], pick(Mode, ~"game.notify_many", fun_notify_many())},
        %% Storage
        {[~"game", ~"storage", ~"get"], fun_storage_get()},
        {[~"game", ~"storage", ~"set"], pick(Mode, ~"game.storage.set", fun_storage_set())},
        {[~"game", ~"storage", ~"player_get"], fun_storage_player_get()},
        {
            [~"game", ~"storage", ~"player_set"],
            pick(Mode, ~"game.storage.player_set", fun_storage_player_set())
        },
        %% Chat
        {[~"game", ~"chat", ~"send"], pick(Mode, ~"game.chat.send", fun_chat_send())},
        %% Spatial
        {[~"game", ~"spatial", ~"query_radius"], fun_spatial_query_radius(Ctx)},
        {[~"game", ~"spatial", ~"query_rect"], fun_spatial_query_rect(Ctx)},
        {[~"game", ~"spatial", ~"nearest"], fun_spatial_nearest()},
        {[~"game", ~"spatial", ~"in_range"], fun_spatial_in_range()},
        {[~"game", ~"spatial", ~"distance"], fun_spatial_distance()},
        %% Zone spawning
        {[~"game", ~"zone", ~"spawn"], fun_zone_spawn(Ctx)},
        {[~"game", ~"zone", ~"despawn"], fun_zone_despawn(Ctx)},
        %% Terrain
        {[~"game", ~"terrain", ~"get_chunk"], fun_terrain_get_chunk(Ctx)},
        {[~"game", ~"terrain", ~"preload"], fun_terrain_preload(Ctx)}
    ].

%% Selects the real function in live mode; in probe mode, swaps anything that
%% mutates persistent state, broadcasts an event, or grants/deducts a
%% resource for `inert/1`, so re-running a script's top-level body a second
%% time (to ask it a question like "do you define phases()?") cannot re-fire
%% that side effect.
pick(live, _Name, RealFn) -> RealFn;
pick(probe, Name, _RealFn) -> inert(Name).

%% See asobi_lua_match.erl / asobi_lua_world.erl `boot_throwaway_lua_state/2`.
inert(Name) ->
    fun(_Args, St) ->
        ?LOG_DEBUG(#{msg => ~"asobi_lua: effectful api suppressed in probe vm", fn => Name}),
        {[false], St}
    end.

install_fns(Fns, St0) ->
    lists:foldl(
        fun({Path, Fn}, St) ->
            {Enc, StA} = luerl:encode(Fn, St),
            {ok, StB} = luerl:set_table_keys(Path, Enc, StA),
            StB
        end,
        St0,
        Fns
    ).

%% --- Core ---

fun_id() ->
    fun(_, St) ->
        Id = asobi_id:generate(),
        {[Id], St}
    end.

%% game.log ships a structured line through the host logger, so it lands in
%% the JSON stdout stream (and the console log viewer) instead of breaking it
%% the way Luerl's stripped print/eprint did. Two seki gates: per-match/zone
%% so one chatty script can't drown its neighbours' lines, plus a node-wide
%% backstop bounding the aggregate log-pipeline cost. Levels map through
%% explicit clauses - script data never mints atoms.
fun_log(Ctx) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Level, Message] when is_binary(Level) ->
                do_log(Level, Message, undefined, Ctx, St);
            [Level, Message, Meta] when
                is_binary(Level) andalso (is_list(Meta) orelse is_map(Meta))
            ->
                do_log(Level, Message, Meta, Ctx, St);
            _ ->
                error_result(~"log requires (level, message[, meta_table])", St)
        end
    end.

do_log(LevelBin, Message, Meta, Ctx, St) ->
    case log_level(LevelBin) of
        invalid ->
            error_result(~"log level must be debug|info|warn|warning|error", St);
        {ok, Level} ->
            case log_allowed(log_key(Ctx)) of
                false ->
                    log_dropped(Ctx),
                    {[false], St};
                true ->
                    ?LOG(Level, log_report(Message, Meta, Ctx)),
                    {[true], St}
            end
    end.

log_level(~"debug") -> {ok, debug};
log_level(~"info") -> {ok, info};
log_level(~"warn") -> {ok, warning};
log_level(~"warning") -> {ok, warning};
log_level(~"error") -> {ok, error};
log_level(_) -> invalid.

%% Zones share their world's match_id, so they key on the zone process
%% instead - one zone at full budget must not starve its siblings.
log_key(#{zone_pid := ZonePid}) when is_pid(ZonePid) -> ZonePid;
log_key(#{match_id := MatchId}) when MatchId =/= undefined -> MatchId;
log_key(_) -> self().

%% Fails closed: embedded without the asobi_lua supervision tree (no
%% limiters registered) means no log flooding path either.
log_allowed(Key) ->
    try
        case seki:check(asobi_lua_log_limiter, Key) of
            {allow, _} ->
                case seki:check(asobi_lua_log_global_limiter, ~"global") of
                    {allow, _} -> true;
                    {deny, _} -> false
                end;
            {deny, _} ->
                false
        end
    catch
        _:_ -> false
    end.

log_report(Message, Meta, Ctx) ->
    Base = #{
        msg => ~"game.log",
        script => asobi_lua_game_error:script_basename(maps:get(script, Ctx, undefined)),
        context => log_context(Ctx),
        match_id => maps:get(match_id, Ctx, undefined),
        message => log_render(Message)
    },
    case Meta of
        undefined -> Base;
        _ -> Base#{meta => bound_meta(Meta)}
    end.

log_context(#{zone_pid := ZonePid}) when is_pid(ZonePid) -> zone;
log_context(_) -> match.

log_render(Message) when is_binary(Message) ->
    asobi_lua_game_error:bound(Message);
log_render(Message) ->
    Storage = to_storage_value(Message),
    Rendered =
        try
            iolist_to_binary(json:encode(Storage))
        catch
            _:_ -> unicode:characters_to_binary(io_lib:format("~0tp", [Storage]))
        end,
    asobi_lua_game_error:bound(Rendered).

-define(MAX_META_BYTES, 2048).

bound_meta(Meta) ->
    Storage = to_storage_value(Meta),
    try iolist_to_binary(json:encode(Storage)) of
        Enc when byte_size(Enc) > ?MAX_META_BYTES -> #{~"_truncated" => true};
        _ -> Storage
    catch
        _:_ -> #{~"_unencodable" => true}
    end.

%% Coarse context only - a per-match/zone tag would be unbounded telemetry
%% cardinality. Guarded like asobi_lua_game_error:emit/3: the observer must
%% never crash the observed game loop.
log_dropped(Ctx) ->
    try
        telemetry:execute(
            [asobi_lua, log, rate_limited], #{count => 1}, #{context => log_context(Ctx)}
        )
    catch
        _:_ -> ok
    end.

fun_broadcast(#{match_pid := MatchPid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Event, Payload] when is_binary(Event) ->
                asobi_match_server:broadcast_event(MatchPid, Event, to_map(Payload)),
                {[true], St};
            [Event] when is_binary(Event) ->
                asobi_match_server:broadcast_event(MatchPid, Event, #{}),
                {[true], St};
            _ ->
                error_result(~"broadcast requires (event, payload)", St)
        end
    end;
fun_broadcast(_) ->
    fun(_, St) -> error_result(~"broadcast not available (no match context)", St) end.

fun_send() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Message] when is_binary(PlayerId) ->
                asobi_presence:send(PlayerId, {game_message, to_storage_value(Message)}),
                {[true], St};
            _ ->
                error_result(~"send requires (player_id, message)", St)
        end
    end.

%% --- Economy ---

fun_economy_grant() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Currency, Amount, Reason] when
                is_binary(PlayerId),
                is_binary(Currency),
                is_number(Amount),
                is_binary(Reason)
            ->
                wrap_result(
                    asobi_economy:grant(PlayerId, Currency, trunc(Amount), #{reason => Reason}),
                    St
                );
            [PlayerId, Currency, Amount] when
                is_binary(PlayerId), is_binary(Currency), is_number(Amount)
            ->
                wrap_result(
                    asobi_economy:grant(PlayerId, Currency, trunc(Amount), #{}),
                    St
                );
            _ ->
                error_result(~"grant requires (player_id, currency, amount[, reason])", St)
        end
    end.

fun_economy_debit() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Currency, Amount, Reason] when
                is_binary(PlayerId),
                is_binary(Currency),
                is_number(Amount),
                is_binary(Reason)
            ->
                wrap_result(
                    asobi_economy:debit(PlayerId, Currency, trunc(Amount), #{reason => Reason}),
                    St
                );
            [PlayerId, Currency, Amount] when
                is_binary(PlayerId), is_binary(Currency), is_number(Amount)
            ->
                wrap_result(
                    asobi_economy:debit(PlayerId, Currency, trunc(Amount), #{}),
                    St
                );
            _ ->
                error_result(~"debit requires (player_id, currency, amount[, reason])", St)
        end
    end.

fun_economy_balance() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId] when is_binary(PlayerId) ->
                case asobi_economy:get_wallets(PlayerId) of
                    {ok, Wallets} ->
                        Sanitized = [
                            #{
                                ~"currency" => maps:get(currency, W, ~""),
                                ~"balance" => maps:get(balance, W, 0)
                            }
                         || W <- Wallets
                        ],
                        ok_result(Sanitized, St);
                    {error, Reason} ->
                        error_result(Reason, St)
                end;
            _ ->
                error_result(~"balance requires (player_id)", St)
        end
    end.

fun_economy_purchase() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, ListingId] when is_binary(PlayerId), is_binary(ListingId) ->
                wrap_result(asobi_economy:purchase(PlayerId, ListingId), St);
            _ ->
                error_result(~"purchase requires (player_id, listing_id)", St)
        end
    end.

%% --- Leaderboard ---

fun_lb_submit() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId, Score] when
                is_binary(BoardId), is_binary(PlayerId), is_number(Score)
            ->
                case asobi_leaderboard_server:submit(BoardId, PlayerId, trunc(Score)) of
                    ok -> {[true], St};
                    {error, _Reason} -> {[false], St}
                end;
            _ ->
                error_result(~"submit requires (board_id, player_id, score)", St)
        end
    end.

fun_lb_top() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, Count] when is_binary(BoardId), is_number(Count) ->
                Entries = asobi_leaderboard_server:top(BoardId, trunc(Count)),
                Encoded = encode_lb_entries(Entries),
                ok_result(Encoded, St);
            _ ->
                error_result(~"top requires (board_id, count)", St)
        end
    end.

fun_lb_rank() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId] when is_binary(BoardId), is_binary(PlayerId) ->
                case asobi_leaderboard_server:rank(BoardId, PlayerId) of
                    {ok, Rank} -> ok_result(Rank, St);
                    {error, not_found} -> error_result(~"not_found", St)
                end;
            _ ->
                error_result(~"rank requires (board_id, player_id)", St)
        end
    end.

fun_lb_around() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [BoardId, PlayerId, Count] when
                is_binary(BoardId), is_binary(PlayerId), is_number(Count)
            ->
                Entries = asobi_leaderboard_server:around(BoardId, PlayerId, trunc(Count)),
                Encoded = encode_lb_entries(Entries),
                ok_result(Encoded, St);
            _ ->
                error_result(~"around requires (board_id, player_id, count)", St)
        end
    end.

%% --- Notifications ---

fun_notify() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Type, Subject, Data] when
                is_binary(PlayerId), is_binary(Type), is_binary(Subject)
            ->
                wrap_result(asobi_notify:send(PlayerId, Type, Subject, to_map(Data)), St);
            [PlayerId, Type, Subject] when
                is_binary(PlayerId), is_binary(Type), is_binary(Subject)
            ->
                wrap_result(asobi_notify:send(PlayerId, Type, Subject, #{}), St);
            _ ->
                error_result(~"notify requires (player_id, type, subject[, data])", St)
        end
    end.

fun_notify_many() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerIds, Type, Subject, Data] when
                is_list(PlayerIds), is_binary(Type), is_binary(Subject)
            ->
                Ids = [Id || Id <- PlayerIds, is_binary(Id)],
                Sent = asobi_notify:send_many(Ids, Type, Subject, to_map(Data)),
                ok_result(Sent, St);
            [PlayerIds, Type, Subject] when
                is_list(PlayerIds), is_binary(Type), is_binary(Subject)
            ->
                Ids = [Id || Id <- PlayerIds, is_binary(Id)],
                Sent = asobi_notify:send_many(Ids, Type, Subject, #{}),
                ok_result(Sent, St);
            _ ->
                error_result(~"notify_many requires (player_ids, type, subject[, data])", St)
        end
    end.

%% --- Storage ---

fun_storage_get() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Collection, Key] when is_binary(Collection), is_binary(Key) ->
                wrap_result(storage_get(Collection, Key, undefined), St);
            _ ->
                error_result(~"get requires (collection, key)", St)
        end
    end.

fun_storage_set() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Collection, Key, Value] when is_binary(Collection), is_binary(Key) ->
                wrap_result(storage_set(Collection, Key, undefined, to_storage_value(Value)), St);
            _ ->
                error_result(~"set requires (collection, key, value)", St)
        end
    end.

fun_storage_player_get() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Collection, Key] when
                is_binary(PlayerId), is_binary(Collection), is_binary(Key)
            ->
                wrap_result(storage_get(Collection, Key, PlayerId), St);
            _ ->
                error_result(~"player_get requires (player_id, collection, key)", St)
        end
    end.

fun_storage_player_set() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [PlayerId, Collection, Key, Value] when
                is_binary(PlayerId), is_binary(Collection), is_binary(Key)
            ->
                wrap_result(storage_set(Collection, Key, PlayerId, to_storage_value(Value)), St);
            _ ->
                error_result(~"player_set requires (player_id, collection, key, value)", St)
        end
    end.

%% --- Chat ---

fun_chat_send() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [ChannelId, SenderId, Content] when
                is_binary(ChannelId), is_binary(SenderId), is_binary(Content)
            ->
                asobi_chat_channel:send_message(ChannelId, SenderId, Content),
                {[true], St};
            _ ->
                error_result(~"chat.send requires (channel_id, sender_id, content)", St)
        end
    end.

%% --- Spatial ---

fun_spatial_query_radius(Ctx) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [X, Y, Radius] when is_number(X), is_number(Y), is_number(Radius) ->
                case maps:find(zone_pid, Ctx) of
                    {ok, ZonePid} ->
                        Results = asobi_zone:query_radius(ZonePid, {X, Y}, Radius),
                        encode_zone_spatial_results(Results, St);
                    error ->
                        error_result(~"query_radius(x, y, radius) requires zone context", St)
                end;
            [Entities0, X, Y, Radius] when
                is_number(X), is_number(Y), is_number(Radius)
            ->
                %% An empty Lua table `{}` decodes (via deep_decode/1) to `[]`,
                %% not `#{}` - there are no pairs to infer a map from. A
                %% populated, string-keyed table already decodes to a map.
                case Entities0 of
                    Entities when is_map(Entities) ->
                        Results = asobi_spatial:query_radius(
                            atomize_entities(Entities), {X, Y}, Radius
                        ),
                        encode_spatial_results(Results, St);
                    [] ->
                        Results = asobi_spatial:query_radius(#{}, {X, Y}, Radius),
                        encode_spatial_results(Results, St);
                    _ ->
                        error_result(
                            ~"query_radius requires (x, y, radius) or (entities, x, y, radius[, opts])",
                            St
                        )
                end;
            [Entities0, X, Y, Radius, OptsRaw] when
                is_number(X), is_number(Y), is_number(Radius)
            ->
                Opts = decode_spatial_opts(OptsRaw),
                case Entities0 of
                    Entities when is_map(Entities) ->
                        Results = asobi_spatial:query_radius(
                            atomize_entities(Entities), {X, Y}, Radius, Opts
                        ),
                        encode_spatial_results(Results, St);
                    [] ->
                        Results = asobi_spatial:query_radius(#{}, {X, Y}, Radius, Opts),
                        encode_spatial_results(Results, St);
                    _ ->
                        error_result(
                            ~"query_radius requires (x, y, radius) or (entities, x, y, radius[, opts])",
                            St
                        )
                end;
            _ ->
                error_result(
                    ~"query_radius requires (x, y, radius) or (entities, x, y, radius[, opts])", St
                )
        end
    end.

fun_spatial_query_rect(#{zone_pid := ZonePid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [X1, Y1, X2, Y2] when
                is_number(X1), is_number(Y1), is_number(X2), is_number(Y2)
            ->
                Results = asobi_zone:query_rect(ZonePid, {X1, Y1}, {X2, Y2}),
                encode_zone_spatial_results(Results, St);
            _ ->
                error_result(~"query_rect requires (x1, y1, x2, y2)", St)
        end
    end;
fun_spatial_query_rect(_) ->
    fun(_, St) -> error_result(~"query_rect requires zone context", St) end.

fun_spatial_nearest() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [Entities0, X, Y, N] when is_number(X), is_number(Y), is_number(N) ->
                %% An empty Lua table `{}` decodes (via deep_decode/1) to `[]`,
                %% not `#{}` - there are no pairs to infer a map from. A
                %% populated, string-keyed table already decodes to a map.
                case Entities0 of
                    Entities when is_map(Entities) ->
                        Results = asobi_spatial:nearest(
                            atomize_entities(Entities), {X, Y}, trunc(N)
                        ),
                        encode_spatial_results(Results, St);
                    [] ->
                        Results = asobi_spatial:nearest(#{}, {X, Y}, trunc(N)),
                        encode_spatial_results(Results, St);
                    _ ->
                        error_result(~"nearest requires (entities, x, y, n[, opts])", St)
                end;
            [Entities0, X, Y, N, OptsRaw] when
                is_number(X), is_number(Y), is_number(N)
            ->
                Opts = decode_spatial_opts(OptsRaw),
                case Entities0 of
                    Entities when is_map(Entities) ->
                        Results = asobi_spatial:nearest(
                            atomize_entities(Entities), {X, Y}, trunc(N), Opts
                        ),
                        encode_spatial_results(Results, St);
                    [] ->
                        Results = asobi_spatial:nearest(#{}, {X, Y}, trunc(N), Opts),
                        encode_spatial_results(Results, St);
                    _ ->
                        error_result(~"nearest requires (entities, x, y, n[, opts])", St)
                end;
            _ ->
                error_result(~"nearest requires (entities, x, y, n[, opts])", St)
        end
    end.

fun_spatial_in_range() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [A, B, Range] when is_map(A), is_map(B), is_number(Range) ->
                Result = asobi_spatial:in_range(atomize_keys(A), atomize_keys(B), Range),
                {[Result], St};
            _ ->
                error_result(~"in_range requires (entity_a, entity_b, range)", St)
        end
    end.

fun_spatial_distance() ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [A, B] when is_map(A), is_map(B) ->
                D = asobi_spatial:distance(atomize_keys(A), atomize_keys(B)),
                {[D], St};
            _ ->
                error_result(~"distance requires (entity_a, entity_b)", St)
        end
    end.

encode_spatial_results(Results, St) ->
    Encoded = [
        #{~"id" => Id, ~"entity" => Entity, ~"distance" => Dist}
     || {Id, Entity, Dist} <- Results
    ],
    {Enc, St1} = luerl:encode(Encoded, St),
    {[Enc], St1}.

encode_zone_spatial_results(Results, St) ->
    Encoded = [
        #{~"id" => Id, ~"x" => X, ~"y" => Y}
     || {Id, {X, Y}} <- Results
    ],
    {Enc, St1} = luerl:encode(Encoded, St),
    {[Enc], St1}.

decode_spatial_opts(OptsRaw) when is_map(OptsRaw) ->
    Opts0 = #{},
    Opts1 =
        case maps:find(~"type", OptsRaw) of
            {ok, T} when is_binary(T) -> Opts0#{type => T};
            {ok, T} when is_list(T) -> Opts0#{type => [B || B <- T, is_binary(B)]};
            _ -> Opts0
        end,
    Opts2 =
        case maps:find(~"exclude", OptsRaw) of
            {ok, E} when is_binary(E) -> Opts1#{exclude => E};
            {ok, E} when is_list(E) -> Opts1#{exclude => [B || B <- E, is_binary(B)]};
            _ -> Opts1
        end,
    Opts3 =
        case maps:find(~"max_results", OptsRaw) of
            {ok, N} when is_number(N) -> Opts2#{max_results => trunc(N)};
            _ -> Opts2
        end,
    case maps:find(~"sort", OptsRaw) of
        {ok, ~"nearest"} -> Opts3#{sort => nearest};
        {ok, ~"farthest"} -> Opts3#{sort => farthest};
        _ -> Opts3
    end;
decode_spatial_opts(_) ->
    #{}.

%% --- Zone spawning ---

%% asobi_lua#110: asobi_zone:spawn_entity/3-4 is a self-cast - the zone's own
%% Luerl VM runs inside the zone process (zone_pid =:= self(), see
%% asobi_lua_world:zone_ctx/2), so making the call synchronous to learn
%% whether the template_id resolved would deadlock the zone. Instead the
%% zone's declared template set is checked here, before the cast, so a
%% typo'd template_id returns `false` synchronously instead of a `true` that
%% just means "the cast was sent", not "something spawned".
%%
%% asobi#253: that template set is read live via known_template/2, NOT
%% cached in Ctx - a Ctx snapshot taken at zone init goes stale forever
%% after a script hot-reload adds/renames a template (asobi_lua_reload
%% re-executes the edited script into the existing Luerl state without
%% ever re-running install/2, so a Ctx-captured closure never sees the
%% update). See asobi_lua_world's ?TEMPLATES_KEY.
%%
%% Note this closure (and known_template/2 below) does NOT run in the zone
%% process: asobi_lua_loader:call/4 (used for every Lua callback with a
%% wall-clock budget, i.e. everything but handle_input/3) spawns a
%% short-lived worker to run the actual Lua call, so `self()` here is that
%% worker, not `ZonePid`. That is exactly why the live template set lives
%% in a `protected` ETS table keyed by reference (readable from any
%% process), not the process dictionary of whichever process happens to be
%% running this callback.
fun_zone_spawn(#{zone_pid := ZonePid} = Ctx) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [TemplateId, X, Y] when is_binary(TemplateId), is_number(X), is_number(Y) ->
                case known_template(TemplateId, Ctx) of
                    true ->
                        asobi_zone:spawn_entity(ZonePid, TemplateId, {X, Y}),
                        {[true], St};
                    false ->
                        {[false], St}
                end;
            [TemplateId, X, Y, Overrides0] when
                is_binary(TemplateId), is_number(X), is_number(Y)
            ->
                case known_template(TemplateId, Ctx) of
                    true ->
                        %% An empty Lua table `{}` decodes (via deep_decode/1) to `[]`,
                        %% not `#{}` - there are no pairs to infer a map from. A
                        %% populated, string-keyed table already decodes to a map.
                        case Overrides0 of
                            Overrides when is_map(Overrides) ->
                                asobi_zone:spawn_entity(ZonePid, TemplateId, {X, Y}, Overrides),
                                {[true], St};
                            [] ->
                                asobi_zone:spawn_entity(ZonePid, TemplateId, {X, Y}, #{}),
                                {[true], St};
                            _ ->
                                error_result(
                                    ~"zone.spawn requires (template_id, x, y[, overrides])", St
                                )
                        end;
                    false ->
                        {[false], St}
                end;
            _ ->
                error_result(~"zone.spawn requires (template_id, x, y[, overrides])", St)
        end
    end;
fun_zone_spawn(_) ->
    fun(_, St) -> error_result(~"zone.spawn not available (no zone context)", St) end.

-spec known_template(binary(), map()) -> boolean().
known_template(TemplateId, #{templates_tab := Tab}) ->
    %% Read live from the per-zone ETS table asobi_lua_world:zone_ctx/2
    %% hands us in Ctx, rather than a map value snapshotted into Ctx at
    %% zone init - see the module-level comment on fun_zone_spawn/1 above.
    %% Reads work from any process (the table is `protected`, not tied to
    %% a specific writer's identity); only the owning zone process ever
    %% writes to it (asobi_lua_world:init_zone_state/2 and
    %% spawn_templates_hint/1), so this is always the latest hot-reloaded
    %% set.
    case ets:lookup(Tab, known) of
        [{known, Templates}] when is_map(Templates) -> maps:is_key(TemplateId, Templates);
        _ -> true
    end;
known_template(_TemplateId, _Ctx) ->
    %% Deliberate fail-open, not an accidental gap: a Ctx with no
    %% `templates_tab` (older/non-world callers, direct API tests that
    %% never populate one) stays unrestricted. Only a genuine per-zone Ctx
    %% (built by zone_ctx/2) ever enforces the known-template allowlist.
    true.

fun_zone_despawn(#{zone_pid := ZonePid}) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [EntityId] when is_binary(EntityId) ->
                asobi_zone:despawn_entity(ZonePid, EntityId),
                {[true], St};
            _ ->
                error_result(~"zone.despawn requires (entity_id)", St)
        end
    end;
fun_zone_despawn(_) ->
    fun(_, St) -> error_result(~"zone.despawn not available (no zone context)", St) end.

%% --- Terrain ---

fun_terrain_get_chunk(#{terrain_store_pid := Pid}) when is_pid(Pid) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [CX, CY] when is_number(CX), is_number(CY) ->
                case asobi_terrain_store:get_chunk(Pid, {trunc(CX), trunc(CY)}) of
                    {ok, Data} ->
                        ok_result(Data, St);
                    {error, Reason} ->
                        error_result(Reason, St)
                end;
            _ ->
                error_result(~"get_chunk requires (cx, cy)", St)
        end
    end;
fun_terrain_get_chunk(_) ->
    fun(_, St) -> error_result(~"terrain not available (no terrain store)", St) end.

fun_terrain_preload(#{terrain_store_pid := Pid}) when is_pid(Pid) ->
    fun(Args, St) ->
        case decode_args(Args, St) of
            [CoordsList] when is_list(CoordsList) ->
                Coords = lists:filtermap(
                    fun
                        (M) when is_map(M) ->
                            CX = maps:get(~"cx", M, maps:get(~"x", M, undefined)),
                            CY = maps:get(~"cy", M, maps:get(~"y", M, undefined)),
                            case {CX, CY} of
                                {X, Y} when is_number(X), is_number(Y) ->
                                    {true, {trunc(X), trunc(Y)}};
                                _ ->
                                    false
                            end;
                        (_) ->
                            false
                    end,
                    CoordsList
                ),
                asobi_terrain_store:preload_chunks(Pid, Coords),
                {[true], St};
            _ ->
                error_result(~"preload requires (coords_list)", St)
        end
    end;
fun_terrain_preload(_) ->
    fun(_, St) -> error_result(~"terrain not available (no terrain store)", St) end.

%% --- Storage helpers ---

%% Global (PlayerId = undefined) and per-player rows are distinct
%% namespaces - see asobi_storage:indexes/0's two partial unique indexes
%% (`WHERE player_id IS NULL` / `WHERE player_id IS NOT NULL`). Every
%% query and write below must carry that scope explicitly, or a global
%% write can match and overwrite an unrelated player's row (or vice
%% versa) (widgrensit/asobi#296 follow-up).

-spec storage_get(binary(), binary(), binary() | undefined) ->
    {ok, term()} | {error, term()}.
storage_get(Collection, Key, PlayerId) ->
    case storage_find(Collection, Key, PlayerId) of
        {ok, Doc} -> {ok, maps:get(value, Doc, #{})};
        {error, _} = Err -> Err
    end.

-spec storage_set(binary(), binary(), binary() | undefined, term()) ->
    {ok, term()} | {error, term()}.
storage_set(Collection, Key, PlayerId, Value) ->
    case storage_find(Collection, Key, PlayerId) of
        {ok, Doc} ->
            storage_update(Doc, Value);
        {error, not_found} ->
            storage_insert(Collection, Key, PlayerId, Value);
        {error, _} = Err ->
            Err
    end.

-spec storage_find(binary(), binary(), binary() | undefined) ->
    {ok, map()} | {error, term()}.
storage_find(Collection, Key, PlayerId) ->
    Q0 = kura_query:from(asobi_storage),
    Q1 = kura_query:where(Q0, {collection, Collection}),
    Q2 = kura_query:where(Q1, {key, Key}),
    Q3 = maybe_filter_player(Q2, PlayerId),
    case asobi_repo:all(Q3) of
        {ok, [Doc | _]} -> {ok, Doc};
        {ok, []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

storage_insert(Collection, Key, PlayerId, Value) ->
    Params = #{
        collection => Collection,
        key => Key,
        value => Value,
        updated_at => calendar:universal_time()
    },
    Params1 =
        case PlayerId of
            undefined -> Params;
            _ -> Params#{player_id => PlayerId}
        end,
    CS = kura_changeset:cast(
        asobi_storage, #{}, Params1, maps:keys(Params1)
    ),
    normalize_repo_error(asobi_repo:insert(CS)).

%% Update-by-identity: Doc is the specific row storage_find/3 already
%% scoped by player_id, so the changeset (and therefore the UPDATE ...
%% WHERE id = $1 kura compiles) can only ever touch that one row -
%% unlike the bulk update_all/2 this replaced, which had no player_id
%% scope on the emitted SQL at all.
storage_update(Doc, Value) ->
    Version = maps:get(version, Doc, 1),
    Params = #{value => Value, version => Version + 1, updated_at => calendar:universal_time()},
    CS = kura_changeset:cast(asobi_storage, Doc, Params, maps:keys(Params)),
    normalize_repo_error(asobi_repo:update(CS)).

%% Repo write failures on an invalid/rejected changeset return the raw
%% `#kura_changeset{}` record; collapse that to just its error list so
%% `to_bin/1` doesn't dump internal changeset state (schema, params,
%% types) into a Lua-visible error string.
normalize_repo_error({error, #kura_changeset{errors = Errors}}) -> {error, Errors};
normalize_repo_error(Result) -> Result.

maybe_filter_player(Q, undefined) -> kura_query:where(Q, {player_id, is_nil});
maybe_filter_player(Q, PlayerId) -> kura_query:where(Q, {player_id, PlayerId}).

%% --- Result encoding ---

-spec ok_result(term(), dynamic()) -> {[term()], dynamic()}.
ok_result(Data, St) ->
    {Enc, St1} = luerl:encode(#{~"ok" => Data}, St),
    {[Enc], St1}.

-spec error_result(term(), dynamic()) -> {[term()], dynamic()}.
error_result(Reason, St) ->
    {Enc, St1} = luerl:encode(#{~"error" => to_bin(Reason)}, St),
    {[Enc], St1}.

-spec wrap_result({ok, term()} | {error, term()}, dynamic()) -> {[term()], dynamic()}.
wrap_result({ok, Data}, St) -> ok_result(sanitize(Data), St);
wrap_result({error, Reason}, St) -> error_result(Reason, St).

%% --- Argument decoding ---

-spec decode_args([term()], dynamic()) -> [term()].
decode_args(Args, St) ->
    [deep_decode(luerl:decode(A, St)) || A <- Args].

%% Recursively turn a Luerl-decoded term into native Erlang terms.
%%
%% Luerl's `decode/2` returns Lua tables as proplists keyed by binaries
%% (string keys) or integers (sequential keys). Mixed-key tables come
%% back as a single proplist; nested tables are still proplists. This
%% function picks the right Erlang shape based on the proplist's key
%% type — string keys → map, integer keys → ordered list (re-sorted by
%% the Lua index because Luerl does not promise key order) — and
%% recurses into every value so the result is fully native.
%%
%% Defensive: `ensure_pairs/1` filters out non-`{K, V}` entries silently
%% so a malformed Lua return won't crash the caller.
%% M-5: cap recursion depth so a Lua-side table nested 100k levels deep
%% can't blow the calling gen_server's process heap. The previous
%% non-tail-recursive implementation grew the stack proportional to Lua
%% depth — a single malicious return from a callback could OOM the
%% match. 64 levels covers any realistic game state.
-define(MAX_DECODE_DEPTH, 64).

-spec deep_decode(term()) -> term().
deep_decode(V) ->
    deep_decode(V, 0).

deep_decode(_V, D) when D > ?MAX_DECODE_DEPTH ->
    %% Truncation policy: replace the over-deep subtree with an atom
    %% rather than crashing — game callers see a clear marker in the
    %% returned value.
    too_deep;
deep_decode([{K, _} | _] = PropList, D) when is_binary(K) ->
    maps:from_list([
        {Key, deep_decode(Val, D + 1)}
     || {Key, Val} <- ensure_pairs(PropList)
    ]);
deep_decode([{N, _} | _] = NumList, D) when is_integer(N) ->
    [deep_decode(Val, D + 1) || {_, Val} <- lists:sort(NumList)];
deep_decode(M, D) when is_map(M) ->
    maps:map(fun(_, V) -> deep_decode(V, D + 1) end, M);
deep_decode(L, D) when is_list(L) ->
    [deep_decode(E, D + 1) || E <- L];
deep_decode(V, _D) ->
    V.

-spec decode_to_map(term(), dynamic()) -> map().
decode_to_map(Term, LuaSt) ->
    case deep_decode(luerl:decode(Term, LuaSt)) of
        M when is_map(M) ->
            M;
        [] ->
            #{};
        L when is_list(L) ->
            ?LOG_WARNING(#{
                msg => ~"asobi_lua decode_to_map: expected map, got list — coercing to #{}",
                length => length(L)
            }),
            #{}
    end.

%% --- Leaderboard encoding ---

-spec encode_lb_entries([{binary(), number(), pos_integer()}]) -> [map()].
encode_lb_entries(Entries) ->
    [
        #{~"player_id" => Id, ~"score" => Score, ~"rank" => Rank}
     || {Id, Score, Rank} <- Entries
    ].

%% --- Sanitization ---

-spec sanitize(term()) -> term().
sanitize(M) when is_map(M) ->
    Cleaned = maps:without([id, inserted_at, updated_at, '__meta__'], M),
    maps:fold(
        fun(K, V, Acc) ->
            BinK = to_bin(K),
            Acc#{BinK => sanitize(V)}
        end,
        #{},
        Cleaned
    );
sanitize(L) when is_list(L) ->
    [sanitize(E) || E <- L];
sanitize(V) ->
    V.

%% --- Utilities ---

-spec to_map(term()) -> map().
to_map(M) when is_map(M) -> M;
to_map([{K, _} | _] = PropList) when is_binary(K) ->
    to_map_acc(PropList, #{});
to_map(_) ->
    #{}.

-spec to_map_acc(list(), map()) -> map().
to_map_acc([], Acc) ->
    Acc;
to_map_acc([{K, V} | T], Acc) when is_binary(K) ->
    to_map_acc(T, Acc#{K => V});
to_map_acc([_ | T], Acc) ->
    to_map_acc(T, Acc).

%% Coerce a Luerl-decoded value into a shape `asobi_storage`'s jsonb column
%% can round-trip. Unlike `to_map/1` (which silently drops anything that
%% isn't a map or string-keyed proplist), this preserves the JSON-compatible
%% leaf types — numbers, binaries, booleans, nil, and array-shaped tables.
%% Game scripts can therefore use plain scalars as storage values:
%%
%%   game.storage.player_set(pid, "barrow", "run_loot", 5)
%%
%% rather than having to wrap them as `{ n = 5 }` to avoid silent data loss.
%% Maps and nested tables recurse so e.g. `{ position = { x = 1, y = 2 } }`
%% round-trips intact.
-spec to_storage_value(term()) -> dynamic().
to_storage_value(V) when is_number(V); is_boolean(V); is_binary(V) -> V;
to_storage_value(nil) ->
    nil;
to_storage_value(V) when is_map(V) ->
    maps:map(fun(_K, Val) -> to_storage_value(Val) end, V);
to_storage_value([{K, _} | _] = L) when is_binary(K) ->
    %% String-keyed proplist — Luerl's representation of `{ k = v }`.
    maps:from_list([{Key, to_storage_value(Val)} || {Key, Val} <- L]);
to_storage_value([]) ->
    %% Empty Lua tables are ambiguous (could be either array or map). Round
    %% to an empty map for parity with `to_map/1`'s prior behaviour. This
    %% clause must come before the generic `is_list/1` clause below.
    #{};
to_storage_value([{K, _} | _] = L) when is_integer(K) ->
    %% Integer-keyed proplist — Luerl's representation of `{ a, b, c }`
    %% when handed an undecoded table.
    [to_storage_value(Val) || {_N, Val} <- lists:sort(L)];
to_storage_value(L) when is_list(L) ->
    %% Plain list — `deep_decode/1` already flattens an integer-keyed
    %% proplist into this shape, so callers passing a deep-decoded
    %% value land here for Lua arrays.
    [to_storage_value(V) || V <- L];
to_storage_value(_) ->
    %% Unsupported (Luerl function refs etc.) — surface as `nil` rather
    %% than silently masking with an empty map.
    nil.

-spec ensure_pairs([term()]) -> [{term(), term()}].
ensure_pairs(L) ->
    [{K, V} || {K, V} <- L].

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> list_to_binary(io_lib:format("~p", [T])).

%% --- Entity key conversion ---
%% Lua tables use binary keys ("x"), but every atom-keyed consumer downstream
%% - asobi_spatial here, and asobi_zone's own tick/crossing/grid logic once
%% asobi_lua_world hands its decoded entities back across the boundary -
%% expects atom keys (x). Exported so asobi_lua_world can atomize its
%% zone_tick/handle_input results before they re-enter the shared,
%% game-module-agnostic asobi_zone code path. See widgrensit/asobi#270.
%%
%% safe_to_atom/1 only atomizes a key if it already exists as an atom
%% (binary_to_existing_atom), so this is NOT a full normalisation: a Lua
%% script that stamps an entity with an arbitrary custom field the engine
%% has never referenced as an atom leaves that one field's key as binary.
%% The result is a legitimately mixed-key map. That's fine for asobi_zone's
%% own reads (type/x/y are always atoms already, by construction), but don't
%% read this as "entities are atom-keyed after this call" - only the fields
%% asobi's own code already knows about are guaranteed to be.
-spec atomize_entities(map()) -> map().
atomize_entities(Entities) ->
    maps:map(
        fun
            (_Id, E) when is_map(E) -> atomize_keys(E);
            (_, V) -> V
        end,
        Entities
    ).

atomize_keys(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = safe_to_atom(K),
            Acc#{Key => V}
        end,
        #{},
        M
    ).

safe_to_atom(B) when is_binary(B) ->
    try
        binary_to_existing_atom(B)
    catch
        _:_ -> B
    end;
safe_to_atom(A) when is_atom(A) -> A;
safe_to_atom(V) ->
    V.

-spec create_table([binary()], dynamic()) -> dynamic().
create_table(Path, St) ->
    {Tab, St1} = luerl:encode(#{}, St),
    {ok, St2} = luerl:set_table_keys(Path, Tab, St1),
    St2.
