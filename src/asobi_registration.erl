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
        oauth_only ->
            oauth_only;
        closed ->
            closed;
        %% `open` and any unrecognised value both resolve to open. mode/0 is on
        %% the per-request create path, so it stays silent - the invalid-value
        %% signal is emitted once at boot by log_mode/0, not per request (a
        %% per-request warning would let a signup flood amplify into log churn).
        _ ->
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

%% Announce the active mode once at boot. An unrecognised configured value is
%% surfaced at error level here - it fails to `open` (locking real players out
%% on a typo is worse than the abuse a mode prevents), so the operator must be
%% able to see at a glance that their intended posture did not take effect.
-spec log_mode() -> ok.
log_mode() ->
    case application:get_env(asobi, registration, open) of
        M when M =:= open; M =:= oauth_only; M =:= closed ->
            ?LOG_NOTICE(#{event => registration_mode, mode => M});
        Other ->
            ?LOG_ERROR(#{event => invalid_registration_mode, value => Other, using => open})
    end,
    ok.
