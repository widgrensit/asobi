-module(asobi_ops_audit_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    clean_broadcast_is_stored_as_ok/1,
    half_failed_broadcast_is_stored_as_partial/1,
    row_carries_the_unattested_actor/1
]).

all() -> [{group, ops_audit}].

groups() ->
    [
        {ops_audit, [], [
            clean_broadcast_is_stored_as_ok,
            half_failed_broadcast_is_stored_as_partial,
            row_carries_the_unattested_actor
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    Username = asobi_test_helpers:unique_username(~"audit_p1"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config0
    ),
    #{~"player_id" := PlayerId} = nova_test:json(Resp),
    [{player_id, PlayerId} | Config0].

end_per_suite(Config) ->
    Config.

%% A display name unique to the calling test, so the row it wrote is the row
%% read back even when other suites are broadcasting on the same database.
actor(Display) ->
    #{
        id => ~"static_secret",
        display => Display,
        source => static_secret,
        caps => [read, player_data, config],
        attested => false
    }.

label(Case) ->
    <<(atom_to_binary(Case))/binary, "_", (asobi_id:rand_suffix(6))/binary>>.

row(Display) ->
    Query = kura_query:where(kura_query:from(asobi_ops_audit_entry), {actor_display, '=', Display}),
    {ok, [Row]} = asobi_repo:all(Query),
    Row.

player_id(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    PlayerId.

clean_broadcast_is_stored_as_ok(Config) ->
    Display = label(?FUNCTION_NAME),
    {ok, [_], []} = asobi_ops_notifications:broadcast(
        actor(Display), ~"system", ~"Maintenance", #{}, [player_id(Config)]
    ),
    Row = row(Display),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(0, maps:get(failed_count, Row)),
    ?assertEqual(~"notifications.broadcast", maps:get(action, Row)),
    Config.

%% The whole reason for the widened contract, against a real database: the
%% unknown recipient fails the notifications foreign key, and the row has to
%% say so rather than reporting the one delivery that worked as a success.
half_failed_broadcast_is_stored_as_partial(Config) ->
    Display = label(?FUNCTION_NAME),
    Unknown = asobi_id:generate(),
    {ok, Succeeded, Failed} = asobi_ops_notifications:broadcast(
        actor(Display), ~"system", ~"Maintenance", #{}, [player_id(Config), Unknown]
    ),
    ?assertEqual([player_id(Config)], Succeeded),
    ?assertMatch([{Unknown, _Reason}], Failed),
    Row = row(Display),
    ?assertEqual(~"partial", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(1, maps:get(failed_count, Row)),
    #{~"failures" := [#{~"subject" := Subject}]} = maps:get(details, Row),
    ?assertEqual(Unknown, Subject),
    Config.

row_carries_the_unattested_actor(Config) ->
    Display = label(?FUNCTION_NAME),
    {ok, _, _} = asobi_ops_notifications:broadcast(
        actor(Display), ~"system", ~"Maintenance", #{}, [player_id(Config)]
    ),
    Row = row(Display),
    ?assertEqual(Display, maps:get(actor_display, Row)),
    ?assertEqual(~"static_secret", maps:get(actor_id, Row)),
    ?assertEqual(~"static_secret", maps:get(actor_source, Row)),
    ?assertEqual(false, maps:get(actor_attested, Row)),
    ?assertEqual(~"player", maps:get(target_type, Row)),
    Config.
