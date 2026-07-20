-module(asobi_client_gate).
-moduledoc """
Pluggable pre-auth "is this traffic allowed in" seam on the anonymous
auth-create routes (asobi#158). Distinct from `asobi_auth_plugin` ("who is the
player"): a gate carries no player identity, and the narrow return type makes
identity leakage structurally impossible. An implementation runs before the
password KDF (asobi#157), so a denial never pays the pbkdf2 cost.

The input is a minimised `t:context/0`, not the raw request: at this point the
request map still carries the registration plaintext password, and a gate has
no need for it. The context exposes only what a traffic gate legitimately uses
(client IP, headers such as `cf-turnstile-response`, path, a challenge token),
so a verbose or buggy gate cannot log or forward credentials.

CAPTCHA/Turnstile/hCaptcha siteverify is the first consumer and ships outside
core (asobi_engine or a contrib plugin): a vendor round-trip must not couple
the public request path to an external SaaS.

Wired via `application:set_env(asobi, client_gate, Module)`; unset is a no-op.
""".

-type context() :: #{
    ip := binary(),
    headers := #{binary() => iodata()},
    path := binary(),
    token := binary()
}.

-export_type([context/0]).

-doc "Decide whether to admit a request: `skip` allows it, `{deny, Reason}` rejects it with a 403.".
-callback verify(context()) -> skip | {deny, Reason :: binary()}.
