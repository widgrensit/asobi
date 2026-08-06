-module(asobi_console_shell_tests).

-include_lib("eunit/include/eunit.hrl").

%% The shell is the only document asobi renders, and it is the document the
%% CSP is built around. Two properties carry the policy: there is exactly one
%% script tag and it carries the nonce, and there is no inline script at all -
%% which is what lets runtime configuration travel in `<meta>` tags without
%% `'unsafe-inline'`.

bundle() ->
    #{script => ~"main-abc.js", styles => [~"style-def.css"], assets => #{}}.

render() ->
    asobi_console_shell:render(~"N0nc3", bundle(), ~"0.59.0").

occurrences(Haystack, Needle) ->
    length(binary:matches(Haystack, Needle)).

%%--------------------------------------------------------------------
%% Scripts
%%--------------------------------------------------------------------

one_script_tag_and_it_is_nonced_test() ->
    Html = render(),
    ?assertEqual(1, occurrences(Html, ~"<script")),
    ?assertNotEqual(nomatch, binary:match(Html, ~"nonce=\"N0nc3\"")),
    ?assertNotEqual(nomatch, binary:match(Html, ~"src=\"/console/assets/main-abc.js\"")).

%% The measured difference between Vite and a Next.js static export, and the
%% reason the console is Vite: an inline script would need a hash or
%% `'unsafe-inline'` in the policy.
no_inline_script_body_test() ->
    Html = render(),
    ?assertEqual(nomatch, binary:match(Html, ~"</script><script")),
    ?assertEqual(1, occurrences(Html, ~"</script>")),
    ?assertEqual(nomatch, binary:match(Html, ~"window.")),
    ?assertEqual(nomatch, binary:match(Html, ~"onload=")).

every_stylesheet_is_linked_test() ->
    Bundle = (bundle())#{styles => [~"a.css", ~"b.css"]},
    Html = asobi_console_shell:render(~"N", Bundle, ~"0.59.0"),
    ?assertNotEqual(nomatch, binary:match(Html, ~"href=\"/console/assets/a.css\"")),
    ?assertNotEqual(nomatch, binary:match(Html, ~"href=\"/console/assets/b.css\"")).

%%--------------------------------------------------------------------
%% Runtime configuration
%%--------------------------------------------------------------------

carries_the_node_version_test() ->
    ?assertNotEqual(nomatch, binary:match(render(), ~"content=\"0.59.0\"")).

api_base_is_empty_when_same_origin_test() ->
    application:unset_env(asobi, console_api_base),
    ?assertNotEqual(
        nomatch, binary:match(render(), ~"<meta name=\"asobi-api-base\" content=\"\">")
    ).

api_base_is_advertised_when_configured_test() ->
    Was = application:get_env(asobi, console_api_base),
    try
        application:set_env(asobi, console_api_base, ~"https://env-7.asobi.dev"),
        ?assertNotEqual(
            nomatch,
            binary:match(
                render(), ~"<meta name=\"asobi-api-base\" content=\"https://env-7.asobi.dev\">"
            )
        )
    after
        restore(Was)
    end.

%%--------------------------------------------------------------------
%% Escaping
%%--------------------------------------------------------------------

escapes_every_dangerous_character_test() ->
    ?assertEqual(
        ~"&amp;&lt;&gt;&quot;&#39;",
        asobi_console_shell:escape(~"&<>\"'")
    ).

escapes_the_ampersand_first_test() ->
    ?assertEqual(~"&amp;lt;", asobi_console_shell:escape(~"&lt;")).

%% A configured base is already held to a scheme and an authority, but the
%% shell must not depend on that: a value that reaches an attribute is
%% escaped here whatever validated it upstream.
a_hostile_version_string_cannot_break_out_of_its_attribute_test() ->
    Html = asobi_console_shell:render(~"N", bundle(), ~"\"><script>alert(1)</script>"),
    ?assertEqual(1, occurrences(Html, ~"<script")),
    ?assertNotEqual(nomatch, binary:match(Html, ~"&quot;&gt;&lt;script&gt;")).

restore({ok, Value}) -> application:set_env(asobi, console_api_base, Value);
restore(undefined) -> application:unset_env(asobi, console_api_base).

%%--------------------------------------------------------------------
%% Target label
%%--------------------------------------------------------------------

%% An operator running several consoles needs to know which one a tab is.
%% The label reaches the page through a meta tag like every other runtime
%% value, so it costs the CSP nothing.

with_env(Key, Value, Fun) ->
    Prev = application:get_env(asobi, Key),
    application:set_env(asobi, Key, Value),
    try
        Fun()
    after
        case Prev of
            {ok, Old} -> application:set_env(asobi, Key, Old);
            undefined -> application:unset_env(asobi, Key)
        end
    end.

unlabelled_deployments_keep_the_plain_title_test() ->
    with_env(console_label, undefined, fun() ->
        application:unset_env(asobi, console_label),
        Html = render(),
        ?assertEqual(1, occurrences(Html, ~"<title>asobi ops</title>")),
        ?assertEqual(1, occurrences(Html, ~"name=\"asobi-target-label\" content=\"\""))
    end).

a_label_reaches_the_tab_title_test() ->
    with_env(console_label, ~"staging", fun() ->
        Html = render(),
        ?assertEqual(1, occurrences(Html, ~"<title>asobi ops - staging</title>")),
        ?assertEqual(1, occurrences(Html, ~"name=\"asobi-target-label\" content=\"staging\""))
    end).

%% The label is operator-supplied config that lands in an attribute and in the
%% title. Both are escaped by the same helper every other value uses.
a_label_cannot_break_out_of_its_attribute_test() ->
    with_env(console_label, ~"\"><script>alert(1)</script>", fun() ->
        Html = render(),
        ?assertEqual(0, occurrences(Html, ~"<script>alert(1)</script>")),
        %% Twice: the label lands in the title and in the meta attribute, and
        %% both go through the same escape.
        ?assertEqual(2, occurrences(Html, ~"&lt;script&gt;")),
        ?assertEqual(0, occurrences(Html, ~"content=\"\"><script"))
    end).

production_defaults_to_false_test() ->
    application:unset_env(asobi, console_production),
    Html = render(),
    ?assertEqual(1, occurrences(Html, ~"name=\"asobi-target-production\" content=\"false\"")).

production_is_marked_when_set_test() ->
    with_env(console_production, true, fun() ->
        Html = render(),
        ?assertEqual(1, occurrences(Html, ~"name=\"asobi-target-production\" content=\"true\""))
    end).
