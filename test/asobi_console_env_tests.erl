-module(asobi_console_env_tests).

-include_lib("eunit/include/eunit.hrl").

%% The console is off unless a deployment asked for it AND gave it something to
%% authenticate against. Everything here is about that pair, because the shape
%% that actually hurts is "enabled, no secret": a sign-in screen nothing can
%% pass looks like it works.

setup() ->
    Keys = [console, ops_secret, console_label, console_production],
    Saved = [{K, application:get_env(asobi, K)} || K <- Keys],
    Vars = [
        "ASOBI_CONSOLE",
        "ASOBI_OPS_SECRET",
        "ASOBI_OPS_SECRET_FILE",
        "ASOBI_CONSOLE_LABEL",
        "ASOBI_CONSOLE_PRODUCTION"
    ],
    [os:unsetenv(V) || V <- Vars],
    [application:unset_env(asobi, K) || K <- Keys],
    {Saved, Vars}.

cleanup({Saved, Vars}) ->
    [os:unsetenv(V) || V <- Vars],
    [
        case Prev of
            {ok, Value} -> application:set_env(asobi, K, Value);
            undefined -> application:unset_env(asobi, K)
        end
     || {K, Prev} <- Saved
    ],
    ok.

with_env(Fun) ->
    {setup, fun setup/0, fun cleanup/1, [Fun]}.

env(Key) -> application:get_env(asobi, Key, undefined).

%%--------------------------------------------------------------------

an_absent_environment_changes_nothing_test_() ->
    with_env(fun() ->
        application:set_env(asobi, console, true),
        application:set_env(asobi, ops_secret, ~"from-sys-config"),
        asobi_console_env:apply(),
        %% A self-hoster who wrote a sys.config keeps it: OS variables override
        %% only when they are actually set.
        ?assertEqual(true, env(console)),
        ?assertEqual(~"from-sys-config", env(ops_secret))
    end).

enabling_without_a_secret_leaves_the_console_off_test_() ->
    with_env(fun() ->
        os:putenv("ASOBI_CONSOLE", "true"),
        asobi_console_env:apply(),
        ?assertEqual(false, env(console))
    end).

enabling_with_a_secret_turns_it_on_test_() ->
    with_env(fun() ->
        os:putenv("ASOBI_CONSOLE", "true"),
        os:putenv("ASOBI_OPS_SECRET", "a-secret-long-enough-to-be-real"),
        asobi_console_env:apply(),
        ?assertEqual(true, env(console)),
        ?assertEqual(~"a-secret-long-enough-to-be-real", env(ops_secret))
    end).

%% A typo must close the surface, not open it.
only_the_words_meaning_yes_enable_it_test_() ->
    with_env(fun() ->
        os:putenv("ASOBI_OPS_SECRET", "s3cret"),
        [
            begin
                os:putenv("ASOBI_CONSOLE", V),
                application:unset_env(asobi, console),
                asobi_console_env:apply(),
                ?assertEqual(true, env(console))
            end
         || V <- ["1", "true", "TRUE", "yes", "on"]
        ],
        [
            begin
                os:putenv("ASOBI_CONSOLE", V),
                application:unset_env(asobi, console),
                asobi_console_env:apply(),
                ?assertEqual(false, env(console))
            end
         || V <- ["0", "false", "no", "off", "ture", "please"]
        ]
    end).

%% Secrets belong in files: a file keeps them out of `docker inspect`, out of
%% the process environment, and out of a compose file that ends up in git.
a_secret_file_beats_the_plain_variable_test_() ->
    with_env(fun() ->
        Path = write_temp(~"secret-from-a-file\n"),
        os:putenv("ASOBI_OPS_SECRET", "secret-from-the-environment"),
        os:putenv("ASOBI_OPS_SECRET_FILE", Path),
        os:putenv("ASOBI_CONSOLE", "true"),
        asobi_console_env:apply(),
        %% Trailing newline stripped: every tool that writes a secret file adds
        %% one, and a secret that fails to compare is indistinguishable from a
        %% wrong secret.
        ?assertEqual(~"secret-from-a-file", env(ops_secret)),
        ?assertEqual(true, env(console)),
        file:delete(Path)
    end).

%% A deployment that mounted a secret and got the path wrong must not come up
%% quietly using something else.
an_unreadable_secret_file_does_not_fall_back_test_() ->
    with_env(fun() ->
        os:putenv("ASOBI_OPS_SECRET", "secret-from-the-environment"),
        os:putenv("ASOBI_OPS_SECRET_FILE", "/nonexistent/ops_secret"),
        os:putenv("ASOBI_CONSOLE", "true"),
        asobi_console_env:apply(),
        ?assertEqual(undefined, env(ops_secret)),
        ?assertEqual(false, env(console))
    end).

an_empty_secret_file_does_not_enable_the_console_test_() ->
    with_env(fun() ->
        Path = write_temp(~"   \n"),
        os:putenv("ASOBI_OPS_SECRET_FILE", Path),
        os:putenv("ASOBI_CONSOLE", "true"),
        asobi_console_env:apply(),
        ?assertEqual(false, env(console)),
        file:delete(Path)
    end).

the_target_label_and_production_flag_come_from_the_environment_test_() ->
    with_env(fun() ->
        os:putenv("ASOBI_CONSOLE_LABEL", "prod-eu"),
        os:putenv("ASOBI_CONSOLE_PRODUCTION", "true"),
        asobi_console_env:apply(),
        ?assertEqual(~"prod-eu", env(console_label)),
        ?assertEqual(true, env(console_production))
    end).

write_temp(Contents) ->
    Path =
        lists:flatten(
            io_lib:format("/tmp/asobi_ops_secret_~p_~p", [erlang:unique_integer([positive]), self()])
        ),
    ok = file:write_file(Path, Contents),
    Path.
