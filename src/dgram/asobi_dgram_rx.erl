-module(asobi_dgram_rx).
-moduledoc """
The receive pipeline: what happens to one datagram, in order.

Separated from the socket process on purpose. Everything here is a pure function
of the bytes plus a small set of injected dependencies, so the ordering that the
whole defence rests on can be tested by calling a function rather than by
arranging a flood against a real port.

## The order, and why each step is where it is

    1. parse guard      magic, version, opcode, reserved flags, length
    2. ingress_global   a constant, the only key an attacker cannot rotate
    3. conn_id lookup    misses are bounded by their own tier
    4. ingress          this connection's pre-MAC budget
    5. MAC verify       the only expensive step
    6. cseq             strictly advancing, before any binding transition
    7. dispatch

Steps 1-4 are arithmetic and two map lookups. Step 5 is HMAC-SHA256. Putting the
MAC anywhere earlier hands an unauthenticated flood a crypto budget, which is the
attack this ordering exists to make impossible rather than merely unlikely.

Step 6 before step 7 is equally load-bearing: `cseq` is the only thing stopping a
captured `hello_confirm` being replayed from another handle, so it must be
checked before the rebind path is entered, not inside it.

## Every rejection is a silent drop

No error datagram of any kind leaves this gateway (ADR 0012, decision 10). A
rejection increments a counter and returns `drop`. An error reply would be an
amplifier and would also tell a prober exactly which of the seven gates it hit.
""".

-export([handle/3]).
-export_type([outcome/0]).

%% What the socket process should do with the result. `drop` is silent by
%% construction: there is no reason field on it, because nothing is ever sent
%% back to explain a rejection.
-type outcome() ::
    drop
    | {reply, binary()}
    | {input, non_neg_integer(), binary()}
    | {teardown, non_neg_integer()}.

