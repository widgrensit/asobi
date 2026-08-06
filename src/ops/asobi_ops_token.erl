-module(asobi_ops_token).
-moduledoc """
The minted, env-scoped ops token: how a managed tenant's browser reaches this
environment's ops plane.

`console.asobi.dev` authenticates the tenant, checks it owns this environment,
maps its role onto capability classes and mints a token. The browser then
talks to **this** environment directly, because the control plane must not
read a tenant game database and a browser can already reach an env pod while
the control plane cannot.

## The shape

```
v1.<base64url(payload)>.<base64url(mac)>
```

`payload` is JSON: `env`, `sub`, `caps`, `iat`, `exp`. The MAC covers
`v1.<payload>` - the version prefix is signed, so a future version cannot be
stripped down to this one.

## The key

`ops_token_secret`, from `ASOBI_OPS_TOKEN_SECRET` - a per-environment secret
that signs ops tokens and does nothing else.

It was briefly derived from `ENGINE_API_KEY`, because both sides already held
that value. Deriving through a label stops two keys being *confused*; it does
not stop them being *compromised together*, and a value that both
authenticates this engine to the control plane and signs the operator
credentials it accepts is one leak away from doing both for an attacker. So
it is its own secret, generated per environment by the provisioner and held
nowhere else - not even in the control plane's database.

Being per environment, a token minted for one env cannot validate at another
even before `env` is checked. `env` is checked anyway.

Rotating it revokes every token outstanding for this environment at once,
which is the only revocation there is.

## What a signature does not buy

A valid MAC is necessary and not sufficient. `exp` must be in the future,
**and the whole lifetime must be short** - a token signed with a year-long
`exp` is refused, so a mint bug on the other side of the wire cannot issue
one this side will honour. Capability classes outside ADR 0007's vocabulary
are refused rather than ignored, and an unknown `env` is refused.

Nothing here is stateful: there is no revocation list, which is exactly why
the lifetime is capped rather than merely checked.
""".

-export([verify/1, sign/2, max_ttl/0, configured/0]).

-define(VERSION, ~"v1").
%% Fifteen minutes. Long enough that an operator is not re-minting mid-task,
%% short enough that a leaked token is a nuisance rather than an incident -
%% and there is nothing to revoke it with.
-define(MAX_TTL_SECONDS, 900).
%% A minted token whose `iat` is in the future is a clock the control plane
%% and this node do not share; a little slack, not an unbounded window.
-define(CLOCK_SKEW_SECONDS, 60).

-type claims() :: #{
    env := binary(),
    sub := binary(),
    caps := [asobi_ops_caps:class()],
    iat := integer(),
    exp := integer()
}.

-export_type([claims/0]).

-doc "The longest lifetime this node will honour, in seconds.".
-spec max_ttl() -> pos_integer().
max_ttl() -> ?MAX_TTL_SECONDS.

-doc """
Whether this node can verify a minted token at all.

Exported so `m:asobi_console_env`'s enable decision reads the same pair
`verify/1` does. A managed environment configures no `ops_secret`, so without
this the console would be switched off underneath the one credential it
accepts.
""".
-spec configured() -> boolean().
configured() -> config() =/= error.

-doc """
Mint a token for `Claims`.

Here rather than only in `asobi_saas` so the two sides cannot drift: the
minting side is a consumer of this function's format, and the round trip is
tested against it.
""".
-spec sign(binary(), claims()) -> binary().
sign(Key, Claims) ->
    Payload = encode(iolist_to_binary(json:encode(claims_json(Claims)))),
    Signed = <<?VERSION/binary, ".", Payload/binary>>,
    Mac = encode(crypto:mac(hmac, sha256, Key, Signed)),
    <<Signed/binary, ".", Mac/binary>>.

-doc """
Verify `Token` against the configured environment, returning its claims.

Every rejection is one atom and the caller answers 403 for all of them, so a
holder of a bad token cannot tell which check failed.
""".
-spec verify(binary()) -> {ok, claims()} | {error, atom()}.
verify(Token) when is_binary(Token) ->
    case config() of
        {ok, Key, EnvId} -> verify(Token, Key, EnvId);
        error -> {error, not_configured}
    end;
