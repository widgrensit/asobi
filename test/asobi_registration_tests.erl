-module(asobi_registration_tests).

-include_lib("eunit/include/eunit.hrl").

registration_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun defaults_to_open/0,
        fun invalid_value_falls_back_to_open/0,
        fun open_allows_every_path/0,
        fun closed_denies_every_path/0,
        fun oauth_only_denies_password_only/0,
        fun register_controller_denies_before_db/0,
        fun guest_controller_denies_before_capacity/0,
        fun log_mode_tolerates_valid_and_invalid/0
    ]}.

setup() ->
    application:unset_env(asobi, registration),
    ok.

cleanup(_) ->
    application:unset_env(asobi, registration),
    ok.

defaults_to_open() ->
    ?assertEqual(open, asobi_registration:mode()).

invalid_value_falls_back_to_open() ->
    application:set_env(asobi, registration, banana),
    ?assertEqual(open, asobi_registration:mode()),
    ?assertEqual(ok, asobi_registration:check(password)).

open_allows_every_path() ->
    application:set_env(asobi, registration, open),
    [?assertEqual(ok, asobi_registration:check(K)) || K <- [password, oauth, guest]].

closed_denies_every_path() ->
    application:set_env(asobi, registration, closed),
    [
        ?assertEqual({deny, ~"registration_closed"}, asobi_registration:check(K))
     || K <- [password, oauth, guest]
    ].

oauth_only_denies_password_only() ->
    application:set_env(asobi, registration, oauth_only),
    ?assertEqual({deny, ~"password_registration_disabled"}, asobi_registration:check(password)),
    ?assertEqual(ok, asobi_registration:check(oauth)),
    ?assertEqual(ok, asobi_registration:check(guest)).

%% closed must reject a well-formed password registration at the controller
%% before any account/DB work - the check is the first thing register/1 does.
register_controller_denies_before_db() ->
    application:set_env(asobi, registration, closed),
    Req = #{json => #{~"username" => ~"validname", ~"password" => ~"longenough1"}},
    ?assertEqual(
        {json, 403, #{}, #{error => ~"registration_closed"}},
        asobi_auth_controller:register(Req)
    ).

%% closed must reject guest creation at the controller before the capacity
%% check / DB, and it must be wired to check(guest) - not a mis-wired kind.
guest_controller_denies_before_capacity() ->
    application:set_env(asobi, registration, closed),
    ?assertEqual(
        {json, 403, #{}, #{error => ~"registration_closed"}},
        asobi_guest_controller:create(~"device-abc", ~"secret-abc")
    ).

%% The boot announcer must not crash on either a valid mode or a typo (the
%% typo takes the error-level branch).
log_mode_tolerates_valid_and_invalid() ->
    application:set_env(asobi, registration, oauth_only),
    ?assertEqual(ok, asobi_registration:log_mode()),
    application:set_env(asobi, registration, banana),
    ?assertEqual(ok, asobi_registration:log_mode()).
