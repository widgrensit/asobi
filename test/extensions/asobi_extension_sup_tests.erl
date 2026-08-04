-module(asobi_extension_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QUESTS, asobi_fixture_quests).
-define(CLANS, asobi_fixture_clans).

extension_sup_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun no_extensions_means_no_children/0,
        fun each_extension_gets_its_own_sub_supervisor/0,
        fun a_spent_extension_goes_dark_alone/0,
        fun nothing_starts_when_migrations_did_not_complete/0
    ]}.

%% Extension children start after migrations, so the ready marker is the
%% precondition every case here but the last one runs under.
setup() ->
    asobi_extensions:reset(),
    asobi_readiness:reset(),
    ok = asobi_readiness:mark_ready(),
    ok.

cleanup(_) ->
    stop_sup(),
    _ = [asobi_fixture_app:uninstall(A) || A <- [?QUESTS, ?CLANS]],
    application:unset_env(asobi, extension_restart),
    _ = logger:remove_handler(asobi_fixture_log),
    asobi_readiness:reset(),
    asobi_extensions:reset(),
    ok.

%% Inert with nothing installed: one idle supervisor, no children, no timers,
%% no tables.
no_extensions_means_no_children() ->
    {ok, Pid} = asobi_extension_sup:start_link(),
    ?assertEqual([], supervisor:which_children(Pid)),
    ?assertEqual([], asobi_extension_sup:running()).

each_extension_gets_its_own_sub_supervisor() ->
    install_both(),
    {ok, _Pid} = asobi_extension_sup:start_link(),
    ?assertEqual([clans, quests], lists:sort(asobi_extension_sup:running())),
    ?assert(is_pid(whereis(asobi_fixture_quests_worker))),
    ?assert(is_pid(whereis(asobi_fixture_clans_worker))),
    %% Each sub-supervisor is a supervisor of its own, not a flat list of the
    %% extensions' children under one shared restart budget.
    [?assert(is_pid(sub_sup(Name))) || Name <- [quests, clans]].

%% The whole point of the tree. quests burns its own restart budget; the node,
%% asobi_extension_sup and clans are all untouched, and core says which one
%% went dark.
a_spent_extension_goes_dark_alone() ->
    application:set_env(asobi, extension_restart, #{intensity => 0, period => 1}),
    install_both(),
    {ok, Top} = asobi_extension_sup:start_link(),
    ok = logger:add_handler(asobi_fixture_log, asobi_fixture_log_handler, #{
        level => all, config => #{pid => self()}
    }),
    QuestsSup = sub_sup(quests),
    Ref = erlang:monitor(process, QuestsSup),
    ok = asobi_fixture_worker:crash(asobi_fixture_quests_worker),
    receive
        {'DOWN', Ref, process, QuestsSup, _} -> ok
    after 5000 -> erlang:error(sub_supervisor_survived_its_budget)
    end,
    ?assertEqual([quests], await_down_log()),
    ?assert(is_process_alive(Top)),
    ?assert(is_process_alive(whereis(asobi_extension_watch))),
    ?assertEqual([clans], asobi_extension_sup:running()),
    ?assert(is_pid(whereis(asobi_fixture_clans_worker))).

%% asobi#369. An extension child that queries at init/1 must not have to carry a
%% retry path around a database that is not there. Migrations run to completion
%% before asobi_sup starts, so if the marker is false they failed: start nothing,
%% say which extensions did not start, and leave a crash loop unwritten. The
%% answer cannot flip afterwards - mark_ready/0 is called once, before this
%% supervisor exists - so there is nothing to retry.
nothing_starts_when_migrations_did_not_complete() ->
    install_both(),
    asobi_readiness:reset(),
    ok = logger:add_handler(asobi_fixture_log, asobi_fixture_log_handler, #{
        level => all, config => #{pid => self()}
    }),
    {ok, Pid} = asobi_extension_sup:start_link(),
    ?assertEqual([], supervisor:which_children(Pid)),
    ?assertEqual([], asobi_extension_sup:running()),
    ?assertEqual(undefined, whereis(asobi_fixture_quests_worker)),
    ?assertEqual([quests, clans], await_not_started_log()).

%% --- Helpers ---

install_both() ->
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    ok = asobi_fixture_app:install(?CLANS, asobi_fixture_clans_extension, [?QUESTS]).

sub_sup(Name) ->
    {Name, Pid, _Type, _Modules} = lists:keyfind(
        Name, 1, supervisor:which_children(asobi_extension_sup)
    ),
    Pid.

await_down_log() ->
    receive
        {log_event, #{msg := {report, #{msg := ~"extension_down", extension := Name}}}} ->
            [Name];
        {log_event, _Other} ->
            await_down_log()
    after 5000 -> []
    end.

await_not_started_log() ->
    receive
        {log_event, #{msg := {report, #{msg := ~"extensions_not_started", extensions := Names}}}} ->
            Names;
        {log_event, _Other} ->
            await_not_started_log()
    after 5000 -> []
    end.

stop_sup() ->
    case whereis(asobi_extension_sup) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            unlink(Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end
    end.
