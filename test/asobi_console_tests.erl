-module(asobi_console_tests).

-include_lib("eunit/include/eunit.hrl").

%% The console bundle is the one place in asobi where a request names a file.
%% These tests pin the property that makes that safe: the served set comes
%% from the build manifest, never from a directory listing and never from a
%% path joined onto user input, so a name the manifest does not carry is not
%% reachable however it is spelled.
%%
%% Every `load/1` here runs while the fixture directory still exists. Deferring
%% it into an `?_assert` would run it after cleanup and turn every refusal
%% test into an `enoent` that passes for the wrong reason.

-define(TMP, "_build/test/console_fixtures").

setup() ->
    Dir = filename:join(?TMP, integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(filename:join(Dir, "assets")),
    Dir.

cleanup(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

fixture(Test) ->
    {setup, fun setup/0, fun cleanup/1, Test}.

write(Dir, Rel, Body) ->
    Path = filename:join(Dir, Rel),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Body).

manifest(Dir, Json) ->
    write(Dir, "manifest.json", Json).

%% The shape the committed build actually produces.
standard(Dir) ->
    manifest(
        Dir,
        ~"""
        {"src/main.jsx": {"file": "assets/main-Ca5kJxSg.js", "isEntry": true},
         "style.css": {"file": "assets/style-BFsHCePs.css"}}
        """
    ),
    write(Dir, "assets/main-Ca5kJxSg.js", ~"export default 1;"),
    write(Dir, "assets/style-BFsHCePs.css", ~"body{}").

refused(Json) ->
    fun(Dir) ->
        manifest(Dir, Json),
        asobi_console:load(Dir)
    end.

committed() ->
    asobi_console:load(filename:join(code:priv_dir(asobi), "console")).

%%--------------------------------------------------------------------
%% The happy path
%%--------------------------------------------------------------------

loads_the_entry_and_its_stylesheet_test_() ->
    fixture(fun(Dir) ->
        standard(Dir),
        {ok, Bundle} = asobi_console:load(Dir),
        [
            ?_assertEqual(~"main-Ca5kJxSg.js", maps:get(script, Bundle)),
            %% Vite emits the entry's CSS as its own manifest chunk when code
            %% splitting is off, so reading only the entry's `css` key gives a
            %% console with no styles and no error anywhere.
            ?_assertEqual([~"style-BFsHCePs.css"], maps:get(styles, Bundle)),
            ?_assertEqual(
                [~"main-Ca5kJxSg.js", ~"style-BFsHCePs.css"],
                lists:sort(maps:keys(maps:get(assets, Bundle)))
            )
        ]
    end).

carries_mime_and_a_strong_etag_test_() ->
    fixture(fun(Dir) ->
        standard(Dir),
        {ok, #{assets := Assets}} = asobi_console:load(Dir),
        #{~"main-Ca5kJxSg.js" := Js, ~"style-BFsHCePs.css" := Css} = Assets,
        [
            ?_assertEqual(~"text/javascript; charset=utf-8", maps:get(mime, Js)),
            ?_assertEqual(~"text/css; charset=utf-8", maps:get(mime, Css)),
            ?_assertMatch(<<$", _:32/binary, $">>, maps:get(etag, Js)),
            ?_assertNotEqual(maps:get(etag, Js), maps:get(etag, Css))
        ]
    end).

%%--------------------------------------------------------------------
%% What the manifest is not allowed to say
%%
%% A manifest is written by a third-party bundler and then read off disk. If
%% it can name `../../rebar.config` the hardening is decorative.
%%--------------------------------------------------------------------

refuses_a_traversal_in_a_manifest_path_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/../../rebar.config", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {bad_asset_name, _}}, Refused(Dir)) end).

refuses_a_name_with_a_separator_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/nested/main.js", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {bad_asset_name, _}}, Refused(Dir)) end).

refuses_a_path_outside_the_assets_directory_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "main.js", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {bad_asset_name, _}}, Refused(Dir)) end).

%% The bare dot segment, which the separator rule alone does not catch.
refuses_a_bare_dot_segment_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/..", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {bad_asset_name, _}}, Refused(Dir)) end).

refuses_a_dotfile_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/.env", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {bad_asset_name, _}}, Refused(Dir)) end).

%% An extension the MIME map does not carry is refused at load, not served as
%% octet-stream and not 404-ed per request, so a build that starts emitting
%% something new breaks loudly and once.
refuses_an_unmapped_extension_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/main.wasm", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertMatch({error, {unknown_asset_type, _}}, Refused(Dir)) end).

%%--------------------------------------------------------------------
%% Failures that must not crash a request
%%--------------------------------------------------------------------

missing_manifest_is_an_error_not_a_crash_test_() ->
    fixture(fun(Dir) ->
        ?_assertMatch({error, {manifest_unreadable, enoent}}, asobi_console:load(Dir))
    end).

