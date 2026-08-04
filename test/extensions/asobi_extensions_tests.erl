-module(asobi_extensions_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(CLANS, asobi_fixture_clans).
-define(TUNABLE, asobi_fixture_tunable).
-define(MINIMAL, asobi_fixture_minimal).
-define(PLAIN, asobi_fixture_plain).

extensions_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun inert_when_nothing_is_installed/0,
        fun discovers_by_manifest_module/0,
        fun an_app_in_asobis_closure_is_not_an_extension/0,
        fun optional_callbacks_default_to_empty/0,
        fun dependency_order_beats_alphabetical_order/0,
        fun resolve_is_memoised/0,
        fun one_lua_namespace_two_claimants/0,
        fun one_table_two_claimants/0,
        fun one_rpc_prefix_two_claimants/0,
        fun one_queue_two_claimants/0,
        fun an_extension_does_not_collide_with_itself/0,
        fun reserved_lua_namespace_refused/0,
        fun reserved_core_table_refused/0,
        fun reserved_core_queue_refused/0,
        fun reserved_rpc_prefix_refused/0,
        fun claiming_outside_the_owned_set_refused/0,
        fun duplicate_extension_names_refused/0,
        fun malformed_info_refused/0,
        fun a_raising_manifest_is_reported_not_propagated/0,
        fun invalid_child_specs_caught_before_boot/0,
        fun unknown_owns_key_refused/0,
        fun resolve_raises_on_an_invalid_set/0
    ]}.

setup() ->
    asobi_extensions:reset(),
    asobi_fixture_tunable_extension:clear(),
    ok.

cleanup(_) ->
    _ = [asobi_fixture_app:uninstall(A) || A <- [?QUESTS, ?CLANS, ?TUNABLE, ?MINIMAL, ?PLAIN]],
    asobi_fixture_tunable_extension:clear(),
    asobi_extensions:reset(),
    ok.

%% --- Discovery ---

%% The machinery has to be free when nobody uses it. No extension installed
%% means an empty list and nothing else: no processes, no tables, no error.
inert_when_nothing_is_installed() ->
    ?assertEqual([], asobi_extensions:resolve()),
    ?assertEqual({ok, []}, asobi_extensions:check()).

discovers_by_manifest_module() ->
    install(?QUESTS),
    [Extension] = asobi_extensions:resolve(),
    ?assertMatch(
        #{
            app := ?QUESTS,
            module := asobi_fixture_quests_extension,
            name := quests,
            extension_version := 1
        },
        Extension
    ),
    #{rpc := Rpc, lua := Lua, owns := Owns} = Extension,
    ?assertEqual({asobi_fixture_quests_rpc, claim, 2}, maps:get(~"quests.claim", Rpc)),
    ?assertEqual([~"quests"], maps:keys(Lua)),
    ?assertEqual([~"quests", ~"quest_progress"], maps:get(tables, Owns)).

%% asobi_lua, asobi_engine and asobi_admin all have asobi in their dependency
%% closure and none of them is an extension. The filter is a module named after
%% the application, not any module ending in `_extension` and not depending on
%% asobi: this fixture carries a perfectly valid manifest module belonging to a
%% different application and is still not an extension.
an_app_in_asobis_closure_is_not_an_extension() ->
    ok = asobi_fixture_app:install(?PLAIN, asobi_fixture_quests_extension, []),
    ?assertEqual([], asobi_extensions:resolve()).

optional_callbacks_default_to_empty() ->
    install(?MINIMAL),
    [Extension] = asobi_extensions:resolve(),
    ?assertMatch(#{name := minimal, rpc := #{}, lua := #{}, owns := #{}}, Extension),
    ?assertEqual([], asobi_extensions:sup_specs(asobi_fixture_minimal_extension)),
    %% Nothing can call it: no Lua namespace for game logic, no RPC for a
    %% client. `rebar3 asobi check` warns; it is not a boot failure.
    #{rpc := Rpc, lua := Lua} = Extension,
    ?assertEqual(0, map_size(Rpc) + map_size(Lua)).

%% asobi_fixture_clans sorts before asobi_fixture_quests but depends on it, so
%% only an ordering that reads OTP's `applications` key can produce this.
dependency_order_beats_alphabetical_order() ->
    install(?QUESTS),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]),
    ?assertEqual([?CLANS, ?QUESTS], lists:sort([?QUESTS, ?CLANS])),
    ?assertEqual([quests, clans], [Name || #{name := Name} <- asobi_extensions:resolve()]).

%% The registry is memoised, not live. Installing an application after the
%% first call is invisible until the term is cleared, which is the price of
%% being callable from inside Nova's boot with no process to ask.
resolve_is_memoised() ->
    install(?QUESTS),
    ?assertEqual(1, length(asobi_extensions:resolve())),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]),
    ?assertEqual(1, length(asobi_extensions:resolve())),
    asobi_extensions:reset(),
    ?assertEqual(2, length(asobi_extensions:resolve())).

%% --- Disjointness ---

