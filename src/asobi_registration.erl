-module(asobi_registration).

-include_lib("kernel/include/logger.hrl").

-export([mode/0, check/1, log_mode/0]).

-type mode() :: open | oauth_only | closed.
-type kind() :: password | oauth | guest.

-export_type([mode/0, kind/0]).

%% Registration posture is an operator deployment decision, not a game
%% capability, so it reads from app env, not the game manifest. See ADR 0002
%% for why `open` is the default and why an unrecognised value falls to `open`.
%% mode/0 is on the per-request create path and stays silent; log_mode/0 emits
%% the invalid-value signal once at boot.
-spec mode() -> mode().
mode() ->
    case classify() of
        {ok, Mode} -> Mode;
        {invalid, _} -> open
    end.

-spec classify() -> {ok, mode()} | {invalid, term()}.
classify() ->
    case application:get_env(asobi, registration, open) of
        open -> {ok, open};
        oauth_only -> {ok, oauth_only};
        closed -> {ok, closed};
        Other -> {invalid, Other}
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

%% Announce the active mode once at boot. An unrecognised value is surfaced at
%% error level so an operator sees that their intended posture did not take
%% effect (it silently fails to `open`).
-spec log_mode() -> ok.
log_mode() ->
    case classify() of
        {ok, Mode} ->
            ?LOG_NOTICE(#{event => registration_mode, mode => Mode});
        {invalid, Value} ->
            ?LOG_ERROR(#{event => invalid_registration_mode, value => Value, using => open})
    end,
    ok.
