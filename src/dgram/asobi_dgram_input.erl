-module(asobi_dgram_input).
-moduledoc """
Applies a verified datagram input, engine side.

The last step of the uplink, and the point of the whole plane's other half: a
`world.input` that travelled over UDP has to land on the **identical**
`asobi_zone:player_input/4` call the WebSocket handler makes. Two paths into the
simulation that could diverge is how a game ends up with rules that depend on the
carrier.

## The gateway is not trusted to name a player

It hands over a `conn_id` and opaque bytes. The player is resolved here, from the
mint record the engine itself created, so a compromised gateway can at most
submit input as a player whose `conn_id` it already holds - which is exactly what
that player could do with their own key. It cannot address anyone else.

The mint registry is deliberately not the binding table: that lives in the
gateway, and the engine keeping its own record is what lets this resolution
happen without asking the untrusted end anything.
""".

-include("asobi_ack.hrl").

-export([apply/2]).

-doc "Resolves the player and applies the input. Silent on an unknown conn_id.".
-spec apply(non_neg_integer(), binary()) -> ok.
apply(ConnId, Body) ->
    case asobi_dgram_mint:player_of(ConnId) of
        error ->
            %% A conn_id the engine never minted, or one whose session has since
            %% died. Counted, because the gateway believing in a binding the
            %% engine has forgotten is worth seeing.
            asobi_dgram_telemetry:input_unknown(ConnId);
        {ok, #{player_id := PlayerId, session_pid := SessionPid}} ->
            deliver(PlayerId, SessionPid, Body)
    end.

%% --- Internal ---

%% The zone comes from the SESSION, exactly as asobi_ws_handler does it, so the
%% datagram path inherits the same zone resolution and the same lifecycle rather
%% than being a second implementation of something already written once.
deliver(PlayerId, SessionPid, Body) ->
    case decode_input(Body) of
        error ->
            asobi_dgram_telemetry:input_undecodable(PlayerId);
        {ok, Input, Seq} ->
            try asobi_player_session:get_state(SessionPid) of
                SState ->
                    case maps:get(zone_pid, SState, undefined) of
                        undefined ->
                            %% In no zone yet. Dropping is correct: the same
                            %% input over the WebSocket would be dropped too.
                            ok;
                        ZonePid ->
                            asobi_zone:player_input(ZonePid, PlayerId, Input, Seq)
                    end
            catch
                %% The session died between the mint lookup and here. The next
                %% datagram will miss the mint registry instead.
                exit:{noproc, _} -> ok
            end
    end.

%% The payload is the frozen `world.input` body, so it is JSON on this carrier
%% too. That looks odd next to a binary downlink and it is deliberate: an input
%% is one small frame per player per tick, the saving would be tens of bytes, and
%% a second encoding of an already-frozen frame is a second thing to keep in step
%% across seven SDKs for no measured gain.
decode_input(Body) ->
    try json:decode(Body) of
        #{~"input" := Input} = Payload when is_map(Input) ->
            {ok, Input, seq_of(Payload)};
        Input when is_map(Input) ->
            {ok, Input, seq_of(Input)};
        _ ->
            error
    catch
        _:_ -> error
    end.

seq_of(#{~"seq" := Seq}) when is_integer(Seq), Seq >= 0, Seq =< ?MAX_ACK_SEQ -> Seq;
seq_of(_) -> undefined.
