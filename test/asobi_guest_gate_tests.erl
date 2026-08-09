-module(asobi_guest_gate_tests).

-include_lib("eunit/include/eunit.hrl").

%% asobi#419: the three ways a guest create is refused used to share one code
%% (`guest.capacity_reached`) and one warning that named none of them, so a
%% field report could not be diagnosed from the node - and the branch a real
%% deployment is most likely to hit, a repo error while counting, was the one
%% reported as "the deployment is full". Pin each branch to its own code, and
%% pin the counts into the log report: the numbers are what tell an operator
%% whether the ceiling is anywhere near.

gate_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun under_the_cap_allows/0,
        fun infinity_allows_at_any_count/0,
        fun at_the_cap_is_capacity_reached/0,
        fun over_the_cap_is_capacity_reached/0,
        fun an_uncountable_table_is_unavailable_not_full/0,
        fun capacity_denial_reports_the_numbers/0,
        fun a_zero_cap_denies_an_empty_table/0
    ]}.

setup() ->
    application:unset_env(asobi, guest_unlinked_cap),
    ok.

cleanup(_) ->
    application:unset_env(asobi, guest_unlinked_cap),
    ok.

under_the_cap_allows() ->
    ?assertEqual(allow, asobi_guest_controller:cap_gate(99, 100)).

infinity_allows_at_any_count() ->
    ?assertEqual(allow, asobi_guest_controller:cap_gate(10_000_000, infinity)),
    %% Including when the count itself is unavailable: with no ceiling there is
    %% nothing the count would have decided.
    ?assertEqual(allow, asobi_guest_controller:cap_gate(unknown, infinity)).

at_the_cap_is_capacity_reached() ->
    ?assertMatch(
        {deny, #{reason := unlinked_cap_reached}}, asobi_guest_controller:cap_gate(100, 100)
    ).

over_the_cap_is_capacity_reached() ->
    ?assertMatch(
        {deny, #{reason := unlinked_cap_reached}}, asobi_guest_controller:cap_gate(101, 100)
    ).

%% The regression this whole change exists for. A failed COUNT means the node
%% could not find out, which is not the same answer as being full, and telling
%% an operator the second sends them looking for a ceiling nowhere near reached.
%% Still a denial - fail closed - but under its own code.
an_uncountable_table_is_unavailable_not_full() ->
    ?assertMatch(
        {deny, #{reason := unlinked_count_unavailable}},
        asobi_guest_controller:cap_gate(unknown, 100000)
    ).

%% The log report is the diagnosis. Without count and cap in it an operator
%% still cannot tell a full deployment from a misconfigured one.
capacity_denial_reports_the_numbers() ->
    {deny, Report} = asobi_guest_controller:cap_gate(250, 200),
    ?assertMatch(#{reason := unlinked_cap_reached, count := 250, cap := 200}, Report),
    {deny, UnknownReport} = asobi_guest_controller:cap_gate(unknown, 200),
    ?assertMatch(#{reason := unlinked_count_unavailable, cap := 200}, UnknownReport).

a_zero_cap_denies_an_empty_table() ->
    ?assertMatch({deny, #{reason := unlinked_cap_reached}}, asobi_guest_controller:cap_gate(0, 0)).
