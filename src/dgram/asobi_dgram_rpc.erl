-module(asobi_dgram_rpc).
-moduledoc """
`asobi.datagram.open` and `asobi.datagram.close`, the player-facing mint.

Built-in `rpc.call` methods rather than new frame types, because `rpc.call`,
`rpc.ok` and `rpc.error` are already frozen and already implemented in every SDK.
The whole datagram plane therefore adds **zero** frames to the JSON wire
(ADR 0012, decision 5), which is what makes an SDK's datagram support additive
rather than a protocol version.

## What comes back

    conn_id     the demux key, cleartext in every datagram and NOT a secret
    kup         base64 of the 32-byte uplink key. Travels once, inside TLS.
    epoch       changes on an engine restart, so a stale credential is refused
    endpoint    where to send, so the plane needs no DNS and no SNI
    expires_in  seconds before the mint lapses if the plane is never opened

## Failure is degradation, not an error

`{error, datagram_unavailable}` means the gateway is unreachable or the plane is
not configured. That is a normal answer: the WebSocket carries everything in
every state, so a client that cannot mint stays on TCP and loses nothing but
latency. An SDK must treat it as "no datagram plane today" and never as a failed
session.
""".

-export([open/2, close/2]).

-doc "Mints a credential for the calling session.".
-spec open(map(), map()) -> {ok, map()} | {error, binary()}.
open(_Params, #{player_id := PlayerId, session := SessionPid}) ->
    case asobi_dgram_link_client:enabled() of
        false ->
            {error, ~"datagram_unavailable"};
        true ->
            case asobi_dgram_mint:open(PlayerId, SessionPid) of
                {ok, Credential} ->
                    {ok, Credential};
                {error, _Reason} ->
                    %% The reason is deliberately not returned. A client can do
                    %% nothing differently for "no gateway" than for "gateway
                    %% timed out", and the distinction is an operator's.
                    {error, ~"datagram_unavailable"}
            end
    end.

-doc """
Revokes this session's credential.

Optional for a client - a session ending revokes anyway - and worth having
because a client that closes the plane deliberately (a player toggling it off,
say) should not wait out the mint's expiry to free the binding.
""".
-spec close(map(), map()) -> {ok, map()} | {error, binary()}.
close(Params, _Caller) ->
    case Params of
        #{~"conn_id" := ConnId} when is_integer(ConnId), ConnId >= 0 ->
            %% Not scoped to the caller, and it does not need to be: revoking a
            %% conn_id you do not hold is not an attack, because the credential
            %% is unguessable and the only effect is that its owner re-mints.
            %% Scoping it would mean a lookup that tells a caller whether a given
            %% conn_id exists, which is strictly worse.
            asobi_dgram_mint:close(ConnId),
            {ok, #{closed => true}};
        _ ->
            {error, ~"rpc.invalid_params"}
    end.
