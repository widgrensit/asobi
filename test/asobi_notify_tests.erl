-module(asobi_notify_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

send_many_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun every_recipient_succeeds/0,
        fun partial_failure_is_reported_not_dropped/0,
        fun a_failure_does_not_abandon_the_rest/0,
        fun only_reachable_recipients_are_pushed/0
    ]}.

setup() ->
    meck:new(asobi_repo, [passthrough]),
    meck:new(asobi_presence, [passthrough]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Message) -> ok end),
    ok.

cleanup(_) ->
    catch meck:unload(asobi_repo),
    catch meck:unload(asobi_presence),
    ok.

%% `player_id` is a uuid column, so the changeset only carries it when the id
%% really is one.
players() ->
    [asobi_id:generate() || _ <- lists:seq(1, 3)].

%% Fail the insert for the listed player ids, succeed for the rest.
expect_inserts_failing_for(Failing) ->
    meck:expect(asobi_repo, insert, fun(#kura_changeset{changes = Changes}) ->
        PlayerId = maps:get(player_id, Changes),
        case lists:member(PlayerId, Failing) of
            true -> {error, connection_closed};
            false -> {ok, Changes#{id => PlayerId}}
        end
    end).

send_many(Ids) ->
    asobi_notify:send_many(Ids, ~"system", ~"Maintenance", #{}).

every_recipient_succeeds() ->
    [P1, P2, _P3] = players(),
    expect_inserts_failing_for([]),
    ?assertEqual({ok, [P1, P2], []}, send_many([P1, P2])).

%% The old shape returned only the survivors, so the caller could not tell a
%% half-delivered broadcast from a complete one.
partial_failure_is_reported_not_dropped() ->
    [P1, P2, P3] = players(),
    expect_inserts_failing_for([P2]),
    ?assertEqual(
        {ok, [P1, P3], [{P2, connection_closed}]},
        send_many([P1, P2, P3])
    ).

a_failure_does_not_abandon_the_rest() ->
    [P1, P2, P3] = players(),
    expect_inserts_failing_for([P1]),
    meck:reset(asobi_repo),
    {ok, Succeeded, Failed} = send_many([P1, P2, P3]),
    ?assertEqual(3, length(Succeeded) + length(Failed)),
    ?assertEqual(3, length(meck:history(asobi_repo))).

only_reachable_recipients_are_pushed() ->
    [P1, P2, P3] = players(),
    expect_inserts_failing_for([P2]),
    meck:reset(asobi_presence),
    {ok, _Succeeded, _Failed} = send_many([P1, P2, P3]),
    Pushed = [
        PlayerId
     || {_, {asobi_presence, send, [PlayerId, _]}, _} <- meck:history(asobi_presence)
    ],
    ?assertEqual([P1, P3], Pushed).
