-module(asobi_telemetry).
-include_lib("kernel/include/logger.hrl").

-export([setup/0]).
-export([match_started/2, match_finished/3, match_player_joined/2, match_player_left/2]).
-export([world_started/2, world_finished/3, world_player_joined/2, world_player_left/2]).
-export([world_phase_changed/3, world_tick/4]).
-export([zone_opened/2, zone_closed/2, zone_tick_skipped/2]).
-export([
    matchmaker_queued/2,
    matchmaker_deduped/2,
    matchmaker_removed/2,
    matchmaker_formed/3,
    matchmaker_failed/2
]).
-export([session_connected/1, session_disconnected/2]).
-export([
    ws_connected/0,
    ws_disconnected/0,
    ws_message_in/1,
    ws_message_out/1,
    ws_connect_rate_limited/1,
    dgram_bindings_expired/1,
    dgram_dropped/2,
    dgram_send_failed/1,
    dgram_recv_failed/1,
    dgram_input_undelivered/2,
    dgram_input_unknown/1,
    dgram_input_undecodable/1,
    dgram_canary_missed/2,
    dgram_link_up/0,
    dgram_link_closed/0,
    dgram_link_error/1,
    join_rate_limited/1,
    rehome_rate_limited/1,
    ws_idle_auth_timeout/0,
    ws_origin_rejected/0,
    ws_legacy_input_unwrap/0
]).
-export([anticheat_violation/3]).
-export([game_error/1, game_error/2]).

%% Categories of game-code error. A fixed literal set on purpose - never derive
%% Kind from untrusted input (atom-table exhaustion). Extend as categories arise.
-type game_error_kind() :: lua_error | unknown_spawn_template | zone_unavailable.
-export_type([game_error_kind/0]).
-export([economy_transaction/4, store_purchase/3]).
-export([chat_message_sent/2]).
-export([vote_started/2, vote_cast/2, vote_resolved/3]).
-export([auth_cache_hit/1, auth_cache_miss/1, auth_cache_sweep/0]).
-export([handle_event/4]).
-export([events/0]).

-doc """
Every event name this module emits - the surface locked by ADR 0005
(`docs/adr/0005-telemetry-event-surface.md`).

Exported so a consumer attaches to the whole surface without restating it.
Restating it is what let the built-in debug logger and `opentelemetry_asobi`
both drift to the same stale 24-name subset, leaving the failure and abuse
signals (rate limits, anticheat, `[asobi, error]`) invisible in dev (#312).
`asobi_telemetry_tests` asserts this list against the names actually passed
to `telemetry:execute/3` in this module, so the two cannot drift again.
""".
-spec events() -> [telemetry:event_name()].
events() ->
    [
        [asobi, match, started],
        [asobi, match, finished],
        [asobi, match, player_joined],
        [asobi, match, player_left],
        [asobi, world, started],
        [asobi, world, finished],
        [asobi, world, player_joined],
        [asobi, world, player_left],
        [asobi, world, phase_changed],
        [asobi, world, tick],
        [asobi, zone, opened],
        [asobi, zone, closed],
        [asobi, zone, tick_skipped],
        [asobi, matchmaker, queued],
        [asobi, matchmaker, deduped],
        [asobi, matchmaker, removed],
        [asobi, matchmaker, formed],
        [asobi, matchmaker, failed],
        [asobi, session, connected],
        [asobi, session, disconnected],
        [asobi, ws, connected],
        [asobi, ws, disconnected],
        [asobi, ws, message_in],
        [asobi, ws, message_out],
        [asobi, dgram, bindings_expired],
        [asobi, dgram, dropped],
        [asobi, dgram, send_failed],
        [asobi, dgram, recv_failed],
        [asobi, dgram, input_undelivered],
        [asobi, dgram, input_unknown],
        [asobi, dgram, input_undecodable],
        [asobi, dgram, canary_missed],
        [asobi, dgram, link_up],
        [asobi, dgram, link_closed],
        [asobi, dgram, link_error],
        [asobi, ws, connect_rate_limited],
        [asobi, ws, idle_auth_timeout],
        [asobi, ws, origin_rejected],
        [asobi, ws, legacy_input_unwrap],
        [asobi, join, rate_limited],
        [asobi, rehome, rate_limited],
        [asobi, anticheat, violation],
        [asobi, error],
        [asobi, economy, transaction],
        [asobi, store, purchase],
        [asobi, chat, message_sent],
        [asobi, vote, started],
        [asobi, vote, cast],
        [asobi, vote, resolved],
        [asobi, auth_cache, hit],
        [asobi, auth_cache, miss],
        [asobi, auth_cache, sweep]
    ].

