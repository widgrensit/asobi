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
