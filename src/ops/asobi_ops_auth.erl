-module(asobi_ops_auth).
-moduledoc """
Ops-plane identity: one actor per request, one membership check (ADR 0007).

Every `/api/v1/ops` request resolves to an actor -
`#{id, display, source, caps, attested}` - and is admitted only when the
route's capability class is in the actor's `caps`. Nothing else in the plane
authorises. The actor ships from the first release because it is the one part
of an identity design that is expensive to retrofit: every audit row and every
token consumer would have to be rewritten.

Two sources are built, and they are the two transports the same operator
credential arrives on:

* **`static_secret`** - the operator secret in the `ops_secret` application
  env, presented as a bearer token and compared in constant time. CI, the CLI
  and any server-side caller. **There is no default credential**: a deployment
  that has not configured one rejects every bearer request, so an install that
  never reads the docs is closed rather than wide open.
* **`local_user`** - the console's session cookie plus its `x-csrf-token`
  header (`m:asobi_console_session`). A browser exchanges the secret for a
  session once and then never holds it again, so an XSS on the console cannot
  exfiltrate a credential that outlives the page.

A bearer token wins when both are present, because a caller that sent one
meant to use it and silently answering as somebody else's session would be
worse than a 403.

A player bearer token is not a credential here. This module never consults
`asobi_auth_cache`, so no player - and no guest - can reach the plane, which
is the whole point of taking these routes off the player-scoped check.

A session stands on its own once minted: it resolves without re-reading
`ops_secret`, and it is revoked by logging out or by the node restarting.
That is deliberate - a session has its own expiry and its own revocation, so
tying it to a value that can change underneath it would end sessions at
surprising moments without ending the bearer access that matters.

`cloud` is reserved in `t:source/0` and not built. Cloud mints a short-lived
env-scoped token in `asobi_saas` and maps its roles onto capability classes
there.

Every rejection is 403 with the same body whatever the cause, so a caller
cannot tell "no secret configured" from "wrong secret" from "not authorised
for this class".
""".

-include_lib("kernel/include/logger.hrl").

-export([verify/1, resolve/1, display/1, verify_secret/1]).

-define(LABEL_HEADER, ~"x-asobi-operator").
-define(CSRF_HEADER, ~"x-csrf-token").
-define(COOKIE, ~"asobi_console").
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

Bearer first, then the console session cookie. Both fail closed: an unset or
empty `ops_secret` rejects every bearer request, and a cookie without a
matching `x-csrf-token` is not a credential.
""".
-spec resolve(cowboy_req:req()) -> {ok, actor()} | {error, atom()}.
resolve(Req) ->
    case presented(Req) of
        {ok, Presented} -> bearer(Presented, Req);
        error -> session(Req)
    end.

-doc """
Whether `Presented` is the configured operator secret.

The one entry point the console login uses, so the constant-time comparison
and the no-default rule are stated in exactly one place. `false` when nothing
is configured, never `true`.
""".
-spec verify_secret(term()) -> boolean().
verify_secret(Presented) when is_binary(Presented), Presented =/= ~"" ->
    case secret() of
        {ok, Secret} -> equal(Secret, Presented);
        error -> false
    end;
verify_secret(_Presented) ->
    false.

-spec bearer(binary(), cowboy_req:req()) -> {ok, actor()} | {error, atom()}.
bearer(Presented, Req) ->
    case secret() of
        {ok, Secret} -> match(Secret, Presented, Req);
        error -> unconfigured(Req)
    end.

-spec session(cowboy_req:req()) -> {ok, actor()} | {error, atom()}.
session(Req) ->
    case cookie(Req) of
        {ok, Id} -> resolved(asobi_console_session:resolve(Id, csrf_header(Req)));
        error -> no_credential(Req)
    end.

%% A request with nothing on it still reports `not_configured` when nothing is
%% configured, and still logs it. That warning is the only signal an operator
%% gets that the plane is dark because they never set a secret, and it must
%% not disappear just because a second credential source exists.
-spec no_credential(cowboy_req:req()) -> {error, atom()}.
no_credential(Req) ->
    case secret() of
        {ok, _} -> {error, no_credential};
        error -> unconfigured(Req)
    end.

-spec unconfigured(cowboy_req:req()) -> {error, not_configured}.
unconfigured(Req) ->
    ?LOG_WARNING(#{
        msg => ~"ops request rejected: no ops_secret configured",
        path => cowboy_req:path(Req)
    }),
    {error, not_configured}.

-spec resolved({ok, asobi_console_session:session()} | {error, atom()}) ->
    {ok, actor()} | {error, atom()}.
resolved({ok, Session}) -> {ok, session_actor(Session)};
resolved({error, Reason}) -> {error, Reason}.

%% The session id is a credential, so it never becomes the actor id: an audit
%% row and a log line would then carry a live cookie. A truncated hash of it
%% is enough to correlate rows to one session and useless to replay.
-spec session_actor(asobi_console_session:session()) -> actor().
session_actor(#{id := Id, label := Label}) ->
    Digest = binary:encode_hex(binary:part(crypto:hash(sha256, Id), 0, 8), lowercase),
    #{
        id => <<"console:", Digest/binary>>,
        display => Label,
        source => local_user,
        caps => [read, player_data, config],
        attested => false
    }.

-spec cookie(cowboy_req:req()) -> {ok, binary()} | error.
cookie(Req) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, Value} when is_binary(Value), Value =/= ~"" -> {ok, Value};
        _ -> error
    end.

-spec csrf_header(cowboy_req:req()) -> binary().
csrf_header(Req) ->
    case cowboy_req:header(?CSRF_HEADER, Req) of
        Token when is_binary(Token) -> Token;
        undefined -> ~""
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
