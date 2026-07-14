-module(asobi_player_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%% An invalid registration changeset must not pay the pbkdf2 cost - hashing an
%% input that will never be inserted is the unauthenticated-DoS lever (#157).
invalid_changeset_skips_hashing_test() ->
    CS = asobi_player:registration_changeset(#{}, #{
        ~"username" => ~"ab", ~"password" => ~"short"
    }),
    ?assertNot(CS#kura_changeset.valid),
    ?assertEqual(undefined, kura_changeset:get_change(CS, hashed_password)).

valid_changeset_hashes_password_test() ->
    CS = asobi_player:registration_changeset(#{}, #{
        ~"username" => ~"validname", ~"password" => ~"longenough1"
    }),
    ?assert(CS#kura_changeset.valid),
    ?assertMatch(H when is_binary(H), kura_changeset:get_change(CS, hashed_password)).