verify(_Token) ->
    {error, malformed}.

verify(Token, Key, EnvId) ->
    case binary:split(Token, ~".", [global]) of
        [?VERSION, Payload, Mac] ->
            Signed = <<?VERSION/binary, ".", Payload/binary>>,
            case authentic(Key, Signed, Mac) of
                true -> claims(Payload, EnvId);
                false -> {error, bad_signature}
            end;
        _ ->
            {error, malformed}
    end.

%% Constant time, and over the decoded MAC rather than its text, so a token
%% carrying differently-padded base64 of the right MAC is still the right MAC.
authentic(Key, Signed, Mac) ->
    case decode(Mac) of
        {ok, Presented} when byte_size(Presented) =:= 32 ->
            crypto:hash_equals(crypto:mac(hmac, sha256, Key, Signed), Presented);
        _ ->
            false
    end.

claims(Payload, EnvId) ->
    case decode(Payload) of
        {ok, Json} -> decoded(Json, EnvId);
        error -> {error, malformed}
    end.

decoded(Json, EnvId) ->
    try json:decode(Json) of
        #{~"env" := Env, ~"sub" := Sub, ~"caps" := Caps, ~"iat" := Iat, ~"exp" := Exp} when
            is_binary(Env), is_binary(Sub), is_list(Caps), is_integer(Iat), is_integer(Exp)
        ->
            check(#{env => Env, sub => Sub, caps => Caps, iat => Iat, exp => Exp}, EnvId);
        _ ->
            {error, malformed}
    catch
        _:_ -> {error, malformed}
    end.

check(#{env := Env}, EnvId) when Env =/= EnvId ->
    {error, wrong_environment};
check(#{iat := Iat, exp := Exp} = Claims, _EnvId) ->
    Now = erlang:system_time(second),
    if
        Exp =< Now -> {error, expired};
        Exp - Iat > ?MAX_TTL_SECONDS -> {error, lifetime_too_long};
        Iat > Now + ?CLOCK_SKEW_SECONDS -> {error, not_yet_valid};
        true -> caps(Claims)
    end.

%% An unknown class is refused rather than dropped: silently narrowing a
%% token's capabilities would turn a mint-side typo into a 403 somewhere far
%% away, with nothing saying why.
caps(#{caps := Caps} = Claims) ->
    Known = asobi_ops_caps:class_names(),
    Parsed = [C || C <- Caps, is_binary(C)],
    case length(Parsed) =:= length(Caps) andalso classes(Parsed, Known) of
        {ok, Classes} -> {ok, Claims#{caps => Classes}};
        _ -> {error, bad_caps}
    end.

classes(Names, Known) ->
    Classes = [
        Class
     || Name <- Names,
        Class <- Known,
        Name =:= atom_to_binary(Class, utf8)
    ],
    case length(Classes) =:= length(Names) of
        true -> {ok, Classes};
        false -> false
    end.

claims_json(#{env := Env, sub := Sub, caps := Caps, iat := Iat, exp := Exp}) ->
    #{
        ~"env" => Env,
        ~"sub" => Sub,
        ~"caps" => [atom_to_binary(C, utf8) || C <- Caps],
        ~"iat" => Iat,
        ~"exp" => Exp
    }.

%% Both halves or nothing: a node that knows its key but not which environment
%% it is cannot check `env`, and answering "close enough" there is how a token
%% for one tenant's environment gets honoured by another's.
config() ->
    case {application:get_env(asobi, ops_token_secret), application:get_env(asobi, env_id)} of
        %% A short secret is how a placeholder becomes a signing key. 32 bytes
        %% is what the provisioner generates; anything less is unconfigured.
        {{ok, Secret}, {ok, EnvId}} when
            is_binary(Secret), byte_size(Secret) >= 32, is_binary(EnvId), EnvId =/= ~""
        ->
            {ok, Secret, EnvId};
        _ ->
            error
    end.

encode(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

decode(Bin) ->
    try
        {ok, base64:decode(Bin, #{mode => urlsafe, padding => false})}
    catch
        _:_ -> error
    end.
