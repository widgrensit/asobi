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
        fun a_malformed_code_spec_refused/0
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
    Text = iolist_to_binary(lists:join(~" ", asobi_extensions:describe(Problems))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?QUESTS, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, atom_to_binary(?TUNABLE, utf8))),
    ?assertNotEqual(nomatch, binary:match(Text, Token)).
