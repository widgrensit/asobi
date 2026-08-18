-module(asobi_dgram_telemetry).
-moduledoc """
Telemetry for the datagram plane, owned by the gateway application.

Here rather than in `asobi_telemetry` because the gateway role is a release of
its own: it ships without nova, kura or shigoto, so it cannot reach a module in
the `asobi` application, and an event emitted from the process parsing hostile
UDP must not need one. `asobi_telemetry:events/0` folds this module's `events/0`
into the attach list, so an operator still has one list to subscribe to and every
event still has exactly one definition.

Both roles emit some of these - `link_up` is the gateway accepting the engine and
the engine reaching the gateway - which is why they live in the app both can see
rather than being defined twice.
""".

-export([events/0]).
-export([
    recv_failed/1,
    pose_saturated/1,
    link_up/0,
    link_closed/0,
    link_error/1,
    canary_missed/2,
    input_unknown/1,
    input_undecodable/1,
    input_undelivered/2,
    send_failed/1,
    dropped/2,
    bindings_expired/1
]).

-doc """
Every event this module emits, for `asobi_telemetry:setup/0` to attach to.

A literal list rather than something derived: a deletion would shrink a derived
list along with the emitter it is meant to be checking, which is the failure the
coverage test exists to catch.
""".
-spec events() -> [[atom()]].
events() ->
    [
        [asobi, dgram, bindings_expired],
        [asobi, dgram, dropped],
        [asobi, dgram, send_failed],
        [asobi, dgram, recv_failed],
        [asobi, dgram, input_undelivered],
        [asobi, dgram, input_unknown],
        [asobi, dgram, input_undecodable],
        [asobi, dgram, canary_missed],
        [asobi, dgram, pose_saturated],
        [asobi, dgram, link_up],
        [asobi, dgram, link_closed],
        [asobi, dgram, link_error]
    ].

-doc """
A receiver socket returned an error other than a timeout or a close.

The loop continues regardless: one bad read must not take a shard down, because
a shard restarting rebinds its socket and the kernel reshuffles every flow that
was landing on it.
""".
-spec recv_failed(term()) -> ok.
recv_failed(Reason) ->
    telemetry:execute([asobi, dgram, recv_failed], #{count => 1}, #{reason => Reason}).

-doc """
Transform values that did not fit their configured scale, per tick.

Saturated to the edge of the range rather than wrapped, so an entity pinned at
the boundary is what a player sees instead of one teleporting across the world.
Any sustained rate means the scale in `dgram_pose` is wrong for this game's world
size, and the fix is configuration rather than code.
""".
-spec pose_saturated(non_neg_integer()) -> ok.
pose_saturated(Count) ->
    telemetry:execute([asobi, dgram, pose_saturated], #{count => Count}, #{}).

-doc "An engine attached to the gateway's link and authenticated.".
-spec link_up() -> ok.
link_up() -> telemetry:execute([asobi, dgram, link_up], #{count => 1}, #{}).

-doc """
The engine link went away.

Not an outage on its own: bindings already in the table keep working, so players
on the plane stay on it. What stops is new mints and revocations, and an
undeliverable revocation is bounded by the mint's own expiry.
""".
-spec link_closed() -> ok.
link_closed() -> telemetry:execute([asobi, dgram, link_closed], #{count => 1}, #{}).

-doc """
Something went wrong on the engine link.

`bad_auth` is the one to alert on: the link is loopback-only, so a failed
authentication is either a misconfigured secret or something local that should
not be talking to it.
""".
-spec link_error(term()) -> ok.
link_error(Reason) ->
    telemetry:execute([asobi, dgram, link_error], #{count => 1}, #{reason => Reason}).

-doc """
The readiness canary did not get its own pong back.

`consecutive` is the field that matters: one miss is a scheduler hiccup, two in a
row means the receive loop is wedged and the node stops reporting ready. A miss
here is the only signal that distinguishes a wedged loop from a quiet port, which
look identical from outside.
""".
-spec canary_missed(term(), non_neg_integer()) -> ok.
canary_missed(Reason, Consecutive) ->
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
-spec input_unknown(non_neg_integer()) -> ok.
input_unknown(ConnId) ->
    telemetry:execute([asobi, dgram, input_unknown], #{count => 1}, #{conn_id => ConnId}).

-doc """
An authenticated input's payload did not parse.

The datagram was genuine - it passed the MAC - so this is a client-side encoding
fault rather than an attack, and it points at one player's build rather than at
the network.
""".
-spec input_undecodable(binary()) -> ok.
input_undecodable(PlayerId) ->
    telemetry:execute([asobi, dgram, input_undecodable], #{count => 1}, #{player_id => PlayerId}).

-doc """
A verified uplink input had nowhere to go.

Fires once per input while the gateway-to-engine seam is unbuilt. Any non-zero
rate here means clients are successfully using the datagram uplink and the engine
is not receiving it, which is the one failure that would otherwise look exactly
like a quiet plane.
""".
-spec input_undelivered(non_neg_integer(), non_neg_integer()) -> ok.
input_undelivered(ConnId, Bytes) ->
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
-spec send_failed(term()) -> ok.
send_failed(Reason) ->
    telemetry:execute([asobi, dgram, send_failed], #{count => 1}, #{reason => Reason}).

-doc """
A datagram was dropped, labelled by which gate rejected it.

`gate` is the interesting dimension and the reason this is one event rather than
seven. `parse` and `ingress_global` rising together is a flood; `mac` rising
alone means someone has a live `conn_id` and not the key, which is the one shape
worth waking up for. Nothing is ever sent back, so this counter is the only
evidence a rejection happened at all.
""".
-spec dropped(atom(), atom()) -> ok.
dropped(Gate, Reason) ->
    telemetry:execute([asobi, dgram, dropped], #{count => 1}, #{gate => Gate, reason => Reason}).

-doc """
Datagram bindings swept for expiry, per sweep.

A mint that is never followed by a `hello` holds a table slot until the session
dies, so the sweep is what bounds a client that opens the plane and walks away.
A rising count here means clients are minting and not connecting, which is a
client-side fault rather than an attack: minting costs an authenticated WebSocket.
""".
-spec bindings_expired(non_neg_integer()) -> ok.
bindings_expired(Count) ->
    telemetry:execute([asobi, dgram, bindings_expired], #{count => Count}, #{}).
