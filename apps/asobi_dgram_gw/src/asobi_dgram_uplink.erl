-module(asobi_dgram_uplink).
-moduledoc """
Where an authenticated `input` datagram goes once the gateway is done with it.

The seam between the gateway role and the engine role. The gateway has no zones
and no player sessions - that is the point of the split - so a verified input has
to cross a process boundary to reach `asobi_zone:player_input/4`, which is the
identical call the WebSocket handler makes.

It travels the same link the engine used to register the binding, in the one
direction the protocol allows the gateway to speak (`asobi_dgram_link`). The
gateway names a `conn_id` and hands over opaque bytes; the engine resolves the
player itself. So a compromised gateway can at most submit input as a player
whose `conn_id` it already holds, which is exactly what that player could do with
their own key.

With no engine attached the input is counted and dropped. Counted rather than
silently discarded, because a plane that works perfectly and delivers nothing
looks identical to a quiet plane from the outside.
""".

-export([deliver/2]).

-doc "Hands a verified input payload to the engine. See the module doc.".
-spec deliver(non_neg_integer(), binary()) -> ok.
deliver(ConnId, Body) ->
    case asobi_dgram_link_server:send({input, ConnId, Body}) of
        ok -> ok;
        {error, _Reason} -> asobi_dgram_telemetry:input_undelivered(ConnId, byte_size(Body))
    end.