-spec setup() -> ok.
setup() ->
    ok = telemetry:attach_many(
        <<"asobi-metrics-logger">>,
        events(),
        fun ?MODULE:handle_event/4,
        #{}
    ),
    ok.

%% --- Match Events ---

-spec match_started(binary(), binary() | undefined) -> ok.
match_started(MatchId, Mode) ->
    telemetry:execute([asobi, match, started], #{count => 1}, #{
        match_id => MatchId, mode => Mode
    }).

-spec match_finished(binary(), pos_integer(), map()) -> ok.
match_finished(MatchId, DurationMs, Result) ->
    telemetry:execute([asobi, match, finished], #{duration_ms => DurationMs, count => 1}, #{
        match_id => MatchId, result => Result
    }).

-spec match_player_joined(binary(), binary()) -> ok.
match_player_joined(MatchId, PlayerId) ->
    telemetry:execute([asobi, match, player_joined], #{count => 1}, #{
        match_id => MatchId, player_id => PlayerId
    }).

-spec match_player_left(binary(), binary()) -> ok.
match_player_left(MatchId, PlayerId) ->
    telemetry:execute([asobi, match, player_left], #{count => 1}, #{
        match_id => MatchId, player_id => PlayerId
    }).

%% --- World Events ---

-spec world_started(binary(), binary() | undefined) -> ok.
world_started(WorldId, Mode) ->
    telemetry:execute([asobi, world, started], #{count => 1}, #{
        world_id => WorldId, mode => Mode
    }).

-spec world_finished(binary(), pos_integer(), map()) -> ok.
world_finished(WorldId, DurationMs, Result) ->
    telemetry:execute([asobi, world, finished], #{duration_ms => DurationMs, count => 1}, #{
        world_id => WorldId, result => Result
    }).

-spec world_player_joined(binary(), binary()) -> ok.
world_player_joined(WorldId, PlayerId) ->
    telemetry:execute([asobi, world, player_joined], #{count => 1}, #{
        world_id => WorldId, player_id => PlayerId
    }).

-spec world_player_left(binary(), binary()) -> ok.
world_player_left(WorldId, PlayerId) ->
    telemetry:execute([asobi, world, player_left], #{count => 1}, #{
        world_id => WorldId, player_id => PlayerId
    }).

-spec world_phase_changed(binary(), binary(), binary()) -> ok.
world_phase_changed(WorldId, FromPhase, ToPhase) ->
    telemetry:execute([asobi, world, phase_changed], #{count => 1}, #{
        world_id => WorldId, from_phase => FromPhase, to_phase => ToPhase
    }).

-doc """
asobi#313: how long a world tick took, sampled.

A world tick is the fan-out to every zone plus the fan-in of their
`tick_done` replies, so this is the saturation signal that degrades first
under entity load. Emitting it at the world tick rate (20 Hz by default) is
too hot for a raw sink, so `asobi_world_ticker` samples roughly once a second
and carries `max_duration_ms` - the worst tick in the sampled window -
alongside the sampled tick's own `duration_ms`. Alert on the max; a sampled
duration alone hides exactly the spikes worth paging on.

`zone_count` is how many zones that tick fanned out to. `world_id` is
unbounded (one per live world) - never a metric label.
""".
-spec world_tick(binary() | undefined, non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    ok.
world_tick(WorldId, DurationMs, MaxDurationMs, ZoneCount) ->
    telemetry:execute(
        [asobi, world, tick],
        #{
            duration_ms => DurationMs,
            max_duration_ms => MaxDurationMs,
            zone_count => ZoneCount,
            count => 1
        },
        #{world_id => WorldId}
    ).

