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
        fun the_migration_seam_lists_the_extensions/0,
        fun one_lua_namespace_two_claimants/0,
        fun one_table_two_claimants/0,
        fun one_rpc_prefix_two_claimants/0,
        fun one_queue_two_claimants/0,
        fun an_extension_does_not_collide_with_itself/0,
        fun reserved_lua_namespace_refused/0,
        fun reserved_core_table_refused/0,
        fun reserved_core_queue_refused/0,
        fun reserved_rpc_prefix_refused/0,
        fun reserved_core_wire_prefix_refused/0,
        fun claiming_outside_the_owned_set_refused/0,
        fun a_queue_is_derived_from_the_worker_that_declares_it/0,
        fun a_table_is_derived_from_the_schema_that_declares_it/0,
        fun a_typo_in_owns_queues_is_caught/0,
        fun a_derived_queue_matches_its_own_owns/0,
        fun duplicate_extension_names_refused/0,
        fun malformed_info_refused/0,
        fun a_name_that_is_not_an_identifier_is_refused/0,
        fun a_name_that_is_an_identifier_is_accepted/0,
        fun a_raising_manifest_is_reported_not_propagated/0,
        fun invalid_child_specs_caught_before_boot/0,
        fun unknown_owns_key_refused/0,
        fun resolve_raises_on_an_invalid_set/0,
        fun lua_args_must_match_the_mfa_arity/0,
        fun an_rpc_handler_must_have_arity_two/0,
        fun a_bot_binding_is_refused_not_ignored/0,
        fun an_ops_handler_must_have_arity_two/0,
        fun an_ops_handler_must_exist/0,
        fun an_ops_action_must_carry_a_real_class/0,
        fun an_ops_action_must_be_one_path_segment/0,
        fun a_declared_ops_action_is_reachable_by_its_class/0,
        fun a_declared_code_carries_its_status_and_message/0,
        fun an_undeclared_code_is_still_a_server_bug/0,
        fun core_codes_stay_core_only/0,
        fun a_code_in_a_reserved_domain_refused/0,
        fun a_code_outside_the_owned_set_refused/0,
        fun one_code_domain_two_claimants/0,
        fun a_bare_code_refused/0,
        fun a_malformed_code_spec_refused/0,
        fun a_requires_on_a_core_subsystem_is_satisfied/0,
        fun a_requires_on_an_installed_extension_resolves_it_first/0,
        fun an_unsatisfiable_requires_is_refused/0,
        fun a_requires_on_an_extension_that_sorts_after_is_caught/0,
        fun an_installed_extension_wins_over_the_same_named_core_subsystem/0,
        fun a_self_requirement_is_named_as_such/0,
        fun a_requires_cycle_is_a_legible_problem_not_a_loop/0,
        fun a_duplicated_requires_entry_reports_once/0,
        fun a_requires_must_be_a_list_of_atoms/0
    ]}.

%% emit/4 needs the quests fixture resolved (for its owned `quests` RPC prefix).
%% asobi_presence:send/2 is meck'd with a passthrough so the produced term is
%% observable through meck's call history - a foreach test body runs in its own
%% process, so message-passing to the setup process would never arrive.
emit_test_() ->
    {foreach, fun emit_setup/0, fun emit_cleanup/1, [
        fun emit_reaches_the_player_under_an_owned_domain/0,
        fun emit_under_an_unowned_domain_is_refused/0,
        fun emit_with_a_malformed_event_is_refused/0,
        fun emit_with_a_non_ascii_event_name_is_refused/0,
        fun emit_with_non_encodable_data_is_refused/0,
        fun emit_with_oversized_data_is_refused/0,
        fun emit_rejects_non_map_data/0
    ]}.

emit_setup() ->
    asobi_extensions:reset(),
    meck:new(asobi_presence, [passthrough, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Message) -> ok end),
    install(?QUESTS).

