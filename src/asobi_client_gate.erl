-module(asobi_client_gate).

%% Pre-auth "is this traffic allowed in" seam on the anonymous auth-create
%% routes (asobi#158). Distinct from asobi_auth_plugin ("who is the player"):
%% a gate carries NO player identity - the narrow return type is what makes
%% identity leakage structurally impossible. An implementation runs before the
%% password KDF (asobi#157), so a denial never pays the pbkdf2 cost.
%%
%% CAPTCHA/Turnstile/hCaptcha siteverify is the first consumer and ships
%% OUTSIDE core (asobi_engine or a contrib plugin) - a vendor round-trip must
%% not couple the public request path to an external SaaS.
%%
%% Wired via `application:set_env(asobi, client_gate, Module)`. Unset = no-op.

-callback verify(cowboy_req:req()) -> skip | {deny, Reason :: binary()}.
