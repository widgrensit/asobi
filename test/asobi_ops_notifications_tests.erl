-module(asobi_ops_notifications_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

broadcast_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun half_delivered_broadcast_is_audited_as_partial/0,
        fun complete_broadcast_is_audited_as_ok/0,
        fun broadcast_row_carries_the_actor/0,
        fun outcome_reaches_the_caller_unchanged/0,
        fun an_actor_without_player_data_sends_nothing/0
    ]}.

setup() ->
    meck:new(asobi_repo, [passthrough]),
    meck:new(asobi_notify, [passthrough]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    ok.

cleanup(_) ->
    catch meck:unload(asobi_repo),
    catch meck:unload(asobi_notify),
    ok.

actor() ->
    #{
        id => ~"static_secret",
        display => ~"kaito",
        source => static_secret,
        caps => [read, player_data, config],
        attested => false
    }.

expect_send_many(Outcome) ->
    meck:expect(asobi_notify, send_many, fun(_Ids, _Type, _Subject, _Content) -> Outcome end),
    meck:reset(asobi_repo),
    meck:reset(asobi_notify).

broadcast() ->
    asobi_ops_notifications:broadcast(actor(), ~"system", ~"Maintenance", #{}, [~"p1", ~"p2"]).

row() ->
    [{_, {asobi_repo, insert, [#kura_changeset{changes = Changes}]}, _}] = meck:history(asobi_repo),
    Changes.

%% The bug the widened contract exists to close: the console used to hand its
%% logger a hand-built `{ok, SentTo}` built from the survivors alone.
half_delivered_broadcast_is_audited_as_partial() ->
    expect_send_many({ok, [~"p1"], [{~"p2", connection_closed}]}),
    _ = broadcast(),
    Row = row(),
    ?assertEqual(~"partial", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(1, maps:get(failed_count, Row)),
    ?assertEqual(~"notifications.broadcast", maps:get(action, Row)).

complete_broadcast_is_audited_as_ok() ->
    expect_send_many({ok, [~"p1", ~"p2"], []}),
    _ = broadcast(),
    ?assertEqual(~"ok", maps:get(outcome, row())).

broadcast_row_carries_the_actor() ->
    expect_send_many({ok, [~"p1", ~"p2"], []}),
    _ = broadcast(),
    Row = row(),
    ?assertEqual(~"kaito", maps:get(actor_display, Row)),
    ?assertEqual(~"static_secret", maps:get(actor_source, Row)),
    ?assertEqual(false, maps:get(actor_attested, Row)),
    ?assertEqual(~"player", maps:get(target_type, Row)).

outcome_reaches_the_caller_unchanged() ->
    Outcome = {ok, [~"p1"], [{~"p2", connection_closed}]},
    expect_send_many(Outcome),
    ?assertEqual(Outcome, broadcast()).

%% There is no route in front of this, so the capability check has to be here
%% or an in-process caller has none at all. The refusal is audited too - a
%% denied attempt is worth a row.
an_actor_without_player_data_sends_nothing() ->
    expect_send_many({ok, [~"p1", ~"p2"], []}),
    ReadOnly = (actor())#{caps => [read]},
    ?assertEqual(
        {error, forbidden},
        asobi_ops_notifications:broadcast(ReadOnly, ~"system", ~"Maintenance", #{}, [~"p1"])
    ),
    ?assertNot(meck:called(asobi_notify, send_many, '_')),
    ?assertEqual(~"error", maps:get(outcome, row())).
