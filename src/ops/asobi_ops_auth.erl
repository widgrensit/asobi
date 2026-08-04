-module(asobi_ops_auth).
-moduledoc """
Ops-plane identity: one actor per request, one membership check (ADR 0007).

Every `/api/v1/ops` request resolves to an actor -
`#{id, display, source, caps, attested}` - and is admitted only when the
route's capability class is in the actor's `caps`. Nothing else in the plane
authorises. The actor ships from the first release because it is the one part
of an identity design that is expensive to retrofit: every audit row and every
token consumer would have to be rewritten.

`static_secret` is the only source built. It is the operator secret in the
`ops_secret` application env, compared in constant time. **There is no default
credential**: a deployment that has not configured one rejects every ops
request, so an install that never reads the docs is closed rather than wide
open.

A player bearer token is not a credential here. This module never consults
`asobi_auth_cache`, so no player - and no guest - can reach the plane, which
is the whole point of taking these routes off the player-scoped check.

`cloud` and `local_user` are reserved in `t:source/0` and not built. Cloud
mints a short-lived env-scoped token in `asobi_saas` and maps its roles onto
capability classes there.

Every rejection is 403 with the same body whatever the cause, so a caller
cannot tell "no secret configured" from "wrong secret" from "not authorised
for this class".
""".

-include_lib("kernel/include/logger.hrl").

-export([verify/1, resolve/1, display/1]).

-define(LABEL_HEADER, ~"x-asobi-operator").
-define(LABEL_MAX_BYTES, 64).
-define(DEFAULT_DISPLAY, ~"operator").

-type source() :: static_secret | cloud | local_user.
-type actor() :: #{
    id := binary(),
    display := binary(),
    source := source(),
    caps := [asobi_ops_caps:class()],
    attested := boolean()
}.

-export_type([source/0, actor/0]).

-doc """
Nova security callback for the ops route group.

Admits with the actor in `auth_data`, or rejects with 403 and a flat error
body.
""".
-spec verify(cowboy_req:req()) ->
    {true, #{ops_actor := actor()}} | {false, 403, #{binary() => binary()}, binary()}.
verify(Req) ->
    Class = asobi_ops_caps:class(cowboy_req:method(Req), cowboy_req:path(Req)),
    case resolve(Req) of
        {ok, #{caps := Caps} = Actor} ->
            case asobi_ops_caps:authorised(Class, Caps) of
                true -> {true, #{ops_actor => Actor}};
                false -> deny()
            end;
        {error, _Reason} ->
            deny()
    end.

-doc """
Resolve a request to an ops actor.

`static_secret` is the only source built, and it fails closed: an unset or
empty `ops_secret` rejects every request rather than admitting one.
""".
-spec resolve(cowboy_req:req()) -> {ok, actor()} | {error, atom()}.
resolve(Req) ->
    case secret() of
        {ok, Secret} ->
            case presented(Req) of
                {ok, Presented} -> match(Secret, Presented, Req);
                error -> {error, no_credential}
            end;
        error ->
            ?LOG_WARNING(#{
                msg => ~"ops request rejected: no ops_secret configured",
                path => cowboy_req:path(Req)
            }),
            {error, not_configured}
    end.

-doc """
The operator label from `x-asobi-operator`, or the default display name.

Attribution, never authority: it is read only here, after the credential has
already been accepted, and it never reaches the capability check. Spoofing it
buys a wrong name in the audit trail and nothing else, which is why the actor
carries it with `attested => false`.

Dropped rather than trusted when it is multi-valued (cowboy joins repeated
headers with a comma), empty, over 64 bytes, or carries anything outside
printable ASCII - the value lands in audit rows and logs.
""".
-spec display(cowboy_req:req()) -> binary().
display(Req) ->
    case cowboy_req:header(?LABEL_HEADER, Req) of
        undefined -> ?DEFAULT_DISPLAY;
        Label -> label(Label)
    end.

-spec label(binary()) -> binary().
label(Label) when byte_size(Label) > 0, byte_size(Label) =< ?LABEL_MAX_BYTES ->
    case printable(Label) andalso binary:match(Label, ~",") =:= nomatch of
        true -> Label;
        false -> ?DEFAULT_DISPLAY
    end;
label(_Label) ->
    ?DEFAULT_DISPLAY.

-spec printable(binary()) -> boolean().
printable(Label) ->
    lists:all(fun(Char) -> Char >= 32 andalso Char =< 126 end, binary_to_list(Label)).

-spec match(binary(), binary(), cowboy_req:req()) -> {ok, actor()} | {error, atom()}.
match(Secret, Presented, Req) ->
    case equal(Secret, Presented) of
        true -> {ok, actor(Req)};
        false -> {error, bad_credential}
    end.

-spec equal(binary(), binary()) -> boolean().
equal(Secret, Presented) ->
    %% Hash both first: crypto:hash_equals/2 raises on operands of different
    %% size, so comparing the raw values would both crash and leak the
    %% secret's length through the response.
    crypto:hash_equals(crypto:hash(sha256, Secret), crypto:hash(sha256, Presented)).

-spec actor(cowboy_req:req()) -> actor().
actor(Req) ->
    #{
        id => ~"static_secret",
        display => display(Req),
        source => static_secret,
        caps => [read, player_data, config],
        attested => false
    }.

-spec secret() -> {ok, binary()} | error.
secret() ->
    case application:get_env(asobi, ops_secret) of
        {ok, Secret} when is_binary(Secret), Secret =/= ~"" -> {ok, Secret};
        _ -> error
    end.

-spec presented(cowboy_req:req()) -> {ok, binary()} | error.
presented(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", Token/binary>> when Token =/= ~"" -> {ok, Token};
        _ -> error
    end.

-spec deny() -> {false, 403, #{binary() => binary()}, binary()}.
deny() ->
    Body = iolist_to_binary(json:encode(asobi_error:object(~"forbidden"))),
    {false, 403, #{~"content-type" => ~"application/json"}, Body}.
