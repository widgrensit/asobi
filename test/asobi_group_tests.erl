-module(asobi_group_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

valid_changeset_test() ->
    CS = asobi_group:changeset(#{}, #{
        ~"name" => ~"raid team", ~"creator_id" => asobi_id:generate()
    }),
    ?assert(CS#kura_changeset.valid).

%% asobi#216: metadata is unbounded jsonb and changeset/2 casts it - the
%% same lever #169 closed for asobi_player, applied here.
metadata_within_limit_passes_test() ->
    CS = asobi_group:changeset(#{}, #{
        ~"name" => ~"raid team",
        ~"creator_id" => asobi_id:generate(),
        ~"metadata" => #{~"tag" => ~"eu"}
    }),
    ?assert(CS#kura_changeset.valid).

metadata_over_limit_is_rejected_test() ->
    Big = #{~"blob" => binary:copy(~"x", 20000)},
    CS = asobi_group:changeset(#{}, #{
        ~"name" => ~"raid team", ~"creator_id" => asobi_id:generate(), ~"metadata" => Big
    }),
    ?assertNot(CS#kura_changeset.valid).

metadata_absent_is_not_checked_test() ->
    CS = asobi_group:changeset(#{}, #{
        ~"name" => ~"raid team", ~"creator_id" => asobi_id:generate()
    }),
    ?assert(CS#kura_changeset.valid).

%% A small-but-unencodable value must fail for the right reason, not be
%% misreported as oversized - shrinking it wouldn't fix the actual problem.
metadata_not_encodable_is_rejected_test() ->
    Bad = #{~"blob" => {tuple, ~"json:encode/1 can't serialize this"}},
    CS = asobi_group:changeset(#{}, #{
        ~"name" => ~"raid team", ~"creator_id" => asobi_id:generate(), ~"metadata" => Bad
    }),
    ?assertNot(CS#kura_changeset.valid),
    ?assertEqual(
        [~"is not encodable"], proplists:get_all_values(metadata, CS#kura_changeset.errors)
    ).
