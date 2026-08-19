-module(asobi_dgram_link).
-moduledoc """
The wire between the engine and the gateway, and its framing.

Pure: `encode/1` and `decode/1` over a length-prefixed frame, plus the
authentication both ends do on connect. The processes that carry it live in
`asobi_dgram_link_client` (engine side) and `asobi_dgram_link_server` (gateway
side); everything worth arguing about is here and testable without a socket.

## Why this is not distributed Erlang

Two BEAM nodes on one box is exactly what dist is for, and it is the wrong answer
here. Dist is all-or-nothing: a node that can reach another can call any function
in it. Handing that to the process that parses packets from the internet gives
back most of what the two-role split was for - the engine's Lua sandbox and its
database credentials would be one `rpc:call` away from whatever compromises the
gateway.

The realistic risk is a crash or a resource exhaustion rather than remote code
execution, because the parser is Erlang binary matching and BEAM does not hand
out arbitrary execution from a malformed binary. So this is defence in depth
rather than a response to a known hole. It costs three message types and a length
prefix, which is cheap enough that the argument for dist is convenience alone.

## Four messages, and no more

    engine -> gateway   register    a minted binding
    engine -> gateway   unregister  a revocation, on session death
    engine -> gateway   pose        one shared body plus who it goes to
    gateway -> engine   input       a verified uplink payload

`pose` travels over TCP, which looks like it defeats the point until you notice
which hop it is: engine to gateway on loopback, where there is no loss to
head-of-line-block on. The hop that matters is gateway to client, and that one is
a datagram. The engine hands over **one** shared body and a list of `conn_id`s,
so the O(N) fan-out happens where the socket is and the body is encoded once
(ADR 0012, decision 14).

Nothing else crosses. The gateway cannot ask the engine for anything, cannot name
a module or a function, and cannot address a process. `input` carries a `conn_id`
and opaque bytes, and the engine resolves the player itself - so a compromised
gateway can at most submit input as a player whose `conn_id` it already holds,
which is the same thing that player could do with their own key.

## The engine connects out

The gateway listens, the engine dials. That way the gateway needs no knowledge of
where the engine is, and a self-hoster's compose file has one address in it. The
engine authenticates with a shared secret from config; the gateway never
authenticates to the engine, because it never asks for anything.
""".

-export([encode/1, decode/1, auth_tag/2, max_frame/0]).
-export_type([message/0]).

%% Bounded well below anything that could arrive: a register is a fixed handful
%% of fields and an input is a game's own move payload. A larger frame is a bug
%% or an attempt, and either way it is refused before allocation.
-define(MAX_FRAME, 65_535).

-type message() ::
    {register, #{
        conn_id := non_neg_integer(),
        kup := binary(),
        player_id := binary(),
        epoch := 0..65535,
        expires_at := integer()
    }}
    | {unregister, non_neg_integer()}
    | {input, non_neg_integer(), binary()}
    | {pose, binary(), [non_neg_integer()]}.

-doc """
Frames one message: `Len:32, Payload`.

`term_to_binary/1` is deliberately NOT used. Both ends are ours, so it would
work, and it would also mean a decoder calling `binary_to_term/1` on bytes from a
socket - which is the single most exploitable thing an Erlang program can do, and
would be exploitable from the gateway inward exactly when the gateway is the
process most likely to be compromised.
""".
-spec encode(message()) -> binary().
encode(
    {register, #{
        conn_id := ConnId,
        kup := KUp,
        player_id := PlayerId,
        epoch := Epoch,
        expires_at := ExpiresAt
    }}
) ->
    frame(
        <<1:8, ConnId:32/little, (byte_size(KUp)):8, KUp/binary, (byte_size(PlayerId)):16/little,
            PlayerId/binary, Epoch:16/little, ExpiresAt:64/signed-little>>
    );
encode({unregister, ConnId}) ->
    frame(<<2:8, ConnId:32/little>>);
encode({input, ConnId, Body}) ->
    frame(<<3:8, ConnId:32/little, Body/binary>>);
encode({pose, SharedBody, ConnIds}) ->
    Ids = <<<<C:32/little>> || C <- ConnIds>>,
    frame(<<4:8, (length(ConnIds)):16/little, Ids/binary, SharedBody/binary>>).

-doc """
Decodes one complete frame's payload, without its length prefix.

Total: anything it does not recognise is `{error, malformed}` rather than a
raise. The gateway is the untrusted end of this link, so the engine's decoder is
a trust boundary even though both ends are ours.
""".
-spec decode(binary()) -> {ok, message()} | {error, atom()}.
decode(
    <<1:8, ConnId:32/little, KLen:8, KUp:KLen/binary, PLen:16/little, PlayerId:PLen/binary,
        Epoch:16/little, ExpiresAt:64/signed-little>>
) ->
    {ok,
        {register, #{
            conn_id => ConnId,
            kup => KUp,
            player_id => PlayerId,
            epoch => Epoch,
            expires_at => ExpiresAt
        }}};
decode(<<2:8, ConnId:32/little>>) ->
    {ok, {unregister, ConnId}};
decode(<<3:8, ConnId:32/little, Body/binary>>) ->
    {ok, {input, ConnId, Body}};
decode(<<4:8, Count:16/little, Rest/binary>>) ->
    IdBytes = Count * 4,
    case Rest of
        <<Ids:IdBytes/binary, SharedBody/binary>> ->
            {ok, {pose, SharedBody, [C || <<C:32/little>> <= Ids]}};
        _ ->
            {error, malformed}
    end;
decode(_) ->
    {error, malformed}.

-doc """
The tag the engine presents on connect, and the gateway checks.

A nonce the gateway chose, signed with the shared secret. A bare secret comparison
would be replayable by anyone who saw one connect; this is not, and it costs one
round trip on a link that opens once.
""".
-spec auth_tag(binary(), binary()) -> binary().
auth_tag(Nonce, Secret) ->
    <<Tag:32/binary>> = crypto:mac(hmac, sha256, Secret, Nonce),
    Tag.

-doc "The largest frame either end will read.".
-spec max_frame() -> pos_integer().
max_frame() -> ?MAX_FRAME.

%% --- Internal ---

frame(Payload) -> <<(byte_size(Payload)):32/little, Payload/binary>>.
