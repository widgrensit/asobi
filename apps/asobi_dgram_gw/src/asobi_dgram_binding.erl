-module(asobi_dgram_binding).
-moduledoc """
The datagram plane's binding table and its two-phase challenge (ADR 0012,
decisions 5, 6 and 7).

Pure data: no ETS, no processes, no timers. The gateway process that owns this
table is a thin shell around it, which is what makes every security-critical
transition here testable by calling a function.

## The credential is a registered binding, not a token

The engine mints `{conn_id, KUp, ...}` over the already-authenticated WebSocket
and registers it here. `KUp` travels exactly once, inside TLS, and never on the
datagram plane; every uplink datagram including the first `hello` is
authenticated under it, so the datagram protocol contains no key exchange at all.

A registered binding revokes instantly when the session dies. A signed token
structurally cannot, which is the whole reason this is a table rather than a
bearer credential.

## The observed address is a return-path handle, never an identity

`conn_id` is the sole demux key and uplink routing never consults the handle: any
NAT, proxy or load balancer may rewrite it, and a kernel-assigned mapping is
expirable and reusable. The reverse direction needs *somewhere* to send, so a
handle is recorded - but only ever by a **completed challenge**, never by
observation, and it is dropped synchronously on teardown. That is what stops a
client that inherits a dead client's NAT mapping from inheriting its downlink.

## What the challenge proves, stated so nobody reads more into it

`hello_ok` carries a 64-bit random challenge to the candidate handle only, and no
state frames follow until the echo returns. The echo proves **the sender can
receive at whatever the return-path handle currently resolves to** - return
routability, which is exactly the anti-reflection property this plane needs.

It is **not** proof of a client address and nothing here may treat it as one.

`cseq` strictly advances and is covered by the MAC. It is the only thing stopping
a captured `hello_confirm` being replayed from another handle, so it is
load-bearing and it is checked **before** the rebind path is entered.
""".

-export([new/0, register/2, unregister/2, lookup/2, size/1]).
-export([hello/6, confirm/5, note_uplink/3]).
-export([sendable/2, expire/2]).
-export_type([table/0, binding/0, handle/0]).

%% Whatever the socket layer uses to address a reply. Opaque here on purpose:
%% this module must never grow an opinion about what an address means.
-type handle() :: term().

%% `registered` until the first challenge completes, `bound` from then on. A
%% rebind in flight does NOT return a connection to `registered`: the downlink
%% keeps going to the handle that already proved itself until the new one proves
%% itself too, which is the difference between a hint and an authority.
-type state() :: registered | bound.

-type binding() :: #{
    conn_id := non_neg_integer(),
    kup := binary(),
    player_id := binary(),
    epoch := 0..65535,
    expires_at := integer(),
    state := state(),
    %% The handle the downlink goes to. `undefined` until a challenge completes,
    %% and it does NOT move to a new handle on a bare `hello` - a rebind takes
    %% effect only when its own echo returns.
    handle := handle() | undefined,
    %% The handle a challenge was minted to, and the challenge itself. Cleared on
    %% success so a captured echo cannot be replayed against a later challenge.
    pending_handle := handle() | undefined,
    challenge := binary() | undefined,
    cseq := non_neg_integer(),
    rebinds := [integer()]
}.

-opaque table() :: #{
    by_conn := #{non_neg_integer() => binding()},
    %% Handle -> conn_id, for teardown only. Populated exclusively by a completed
    %% challenge; nothing observed ever reaches it.
    by_handle := #{handle() => non_neg_integer()}
}.

%% ADR 0012, decision 7: bounded at 3 rebinds per 60 s per connection, then
%% teardown. A client legitimately behind a flapping path is degraded rather than
%% served, because the WebSocket carries everything throughout.
-define(REBIND_LIMIT, 3).
-define(REBIND_WINDOW_MS, 60_000).

-doc "An empty table.".
-spec new() -> table().
new() -> #{by_conn => #{}, by_handle => #{}}.