emit_cleanup(_) ->
    asobi_fixture_app:uninstall(?QUESTS),
    meck:unload(asobi_presence),
    asobi_extensions:reset(),
    ok.

emit_reaches_the_player_under_an_owned_domain() ->
    Data = #{~"quest_id" => ~"01j8", ~"reward" => 250},
    ?assertEqual(ok, asobi_extensions:emit(quests, ~"p1", ~"quests.completed", Data)),
    ?assert(
        meck:called(
            asobi_presence, send, [~"p1", {extension_event, quests, ~"quests.completed", Data}]
        )
    ).

emit_under_an_unowned_domain_is_refused() ->
    %% quests owns the `quests` RPC prefix, not `social`.
    {error, Object} = asobi_extensions:emit(quests, ~"p1", ~"social.pinged", #{}),
    ?assertEqual(~"event.unowned_domain", code_of(Object)),
    ?assertEqual(0, meck:num_calls(asobi_presence, send, ['_', '_'])).

emit_with_a_malformed_event_is_refused() ->
    OwnedButTooLong = <<"quests.", (binary:copy(~"a", 58))/binary>>,
    ?assertEqual(65, byte_size(OwnedButTooLong)),
    Names = [~"nodot", ~"quests.", ~".completed", ~"", ~"quests.a.b", OwnedButTooLong],
    [
        begin
            {error, Object} = asobi_extensions:emit(quests, ~"p1", Name, #{}),
            ?assertEqual(~"event.invalid_name", code_of(Object))
        end
     || Name <- Names
    ],
    ?assertEqual(0, meck:num_calls(asobi_presence, send, ['_', '_'])).

%% A non-ASCII / invalid-UTF-8 byte in the name is rejected before it can reach
%% json:encode/1 and crash every subscriber's socket. The domain is owned, so
%% only the charset check stands between it and the wire.
emit_with_a_non_ascii_event_name_is_refused() ->
    {error, Object} = asobi_extensions:emit(quests, ~"p1", <<"quests.", 16#FF>>, #{}),
    ?assertEqual(~"event.invalid_name", code_of(Object)),
    ?assertEqual(0, meck:num_calls(asobi_presence, send, ['_', '_'])).

%% A pid (or any non-JSON term) in Data raises inside json:encode/1; emit/4
%% catches it at the boundary and returns an error rather than crashing the
%% socket clause. Owned domain + valid name, so only encodability stands here.
emit_with_non_encodable_data_is_refused() ->
    {error, Object} = asobi_extensions:emit(quests, ~"p1", ~"quests.completed", #{~"pid" => self()}),
    ?assertEqual(~"event.invalid_data", code_of(Object)),
    ?assertEqual(0, meck:num_calls(asobi_presence, send, ['_', '_'])).

%% One byte of data blob per the 64 KiB cap, plus the JSON overhead, is over it.
emit_with_oversized_data_is_refused() ->
    Big = #{~"blob" => binary:copy(~"a", 65536)},
    {error, Object} = asobi_extensions:emit(quests, ~"p1", ~"quests.completed", Big),
    ?assertEqual(~"event.payload_too_large", code_of(Object)),
    ?assertEqual(0, meck:num_calls(asobi_presence, send, ['_', '_'])).

%% The `is_map(Data)` guard has no in-type value that fails it, so the non-map
%% arguments travel through apply/3 - which eqwalizer does not arg-check - to
%% reach the guard at runtime without a static type error.
emit_rejects_non_map_data() ->
    [
        ?assertError(
            function_clause,
            erlang:apply(asobi_extensions, emit, [quests, ~"p1", ~"quests.completed", NotAMap])
        )
     || NotAMap <- [[], 7]
    ].

code_of(#{error := #{code := Code}}) ->
    Code.

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

%% kura calls this optional kura_repo callback. It names the extensions only:
%% kura adds the repo's own application and sorts the result itself.
the_migration_seam_lists_the_extensions() ->
    ?assertEqual([], asobi_repo:migration_apps()),
    install(?QUESTS),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]),
    asobi_extensions:reset(),
    ?assertEqual([?QUESTS, ?CLANS], asobi_repo:migration_apps()).

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

%% `session` and `presence` are core wire frame families with no error domain
%% and no Lua namespace, now reserved via core_wire_prefixes/0. An extension
%% claiming either as an owns/0 RPC prefix is refused, so it cannot forge a
%% frame in a core family or emit an event under it.
reserved_core_wire_prefix_refused() ->
    tunable(#{owns => #{rpc => [~"session"]}}),
    ?assert(lists:member({reserved_namespace, rpc, ~"session", ?TUNABLE}, check_problems())),
    retune(#{owns => #{rpc => [~"presence"]}}),
    ?assert(lists:member({reserved_namespace, rpc, ~"presence", ?TUNABLE}, check_problems())).

claiming_outside_the_owned_set_refused() ->
    tunable(#{
        owns => #{rpc => [~"tunable"]},
        rpc => #{~"gold.grant" => {tunable_rpc, grant, 2}}
    }),
    ?assert(lists:member({undeclared_claim, rpc, ~"gold", ?TUNABLE}, check_problems())).

%% asobi#369. `rpc` and `lua` claims are derived from the manifest, so a
%% collision is caught even with no `owns/0` at all. A queue was only ever what
%% `owns/0` said, which made the claim unenforceable: nothing read it, so a typo
%% was invisible. It now derives from `queue/0` + `perform/1` on the extension's
%% own modules - core's own rule, applied to an extension's module list. The
%% minimal fixture declares no `owns/0` whatsoever, so only the derivation can
%% produce this collision.
a_queue_is_derived_from_the_worker_that_declares_it() ->
    ok = asobi_fixture_app:install(
        ?MINIMAL, [asobi_fixture_minimal_extension, asobi_fixture_quests_job], []
    ),
    tunable(#{owns => #{queues => [~"quests"]}}),
    ?assert(
        lists:member({namespace_conflict, queues, ~"quests", ?MINIMAL, ?TUNABLE}, check_problems())
    ).

a_table_is_derived_from_the_schema_that_declares_it() ->
    ok = asobi_fixture_app:install(
        ?MINIMAL, [asobi_fixture_minimal_extension, asobi_fixture_quests_schema], []
    ),
    tunable(#{owns => #{tables => [~"quest_progress"]}}),
    ?assert(
        lists:member(
            {namespace_conflict, tables, ~"quest_progress", ?MINIMAL, ?TUNABLE}, check_problems()
        )
    ).

%% The typo that used to be invisible. The worker says `quests`; `owns/0` says
%% `quest`. Deriving the real queue is what turns that into a build failure -
%% `owns/0` is now the closed-set assertion over what was derived, not its
%% source.
a_typo_in_owns_queues_is_caught() ->
    tunable(#{owns => #{queues => [~"quest"]}}, [asobi_fixture_quests_job]),
    ?assert(lists:member({undeclared_claim, queues, ~"quests", ?TUNABLE}, check_problems())).

%% An extension does not collide with itself: the queue it derives is the queue
%% it owns.
a_derived_queue_matches_its_own_owns() ->
    tunable(#{owns => #{queues => [~"quests"]}}, [asobi_fixture_quests_job]),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

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

%% The name is a path segment in `/ext/<name>`, a symlink in the console build
%% workspace and a JavaScript import binding in its generated registry, each of
%% which interpolates it without escaping.
a_name_that_is_not_an_identifier_is_refused() ->
    tunable(#{info => #{name => tunable, extension_version => 1}}),
    [
        begin
            retune(#{info => #{name => Name, extension_version => 1}}),
            ?assertMatch(
                [{bad_manifest, ?TUNABLE, _, {info, ~"name must match ^[a-z][a-z0-9_]*$", Name}}],
                check_problems()
            )
        end
     || Name <- ['my-quests', 'a/../x', 'Quests', '1st', 'has space', '']
    ].

a_name_that_is_an_identifier_is_accepted() ->
    tunable(#{info => #{name => tunable_2, extension_version => 1}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

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

%% --- Lua bindings ---

%% asobi#361. `args` is what the injector decodes and `mfa` is what it applies,
%% so a binding whose lengths disagree cannot be called at all. Core's own
%% quests fixture shipped one of these.
lua_args_must_match_the_mfa_arity() ->
    tunable(#{
        lua => #{
            ~"tunable" => #{
                ~"status" => #{
                    mfa => {tunable_lua, status, 2},
                    args => [binary],
                    effects => none,
                    vms => [match]
                }
            }
        }
    }),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {lua, ~"args must declare one type per mfa argument", _}}],
        check_problems()
    ),
    retune(#{
        lua => #{
            ~"tunable" => #{
                ~"status" => #{
                    mfa => {tunable_lua, status, 1},
                    args => [binary],
                    effects => none,
                    vms => [match]
                }
            }
        }
    }),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% asobi_rpc applies every target as `Module:Function(Params, Ctx)`, so a
