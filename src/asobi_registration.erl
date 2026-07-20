-module(asobi_registration).

-include_lib("kernel/include/logger.hrl").

-export([mode/0, check/1, log_mode/0]).

-type mode() :: open | oauth_only | closed.
-type kind() :: password | oauth | guest.

-export_type([mode/0, kind/0]).

%% Registration posture is an operator deployment decision, not a game
%% capability (ADR 0002), so it reads from app env rather than the game
%% manifest. Default `open` MUST hold: an oauth_only/closed default breaks the
%% shipped headless quickstarts and asobi_register_bench, and locking out real
%% players is worse than the abuse a cost-bound prevents. Any unrecognised
%% value falls back to `open` and warns.
-spec mode() -> mode().
mode() ->
    case application:get_env(asobi, registration, open) of
        open ->
            open;
        oauth_only ->
            oauth_only;
        closed ->
            closed;
        Other ->
            ?LOG_WARNING(#{event => invalid_registration_mode, value => Other, using => open}),
            open
    end.

%% Whether a create path may mint a new player. `closed` freezes every public
%% signup path (password, oauth-first-time, guest-first-time); `oauth_only`
%% blocks only password registration and leaves guest signup to its own
%% `guest_auth` toggle (asobi#158).
-spec check(kind()) -> ok | {deny, binary()}.
check(Kind) -> check(mode(), Kind).

-spec check(mode(), kind()) -> ok | {deny, binary()}.
check(open, _) -> ok;
check(closed, _) -> {deny, ~"registration_closed"};
check(oauth_only, password) -> {deny, ~"password_registration_disabled"};
check(oauth_only, oauth) -> ok;
check(oauth_only, guest) -> ok.

-spec log_mode() -> ok.
log_mode() ->
    ?LOG_NOTICE(#{event => registration_mode, mode => mode()}),
    ok.