-doc """
Records a minted binding. Called from the engine's mint path, over TLS.

Refuses a duplicate `conn_id` rather than overwriting: an overwrite would silently
re-point a live connection's credential, and `conn_id` collisions are a generator
defect worth seeing.
""".
-spec register(binding(), table()) -> {ok, table()} | {error, duplicate}.
register(#{conn_id := ConnId} = Binding, #{by_conn := ByConn} = T) ->
    case maps:is_key(ConnId, ByConn) of
        true ->
            {error, duplicate};
        false ->
            {ok, T#{
                by_conn => ByConn#{
                    ConnId => Binding#{
                        state => registered,
                        handle => undefined,
                        pending_handle => undefined,
                        challenge => undefined,
                        cseq => 0,
                        rebinds => []
                    }
                }
            }}
    end.

-doc """
Removes a binding and its handle mapping, synchronously.

Synchronously is the point. A handle left behind is a downlink a later client can
inherit simply by being assigned the same NAT mapping.
""".
-spec unregister(non_neg_integer(), table()) -> table().
unregister(ConnId, #{by_conn := ByConn, by_handle := ByHandle} = T) ->
    case ByConn of
        #{ConnId := #{handle := Handle}} ->
            T#{
                by_conn => maps:remove(ConnId, ByConn),
                by_handle => drop_handle(Handle, ConnId, ByHandle)
            };
        _ ->
            T
    end.

