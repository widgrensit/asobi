-module(asobi_client_gate_plugin_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REGISTER, #{path => ~"/api/v1/auth/register"}).

gate_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun unset_gate_is_noop/0,
        fun non_auth_path_is_noop/0,
        fun deny_propagates/0,
        fun skip_passes/0,
        fun crash_fails_closed_by_default/0,
        fun crash_can_fail_open/0,
        fun bad_return_fails_closed/0,
        fun hang_fails_closed/0,
        fun false_disables_gate/0,
        fun applies_to_oauth_and_guest/0,
        fun folds_slash_variants/0
    ]}.

setup() ->
    application:unset_env(asobi, client_gate),
    application:unset_env(asobi, client_gate_on_error),
    application:unset_env(asobi, client_gate_timeout),
    meck:new(fake_gate, [non_strict, no_link]),
    ok.

cleanup(_) ->
    meck:unload(fake_gate),
    application:unset_env(asobi, client_gate),
    application:unset_env(asobi, client_gate_on_error),
    application:unset_env(asobi, client_gate_timeout),
    ok.

%% Default (unset) MUST be a no-op even on a gated path - bots, CI, headless
%% clients and asobi_register_bench all depend on it.
unset_gate_is_noop() ->
    ?assertEqual(pass, asobi_client_gate_plugin:decision(?REGISTER)).

non_auth_path_is_noop() ->
    set_gate(fun(_) -> {deny, ~"nope"} end),
    ?assertEqual(pass, asobi_client_gate_plugin:decision(#{path => ~"/api/v1/friends"})).

deny_propagates() ->
    set_gate(fun(_) -> {deny, ~"captcha_failed"} end),
    ?assertEqual({deny, ~"captcha_failed"}, asobi_client_gate_plugin:decision(?REGISTER)).

skip_passes() ->
    set_gate(fun(_) -> skip end),
    ?assertEqual(pass, asobi_client_gate_plugin:decision(?REGISTER)).

crash_fails_closed_by_default() ->
    set_gate(fun(_) -> error(vendor_down) end),
    ?assertEqual({deny, ~"client_gate_unavailable"}, asobi_client_gate_plugin:decision(?REGISTER)).

crash_can_fail_open() ->
    application:set_env(asobi, client_gate_on_error, skip),
    set_gate(fun(_) -> error(vendor_down) end),
    ?assertEqual(pass, asobi_client_gate_plugin:decision(?REGISTER)).

bad_return_fails_closed() ->
    set_gate(fun(_) -> ok end),
    ?assertEqual({deny, ~"client_gate_unavailable"}, asobi_client_gate_plugin:decision(?REGISTER)).

%% A hanging gate (the dominant siteverify failure mode) must not pin the
%% request - the deadline elapses and the gate fails closed by default.
hang_fails_closed() ->
    application:set_env(asobi, client_gate_timeout, 100),
    set_gate(fun(_) -> timer:sleep(infinity) end),
    ?assertEqual({deny, ~"client_gate_unavailable"}, asobi_client_gate_plugin:decision(?REGISTER)).

%% `client_gate` set to the atom false is a plausible "disable" typo; it must
%% be a clean no-op, not silently accepted as a bogus module.
false_disables_gate() ->
    application:set_env(asobi, client_gate, false),
    ?assertEqual(pass, asobi_client_gate_plugin:decision(?REGISTER)).

applies_to_oauth_and_guest() ->
    set_gate(fun(_) -> {deny, ~"x"} end),
    ?assertEqual({deny, ~"x"}, asobi_client_gate_plugin:decision(#{path => ~"/api/v1/auth/oauth"})),
    ?assertEqual({deny, ~"x"}, asobi_client_gate_plugin:decision(#{path => ~"/api/v1/auth/guest"})).

%% Slash-fold variants the router collapses onto a gated path must still gate,
%% mirroring the asobi#157 regression cases on select_limiter/1.
folds_slash_variants() ->
    set_gate(fun(_) -> {deny, ~"x"} end),
    [
        ?assertEqual({deny, ~"x"}, asobi_client_gate_plugin:decision(#{path => P}))
     || P <- [
            ~"/api/v1/auth//register",
            ~"/api/v1/auth/register/",
            ~"/api/v1//auth/register",
            ~"//api/v1/auth/guest"
        ]
    ].

set_gate(Fun) ->
    meck:expect(fake_gate, verify, Fun),
    application:set_env(asobi, client_gate, fake_gate).
