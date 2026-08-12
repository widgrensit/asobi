-module(asobi_ops_audit_SUITE).

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([
    clean_broadcast_is_stored_as_ok/1,
    half_failed_broadcast_is_stored_as_partial/1,
    row_carries_the_unattested_actor/1,
    successful_extension_mutation_is_stored_as_ok/1,
    failed_extension_mutation_is_stored_as_error/1
]).

all() -> [{group, ops_audit}, {group, extension_ops}].

groups() ->
    [
        {ops_audit, [], [
            clean_broadcast_is_stored_as_ok,
            half_failed_broadcast_is_stored_as_partial,
            row_carries_the_unattested_actor
        ]},
        {extension_ops, [], [
            successful_extension_mutation_is_stored_as_ok,
            failed_extension_mutation_is_stored_as_error
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

%% The registry is memoised at Nova's boot, so the fixture is installed and the
%% memo cleared rather than the node restarted, exactly as asobi_rpc_SUITE does.
init_per_group(extension_ops, Config) ->
    ok = asobi_fixture_app:install(asobi_fixture_quests, asobi_fixture_quests_extension, []),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(extension_ops, Config) ->
    asobi_fixture_app:uninstall(asobi_fixture_quests),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config;
end_per_group(_Group, Config) ->
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

%% asobi#397 against the real write path: an extension handler answers the rpc
%% reply shapes, and both a success and a failure carrying details used to
%% raise inside the audit path and leave no row.
successful_extension_mutation_is_stored_as_ok(Config) ->
    Display = label(?FUNCTION_NAME),
    {json, _} = asobi_ops_extension:handle(ext_req(Display, #{~"key" => ~"daily"})),
    Row = row(Display),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(0, maps:get(failed_count, Row)),
    ?assertEqual(~"quests.define", maps:get(action, Row)),
    ?assertEqual(~"extension", maps:get(target_type, Row)),
    ?assertEqual(~"quests", maps:get(target_id, Row)),
    Config.

failed_extension_mutation_is_stored_as_error(Config) ->
    Display = label(?FUNCTION_NAME),
    {asobi_error, ~"quests.already_claimed", _} =
        asobi_ops_extension:handle(ext_req(Display, #{~"key" => ~"conflict"})),
    Row = row(Display),
    ?assertEqual(~"error", maps:get(outcome, Row)),
    ?assertEqual(0, maps:get(succeeded_count, Row)),
    ?assertEqual(0, maps:get(failed_count, Row)),
    ?assertEqual(#{~"reason" => ~"quests.already_claimed"}, maps:get(details, Row)),
    Config.

ext_req(Display, Params) ->
    #{
        bindings => #{~"extension" => ~"quests", ~"action" => ~"define"},
        auth_data => #{ops_actor => actor(Display)},
        json => Params
    }.
