-module(asobi_rpc_controller).
-moduledoc """
The HTTP transport for the extension RPC dispatcher.

`POST /api/v1/rpc/<method>` is `rpc.call` over HTTP: the method comes from the
path, `params` from the JSON body (`{"params": {...}}`), and the caller from
the authenticated player the route group's `asobi_auth_plugin:verify/1`
resolved. It hands both to `asobi_rpc:dispatch/2` - the same transport-free
core the socket `rpc.call` frame uses - and encodes the outcome through
`asobi_rpc:envelope/1`, so a call answers byte-identically on either transport
below the transport itself.

The HTTP status is 200 for a result and the error object's own status
(`asobi_error:status/1`) otherwise. The `rpc.ok` / `rpc.error` envelope is the
body in both cases, never the bare `{asobi_error, ...}` shape the other
controllers return: the envelope is the frozen wire contract this surface owes
its clients, and it must read the same as a socket reply.

`protocol` is injected server-side (`asobi_rpc:protocol/0`); an HTTP client
sends only `params`. The caller is tagged `transport => http`, so a handler
reads `Ctx.transport` to know its `session` is this request process - alive
only for the one call - rather than a durable socket pid; one that must reach
the player after it returns keys on `player_id` through presence (the
`module.event` path), never on the session pid.
""".

-export([call/1]).

-spec call(cowboy_req:req()) -> {json, pos_integer(), map(), map()}.
call(#{bindings := #{~"method" := Method}, auth_data := #{player_id := PlayerId}} = Req) when
    is_binary(PlayerId)
->
    Payload = #{
        ~"protocol" => asobi_rpc:protocol(),
        ~"method" => Method,
        ~"params" => params(Req)
    },
    Caller = #{player_id => PlayerId, session => self(), transport => http},
    Outcome = asobi_rpc:dispatch(Payload, Caller),
    {Type, Body} = asobi_rpc:envelope(Outcome),
    {json, http_status(Outcome), #{}, #{~"type" => Type, ~"payload" => Body}}.

%% The dispatcher validates `params`: a missing key or a non-map body reaches
%% it as `undefined` and comes back `rpc.invalid_params`, exactly as it does on
%% the socket. So no shape is enforced here beyond guarding the body-map read.
params(#{json := Json}) when is_map(Json) -> maps:get(~"params", Json, undefined);
params(_Req) -> undefined.

http_status({ok, _Result}) -> 200;
http_status({error, #{error := #{code := Code}}}) -> asobi_error:status(Code).
