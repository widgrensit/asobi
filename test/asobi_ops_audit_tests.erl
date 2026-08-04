-module(asobi_ops_audit_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

audit_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun clean_outcome_is_ok/0,
        fun partial_outcome_is_not_a_success/0,
        fun total_failure_is_not_partial/0,
        fun error_outcome_records_its_reason/0,
        fun unattested_actor_is_recorded_as_unattested/0,
        fun attested_actor_is_recorded_as_attested/0,
        fun target_is_recorded_when_there_is_one/0,
        fun absent_target_writes_no_target_columns/0,
        fun mutation_records_the_operations_own_outcome/0,
        fun crashing_mutation_is_audited_and_re_raised/0,
        fun failed_audit_write_does_not_fail_the_operation/0,
        fun crashing_audit_write_does_not_fail_the_operation/0,
        fun failure_details_are_bounded/0,
        fun oversized_reason_is_truncated/0
    ]}.

setup() ->
    meck:new(asobi_repo, [passthrough]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    ok.

cleanup(_) ->
    catch meck:unload(asobi_repo),
    ok.

actor() ->
    #{
        id => ~"static_secret",
        display => ~"operator",
        source => static_secret,
        caps => [read, player_data, config],
        attested => false
    }.

%% The changes map of the single changeset the call handed to the repo.
row() ->
    [{_, {asobi_repo, insert, [#kura_changeset{changes = Changes}]}, _}] = meck:history(asobi_repo),
    Changes.

record(Outcome) ->
    record(actor(), undefined, Outcome).

record(Actor, Target, Outcome) ->
    meck:reset(asobi_repo),
    ok = asobi_ops_audit:record(Actor, ~"notifications.broadcast", Target, Outcome),
    row().

clean_outcome_is_ok() ->
    Row = record({ok, [~"p1", ~"p2"], []}),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(2, maps:get(succeeded_count, Row)),
    ?assertEqual(0, maps:get(failed_count, Row)),
    ?assertEqual(#{}, maps:get(details, Row)).

%% The defect this whole contract exists for: a send that reached some of its
%% recipients must not be stored as a success.
partial_outcome_is_not_a_success() ->
    Row = record({ok, [~"p1"], [{~"p2", timeout}]}),
    ?assertEqual(~"partial", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(1, maps:get(failed_count, Row)),
    ?assertMatch(
        #{failures := [#{subject := ~"p2", reason := ~"timeout"}]},
        maps:get(details, Row)
    ).

total_failure_is_not_partial() ->
    Row = record({ok, [], [{~"p1", timeout}, {~"p2", timeout}]}),
    ?assertEqual(~"error", maps:get(outcome, Row)),
    ?assertEqual(0, maps:get(succeeded_count, Row)),
    ?assertEqual(2, maps:get(failed_count, Row)).

error_outcome_records_its_reason() ->
    Row = record({error, invalid_subject}),
    ?assertEqual(~"error", maps:get(outcome, Row)),
    ?assertEqual(#{reason => ~"invalid_subject"}, maps:get(details, Row)).

%% An actor named only by the `x-asobi-operator` label is self-declared. The
%% row has to say so, or every stored name implies a verification that never
%% happened.
unattested_actor_is_recorded_as_unattested() ->
    Row = record(actor(), undefined, {ok, [~"p1"], []}),
    ?assertEqual(~"static_secret", maps:get(actor_id, Row)),
    ?assertEqual(~"operator", maps:get(actor_display, Row)),
    ?assertEqual(~"static_secret", maps:get(actor_source, Row)),
    ?assertEqual(false, maps:get(actor_attested, Row)).

attested_actor_is_recorded_as_attested() ->
    Cloud = (actor())#{
        id => ~"user_7",
        display => ~"kaito",
        source => cloud,
        attested => true
    },
    Row = record(Cloud, undefined, {ok, [~"p1"], []}),
    ?assertEqual(~"user_7", maps:get(actor_id, Row)),
    ?assertEqual(~"cloud", maps:get(actor_source, Row)),
    ?assertEqual(true, maps:get(actor_attested, Row)).

target_is_recorded_when_there_is_one() ->
    Row = record(actor(), {~"player", ~"p1"}, {ok, [~"p1"], []}),
    ?assertEqual(~"player", maps:get(target_type, Row)),
    ?assertEqual(~"p1", maps:get(target_id, Row)).

%% A fan-out has a subject type but no single subject. The column is absent
%% rather than carrying an atom the cast would reject.
absent_target_writes_no_target_columns() ->
    Row = record(actor(), undefined, {ok, [~"p1"], []}),
    ?assertNot(maps:is_key(target_type, Row)),
    ?assertNot(maps:is_key(target_id, Row)).

mutation_records_the_operations_own_outcome() ->
    meck:reset(asobi_repo),
    Outcome = {ok, [~"p1"], [{~"p2", db_down}]},
    ?assertEqual(
        Outcome,
        asobi_ops_audit:mutation(actor(), ~"notifications.broadcast", undefined, fun() ->
            Outcome
        end)
    ),
    ?assertEqual(~"partial", maps:get(outcome, row())).

crashing_mutation_is_audited_and_re_raised() ->
    meck:reset(asobi_repo),
    ?assertError(
        badarg,
        asobi_ops_audit:mutation(actor(), ~"notifications.broadcast", undefined, fun() ->
            erlang:error(badarg)
        end)
    ),
    Row = row(),
    ?assertEqual(~"error", maps:get(outcome, Row)),
    ?assertMatch(#{reason := <<"{error,badarg}">>}, maps:get(details, Row)).

%% The mutation already happened. Refusing the caller cannot undo it and only
%% invites a retry that applies it twice.
failed_audit_write_does_not_fail_the_operation() ->
    meck:expect(asobi_repo, insert, fun(_CS) -> {error, connection_closed} end),
    try
        Outcome = {ok, [~"p1"], []},
        ?assertEqual(
            Outcome,
            asobi_ops_audit:mutation(actor(), ~"notifications.broadcast", undefined, fun() ->
                Outcome
            end)
        )
    after
        meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end)
    end.

%% Same policy, harsher failure: the audit path must not be able to turn a
%% completed mutation into a crash the caller retries.
crashing_audit_write_does_not_fail_the_operation() ->
    meck:expect(asobi_repo, insert, fun(_CS) -> erlang:error(pool_gone) end),
    try
        Outcome = {ok, [~"p1"], []},
        ?assertEqual(
            Outcome,
            asobi_ops_audit:mutation(actor(), ~"notifications.broadcast", undefined, fun() ->
                Outcome
            end)
        )
    after
        meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end)
    end.

failure_details_are_bounded() ->
    Failed = [{integer_to_binary(N), timeout} || N <- lists:seq(1, 60)],
    Row = record({ok, [], Failed}),
    #{failures := Failures, failures_omitted := Omitted} = maps:get(details, Row),
    ?assertEqual(50, length(Failures)),
    ?assertEqual(10, Omitted),
    ?assertEqual(60, maps:get(failed_count, Row)).

oversized_reason_is_truncated() ->
    Row = record({error, binary:copy(~"x", 500)}),
    #{reason := Reason} = maps:get(details, Row),
    ?assertEqual(203, byte_size(Reason)),
    ?assertEqual(~"...", binary:part(Reason, byte_size(Reason) - 3, 3)).