-doc """
asobi#313: a zone process started. Zones are lazy, so live-zone count is not
derivable from world count; pair this with `zone_closed/2` and track the
difference as a gauge. Both metadata keys are unbounded - never a label.
""".
-spec zone_opened(binary() | undefined, {integer(), integer()}) -> ok.
zone_opened(WorldId, Coords) ->
    telemetry:execute([asobi, zone, opened], #{count => 1}, #{
        world_id => WorldId, coords => Coords
    }).

-doc "asobi#313: a zone process went away (reaped, crashed, or world shutdown). See `zone_opened/2`.".
-spec zone_closed(binary() | undefined, {integer(), integer()}) -> ok.
zone_closed(WorldId, Coords) ->
    telemetry:execute([asobi, zone, closed], #{count => 1}, #{
        world_id => WorldId, coords => Coords
    }).

-doc """
asobi#426: `count` zones were skipped by this world tick because they had not
yet retired the previous one.

This is the back-pressure signal. A steady trickle is a world running close to
its tick budget; a count that climbs toward the world's zone count and stays
there is a world that can no longer keep up, and before #426 the only symptom
of that was CPU. Unlike `world_tick/4` this is **not** sampled - it is emitted
only on a tick that actually skipped, so a healthy world emits nothing at all.
""".
-spec zone_tick_skipped(binary() | undefined, pos_integer()) -> ok.
zone_tick_skipped(WorldId, Count) ->
    telemetry:execute([asobi, zone, tick_skipped], #{count => Count}, #{world_id => WorldId}).

%% --- Matchmaker Events ---

-spec matchmaker_queued(binary(), binary() | undefined) -> ok.
matchmaker_queued(PlayerId, Mode) ->
    telemetry:execute([asobi, matchmaker, queued], #{count => 1}, #{
        player_id => PlayerId, mode => Mode
    }).