%% handler declared at any other arity cannot be called. Refusing it here is
%% what turns a 500 on the first client call into a build failure.
an_rpc_handler_must_have_arity_two() ->
    tunable(#{rpc => #{~"tunable.thing" => {tunable_rpc, thing, 3}}}),
    ?assertMatch(
        [
            {bad_manifest, ?TUNABLE, _,
                {rpc, ~"method must be <prefix>.<method> mapped to {Module, Function, 2}", _}}
        ],
        check_problems()
    ),
    retune(#{rpc => #{~"tunable.thing" => {tunable_rpc, thing, 2}}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% asobi#369. A bot script is loaded through asobi_lua_loader:new/1, whose
%% PreInstall is the identity, so it never reaches asobi_lua_api:install/2 and
%% has no `game` table at all - `vms => [bot]` used to be a declaration that
%% silently installed nothing. Refused at build time instead.
a_bot_binding_is_refused_not_ignored() ->
    tunable(#{lua => #{~"tunable" => #{~"status" => binding([match, bot])}}}),
    ?assertMatch(
        [
            {bad_manifest, ?TUNABLE, _,
                {lua, ~"vms cannot include bot: a bot VM has no game.* table to install into", _}}
        ],
        check_problems()
    ),
    retune(#{lua => #{~"tunable" => #{~"status" => binding([match, world, zone])}}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

binding(Vms) ->
    #{mfa => {tunable_lua, status, 1}, args => [binary], effects => none, vms => Vms}.

%% asobi#372. `ops/0` is dispatched by core as `Module:Function(Params, Ctx)`,
%% exactly as `rpc/0` is, so the same arity rule holds for the same reason.
an_ops_handler_must_have_arity_two() ->
    tunable(#{ops => #{~"thing" => ops_entry(#{mfa => {tunable_ops, thing, 1}})}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {ops, _, ~"thing"}}],
        check_problems()
    ),
    retune(#{ops => #{~"thing" => ops_entry(#{})}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% The class is the only thing that authorises the call, so a class outside
%% ADR 0007's vocabulary is a build failure rather than a route that resolves
%% to a capability nobody can hold.
an_ops_action_must_carry_a_real_class() ->
    tunable(#{ops => #{~"thing" => ops_entry(#{class => superuser})}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {ops, _, ~"thing"}}],
        check_problems()
    ).

%% The action is one path segment under /api/v1/ops/ext/<name>/, so a slash
%% would silently mount somewhere the capability check cannot tag.
an_ops_action_must_be_one_path_segment() ->
    tunable(#{ops => #{~"quests/define" => ops_entry(#{})}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {ops, _, ~"quests/define"}}],
        check_problems()
    ).

%% The end of the chain: a declared action resolves to its declared class on
%% the path the router serves, and the same path with a method it does not
%% answer resolves to nothing - which is what denies it.
a_declared_ops_action_is_reachable_by_its_class() ->
    tunable(#{ops => #{~"thing" => ops_entry(#{class => player_data})}}),
    _ = asobi_extensions:resolve(),
    ?assertEqual(
        player_data,
        asobi_ops_caps:class(~"POST", ~"/api/v1/ops/ext/tunable/thing")
    ),
    ?assertEqual(
        undefined,
        asobi_ops_caps:class(~"GET", ~"/api/v1/ops/ext/tunable/thing")
    ),
    ?assertEqual(
        undefined,
        asobi_ops_caps:class(~"POST", ~"/api/v1/ops/ext/tunable/other")
    ).

%% A real exported handler: ops entries are handler-existence-checked, so a
%% fake module would fail validation before the property under test runs.
ops_entry(Overrides) ->
    maps:merge(
        #{method => post, mfa => {asobi_fixture_quests_ops, summary, 2}, class => config},
        Overrides
    ).

%% The missing-handler refusal itself: shape-perfect entries whose module or
%% function does not exist must fail the build, not 500 on first call.
an_ops_handler_must_exist() ->
    tunable(#{ops => #{~"thing" => ops_entry(#{mfa => {asobi_no_such_module, thing, 2}})}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {ops, ~"mfa does not name an exported function", ~"thing"}}],
        check_problems()
    ),
    retune(#{ops => #{~"thing" => ops_entry(#{mfa => {asobi_fixture_quests_ops, nope, 2}})}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {ops, ~"mfa does not name an exported function", ~"thing"}}],
        check_problems()
    ),
    retune(#{ops => #{~"thing" => ops_entry(#{})}}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% --- Error codes ---

%% asobi#360. An extension reporting an ordinary domain condition must not
%% answer 500 and page somebody.
a_declared_code_carries_its_status_and_message() ->
    install(?QUESTS),
    _ = asobi_extensions:resolve(),
    ?assertEqual(409, asobi_error:status(~"quests.already_claimed")),
    ?assertEqual(404, asobi_error:status(~"quests.not_found")),
    ?assertEqual(
        ~"This quest was already claimed.", asobi_error:message(~"quests.already_claimed")
    ),
    ?assertMatch(
        #{error := #{code := ~"quests.already_claimed", details := #{}}},
        asobi_error:object(~"quests.already_claimed")
    ),
    ?assert(lists:member(~"quests.already_claimed", asobi_error:codes())).

%% The set stays closed. Owning the domain does not mint every code inside it.
an_undeclared_code_is_still_a_server_bug() ->
    install(?QUESTS),
    _ = asobi_extensions:resolve(),
    ?assertEqual(500, asobi_error:status(~"quests.invented_at_runtime")),
    ?assertNotEqual(
        asobi_error:message(~"quests.already_claimed"),
        asobi_error:message(~"quests.invented_at_runtime")
    ).

%% asobi_extension_reserved derives core's reserved RPC prefixes from
%% core_codes/0. If it saw the extension's own codes it would tell the
%% extension it may not claim the namespace it just claimed.
core_codes_stay_core_only() ->
    install(?QUESTS),
    _ = asobi_extensions:resolve(),
    ?assertNot(lists:member(~"quests.already_claimed", asobi_error:core_codes())),
    %% Re-validating a node whose extension codes are already installed - what
    %% `rebar3 asobi check` does against a booted release - must not now tell
    %% quests it claims a namespace core reserves.
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

a_code_in_a_reserved_domain_refused() ->
    tunable(#{codes => #{~"storage.wedged" => #{status => 409, message => ~"No."}}}),
    ?assert(lists:member({reserved_namespace, rpc, ~"storage", ?TUNABLE}, check_problems())).

a_code_outside_the_owned_set_refused() ->
    tunable(#{
        owns => #{rpc => [~"tunable"]},
        codes => #{~"gold.spent" => #{status => 402, message => ~"No gold."}}
    }),
    ?assert(lists:member({undeclared_claim, rpc, ~"gold", ?TUNABLE}, check_problems())).

one_code_domain_two_claimants() ->
    install(?QUESTS),
    tunable(#{codes => #{~"quests.stalled" => #{status => 409, message => ~"Stalled."}}}),
    assert_conflict(rpc, ~"quests").

%% A bare code sits in core's cross-cutting namespace, which no extension owns
%% and the reserved set cannot protect.
a_bare_code_refused() ->
    tunable(#{codes => #{~"already_claimed" => #{status => 409, message => ~"No."}}}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {codes, _, ~"already_claimed"}}],
        check_problems()
    ).

a_malformed_code_spec_refused() ->
    tunable(#{codes => #{~"tunable.nope" => #{status => 4090, message => ~"No."}}}),
    ?assertMatch([{bad_manifest, ?TUNABLE, _, {codes, _, ~"tunable.nope"}}], check_problems()),
    retune(#{codes => #{~"tunable.nope" => #{status => 409}}}),
    ?assertMatch([{bad_manifest, ?TUNABLE, _, {codes, _, ~"tunable.nope"}}], check_problems()).

%% --- Requirements ---

%% A core subsystem is always present and boots first, so a requires on one is
%% satisfied with no other extension in play and imposes no ordering. This is
%% the quests-requires-economy shape the real fixture ships.
a_requires_on_a_core_subsystem_is_satisfied() ->
    tunable(#{requires => [economy]}),
    ?assertMatch({ok, [_]}, asobi_extensions:check()).

%% A requires on another installed extension is satisfied when that extension
%% resolves first, which the resolver's dependency order guarantees exactly
%% when the requirer's application depends on the provider's. The clans fixture
%% requires quests; installing it with the application dependency puts quests
%% first, so the requirement holds.
a_requires_on_an_installed_extension_resolves_it_first() ->
    install(?QUESTS),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]),
    ?assertEqual([quests], asobi_fixture_clans_extension:requires()),
    ?assertEqual([quests, clans], [Name || #{name := Name} <- asobi_extensions:resolve()]),
    ?assertMatch({ok, [_, _]}, asobi_extensions:check()).

%% A name that resolves to nothing - no core subsystem, no installed extension
%% - is refused by the gate and raised through the boot backstop, with one line
%% naming the extension and the missing dependency.
an_unsatisfiable_requires_is_refused() ->
    tunable(#{requires => [does_not_exist]}),
    Problems = check_problems(),
    ?assert(lists:member({unsatisfied_requirement, ?TUNABLE, does_not_exist}, Problems)),
    Text = asobi_test_helpers:binary_join(~" ", asobi_extensions:describe(Problems)),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?TUNABLE, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, ~"does_not_exist")),
    ?assertError({asobi_extensions, _}, asobi_extensions:resolve()).

%% The ordering half. clans requires quests, but installed without the
%% application dependency the two are independent, so the resolver lists them
%% alphabetically - clans before quests - and the provider lands after the
%% requirer. That is refused: a requires not backed by an application
%% dependency cannot promise the boot order it needs. The refusal hinges on the
%% resolve order (the alphabetical tie-break clans < quests puts the provider
%% last); a future change to that ordering would surface here as an edit to
%% this assertion, which is intended.
a_requires_on_an_extension_that_sorts_after_is_caught() ->
    install(?QUESTS),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, []),
    ?assert(lists:member({requirement_out_of_order, ?CLANS, quests}, check_problems())).

%% The union-shadow rule, pinned. economy is a core subsystem, but here an
%% installed extension is also named economy and sorts after quests, which
%% requires it. The installed check runs before the capability free pass, so
%% the requirement is out of order (the extension wins) rather than trivially
%% satisfied by the capability - the transparency an extraction depends on.
an_installed_extension_wins_over_the_same_named_core_subsystem() ->
    install(?QUESTS),
    tunable(#{info => #{name => economy, extension_version => 1}}),
    Problems = check_problems(),
    ?assert(lists:member({requirement_out_of_order, ?QUESTS, economy}, Problems)),
    ?assertNot(lists:member({unsatisfied_requirement, ?QUESTS, economy}, Problems)).

%% A requires entry equal to the extension's own name is a manifest bug, and
%% naming it so beats the out-of-order line, whose "add an application
%% dependency" fix is uncompletable for a self-reference. The self check runs
%% before the capability free pass too: economy is a capability, but naming
%% yourself economy is still self-reference.
a_self_requirement_is_named_as_such() ->
    tunable(#{info => #{name => economy, extension_version => 1}, requires => [economy]}),
    Problems = check_problems(),
    ?assert(lists:member({self_requirement, ?TUNABLE, economy}, Problems)),
    ?assertNot(lists:member({requirement_out_of_order, ?TUNABLE, economy}, Problems)),
    Text = asobi_test_helpers:binary_join(~" ", asobi_extensions:describe(Problems)),
    ?assertNotEqual(nomatch, binary:match(Text, ~"itself")).

%% A two-cycle terminates with a legible problem, not a loop. clans requires
%% quests; a second extension named quests requires clans back. The walk visits
%% each once, so the cycle surfaces as one out-of-order problem - the provider
%% that sorts last - never a non-terminating resolve.
a_requires_cycle_is_a_legible_problem_not_a_loop() ->
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, []),
    tunable(#{info => #{name => quests, extension_version => 1}, requires => [clans]}),
    ?assert(lists:member({requirement_out_of_order, ?CLANS, quests}, check_problems())).

%% asobi#369-style dedup discipline: a name repeated in one requires/0 must not
%% report the same problem twice.
a_duplicated_requires_entry_reports_once() ->
    tunable(#{requires => [does_not_exist, does_not_exist]}),
    ?assertEqual(
        [{unsatisfied_requirement, ?TUNABLE, does_not_exist}],
        [P || {unsatisfied_requirement, _, does_not_exist} = P <- check_problems()]
    ).

a_requires_must_be_a_list_of_atoms() ->
    tunable(#{requires => [~"economy"]}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {requires, ~"must be a list of atoms", ~"economy"}}],
        check_problems()
    ),
    retune(#{requires => not_a_list}),
    ?assertMatch(
        [{bad_manifest, ?TUNABLE, _, {requires, ~"must be a list of atoms", not_a_list}}],
        check_problems()
    ).

%% --- Helpers ---

%% The schema and the worker are part of the fixture because table and queue
%% claims are derived from them, exactly as a real extension's are.
install(?QUESTS) ->
    ok = asobi_fixture_app:install(
        ?QUESTS,
        [asobi_fixture_quests_extension, asobi_fixture_quests_schema, asobi_fixture_quests_job],
        []
    );
install(?MINIMAL) ->
    ok = asobi_fixture_app:install(?MINIMAL, asobi_fixture_minimal_extension, []).

tunable(Manifest) ->
    tunable(Manifest, []).

tunable(Manifest, ExtraModules) ->
    ok = asobi_fixture_tunable_extension:set(Manifest),
    ok = asobi_fixture_app:install(
        ?TUNABLE, [asobi_fixture_tunable_extension | ExtraModules], []
    ).

%% The application is already loaded; only the manifest changes.
retune(Manifest) ->
    ok = asobi_fixture_tunable_extension:set(Manifest).

check_problems() ->
    case asobi_extensions:check() of
        {error, Problems} -> Problems;
        {ok, Resolved} -> erlang:error({expected_problems, [N || #{name := N} <- Resolved]})
    end.

%% Both claimants, by application name, in the message a human reads.
assert_conflict(Kind, Token) ->
    Problems = check_problems(),
    ?assert(lists:member({namespace_conflict, Kind, Token, ?QUESTS, ?TUNABLE}, Problems)),
    Text = asobi_test_helpers:binary_join(~" ", asobi_extensions:describe(Problems)),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?QUESTS, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?TUNABLE, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, Token)).
