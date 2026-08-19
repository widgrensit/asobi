-module(asobi_rpc).
-moduledoc """
The extension RPC dispatcher: `rpc.call` in, `rpc.ok` or `rpc.error` out.

`rpc/0` in an extension's manifest declares `Method => {M, F, A}`. This is
what reads it. Without this module the declaration is validated and then
nothing calls it, which is the state the first real extension reported.

## The frame

```json
{"type": "rpc.call", "cid": "c-1",
 "payload": {"protocol": 1, "method": "quests.claim", "params": {"quest_id": "q-1"}}}
```

```json
{"type": "rpc.ok",    "cid": "c-1", "payload": {"result": {"reward": 100}}}
{"type": "rpc.error", "cid": "c-1", "payload": {"error": {"code": "...", "message": "...", "details": {}}}}
```

- **`cid` is required and validated here**, unlike the rest of the socket
  where it is an optional echo. An RPC reply is useless without correlation -
  it is the only way a client pairs `rpc.ok` with the call it made - and the
  value is echoed into a frame, so it is bounded to 1-64 printable ASCII
  bytes rather than reflected unchecked. A rejected `cid` is not echoed back;
  there is nothing trustworthy to echo.
- **`params` and `result` are always objects.** A bare scalar cannot grow a
  field later without breaking every client, and this is the one wire shape
  seven SDKs must agree on.
- **`protocol` is a number, currently `1`.** Version the payload, not the
  frame type, so a future version is a rejection a client can read rather
  than an `unknown_type`.

## The handler contract

```erlang
-spec claim(asobi_rpc:params(), asobi_rpc:ctx()) -> asobi_rpc:reply().
claim(#{~"quest_id" := QuestId}, #{player_id := PlayerId}) ->
    case asobi_quests:claim(PlayerId, QuestId) of
        {ok, Reward}          -> {ok, #{reward => Reward}};
        {error, already_done} -> {error, ~"quests.already_claimed"}
    end.
```

`(Params, Ctx) -> {ok, map()} | {error, Code} | {error, Code, Details}`, and
the arity in `rpc/0` is therefore always 2.

The failure half is a **code**, not a status and an object. Both of those are
derivable from the code - `asobi_error:status/1` and `asobi_error:object/2` -
and an extension mints its own codes in its own domain (`codes/0`), so
returning a status would let two call sites answer the same code differently
and would put object construction in every extension. It is also the dialect
core's own controllers already speak (`{asobi_error, Code, Details}`), so
there is one shape to learn rather than two.

`Ctx` is `#{player_id, session, method, transport}` and may gain keys. Match
the ones you need with `:=`; never match it exhaustively.

`Ctx.session` is a process, but which process depends on `Ctx.transport`. Over
`ws` it is the durable player-session pid. Over `http`
(`POST /api/v1/rpc/<method>`, `m:asobi_rpc_controller`) it is the request
process, alive only for the one call. A handler that must reach the player
after it returns checks `transport =:= ws` before touching `session`, and
otherwise keys on `player_id` through presence (the `module.event` path) -
never the session pid, which over HTTP is dead the moment the reply is sent.

An extension error surfaces as **its own code**, provided the extension
declared it in `codes/0`. A handler that raises, returns outside the contract,
or returns a code nobody declared becomes `internal`, each logged as the
extension defect it is. The last of those is what keeps the code set closed on
this surface: every other call site's code is a binary literal checked at build
time, and a handler's is a runtime term that could have been built from
`params`.

## Readiness

The route table compiles inside `nova_sup:init/1`; migrations run afterwards
from `asobi_app:start/2`. A socket is therefore reachable before an
extension's tables exist, so every dispatch passes `asobi_readiness:guard/0`
first and answers `not_ready` (503) until migrations have finished.

## Authorisation

Every declared method is player-scoped: the caller is the authenticated
player on that socket, and an unauthenticated socket gets `unauthenticated`
before anything is looked up. There is deliberately no per-method capability
class. `read | player_data | config` (ADR 0007) is an **operator**
vocabulary, minted by `m:asobi_ops_auth` for the ops plane and never held by
a player, so tagging a socket method with one would make it deniable for
every caller this dispatcher has - another declaration nothing can reach.
The reachable home for an operator-only extension method is the ops plane,
which is read-only today by assertion, so opening it is a decision about that
plane rather than about this manifest.

## Transports

Two transports reach this dispatcher and share `dispatch/2` and `envelope/1`,
so the reply envelope is byte-identical between them. What they do NOT share is
everything in front of the dispatcher, and these divergences are frozen:

- **The dispatcher enforces no auth, no rate limit and no size cap.** Each
  transport enforces its own, separately, before calling in. A `ws` frame is
  gated by socket auth, a per-connection 60/s message cap and a 64 KiB frame
  cap; an `http` `POST` is gated by `asobi_auth_plugin` (401), the api rate
  limiter (300/s per client IP) and the 1 MiB `asobi_body_cap_plugin`. A third
  transport must supply its own; it must not assume the dispatcher does.
- **The request-size caps differ and do not converge** - 64 KiB over `ws`,
  1 MiB over `http`. The accepted request size is a property of the transport;
  only the reply envelope is shared.
- **Protocol versioning differs.** The `ws` payload carries a `protocol`
  field, so a foreign version answers `rpc.unsupported_protocol`. The HTTP
  controller injects `protocol` server-side and versions through the URL
  (`/api/v1/...`) instead, so `rpc.unsupported_protocol` cannot fire over
  `http` by design.
""".

