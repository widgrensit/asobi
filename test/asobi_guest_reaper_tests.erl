-module(asobi_guest_reaper_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#327: start_link/0 returned `ignore` when guest_auth was false, and a
%% supervisor skips - never retries - a child that returns ignore. Every writer
%% of guest_auth is in an application that starts after asobi, so the flag was
%% always false at asobi_sup boot and the reaper never ran. The boot ordering
%% these tests pin (unset at start, true afterwards) is the real deployment.

reaper_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"starts even with guest_auth unset", fun starts_without_guest_auth/0},
        {"sweep is a no-op while guest auth is off", fun sweep_skipped_when_disabled/0},
        {"guest_auth set after start: a sweep queries", fun sweep_runs_when_enabled_later/0},
        {"timer tick picks up a flag set after boot", fun timer_sweep_self_corrects/0},
        {"an installed extension erases before core deletes", fun extension_erases_first/0},
        {"a refusing extension leaves the player alone", fun refusing_extension_aborts_reap/0}
    ]}.

setup() ->
    application:unset_env(asobi, guest_auth),
    application:set_env(asobi, guest_reap_after, 60),
    asobi_extensions:reset(),
    asobi_fixture_erase:reset(),
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, all, fun(_Q) -> {ok, []} end),
    ok.

cleanup(_) ->
    case whereis(asobi_guest_reaper) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    meck:unload(asobi_repo),
    _ = asobi_fixture_app:uninstall(asobi_fixture_quests),
    asobi_fixture_erase:reset(),
    asobi_extensions:reset(),
    application:unset_env(asobi, guest_auth),
    application:unset_env(asobi, guest_reap_after),
    application:unset_env(asobi, guest_reap_interval_ms),
    ok.

starts_without_guest_auth() ->
    ?assertMatch({ok, _}, asobi_guest_reaper:start_link()),
    ?assert(is_pid(whereis(asobi_guest_reaper))).

sweep_skipped_when_disabled() ->
    {ok, _} = asobi_guest_reaper:start_link(),
    ?assertEqual({ok, 0}, asobi_guest_reaper:sweep_now()),
    ?assertEqual(0, meck:num_calls(asobi_repo, all, '_')).

sweep_runs_when_enabled_later() ->
    {ok, _} = asobi_guest_reaper:start_link(),
    application:set_env(asobi, guest_auth, true),
    ?assertEqual({ok, 0}, asobi_guest_reaper:sweep_now()),
    ?assertEqual(1, meck:num_calls(asobi_repo, all, '_')).

timer_sweep_self_corrects() ->
    application:set_env(asobi, guest_reap_interval_ms, 25),
    {ok, _} = asobi_guest_reaper:start_link(),
    application:set_env(asobi, guest_auth, true),
    ?assert(wait_for_sweep(200)).

%% asobi#369. An extension row foreign-keying into players.id is ON DELETE NO
%% ACTION, exactly like core's own children, so without running the extension's
%% erase path first the delete is a constraint violation and every guest quietly
%% stops being reaped. Extensions run before core deletes anything, so an erase
%% path can still read the player's core rows.
extension_erases_first() ->
    install_quests(),
    expect_one_reapable_guest(),
    {ok, _} = asobi_guest_reaper:start_link(),
    application:set_env(asobi, guest_auth, true),
    ?assertEqual({ok, 1}, asobi_guest_reaper:sweep_now()),
    ?assertEqual([{quests, ~"p-1"}], asobi_fixture_erase:calls()),
    ?assertEqual(1, meck:num_calls(asobi_repo, delete, '_')).

%% Atomic. The extension refuses, the assertion inside the transaction raises,
%% and core never deletes a row - so the player survives intact rather than
%% half-erased, and the sweep reports skipped rather than reaped.
refusing_extension_aborts_reap() ->
    install_quests(),
    ok = asobi_fixture_erase:outcome(quests, {error, ledger_is_immutable}),
    expect_one_reapable_guest(),
    {ok, _} = asobi_guest_reaper:start_link(),
    application:set_env(asobi, guest_auth, true),
    ?assertEqual({ok, 0}, asobi_guest_reaper:sweep_now()),
    ?assertEqual(0, meck:num_calls(asobi_repo, delete, '_')),
    ?assertEqual(0, meck:num_calls(asobi_repo, delete_all, '_')).

install_quests() ->
    ok = asobi_fixture_app:install(
        asobi_fixture_quests, asobi_fixture_quests_extension, []
    ).

%% One unclaimed guest identity, and a transaction that runs its fun inline so
%% the assertion inside it is the thing under test.
expect_one_reapable_guest() ->
    meck:expect(asobi_repo, all, fun(_Q) ->
        {ok, [#{player_id => ~"p-1", provider => ~"guest"}]}
    end),
    meck:expect(asobi_repo, get, fun(asobi_player, ~"p-1") ->
        {ok, #{id => ~"p-1", hashed_password => undefined}}
    end),
    meck:expect(asobi_repo, delete_all, fun(_Q) -> {ok, 1} end),
    meck:expect(asobi_repo, delete, fun(asobi_player, _Player) -> {ok, #{}} end),
    meck:expect(asobi_repo, transaction, fun(Fun) -> Fun() end).

wait_for_sweep(0) ->
    meck:num_calls(asobi_repo, all, '_') > 0;
wait_for_sweep(Attempts) ->
    case meck:num_calls(asobi_repo, all, '_') > 0 of
        true ->
            true;
        false ->
            timer:sleep(25),
            wait_for_sweep(Attempts - 1)
    end.