one_lua_namespace_two_claimants() ->
    install(?QUESTS),
    tunable(#{lua => #{~"quests" => #{}}}),
    assert_conflict(lua, ~"quests").

one_table_two_claimants() ->
    install(?QUESTS),
    tunable(#{owns => #{tables => [~"quest_progress"]}}),
    assert_conflict(tables, ~"quest_progress").

one_rpc_prefix_two_claimants() ->
    install(?QUESTS),
    tunable(#{rpc => #{~"quests.reset" => {tunable_rpc, reset, 2}}}),
    assert_conflict(rpc, ~"quests").

one_queue_two_claimants() ->
    install(?QUESTS),
    tunable(#{owns => #{queues => [~"quests"]}}),
    assert_conflict(queues, ~"quests").

%% The claim set is owns/0 plus what the manifest implies, so a well-formed
%% extension declares its Lua namespace twice - once in lua/0 and once in
%% owns.lua. It must not collide with itself.
an_extension_does_not_collide_with_itself() ->
    install(?QUESTS),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]),
    ?assertMatch({ok, [_, _]}, asobi_extensions:check()).

%% --- Core's reserved names ---

reserved_lua_namespace_refused() ->
    tunable(#{lua => #{~"economy" => #{}}}),
    ?assert(lists:member({reserved_namespace, lua, ~"economy", ?TUNABLE}, check_problems())).

reserved_core_table_refused() ->
    tunable(#{owns => #{tables => [~"players"]}}),
    ?assert(lists:member({reserved_namespace, tables, ~"players", ?TUNABLE}, check_problems())).

reserved_core_queue_refused() ->
    tunable(#{owns => #{queues => [~"broadcast"]}}),
    ?assert(lists:member({reserved_namespace, queues, ~"broadcast", ?TUNABLE}, check_problems())).

%% An RPC prefix and an error-code domain are the same token, so owning
%% "storage" would mint codes inside core's closed code set.
reserved_rpc_prefix_refused() ->
    tunable(#{rpc => #{~"storage.get" => {tunable_rpc, get, 2}}}),
    ?assert(lists:member({reserved_namespace, rpc, ~"storage", ?TUNABLE}, check_problems())).

claiming_outside_the_owned_set_refused() ->
    tunable(#{
        owns => #{rpc => [~"tunable"]},
        rpc => #{~"gold.grant" => {tunable_rpc, grant, 2}}
    }),
    ?assert(lists:member({undeclared_claim, rpc, ~"gold", ?TUNABLE}, check_problems())).

duplicate_extension_names_refused() ->
    install(?QUESTS),
    tunable(#{info => #{name => quests, extension_version => 1}}),
    ?assert(lists:member({duplicate_name, quests, ?QUESTS, ?TUNABLE}, check_problems())).

%% --- Malformed manifests ---

malformed_info_refused() ->
    tunable(#{info => #{name => tunable}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, asobi_fixture_tunable_extension, {info, _, _}}],
        check_problems()
    ).

a_raising_manifest_is_reported_not_propagated() ->
    tunable(#{owns => {raise, boom}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {owns, {raised, error, boom}}}],
        check_problems()
    ).

%% supervisor:check_childspecs/1 at build time instead of a failed_to_start_child
%% raised out of Nova's boot.
invalid_child_specs_caught_before_boot() ->
    tunable(#{sup => [#{id => no_start_key}]}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {sup, ~"invalid child specs", _}}],
        check_problems()
    ).

unknown_owns_key_refused() ->
    tunable(#{owns => #{telemetry => [~"tunable"]}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {owns, ~"unknown namespace kind", telemetry}}],
        check_problems()
    ).

%% The backstop. A node that cannot say which extension owns a namespace must
%% not serve traffic under either.
resolve_raises_on_an_invalid_set() ->
    install(?QUESTS),
    tunable(#{lua => #{~"quests" => #{}}}),
    ?assertError({asobi_extensions, _}, asobi_extensions:resolve()).

%% --- Helpers ---

install(?QUESTS) ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []);
install(?MINIMAL) ->
    ok = asobi_fixture_app:install(?MINIMAL, asobi_fixture_minimal_extension, []).

tunable(Manifest) ->
    ok = asobi_fixture_tunable_extension:set(Manifest),
    ok = asobi_fixture_app:install(?TUNABLE, asobi_fixture_tunable_extension, []).

check_problems() ->
    case asobi_extensions:check() of
        {error, Problems} -> Problems;
        {ok, Resolved} -> erlang:error({expected_problems, [N || #{name := N} <- Resolved]})
    end.

%% Both claimants, by application name, in the message a human reads.
assert_conflict(Kind, Token) ->
    Problems = check_problems(),
    ?assert(lists:member({namespace_conflict, Kind, Token, ?QUESTS, ?TUNABLE}, Problems)),
    Text = iolist_to_binary(lists:join(~" ", asobi_extensions:describe(Problems))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?QUESTS, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?TUNABLE, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, Token)).