-doc "The binding for `ConnId`, or `error`. The sole demux path for an uplink.".
-spec lookup(non_neg_integer(), table()) -> {ok, binding()} | error.
lookup(ConnId, #{by_conn := ByConn}) -> maps:find(ConnId, ByConn).

-doc "How many bindings are live.".
-spec size(table()) -> non_neg_integer().
size(#{by_conn := ByConn}) -> map_size(ByConn).

-doc """
Handles a MAC-valid `hello` and mints a challenge.

`Challenge` is supplied by the caller rather than generated here so this module
stays pure and a test can pin the value; the gateway passes
`crypto:strong_rand_bytes/1`.

A `hello` from a handle other than the bound one is a **hint, never an
authority**: a new challenge is minted to the new handle and the downlink stays
where it is until that challenge's echo returns. Rebinds are counted, and a
connection past the budget is told to tear down rather than served.
""".
-spec hello(non_neg_integer(), non_neg_integer(), handle(), integer(), binary(), table()) ->
    {ok, binary(), table()} | {error, atom(), table()}.
hello(ConnId, CSeq, Handle, Now, Challenge, #{by_conn := ByConn} = T) ->
    case ByConn of
        #{ConnId := Binding} ->
            %% cseq FIRST, before the rebind path is entered at all. It is the
            %% only thing stopping a captured hello being replayed from another
            %% handle, so a rebind decision taken ahead of it would be taken on
            %% unauthenticated ordering.
            case advance_cseq(Binding, CSeq) of
                {error, Reason} ->
                    {error, Reason, T};
                {ok, Advanced} ->
                    mint_challenge(ConnId, Handle, Now, Challenge, Advanced, ByConn, T)
            end;
        _ ->
            {error, unknown_conn, T}
    end.

-doc """
Handles a MAC-valid `hello_confirm` and binds the downlink.

The echo must match the outstanding challenge AND come from the handle that
challenge was minted to. Either alone is not enough: matching the challenge from
a different handle is the reflection this exists to prevent, and matching the
handle without the challenge is no proof at all.
""".
-spec confirm(non_neg_integer(), non_neg_integer(), handle(), binary(), table()) ->
    {ok, table()} | {error, atom(), table()}.
confirm(ConnId, CSeq, Handle, Echo, #{by_conn := ByConn, by_handle := ByHandle} = T) ->
    case ByConn of
        #{ConnId := Binding} ->
            case advance_cseq(Binding, CSeq) of
                {error, Reason} ->
                    {error, Reason, T};
                {ok, Advanced} ->
                    confirm_echo(ConnId, Handle, Echo, Advanced, ByConn, ByHandle, T)
            end;
        _ ->
            {error, unknown_conn, T}
    end.

-doc """
Advances `cseq` for a datagram that carries no binding transition of its own.

`input`, `ping` and `bye` all go through here, so a replayed one is refused on the
same rule that protects the handshake rather than on a rule of its own.
""".
-spec note_uplink(non_neg_integer(), non_neg_integer(), table()) ->
    {ok, binding(), table()} | {error, atom(), table()}.
note_uplink(ConnId, CSeq, #{by_conn := ByConn} = T) ->
    case ByConn of
        #{ConnId := Binding} ->
            case advance_cseq(Binding, CSeq) of
                {error, Reason} ->
                    {error, Reason, T};
                {ok, Advanced} ->
                    {ok, Advanced, T#{by_conn => ByConn#{ConnId => Advanced}}}
            end;
        _ ->
            {error, unknown_conn, T}
    end.

-doc """
The handle to send this connection's downlink to, if it has one.

`error` for a connection that has never completed a challenge, which is what
guarantees no state frame precedes return-routability.
""".
-spec sendable(non_neg_integer(), table()) -> {ok, handle()} | error.
sendable(ConnId, #{by_conn := ByConn}) ->
    case ByConn of
        #{ConnId := #{handle := Handle}} when Handle =/= undefined -> {ok, Handle};
        _ -> error
    end.

-doc "Removes every binding whose mint has expired, returning what was dropped.".
-spec expire(integer(), table()) -> {[non_neg_integer()], table()}.
expire(Now, #{by_conn := ByConn} = T) ->
    Dead = [C || C := #{expires_at := Exp} <- ByConn, Exp =< Now],
    {Dead, unregister_all(Dead, T)}.

%% --- Internal ---

unregister_all([], T) -> T;
unregister_all([ConnId | Rest], T) -> unregister_all(Rest, unregister(ConnId, T)).

mint_challenge(ConnId, Handle, Now, Challenge, Binding, ByConn, T) ->
    #{handle := Bound, rebinds := Rebinds} = Binding,
    IsRebind = Bound =/= undefined andalso Bound =/= Handle,
    Recent = [At || At <- Rebinds, Now - At < ?REBIND_WINDOW_MS],
    case IsRebind andalso length(Recent) >= ?REBIND_LIMIT of
        true ->
            %% Past the budget. The caller tears the connection down rather than
            %% minting again; a client whose path is genuinely flapping is served
            %% by the WebSocket throughout.
            {error, rebind_limit, T};
        false ->
            Rebinds1 =
                case IsRebind of
                    true -> [Now | Recent];
                    false -> Recent
                end,
            Updated = Binding#{
                pending_handle => Handle,
                challenge => Challenge,
                rebinds => Rebinds1
            },
            {ok, Challenge, T#{by_conn => ByConn#{ConnId => Updated}}}
    end.

confirm_echo(ConnId, Handle, Echo, Binding, ByConn, ByHandle, T) ->
    #{pending_handle := Pending, challenge := Challenge, handle := Old} = Binding,
    Matches =
        Challenge =/= undefined andalso
            Pending =:= Handle andalso
            crypto:hash_equals(Challenge, Echo),
    case Matches of
        false ->
            %% Advance cseq regardless, so a failed confirm cannot be retried with
            %% the same one. The table is returned updated for that reason alone.
            {error, bad_challenge, T#{by_conn => ByConn#{ConnId => Binding}}};
        true ->
            Bound = Binding#{
                state => bound,
                handle => Handle,
                pending_handle => undefined,
                %% Cleared on success so a captured echo cannot be replayed
                %% against whatever challenge is outstanding later.
                challenge => undefined
            },
            {ok, T#{
                by_conn => ByConn#{ConnId => Bound},
                by_handle => (drop_handle(Old, ConnId, ByHandle))#{Handle => ConnId}
            }}
    end.

%% Strictly advancing, never equal. Equality would admit an exact replay, which is
%% the entire attack this counter exists to stop.
advance_cseq(#{cseq := Last} = Binding, CSeq) when CSeq > Last ->
    {ok, Binding#{cseq => CSeq}};
advance_cseq(_Binding, _CSeq) ->
    {error, stale_cseq}.

drop_handle(undefined, _ConnId, ByHandle) ->
    ByHandle;
drop_handle(Handle, ConnId, ByHandle) ->
    case ByHandle of
        #{Handle := ConnId} -> maps:remove(Handle, ByHandle);
        _ -> ByHandle
    end.
