-module(asobi_dgram_uplink).
-moduledoc """
Where an authenticated `input` datagram goes once the gateway is done with it.

The seam between the gateway role and the engine role. The gateway has no zones
and no player sessions - that is the point of the split - so a verified input has
to cross a process boundary to reach `asobi_zone:player_input/4`, which is the
identical call the WebSocket handler makes.

Left as an explicit indirection rather than a direct call so the transport
between the two roles is a decision that can be made once, visibly, when the
engine side is built. Today it logs and drops, which is honest: nothing is
listening yet, and pretending otherwise by silently discarding would make the
first end-to-end test mysterious rather than obvious.
""".

-export([deliver/2]).

-doc "Hands a verified input payload to the engine. See the module doc.".
-spec deliver(non_neg_integer(), binary()) -> ok.
deliver(ConnId, Body) ->
    asobi_telemetry:dgram_input_undelivered(ConnId, byte_size(Body)),
    ok.
