-module(asobi_extension_erase_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(CLANS, asobi_fixture_clans).
-define(MINIMAL, asobi_fixture_minimal).
-define(PLAYER, ~"01960000-0000-7000-8000-000000000001").

erase_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun nothing_installed_is_nothing_to_run/0,
        fun an_extension_without_an_erase_path_is_skipped/0,
        fun every_extension_erases_in_dependency_order/0,
        fun a_refusing_extension_stops_the_whole_deletion/0,
        fun a_raising_extension_is_attributed_not_propagated/0,
        fun a_return_outside_the_contract_is_a_failure/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_erase:reset(),
    ok.

cleanup(_) ->
    _ = [asobi_fixture_app:uninstall(A) || A <- [?QUESTS, ?CLANS, ?MINIMAL]],
    asobi_fixture_erase:reset(),
    asobi_extensions:reset(),
    ok.

nothing_installed_is_nothing_to_run() ->
    ?assertEqual(ok, asobi_extension_erase:run(?PLAYER)),
    ?assertEqual([], asobi_fixture_erase:calls()).

%% The callback is optional: an extension whose rows cascade declares nothing
%% and must not become a deletion failure.
an_extension_without_an_erase_path_is_skipped() ->
    ok = asobi_fixture_app:install(?MINIMAL, asobi_fixture_minimal_extension, []),
    ?assertEqual(ok, asobi_extension_erase:run(?PLAYER)),
    ?assertEqual([], asobi_fixture_erase:calls()).

%% clans sorts first alphabetically and depends on quests, so this order can
%% only come from the resolved dependency order.
every_extension_erases_in_dependency_order() ->
    install_both(),
    ?assertEqual(ok, asobi_extension_erase:run(?PLAYER)),
    ?assertEqual([{quests, ?PLAYER}, {clans, ?PLAYER}], asobi_fixture_erase:calls()).

%% Atomic, not best-effort: the first refusal names itself and nothing after it
%% is attempted, so the caller's assertion rolls the transaction back with every
%% extension's rows still in place.
a_refusing_extension_stops_the_whole_deletion() ->
    install_both(),
    ok = asobi_fixture_erase:outcome(quests, {error, ledger_is_immutable}),
    ?assertEqual(
        {error, {quests, ledger_is_immutable}}, asobi_extension_erase:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_erase:calls()).

%% The reason is sanitised - class, truncated text, top frame without
%% arguments - because whatever the extension raised with can hold the
%% subject's data, and the reason reaches the log and the caller's badmatch.
a_raising_extension_is_attributed_not_propagated() ->
    install_both(),
    ok = asobi_fixture_erase:outcome(quests, {raise, boom}),
    ?assertMatch(
        {error, {quests, {raised, error, ~"boom", _}}}, asobi_extension_erase:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_erase:calls()).

%% Only the shape of what came back survives - an atom carries no size, so it
%% reports as `other` - for the same reason the raise path truncates.
a_return_outside_the_contract_is_a_failure() ->
    install_both(),
    ok = asobi_fixture_erase:outcome(quests, deleted_i_think),
    ?assertEqual(
        {error, {quests, {bad_return, other}}}, asobi_extension_erase:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_erase:calls()).

install_both() ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]).
