-module(asobi_group_roles_tests).
-include_lib("eunit/include/eunit.hrl").

rank_hierarchy_test() ->
    ?assert(asobi_group_roles:rank(~"owner") > asobi_group_roles:rank(~"admin")),
    ?assert(asobi_group_roles:rank(~"admin") > asobi_group_roles:rank(~"moderator")),
    ?assert(asobi_group_roles:rank(~"moderator") > asobi_group_roles:rank(~"member")),
    ?assertEqual(0, asobi_group_roles:rank(~"unknown")).

valid_role_test() ->
    ?assert(asobi_group_roles:valid_role(~"owner")),
    ?assert(asobi_group_roles:valid_role(~"admin")),
    ?assert(asobi_group_roles:valid_role(~"moderator")),
    ?assert(asobi_group_roles:valid_role(~"member")),
    ?assertNot(asobi_group_roles:valid_role(~"superuser")),
    ?assertNot(asobi_group_roles:valid_role(~"")).

can_manage_test() ->
    ?assert(asobi_group_roles:can_manage(~"owner", ~"admin")),
    ?assert(asobi_group_roles:can_manage(~"owner", ~"member")),
    ?assert(asobi_group_roles:can_manage(~"admin", ~"moderator")),
    ?assert(asobi_group_roles:can_manage(~"admin", ~"member")),
    ?assertNot(asobi_group_roles:can_manage(~"admin", ~"admin")),
    ?assertNot(asobi_group_roles:can_manage(~"member", ~"member")),
    ?assertNot(asobi_group_roles:can_manage(~"moderator", ~"admin")).

can_kick_test() ->
    ?assert(asobi_group_roles:can_kick(~"owner", ~"admin")),
    ?assert(asobi_group_roles:can_kick(~"owner", ~"member")),
    ?assert(asobi_group_roles:can_kick(~"admin", ~"moderator")),
    ?assert(asobi_group_roles:can_kick(~"moderator", ~"member")),
    ?assertNot(asobi_group_roles:can_kick(~"member", ~"member")),
    ?assertNot(asobi_group_roles:can_kick(~"moderator", ~"moderator")),
    ?assertNot(asobi_group_roles:can_kick(~"moderator", ~"admin")).

can_promote_test() ->
    ?assert(asobi_group_roles:can_promote(~"owner", ~"member", ~"admin")),
    ?assert(asobi_group_roles:can_promote(~"owner", ~"member", ~"moderator")),
    ?assert(asobi_group_roles:can_promote(~"admin", ~"member", ~"moderator")),
    ?assertNot(asobi_group_roles:can_promote(~"admin", ~"member", ~"admin")),
    ?assertNot(asobi_group_roles:can_promote(~"admin", ~"member", ~"owner")),
    ?assertNot(asobi_group_roles:can_promote(~"moderator", ~"member", ~"moderator")),
    ?assertNot(asobi_group_roles:can_promote(~"member", ~"member", ~"moderator")).

can_update_group_test() ->
    ?assert(asobi_group_roles:can_update_group(~"owner")),
    ?assert(asobi_group_roles:can_update_group(~"admin")),
    ?assertNot(asobi_group_roles:can_update_group(~"moderator")),
    ?assertNot(asobi_group_roles:can_update_group(~"member")).