%% An `add' that returned the caller's existing ticket instead of minting one,
%% per the (player, mode) self-match guard (asobi#230). That branch emitted
%% nothing before, so a queue that never paired looked identical to an idle one.
%% A hint rather than a diagnosis - a double-tapped "find match" dedupes exactly
%% like two clients sharing an identity.
-spec matchmaker_deduped(binary(), binary()) -> ok.
matchmaker_deduped(PlayerId, Mode) ->
    telemetry:execute([asobi, matchmaker, deduped], #{count => 1}, #{
        player_id => PlayerId, mode => Mode
    }).

-spec matchmaker_removed(binary(), atom()) -> ok.
matchmaker_removed(PlayerId, Reason) ->
    telemetry:execute([asobi, matchmaker, removed], #{count => 1}, #{
        player_id => PlayerId, reason => Reason
    }).

-spec matchmaker_formed(binary(), pos_integer(), pos_integer()) -> ok.
matchmaker_formed(Mode, PlayerCount, WaitMs) ->
    telemetry:execute(
        [asobi, matchmaker, formed],
        #{
            player_count => PlayerCount, wait_ms => WaitMs, count => 1
        },
        #{mode => Mode}
    ).

-spec matchmaker_failed(binary(), non_neg_integer()) -> ok.
matchmaker_failed(Mode, PlayerCount) ->
    telemetry:execute(
        [asobi, matchmaker, failed],
        #{player_count => PlayerCount, count => 1},
        #{mode => Mode}
    ).

%% --- Session Events ---

-spec session_connected(binary()) -> ok.
session_connected(PlayerId) ->
    telemetry:execute([asobi, session, connected], #{count => 1}, #{
        player_id => PlayerId
    }).

-spec session_disconnected(binary(), pos_integer()) -> ok.
session_disconnected(PlayerId, DurationMs) ->
    telemetry:execute(
        [asobi, session, disconnected],
        #{
            duration_ms => DurationMs, count => 1
        },
        #{player_id => PlayerId}
    ).

%% --- WebSocket Events ---

-spec ws_connected() -> ok.
ws_connected() ->
    telemetry:execute([asobi, ws, connected], #{count => 1}, #{}).

-spec ws_disconnected() -> ok.
ws_disconnected() ->
    telemetry:execute([asobi, ws, disconnected], #{count => 1}, #{}).

-doc "asobi#193: a player hit the per-identity join rate cap.".
-spec join_rate_limited(binary()) -> ok.
join_rate_limited(PlayerId) ->
    telemetry:execute(
        [asobi, join, rate_limited], #{count => 1}, #{player_id => PlayerId}
    ).

-doc """
A receiver socket returned an error other than a timeout or a close.

The loop continues regardless: one bad read must not take a shard down, because
a shard restarting rebinds its socket and the kernel reshuffles every flow that
was landing on it.
""".
-spec dgram_recv_failed(term()) -> ok.
dgram_recv_failed(Reason) ->
    telemetry:execute([asobi, dgram, recv_failed], #{count => 1}, #{reason => Reason}).

-doc "An engine attached to the gateway's link and authenticated.".
-spec dgram_link_up() -> ok.
dgram_link_up() -> telemetry:execute([asobi, dgram, link_up], #{count => 1}, #{}).

-doc """
The engine link went away.

Not an outage on its own: bindings already in the table keep working, so players
on the plane stay on it. What stops is new mints and revocations, and an
undeliverable revocation is bounded by the mint's own expiry.
""".
-spec dgram_link_closed() -> ok.
dgram_link_closed() -> telemetry:execute([asobi, dgram, link_closed], #{count => 1}, #{}).

-doc """
Something went wrong on the engine link.

`bad_auth` is the one to alert on: the link is loopback-only, so a failed
authentication is either a misconfigured secret or something local that should
not be talking to it.
""".
-spec dgram_link_error(term()) -> ok.
dgram_link_error(Reason) ->
    telemetry:execute([asobi, dgram, link_error], #{count => 1}, #{reason => Reason}).

-doc """
The readiness canary did not get its own pong back.

`consecutive` is the field that matters: one miss is a scheduler hiccup, two in a
row means the receive loop is wedged and the node stops reporting ready. A miss
here is the only signal that distinguishes a wedged loop from a quiet port, which
look identical from outside.
""".
-spec dgram_canary_missed(term(), non_neg_integer()) -> ok.
dgram_canary_missed(Reason, Consecutive) ->
    telemetry:execute(
        [asobi, dgram, canary_missed],
        #{count => 1, consecutive => Consecutive},
        #{reason => Reason}
    ).

-doc """
The gateway delivered an input for a `conn_id` the engine has no mint for.

Expected in small numbers around a session ending - the two ends revoke
asynchronously - and worth investigating if sustained, because it means the
gateway believes in a binding the engine has forgotten.
""".
-spec dgram_input_unknown(non_neg_integer()) -> ok.
dgram_input_unknown(ConnId) ->
    telemetry:execute([asobi, dgram, input_unknown], #{count => 1}, #{conn_id => ConnId}).

-doc """
An authenticated input's payload did not parse.

The datagram was genuine - it passed the MAC - so this is a client-side encoding
fault rather than an attack, and it points at one player's build rather than at
the network.
""".
-spec dgram_input_undecodable(binary()) -> ok.
dgram_input_undecodable(PlayerId) ->
    telemetry:execute([asobi, dgram, input_undecodable], #{count => 1}, #{player_id => PlayerId}).

-doc """
A verified uplink input had nowhere to go.

Fires once per input while the gateway-to-engine seam is unbuilt. Any non-zero
rate here means clients are successfully using the datagram uplink and the engine
is not receiving it, which is the one failure that would otherwise look exactly
like a quiet plane.
""".
-spec dgram_input_undelivered(non_neg_integer(), non_neg_integer()) -> ok.
dgram_input_undelivered(ConnId, Bytes) ->
    telemetry:execute(
        [asobi, dgram, input_undelivered],
        #{count => 1, bytes => Bytes},
        #{conn_id => ConnId}
    ).

-doc """
A downlink datagram could not be handed to the kernel.

Almost always local buffer pressure rather than anything about the network: a
connectionless socket has no delivery to fail. Nothing is retried, because the
next pose supersedes this one. Worth an alert only if it is sustained, which
means the gateway is producing faster than the host can send.
""".
-spec dgram_send_failed(term()) -> ok.
dgram_send_failed(Reason) ->
    telemetry:execute([asobi, dgram, send_failed], #{count => 1}, #{reason => Reason}).

-doc """
A datagram was dropped, labelled by which gate rejected it.

`gate` is the interesting dimension and the reason this is one event rather than
seven. `parse` and `ingress_global` rising together is a flood; `mac` rising
alone means someone has a live `conn_id` and not the key, which is the one shape
worth waking up for. Nothing is ever sent back, so this counter is the only
evidence a rejection happened at all.
""".
-spec dgram_dropped(atom(), atom()) -> ok.
dgram_dropped(Gate, Reason) ->
    telemetry:execute([asobi, dgram, dropped], #{count => 1}, #{gate => Gate, reason => Reason}).

-doc """
Datagram bindings swept for expiry, per sweep.

A mint that is never followed by a `hello` holds a table slot until the session
dies, so the sweep is what bounds a client that opens the plane and walks away.
A rising count here means clients are minting and not connecting, which is a
client-side fault rather than an attack: minting costs an authenticated WebSocket.
""".
-spec dgram_bindings_expired(non_neg_integer()) -> ok.
dgram_bindings_expired(Count) ->
    telemetry:execute([asobi, dgram, bindings_expired], #{count => Count}, #{}).

-spec ws_connect_rate_limited(binary()) -> ok.
ws_connect_rate_limited(PeerIp) ->
    telemetry:execute(
        [asobi, ws, connect_rate_limited], #{count => 1}, #{peer_ip => PeerIp}
    ).

-doc """
asobi#248: a player hit the per-identity or global zone-crossing rate cap.
Fires per denied crossing - the denied entity is clamped back inside its
current zone (private, see asobi_zone's clamp_to_zone/3), but under
sustained input the crossing is still re-detected (and re-denied) every
tick, so a client thrashing a boundary can drive this at up to the world
tick rate. Aggregate this; do not use `player_id` as a metric label.
""".
-spec rehome_rate_limited(binary()) -> ok.
rehome_rate_limited(PlayerId) ->
    telemetry:execute(
        [asobi, rehome, rate_limited], #{count => 1}, #{player_id => PlayerId}
    ).

-spec ws_idle_auth_timeout() -> ok.
ws_idle_auth_timeout() ->
    telemetry:execute([asobi, ws, idle_auth_timeout], #{count => 1}, #{}).

-doc "#160: a WS upgrade was rejected by the Origin allowlist.".
-spec ws_origin_rejected() -> ok.
ws_origin_rejected() ->
    telemetry:execute([asobi, ws, origin_rejected], #{count => 1}, #{}).

%% asobi#478: a client sent input wrapped as a sole `data` key, the deprecated
%% compat shape. Counted so the carve-out's removal can be scheduled against real
%% traffic instead of guesswork.
-spec ws_legacy_input_unwrap() -> ok.
ws_legacy_input_unwrap() ->
    telemetry:execute([asobi, ws, legacy_input_unwrap], #{count => 1}, #{}).

-spec anticheat_violation(binary(), atom(), map()) -> ok.
anticheat_violation(PlayerId, Type, Details) ->
    telemetry:execute(
        [asobi, anticheat, violation],
        #{count => 1},
        #{player_id => PlayerId, type => Type, details => Details}
    ).

-doc """
Emit `[asobi, error]` for a game-code error - the game author's logic failing,
e.g. a Lua callback raising. `count => 1`, metadata `#{kind, details}`.