-doc """
Runs one datagram through the pipeline.

`Deps` injects the table and the challenge source so this stays testable without
a running gateway; the socket process passes the real ones.
""".
-spec handle(binary(), asobi_dgram_binding:handle(), #{
    kup_of := fun((non_neg_integer()) -> {ok, binary()} | error),
    hello := fun(
        (non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()) ->
            {ok, binary()} | {error, atom()}
    ),
    confirm := fun(
        (non_neg_integer(), non_neg_integer(), asobi_dgram_binding:handle(), binary()) ->
            ok | {error, atom()}
    ),
    note_uplink := fun((non_neg_integer(), non_neg_integer()) -> ok | {error, atom()}),
    challenge := fun(() -> binary())
}) -> outcome().
handle(Bin, Handle, Deps) ->
    %% 1. The parse guard. Pure arithmetic, and the only step that runs on
    %% every byte that reaches the port.
    case asobi_dgram:peek(Bin) of
        {error, Reason} ->
            reject(parse, Reason);
        {ok, #{opcode := Opcode, conn_id := ConnId}} ->
            case is_uplink(Opcode) of
                false ->
                    %% A downlink opcode arriving on the uplink is either a
                    %% confused client or a reflection attempt. Neither is worth
                    %% a table lookup.
                    reject(parse, downlink_opcode);
                true ->
                    guarded(Bin, Handle, Opcode, ConnId, Deps)
            end
    end.

%% --- Internal ---

guarded(Bin, Handle, Opcode, ConnId, Deps) ->
    %% 2. The volumetric budget, keyed on a constant.
    case seki:check(asobi_dgram_ingress_global_limiter, ~"global") of
        {deny, _} ->
            reject(ingress_global, flooded);
        {allow, _} ->
            %% 3. The conn_id lookup. A miss is charged to its own tier, which
            %% bounds log and telemetry volume rather than CPU - the datagram is
            %% already going to be dropped either way.
            #{kup_of := KUpOf} = Deps,
            case KUpOf(ConnId) of
                error ->
                    case asobi_dgram_limits:allow_unknown() of
                        true -> reject(unknown_conn, no_such_conn);
                        false -> drop
                    end;
                {ok, KUp} ->
                    %% 4. This connection's own pre-MAC budget.
                    case asobi_dgram_limits:allow_ingress(ConnId) of
                        false -> reject(ingress, throttled);
                        true -> authenticated(Bin, Handle, Opcode, ConnId, KUp, Deps)
                    end
            end
    end.

authenticated(Bin, Handle, Opcode, ConnId, KUp, Deps) ->
    %% 5. The MAC. Everything above exists so that reaching this line costs an
    %% attacker a live conn_id they cannot guess and a budget they cannot rotate.
    case asobi_dgram:verify(Bin, KUp) of
        {error, _} ->
            reject(mac, bad_mac);
        ok ->
            case asobi_dgram:decode_uplink(Bin) of
                {error, Reason} ->
                    reject(parse, Reason);
                {ok, #{cseq := CSeq, body := Body}} ->
                    %% 6 and 7. cseq is checked inside each transition, ahead of
                    %% the transition itself - see asobi_dgram_binding.
                    dispatch(Opcode, ConnId, CSeq, Handle, Body, Deps)
            end
    end.

dispatch(hello, ConnId, CSeq, Handle, _Body, #{hello := Hello}) ->
    case Hello(ConnId, CSeq, Handle, crypto:strong_rand_bytes(8)) of
        {ok, Challenge} ->
            {reply,
                asobi_dgram:encode_downlink(#{
                    opcode => hello_ok,
                    conn_id => ConnId,
                    %% The challenge goes to the CANDIDATE handle and nothing
                    %% else follows until the echo returns. path_tag is zero
                    %% here because the client has not been given one yet.
                    path_tag => 0,
                    body => Challenge
                })};
        {error, rebind_limit} ->
            %% Past the budget. Tearing down beats minting again: a client whose
            %% path genuinely flaps is served by the WebSocket throughout.
            {teardown, ConnId};
        {error, Reason} ->
            reject(binding, Reason)
    end;
dispatch(hello_confirm, ConnId, CSeq, Handle, Body, #{confirm := Confirm}) ->
    Echo = binary:part(Body, 0, min(8, byte_size(Body))),
    case Confirm(ConnId, CSeq, Handle, Echo) of
        ok ->
            %% No reply at all. The binding is the effect, and a confirmation of
            %% the confirmation would be a reply with nothing to say.
            drop;
        {error, Reason} ->
            reject(binding, Reason)
    end;
dispatch(ping, ConnId, CSeq, _Handle, Body, #{note_uplink := Note}) ->
    case Note(ConnId, CSeq) of
        {error, Reason} ->
            reject(binding, Reason);
        ok ->
            Client = binary:part(Body, 0, min(8, byte_size(Body))),
            {reply,
                asobi_dgram:encode_downlink(#{
                    opcode => pong,
                    conn_id => ConnId,
                    path_tag => 0,
                    %% The client's own stamp echoed plus ours, so a client can
                    %% measure the round trip without keeping state per ping.
                    body => <<Client/binary, (erlang:system_time(millisecond)):64/little>>
                })}
    end;
dispatch(bye, ConnId, CSeq, _Handle, _Body, #{note_uplink := Note}) ->
    case Note(ConnId, CSeq) of
        ok -> {teardown, ConnId};
        {error, Reason} -> reject(binding, Reason)
    end;
dispatch(input, ConnId, CSeq, _Handle, Body, #{note_uplink := Note}) ->
    case Note(ConnId, CSeq) of
        {error, Reason} ->
            reject(binding, Reason);
        ok ->
            %% 8. The post-MAC input budget, last because it is the only tier
            %% that bounds an authenticated client rather than an attacker.
            case asobi_dgram_limits:allow_input(ConnId) of
                true -> {input, ConnId, Body};
                false -> reject(input, throttled)
            end
    end.

%% Counted, never answered. An error datagram would be an amplifier and would
%% also tell a prober which of the gates it hit.
reject(Gate, Reason) ->
    asobi_telemetry:dgram_dropped(Gate, Reason),
    drop.

is_uplink(hello) -> true;
is_uplink(hello_confirm) -> true;
is_uplink(ping) -> true;
is_uplink(bye) -> true;
is_uplink(input) -> true;
is_uplink(_) -> false.
