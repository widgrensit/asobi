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

%% M3 (#169): metadata is unbounded jsonb; the changeset now caps the encoded
%% size so a PUT cannot persist an arbitrary blob under the 1 MiB body cap.
metadata_within_limit_passes_test() ->
    CS = asobi_player:update_changeset(#{}, #{~"metadata" => #{~"level" => 7}}),
    ?assert(CS#kura_changeset.valid).

metadata_over_limit_is_rejected_test() ->
    Big = #{~"blob" => binary:copy(~"x", 20000)},
    CS = asobi_player:update_changeset(#{}, #{~"metadata" => Big}),
    ?assertNot(CS#kura_changeset.valid).

metadata_absent_is_not_checked_test() ->
    %% A profile update that does not touch metadata must not fail the cap.
    CS = asobi_player:update_changeset(#{}, #{~"display_name" => ~"Alice"}),
    ?assert(CS#kura_changeset.valid).

metadata_at_the_limit_passes_test() ->
    %% ~16 KB of encodable content sits under the 16384-byte ceiling.
    Ok = #{~"blob" => binary:copy(~"x", 16000)},
    CS = asobi_player:update_changeset(#{}, #{~"metadata" => Ok}),
    ?assert(CS#kura_changeset.valid).
