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
        fun applies_to_oauth_and_guest/0
    ]}.

setup() ->
    application:unset_env(asobi, client_gate),
    application:unset_env(asobi, client_gate_on_error),
    meck:new(fake_gate, [non_strict, no_link]),
    ok.

cleanup(_) ->
    meck:unload(fake_gate),
    application:unset_env(asobi, client_gate),
    application:unset_env(asobi, client_gate_on_error),
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

applies_to_oauth_and_guest() ->
    set_gate(fun(_) -> {deny, ~"x"} end),
    ?assertEqual({deny, ~"x"}, asobi_client_gate_plugin:decision(#{path => ~"/api/v1/auth/oauth"})),
    ?assertEqual({deny, ~"x"}, asobi_client_gate_plugin:decision(#{path => ~"/api/v1/auth/guest"})).

set_gate(Fun) ->
    meck:expect(fake_gate, verify, Fun),
    application:set_env(asobi, client_gate, fake_gate).
