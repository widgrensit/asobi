-module(asobi_ops_extension).
-moduledoc """
The ops plane's one extension seam: `/api/v1/ops/ext/:extension/:action`.

`rpc/0` is player-scoped by construction, so an extension with an operator
action - `quests.define` was the first - had nowhere to put it. `ops/0` is
that home, and this module is what makes it reachable.

Extensions contribute no routes of their own. Core owns this one and dispatches
every declared action behind it, exactly as it owns one WebSocket frame type
and dispatches `rpc/0` behind that. The route table stays core's.

## What authorises

Nothing here. `asobi_ops_auth:verify/1` has already resolved the actor and
checked the action's declared class against its caps before this module runs,
because `asobi_ops_caps:class/2` reads the same manifest entry this dispatch
reads. An action nobody declared has no class, and a route with no class is
denied - so an unknown extension, an unknown action and a method the action
does not answer are all 403 from the security callback rather than 404 from
here. That is the same answer the plane gives every other unauthorised call,
and it is deliberate: enumerating which extensions are installed is not a
capability an unauthorised caller should have.

## What is audited

Everything but `get`. Core wraps the call in `asobi_ops_audit:mutation/4`
before it runs, so an extension cannot write on this plane without a durable
row naming the operator. An extension opts into neither the audit nor its
shape; declaring a method other than `get` is what opts in.

## What a handler is given

`Module:Function(Params, Ctx)`, the same shape as an RPC handler:

* `Params` is the decoded JSON body for a write, and the parsed query string
  for a `get`. Always a map with binary keys.
* `Ctx` carries the actor, so a handler can record who asked without another
  lookup, plus the extension and action it was reached as.

and it returns an `t:asobi_rpc:reply/0`: `{ok, map()}`, `{error, Code}` or
`{error, Code, Details}`. Codes come from the extension's own `codes/0` domain,
so the answer is the shared error object every other route already returns.
""".

-include_lib("kernel/include/logger.hrl").

-export([handle/1]).

-doc "What an ops handler is told about its caller.".
-type ctx() :: #{
    actor := asobi_ops_auth:actor(),
    extension := binary(),
    action := binary()
}.

-export_type([ctx/0]).

-spec handle(cowboy_req:req()) ->
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.
handle(
    #{
        bindings := #{~"extension" := Extension, ~"action" := Action},
        auth_data := #{ops_actor := Actor}
    } = Req
) ->
    case asobi_readiness:guard() of
        ok -> dispatch(Extension, Action, Actor, Req);
        {error, _Object} -> {asobi_error, ~"not_ready"}
    end.

%% The entry is re-read rather than threaded from the capability check: the
%% check runs in the security callback and passing a term across that boundary
%% would mean two sources for the same fact. The read is a persistent_term hit.
dispatch(Extension, Action, Actor, Req) ->
    case asobi_extensions:ops_action(Extension, Action) of
        #{method := get, mfa := Mfa} ->
            reply(call(Mfa, query_params(Req), ctx(Extension, Action, Actor)), Extension, Action);
        #{mfa := Mfa} ->
            Ctx = ctx(Extension, Action, Actor),
            Params = body_params(Req),
            Outcome = asobi_ops_audit:mutation(
                Actor,
                <<Extension/binary, ".", Action/binary>>,
                {~"extension", Extension},
                fun() -> call(Mfa, Params, Ctx) end
            ),
            reply(Outcome, Extension, Action);
        undefined ->
            %% Unreachable through the router: an undeclared action has no
            %% class and the security callback already denied it. Answered
            %% rather than crashed because a manifest could change under a live
            %% request, and answered `forbidden` so this agrees with the gate
            %% instead of confirming that the action does not exist.
            {asobi_error, ~"forbidden"}
    end.

ctx(Extension, Action, Actor) ->
    #{actor => Actor, extension => Extension, action => Action}.

call({M, F, 2}, Params, Ctx) ->
    try
        M:F(Params, Ctx)
    catch
        Class:Reason:Stack -> {raised, Class, Reason, Stack}
    end.

reply({ok, Result}, _Extension, _Action) when is_map(Result) ->
    {json, Result};
reply({error, Code}, Extension, Action) ->
    error_reply(Code, #{}, Extension, Action);
reply({error, Code, Details}, Extension, Action) when is_map(Details) ->
    error_reply(Code, Details, Extension, Action);
reply({raised, Class, Reason, Stack}, Extension, Action) ->
    ?LOG_ERROR(#{
        msg => ~"ops_extension_handler_raised",
        extension => Extension,
        action => Action,
        class => Class,
        reason => Reason,
        stacktrace => Stack
    }),
    {asobi_error, ~"internal"};
reply(Other, Extension, Action) ->
    ?LOG_ERROR(#{
        msg => ~"ops_extension_handler_returned_outside_the_contract",
        extension => Extension,
        action => Action,
        returned => Other
    }),
    {asobi_error, ~"internal"}.

%% A code the extension never declared would let a handler mint an arbitrary
%% status out of `params`, so it is a defect here exactly as it is on the RPC
%% seam.
error_reply(Code, Details, Extension, Action) when is_binary(Code) ->
    case asobi_error:defined(Code) of
        true ->
            {asobi_error, Code, Details};
        false ->
            ?LOG_ERROR(#{
                msg => ~"ops_extension_undeclared_code",
                extension => Extension,
                action => Action,
                code => Code
            }),
            {asobi_error, ~"internal"}
    end;
error_reply(Code, _Details, Extension, Action) ->
    reply({returned, Code}, Extension, Action).

body_params(#{json := Params}) when is_map(Params) -> Params;
body_params(_Req) -> #{}.

query_params(Req) ->
    maps:from_list(cowboy_req:parse_qs(Req)).
