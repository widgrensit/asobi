-module(asobi_extension_export_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(CLANS, asobi_fixture_clans).
-define(MINIMAL, asobi_fixture_minimal).
-define(PLAYER, ~"01960000-0000-7000-8000-000000000001").

export_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun nothing_installed_is_an_empty_report/0,
        fun an_extension_without_an_export_path_is_a_visible_marker/0,
        fun every_extension_exports_in_dependency_order/0,
        fun a_refusing_extension_fails_the_whole_export/0,
        fun a_raising_extension_is_attributed_not_propagated/0,
        fun a_return_outside_the_contract_is_a_failure/0,
        fun a_section_that_cannot_be_encoded_fails_the_export/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_export:reset(),
    ok.

cleanup(_) ->
    _ = [asobi_fixture_app:uninstall(A) || A <- [?QUESTS, ?CLANS, ?MINIMAL]],
    asobi_fixture_export:reset(),
    asobi_extensions:reset(),
    ok.

nothing_installed_is_an_empty_report() ->
    ?assertEqual({ok, #{}}, asobi_extension_export:run(?PLAYER)),
    ?assertEqual([], asobi_fixture_export:calls()).

%% The callback is optional, but an extension without one must be visible in
%% the artefact rather than silently absent - the condition under which the
%% callback could ship at all.
an_extension_without_an_export_path_is_a_visible_marker() ->
    ok = asobi_fixture_app:install(?MINIMAL, asobi_fixture_minimal_extension, []),
    ?assertEqual(
        {ok, #{minimal => #{skipped => ~"export_player/1 not exported"}}},
        asobi_extension_export:run(?PLAYER)
    ),
    ?assertEqual([], asobi_fixture_export:calls()).

%% clans sorts first alphabetically and depends on quests, so this order can
%% only come from the resolved dependency order.
every_extension_exports_in_dependency_order() ->
    install_both(),
    ?assertEqual(
        {ok, #{
            quests => #{data => #{~"rows" => [?PLAYER]}},
            clans => #{data => #{~"rows" => [?PLAYER]}}
        }},
        asobi_extension_export:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}, {clans, ?PLAYER}], asobi_fixture_export:calls()).

%% Fail-closed, not best-effort: an extension that promised data and could not
%% deliver it is the silent incompleteness the skipped marker exists to
%% prevent, so the first failure names itself and nothing after it is
%% attempted.
a_refusing_extension_fails_the_whole_export() ->
    install_both(),
    ok = asobi_fixture_export:outcome(quests, {error, db_down}),
    ?assertEqual({error, {quests, db_down}}, asobi_extension_export:run(?PLAYER)),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_export:calls()).

%% The reason is sanitised - class, truncated text, top frame without
%% arguments - because whatever the extension raised with can hold the
%% subject's data, and the reason reaches the log and the caller's error.
a_raising_extension_is_attributed_not_propagated() ->
    install_both(),
    ok = asobi_fixture_export:outcome(quests, {raise, boom}),
    ?assertMatch(
        {error, {quests, {raised, error, ~"boom", _}}}, asobi_extension_export:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_export:calls()).

%% Only the shape of what came back - a tag and a size - survives, for the
%% same reason the raise path truncates.
a_return_outside_the_contract_is_a_failure() ->
    install_both(),
    ok = asobi_fixture_export:outcome(quests, {ok, not_a_map}),
    ?assertEqual(
        {error, {quests, {bad_return, {ok, 2}}}}, asobi_extension_export:run(?PLAYER)
    ),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_export:calls()).

%% The export is served as one JSON object, so a section json:encode/1
%% refuses must fail here, attributed to its extension - not as an
%% unattributed 500 after the payload has already left the controller.
a_section_that_cannot_be_encoded_fails_the_export() ->
    install_both(),
    ok = asobi_fixture_export:outcome(quests, {ok, #{~"where" => {59.3, 18.1}}}),
    ?assertMatch({error, {quests, _}}, asobi_extension_export:run(?PLAYER)),
    ?assertEqual([{quests, ?PLAYER}], asobi_fixture_export:calls()).

install_both() ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]).