-include_lib("kernel/include/logger.hrl").

-export([handle/3, dispatch/2, envelope/1, protocol/0]).

-define(PROTOCOL, 1).
-define(MAX_CID_BYTES, 64).

-doc "The `params` object, exactly as the client sent it. Keys are binaries.".
-type params() :: #{binary() => term()}.

-doc "What a handler is told about its caller. Additive; never match it exhaustively.".
-type ctx() :: #{
    player_id := binary(), session := pid(), method := binary(), transport := ws | http
}.

-doc "What a handler returns.".
-type reply() ::
    {ok, map()}
    | {error, asobi_error:code()}
    | {error, asobi_error:code(), asobi_error:details()}.

-doc """
The authenticated player behind the transport, or `unauthenticated`.

`transport` marks which one so a handler can branch on `Ctx.transport`; it is
optional here and defaults to `ws` in `invoke/5`, so a caller built without it
stays safe.
""".
-type caller() ::
    #{player_id := binary(), session := pid(), transport => ws | http} | unauthenticated.

-export_type([params/0, ctx/0, reply/0, caller/0]).

-doc "The RPC protocol version this node speaks.".
-spec protocol() -> pos_integer().
protocol() ->
    ?PROTOCOL.

-doc """
Dispatch one `rpc.call`.

Returns the `cid` to echo - `undefined` when the client's own `cid` was
rejected - and the outcome to encode.
""".
-spec handle(term(), term(), caller()) ->
    {binary() | undefined, {ok, map()} | {error, asobi_error:object()}}.
handle(Cid, Payload, Caller) ->
    case cid(Cid) of
        {ok, Valid} -> {Valid, dispatch(Payload, Caller)};
        error -> {undefined, {error, asobi_error:object(~"rpc.invalid_cid")}}
    end.

-doc """
Dispatch one call, without a transport.

`handle/3` is this behind the socket's `cid` validation;
`m:asobi_rpc_controller` is this behind HTTP request parsing. Both hand the
same `#{"protocol", "method", "params"}` payload and the same `caller()`, and
both encode the outcome through `envelope/1`, so a given call answers
byte-identically on either transport below the transport itself.
""".
-spec dispatch(term(), caller()) -> {ok, map()} | {error, asobi_error:object()}.
dispatch(_Payload, unauthenticated) ->
    {error, asobi_error:object(~"unauthenticated")};
dispatch(Payload, Caller) ->
    case asobi_readiness:guard() of
        ok -> ready(Payload, Caller);
        {error, Object} -> {error, Object}
    end.

