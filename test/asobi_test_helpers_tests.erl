-module(asobi_test_helpers_tests).

-include_lib("eunit/include/eunit.hrl").

%% Shape only. The property that actually matters for asobi#357 - a fixture id
%% no *other run* will produce - cannot be asserted from inside one run, and a
%% test that spawns peer nodes to show erlang:unique_integer/1 colliding is
%% flaky in both directions (fresh instances usually, not always, hand out the
%% same counter values). The regression evidence is running a suite twice
%% against the same database.
unique_id_keeps_the_prefix_test() ->
    ?assertMatch(<<"txn_", _/binary>>, asobi_test_helpers:unique_id(~"txn")).

unique_id_draws_from_a_large_space_test() ->
    Ids = [asobi_test_helpers:unique_id(~"x") || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Ids))),
    %% 8 random bytes, hex-encoded: the suffix has to be wide enough that two
    %% runs colliding is not a thing that happens.
    ?assertEqual(16, byte_size(id_suffix(Ids))).

%% `unique_id/1` is spec'd `-> binary()`, but a list comprehension erases the
%% element type, so the ids come back `term()`. Narrow once rather than
%% indexing an unknown shape.
-spec id_suffix([term()]) -> binary().
id_suffix([Id | _]) when is_binary(Id) ->
    case binary:split(Id, ~"_") of
        [_Prefix, Suffix] when is_binary(Suffix) -> Suffix
    end.

%% Five test modules depend on these, and `who/1` already regressed once inside
%% the PR that added it - caught by review rather than by a test. That is what
%% these pin.
session_helpers_test_() ->
    {setup, fun ensure_pg/0, fun(_) -> ok end, [
        {"with_session releases on a raising body", fun with_session_releases_on_raise/0},
        {"release_session leaves the group before it returns", fun release_is_synchronous/0},
        {"release_session drains what it forwarded", fun release_drains/0},
        {"assert_no_session passes on an empty group", fun assert_no_session_empty/0},
        {"assert_no_session names the calling module", fun assert_no_session_names_caller/0}
    ]}.

ensure_pg() ->
    case whereis(nova_scope) of
        undefined ->
            {ok, _} = pg:start(nova_scope),
            ok;
        _ ->
            ok
    end.

%% The whole thesis: the release is structural, so it happens on the path a
%% failing assertion takes.
with_session_releases_on_raise() ->
    Id = asobi_test_helpers:unique_id(~"wsr"),
    ?assertError(boom, asobi_test_helpers:with_session(Id, fun() -> error(boom) end)),
    ?assertEqual([], pg:get_members(nova_scope, {player, Id})).

%% No sleep: `pg:leave/3` is a call, which is why it replaced `exit/2` here - a
%% killed pid lingers in the group long enough for a reader to get a dead one.
release_is_synchronous() ->
    Id = asobi_test_helpers:unique_id(~"rsl"),
    Pid = asobi_test_helpers:fake_session(Id),
    ?assertEqual([Pid], pg:get_members(nova_scope, {player, Id})),
    ok = asobi_test_helpers:release_session(Id, Pid),
    ?assertEqual([], pg:get_members(nova_scope, {player, Id})).

release_drains() ->
    Id = asobi_test_helpers:unique_id(~"rsd"),
    Pid = asobi_test_helpers:fake_session(Id, self()),
    Pid ! one,
    Pid ! two,
    timer:sleep(50),
    ok = asobi_test_helpers:release_session(Id, Pid),
    receive
        {Id, _} = Stale -> erlang:error({undrained, Stale})
    after 0 -> ok
    end.

assert_no_session_empty() ->
    Id = asobi_test_helpers:unique_id(~"ans"),
    ?assertEqual(ok, asobi_test_helpers:assert_no_session(Id)).

%% Regression pin: `who/1` must name the module that SPAWNED the leaker. When
%% fake_session was extracted into asobi_test_helpers, `current_function` began
%% naming the shared helper for every leaker - the one answer this cannot use.
%% The sleep is required: the label is applied by the spawned process.
assert_no_session_names_caller() ->
    Id = asobi_test_helpers:unique_id(~"leak"),
    Pid = asobi_test_helpers:fake_session(Id),
    try
        timer:sleep(50),
        Reason =
            try asobi_test_helpers:assert_no_session(Id) of
                ok -> no_error
            catch
                error:R -> R
            end,
        ?assertMatch({session_already_registered, Id, [_ | _]}, Reason),
        {session_already_registered, _, [{_, Label, _} | _]} = Reason,
        ?assertMatch({fake_session, Id, {?MODULE, _, _, _}}, Label)
    after
        asobi_test_helpers:release_session(Id, Pid)
    end.
