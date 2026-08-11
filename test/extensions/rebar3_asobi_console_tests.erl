-module(rebar3_asobi_console_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- The generated registry ---

registry_emits_one_static_import_per_extension_test() ->
    Js = generated([
        #{app => asobi_quests, name => "quests", dir => "/x"},
        #{app => asobi_clans, name => "clans", dir => "/y"}
    ]),
    ?assertNotEqual(
        nomatch, binary:match(Js, ~"import ext_quests from '../extensions/quests/index.jsx';")
    ),
    ?assertNotEqual(
        nomatch, binary:match(Js, ~"import ext_clans from '../extensions/clans/index.jsx';")
    ),
    ?assertNotEqual(
        nomatch, binary:match(Js, ~"export const extensions = [ext_quests, ext_clans];")
    ).

%% A lazily imported chunk is refused by the console's CSP rather than merely
%% arriving late, which is the whole reason this is a build step.
registry_never_emits_a_dynamic_import_test() ->
    Js = generated([#{app => asobi_quests, name => "quests", dir => "/x"}]),
    ?assertEqual(nomatch, binary:match(Js, ~"import(")).

registry_with_no_extensions_matches_the_committed_stub_test() ->
    ?assertNotEqual(nomatch, binary:match(generated([]), ~"export const extensions = [];")).

%% --- The generated Vite config ---

host_config_carries_the_port_and_target_through_test() ->
    Js = config("/out", [{port, 6000}, {target, "http://node:8082"}]),
    ?assertNotEqual(nomatch, binary:match(Js, ~"port: 6000")),
    ?assertNotEqual(nomatch, binary:match(Js, ~"http://node:8082")),
    ?assertNotEqual(nomatch, binary:match(Js, ~"preserveSymlinks: true")),
    ?assertNotEqual(nomatch, binary:match(Js, ~"cookieDomainRewrite")).

host_config_defaults_the_port_and_target_test() ->
    Js = config("/out", []),
    ?assertNotEqual(nomatch, binary:match(Js, ~"port: 5173")),
    ?assertNotEqual(nomatch, binary:match(Js, ~"http://localhost:8082")).

%% --- Quoting into that config ---

%% A value ending in a backslash used to escape the quote meant to close the
%% literal it sits in, which put the rest of the argument in the generated
%% config as JavaScript that `vite` then ran.
quote_does_not_let_a_backslash_close_the_literal_test() ->
    ?assertEqual(~"\"x\\\\\"", quoted("x\\")).

quote_escapes_an_embedded_quote_test() ->
    ?assertEqual(~"\"a\\\"b\"", quoted("a\"b")).

quote_escapes_a_newline_rather_than_breaking_the_file_test() ->
    ?assertEqual(~"\"a\\nb\"", quoted("a\nb")).

quote_leaves_an_ordinary_path_alone_test() ->
    ?assertEqual(~"\"/srv/game/priv/console\"", quoted("/srv/game/priv/console")).

%% The escape has to survive the round trip, not merely look escaped: the
%% generated file is read back by node.
quote_round_trips_through_json_test() ->
    [
        ?assertEqual(unicode:characters_to_binary(Value), json:decode(quoted(Value)))
     || Value <- ["x\\", "a\"b", "a\nb", "/srv/console", "c:\\build\\out"]
    ].

%% --- Discovery ---

with_console_skips_an_extension_with_no_index_jsx_test() ->
    Dir = tmpdir(),
    ok = filelib:ensure_path(filename:join([Dir, "priv", "console"])),
    ?assertEqual(none, rebar3_asobi_console:with_console(#{app => a, name => q}, #{a => Dir})).

with_console_finds_one_that_has_it_test() ->
    Dir = tmpdir(),
    Console = filename:join([Dir, "priv", "console"]),
    ok = filelib:ensure_path(Console),
    ok = file:write_file(filename:join(Console, "index.jsx"), ~"export default {};"),
    ?assertEqual(
        {ok, #{app => a, name => "q", dir => Console}},
        rebar3_asobi_console:with_console(#{app => a, name => q}, #{a => Dir})
    ).

with_console_skips_an_extension_whose_app_is_not_in_the_build_test() ->
    ?assertEqual(none, rebar3_asobi_console:with_console(#{app => a, name => q}, #{})).

console_source_refuses_a_tree_without_package_json_test() ->
    ?assertMatch(
        {error, {no_console_source, _}},
        rebar3_asobi_console:console_source(#{asobi => tmpdir()})
    ).

console_source_refuses_a_project_without_asobi_test() ->
    ?assertEqual({error, no_asobi}, rebar3_asobi_console:console_source(#{other => "/x"})).

%% --- Reporting ---

%% Every failure this module can reach is a sentence an operator can act on,
%% not a term. That is the whole reason the error paths are named.
every_error_term_has_a_sentence_test() ->
    Terms = [
        {no_console_source, "/x"},
        no_asobi,
        no_output,
        {unknown_output_app, game_console},
        invalid_extension_set,
        {symlink_failed, "quests", eperm},
        {write_failed, "/x", enospc},
        {write_failed, "/x", invalid_unicode},
        {command_failed, "npm ci", 1}
    ],
    [
        begin
            Sentence = rebar3_asobi_console:format_error(Term),
            ?assert(is_list(Sentence)),
            ?assert(length(Sentence) > 20)
        end
     || Term <- Terms
    ].

%% --- Helpers ---

generated(Extensions) ->
    unicode:characters_to_binary(rebar3_asobi_console:registry(Extensions)).

config(Out, Args) ->
    unicode:characters_to_binary(rebar3_asobi_console:host_config(Out, Args)).

quoted(Value) ->
    unicode:characters_to_binary(rebar3_asobi_console:quote(Value)).

tmpdir() ->
    Dir = filename:join(["/tmp", "rebar3_asobi_console_tests", unique()]),
    ok = filelib:ensure_path(Dir),
    Dir.

unique() ->
    integer_to_list(erlang:unique_integer([positive])).