`details` is passed verbatim to every attached handler (which may log or export
it), so emitters MUST keep it bounded and free of sensitive data: no raw player
input, secrets, PII, or file-system paths, and no unbounded values (truncate a
message, classify the reason - never pass a raw luerl/error term, which can
embed interpolated player input). Consumers should aggregate on `kind` only, not
on `details` (this event can fire at high frequency).
""".
-spec game_error(game_error_kind(), map()) -> ok.
game_error(Kind, Details) ->
    telemetry:execute([asobi, error], #{count => 1}, #{kind => Kind, details => Details}).

-doc "Emit `[asobi, error]` with no extra context. See `game_error/2`.".
-spec game_error(game_error_kind()) -> ok.
game_error(Kind) ->
    game_error(Kind, #{}).

-spec ws_message_in(binary()) -> ok.
ws_message_in(Type) ->
    telemetry:execute([asobi, ws, message_in], #{count => 1}, #{type => Type}).

-spec ws_message_out(binary()) -> ok.
ws_message_out(Type) ->
    telemetry:execute([asobi, ws, message_out], #{count => 1}, #{type => Type}).

%% --- Economy Events ---

-spec economy_transaction(binary(), binary(), integer(), binary()) -> ok.
economy_transaction(PlayerId, Currency, Amount, Reason) ->
    telemetry:execute([asobi, economy, transaction], #{amount => Amount, count => 1}, #{
        player_id => PlayerId, currency => Currency, reason => Reason
    }).

-spec store_purchase(binary(), binary(), integer()) -> ok.
store_purchase(PlayerId, ItemId, Cost) ->
    telemetry:execute([asobi, store, purchase], #{cost => Cost, count => 1}, #{
        player_id => PlayerId, item_id => ItemId
    }).

%% --- Chat Events ---

-spec chat_message_sent(binary(), binary()) -> ok.
chat_message_sent(ChannelId, SenderId) ->
    telemetry:execute([asobi, chat, message_sent], #{count => 1}, #{
        channel_id => ChannelId, sender_id => SenderId
    }).

%% --- Vote Events ---

-spec vote_started(binary(), binary()) -> ok.
vote_started(VoteId, Method) ->
    telemetry:execute([asobi, vote, started], #{count => 1}, #{
        vote_id => VoteId, method => Method
    }).

-spec vote_cast(binary(), binary()) -> ok.
vote_cast(VoteId, PlayerId) ->
    telemetry:execute([asobi, vote, cast], #{count => 1}, #{
        vote_id => VoteId, player_id => PlayerId
    }).

-spec vote_resolved(binary(), pos_integer(), map()) -> ok.
vote_resolved(VoteId, DurationMs, Result) ->
    telemetry:execute([asobi, vote, resolved], #{duration_ms => DurationMs, count => 1}, #{
        vote_id => VoteId, result => Result
    }).

%% --- Auth Cache Events ---

-spec auth_cache_hit(positive | negative) -> ok.
auth_cache_hit(Kind) ->
    telemetry:execute([asobi, auth_cache, hit], #{count => 1}, #{kind => Kind}).

-spec auth_cache_miss(positive | negative) -> ok.
auth_cache_miss(Kind) ->
    telemetry:execute([asobi, auth_cache, miss], #{count => 1}, #{kind => Kind}).

-spec auth_cache_sweep() -> ok.
auth_cache_sweep() ->
    telemetry:execute([asobi, auth_cache, sweep], #{count => 1}, #{}).

%% --- Internal ---

-spec handle_event(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> ok.
handle_event(EventName, Measurements, Metadata, _Config) ->
    %% Macro, not logger:debug/1: the macro's logger:allow/2 guard skips building
    %% this report entirely when debug is off. This runs synchronously inside the
    %% emitting process, which for the matchmaker events is its message loop.
    ?LOG_DEBUG(#{
        msg => ~"telemetry_event",
        event => EventName,
        measurements => Measurements,
        metadata => Metadata
    }).