unparseable_manifest_is_an_error_test_() ->
    Refused = refused(~"not json at all"),
    fixture(fun(Dir) -> ?_assertMatch({error, {manifest_not_json, _}}, Refused(Dir)) end).

manifest_with_no_entry_is_an_error_test_() ->
    Refused = refused(
        ~"""
    {"style.css": {"file": "assets/style.css"}}
    """
    ),
    fixture(fun(Dir) -> ?_assertEqual({error, no_entry}, Refused(Dir)) end).

manifest_with_two_entries_is_an_error_test_() ->
    Refused = refused(
        ~"""
    {"a": {"file": "assets/a.js", "isEntry": true},
     "b": {"file": "assets/b.js", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) -> ?_assertEqual({error, no_entry}, Refused(Dir)) end).

declared_but_absent_file_is_an_error_test_() ->
    Refused = refused(
        ~"""
    {"m": {"file": "assets/gone.js", "isEntry": true}}
    """
    ),
    fixture(fun(Dir) ->
        ?_assertMatch({error, {asset_unreadable, ~"gone.js", enoent}}, Refused(Dir))
    end).

%%--------------------------------------------------------------------
%% The committed bundle
%%
%% `priv/console` is committed, so these assert about the artefact that ships
%% rather than about a fixture.
%%--------------------------------------------------------------------

committed_bundle_loads_test() ->
    {ok, Bundle} = committed(),
    ?assertMatch(#{script := <<"main-", _/binary>>}, Bundle),
    ?assertMatch([<<"style-", _/binary>>], maps:get(styles, Bundle)).

%% One chunk, because `script-src` is a bare nonce with no host source and a
%% nonce does not propagate to a module's static imports. A code-split build
%% would fetch its second chunk, be refused by the browser, and leave nothing
%% in the Erlang logs to say why the console is blank.
committed_bundle_is_a_single_script_test() ->
    {ok, #{assets := Assets}} = committed(),
    Scripts = [Name || Name <- maps:keys(Assets), filename:extension(Name) =:= ~".js"],
    ?assertEqual(1, length(Scripts)).

%% `unsafe-eval` is not in the policy, so a bundle that compiles strings to
%% code is a blank console. Nothing in the JS toolchain enforces that.
committed_bundle_needs_no_unsafe_eval_test() ->
    {ok, #{assets := Assets, script := Script}} = committed(),
    #{Script := #{body := Body}} = Assets,
    ?assertEqual(nomatch, binary:match(Body, ~"new Function(")),
    ?assertEqual(nomatch, binary:match(Body, ~"eval(")).

%%--------------------------------------------------------------------
%% The switch
%%--------------------------------------------------------------------

disabled_by_default_test() ->
    Was = application:get_env(asobi, console),
    application:unset_env(asobi, console),
    try
        ?assertNot(asobi_console:enabled())
    after
        restore(console, Was)
    end.

enabled_only_by_true_test() ->
    Was = application:get_env(asobi, console),
    try
        application:set_env(asobi, console, ~"yes"),
        ?assertNot(asobi_console:enabled()),
        application:set_env(asobi, console, true),
        ?assert(asobi_console:enabled())
    after
        restore(console, Was)
    end.

%%--------------------------------------------------------------------
%% Which application's bundle is served
%%
%% A host whose extensions ship console screens composes its own bundle with
%% `rebar3 asobi console` and points `console_bundle_app` at the application it
%% was written into. Getting that wrong must not quietly serve asobi's own
%% bundle: the screens the host built the thing for are exactly the ones that
%% would be missing, with nothing saying so.
%%--------------------------------------------------------------------

serves_asobis_own_bundle_when_unconfigured_test() ->
    Was = application:get_env(asobi, console_bundle_app),
    application:unset_env(asobi, console_bundle_app),
    asobi_console:reset(),
    try
        ?assertMatch({ok, #{script := <<"main-", _/binary>>}}, asobi_console:bundle())
    after
        restore(console_bundle_app, Was),
        asobi_console:reset()
    end.

refuses_a_bundle_app_that_is_not_in_the_release_test() ->
    Was = application:get_env(asobi, console_bundle_app),
    asobi_console:reset(),
    try
        application:set_env(asobi, console_bundle_app, no_such_application),
        ?assertEqual(
            {error, {bundle_app_unavailable, no_such_application}},
            asobi_console:bundle()
        ),
        %% And nothing is reachable through it either, rather than falling
        %% through to whatever asobi's own bundle holds under the same name.
        ?assertEqual(error, asobi_console:asset(~"main-Ca5kJxSg.js"))
    after
        restore(console_bundle_app, Was),
        asobi_console:reset()
    end.

restore(Key, {ok, Value}) -> application:set_env(asobi, Key, Value);
restore(Key, undefined) -> application:unset_env(asobi, Key).
