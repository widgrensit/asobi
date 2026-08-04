-module(asobi_registration).

-include_lib("kernel/include/logger.hrl").

-export([mode/0, check/1, log_mode/0]).

-type mode() :: open | oauth_only | closed.
-type kind() :: password | oauth | guest.

-export_type([mode/0, kind/0]).

%% Registration posture has two layers, composed the way ADR 0006 composes the
%% mode registry: `registration` is the operator's key from sys.config and wins
%% whenever it is set, `script_registration` is what the loaded game declared
%% (asobi_lua#122 - an engine-hosted game has no sys.config to edit, so without
%% a script layer every hosted game silently ran `open`). A game bundle can
%% therefore choose a posture for a deployment that states none, and can never
%% widen one that does. See ADR 0002 for why `open` is the default and why an
%% unrecognised value falls to `open`. mode/0 is on the per-request create path
%% and stays silent; log_mode/0 emits the invalid-value signal once at boot.
-spec mode() -> mode().
mode() ->
    case classify() of
        {ok, Mode} -> Mode;
        {invalid, _} -> open
    end.

-spec classify() -> {ok, mode()} | {invalid, term()}.
classify() ->
    case application:get_env(asobi, registration) of
        undefined -> classify_value(application:get_env(asobi, script_registration, open));
        {ok, Value} -> classify_value(Value)
    end.

-spec classify_value(term()) -> {ok, mode()} | {invalid, term()}.
classify_value(open) -> {ok, open};
classify_value(oauth_only) -> {ok, oauth_only};
classify_value(closed) -> {ok, closed};
classify_value(Other) -> {invalid, Other}.

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