-doc """
The `rpc.ok` / `rpc.error` wire payload for a dispatch outcome.

The single source of truth for the pair, shared by the socket encoder
(`asobi_ws_handler:encode_rpc/2`) and the HTTP controller so a frozen payload
cannot drift between them: `{ok, Result}` becomes
`{~"rpc.ok", #{~"result" => Result}}`, and `{error, Object}` becomes
`{~"rpc.error", Object}` - the error object alone, never wrapped again.
""".
-spec envelope({ok, map()} | {error, asobi_error:object()}) -> {binary(), map()}.
envelope({ok, Result}) ->
    {~"rpc.ok", #{~"result" => Result}};
envelope({error, Object}) ->
    {~"rpc.error", Object}.

%%====================================================================
%% Internal
%%====================================================================

ready(Payload, _Caller) when not is_map(Payload) ->
    {error, asobi_error:object(~"invalid_payload")};
ready(Payload, Caller) ->
    case maps:get(~"protocol", Payload, undefined) of
        ?PROTOCOL -> versioned(Payload, Caller);
        _ -> {error, asobi_error:object(~"rpc.unsupported_protocol", #{supported => [?PROTOCOL]})}
    end.

versioned(Payload, Caller) ->
    Method = maps:get(~"method", Payload, undefined),
    Params = maps:get(~"params", Payload, undefined),
    case {is_binary(Method), is_map(Params)} of
        {true, true} -> lookup(Method, Params, Caller);
        {true, false} -> {error, asobi_error:object(~"rpc.invalid_params")};
        {false, _} -> {error, asobi_error:object(~"rpc.unknown_method")}
    end.

%% Built-ins are checked FIRST and the `asobi.` prefix is reserved for them, so
%% an extension cannot shadow a core method by declaring the same name. The
%% datagram mint lives here rather than on a new frame type because `rpc.call`
%% is already frozen and already implemented in every SDK, so the whole datagram
%% plane adds zero frames to the JSON wire (ADR 0012, decision 5).
lookup(Method, Params, Caller) ->
    case builtins() of
        #{Method := {Module, Function}} ->
            invoke(Module, Function, Method, Params, Caller);
        _ ->
            case maps:find(Method, asobi_extensions:rpc_methods()) of
                {ok, {Module, Function, 2}} -> invoke(Module, Function, Method, Params, Caller);
                {ok, Target} -> bad_arity(Method, Target);
                error -> {error, asobi_error:object(~"rpc.unknown_method")}
            end
    end.

builtins() ->
    #{
        ~"asobi.datagram.open" => {asobi_dgram_rpc, open},
        ~"asobi.datagram.close" => {asobi_dgram_rpc, close}
    }.

%% Backstop. `asobi_extensions` refuses a non-2 arity at `rebar3 asobi check`
%% and again at boot, so reaching this means a manifest got past both gates;
%% answering `unknown_method` would then hide a defect behind a 404.
bad_arity(Method, Target) ->
    ?LOG_ERROR(#{
        event => rpc_handler_bad_arity,
        method => Method,
        target => Target,
        detail => ~"an rpc handler is called as handler(Params, Ctx) and must have arity 2"
    }),
    {error, asobi_error:object(~"internal")}.

invoke(Module, Function, Method, Params, #{player_id := PlayerId, session := Session} = Caller) ->
    Ctx = #{
        player_id => PlayerId,
        session => Session,
        method => Method,
        transport => maps:get(transport, Caller, ws)
    },
    try Module:Function(Params, Ctx) of
        Reply -> reply(Reply, Method)
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(#{
                event => rpc_handler_crashed,
                method => Method,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            {error, asobi_error:object(~"internal")}
    end.

reply({ok, Result}, Method) when is_map(Result) ->
    encodable(Result, Method);
reply({error, Code}, Method) when is_binary(Code) ->
    failure(Code, #{}, Method);
reply({error, Code, Details}, Method) when is_binary(Code), is_map(Details) ->
    failure(Code, Details, Method);
reply(Other, Method) ->
    ?LOG_ERROR(#{
        event => rpc_handler_bad_return,
        method => Method,
        returned => class_of(Other),
        detail => ~"an rpc handler returns {ok, map()} | {error, Code} | {error, Code, Details}"
    }),
    {error, asobi_error:object(~"internal")}.

%% The code set stays closed. A handler's return value is a runtime term, so
%% the build-time literal check every other call site gets (see
%% `asobi_error_contract_tests`) cannot apply here; this is its runtime
%% equivalent. `defined/1` accepts core's codes and every installed manifest's,
%% so an extension's own declared code goes out as itself - answering
%% `internal` there would hide the extension's contract behind a core defect.
%% A code nobody declared does not reach a client: clients may branch on
%% `code`, and a handler is free to build a string from `params`.
failure(Code, Details, Method) ->
    case asobi_error:defined(Code) of
        true ->
            encodable_error(asobi_error:object(Code, Details), Method);
        false ->
            ?LOG_ERROR(#{event => undefined_error_code, code => Code, method => Method}),
            {error, asobi_error:object(~"internal")}
    end.

%% The result is encoded into a frame by the caller, where a raise would be
%% caught as a generic socket error rather than reported as this method's.
%% Encoding it here, where the method is known, is worth one extra pass on a
%% path that is not the tick loop.
encodable(Result, Method) ->
    try
        _ = json:encode(Result),
        {ok, Result}
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                event => rpc_result_not_encodable,
                method => Method,
                class => Class,
                reason => Reason
            }),
            {error, asobi_error:object(~"internal")}
    end.

%% Symmetric with encodable/2 on the ok path: a handler's `Details` is a runtime
%% term and may hold a pid, ref or tuple that no reply encoder can serialise.
%% Both transports encode this object, so an unencodable one would raise in the
%% encoder - uncaught on the socket, uncaught in the controller. Encoding it
%% here, where the method is known, degrades that to `internal` rather than a
%% crash. `params` is always JSON-decoded, so this is an author footgun, not an
%% attacker one.
encodable_error(Object, Method) ->
    try
        _ = json:encode(Object),
        {error, Object}
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                event => rpc_error_not_encodable,
                method => Method,
                class => Class,
                reason => Reason
            }),
            {error, asobi_error:object(~"internal")}
    end.

class_of(Term) when is_atom(Term) -> Term;
class_of(Term) when is_tuple(Term), tuple_size(Term) > 0, is_atom(element(1, Term)) ->
    element(1, Term);
class_of(_Term) ->
    unknown.

%% Bounded and printable because the value is reflected into a frame and into
%% nothing else: it is never a key, a log field or a lookup.
cid(Cid) when is_binary(Cid), byte_size(Cid) > 0, byte_size(Cid) =< ?MAX_CID_BYTES ->
    case printable(Cid) of
        true -> {ok, Cid};
        false -> error
    end;
cid(_Cid) ->
    error.

printable(Cid) ->
    lists:all(fun(C) -> C >= 32 andalso C =< 126 end, binary_to_list(Cid)).
