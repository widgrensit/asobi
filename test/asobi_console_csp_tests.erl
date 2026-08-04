-module(asobi_console_csp_tests).

-include_lib("eunit/include/eunit.hrl").

%% The policy is the console's security boundary, not a header it happens to
%% send. These tests hold the two halves of that: what must be in it, and what
%% must never be.

directives(Policy) ->
    [string:trim(Directive) || Directive <- binary:split(Policy, ~";", [global])].

directive(Policy, Name) ->
    Prefix = <<Name/binary, " ">>,
    Size = byte_size(Prefix),
    case [D || <<P:Size/binary, _/binary>> = D <- directives(Policy), P =:= Prefix] of
        [Found] -> Found;
        Other -> Other
    end.

with_base(Value, Test) ->
    Was = application:get_env(asobi, console_api_base),
    try
        application:set_env(asobi, console_api_base, Value),
        Test()
    after
        case Was of
            {ok, Old} -> application:set_env(asobi, console_api_base, Old);
            undefined -> application:unset_env(asobi, console_api_base)
        end
    end.

%%--------------------------------------------------------------------
%% What must be there
%%--------------------------------------------------------------------

shell_denies_everything_by_default_test() ->
    ?assertEqual(~"default-src 'none'", hd(directives(asobi_console_csp:shell(~"abc")))).

shell_allows_only_the_nonced_script_test() ->
    ?assertEqual(
        ~"script-src 'nonce-abc'", directive(asobi_console_csp:shell(~"abc"), ~"script-src")
    ).

%% `'self'` in `script-src` alongside the nonce would let an injected
%% `<script src="/console/assets/...">` run. The nonce is the whole point.
shell_script_src_has_no_host_source_test() ->
    Policy = asobi_console_csp:shell(~"abc"),
    ?assertEqual(nomatch, binary:match(directive(Policy, ~"script-src"), ~"'self'")).

shell_names_every_directive_the_page_needs_test() ->
    Policy = asobi_console_csp:shell(~"abc"),
    [
        ?assertNotEqual([], directive(Policy, Name), Name)
     || Name <- [
            ~"default-src",
            ~"script-src",
            ~"style-src",
            ~"img-src",
            ~"font-src",
            ~"connect-src",
            ~"base-uri",
            ~"form-action",
            ~"frame-ancestors",
            ~"object-src"
        ]
    ].

%% Inline `style=` attributes fall back to `style-src`, so the absence of
%% `style-src-attr` is what makes the no-inline-styles rule enforceable rather
%% than a convention.
shell_has_no_style_src_attr_escape_hatch_test() ->
    Policy = asobi_console_csp:shell(~"abc"),
    ?assertEqual([], directive(Policy, ~"style-src-attr")),
    ?assertEqual(~"style-src 'self'", directive(Policy, ~"style-src")).

asset_policy_makes_a_chunk_inert_as_a_document_test() ->
    ?assertEqual(
        ~"default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
        asobi_console_csp:asset()
    ).

%%--------------------------------------------------------------------
%% What must never be there
%%--------------------------------------------------------------------

no_unsafe_directive_anywhere_test() ->
    [
        ?assertEqual(nomatch, binary:match(Policy, Unsafe), {Policy, Unsafe})
     || Policy <- [asobi_console_csp:shell(~"abc"), asobi_console_csp:asset()],
        Unsafe <- [~"unsafe-inline", ~"unsafe-eval", ~"unsafe-hashes", ~"'*'", ~" *"]
    ].

%%--------------------------------------------------------------------
%% The nonce
%%--------------------------------------------------------------------

%% A reused nonce is not a nonce. The shell is served `no-store` for the same
%% reason, and both halves have to hold.
nonce_is_fresh_every_call_test() ->
    Nonces = [asobi_console_csp:nonce() || _ <- lists:seq(1, 50)],
    ?assertEqual(50, length(lists:usort(Nonces))).

nonce_is_long_enough_to_be_unguessable_test() ->
    ?assert(byte_size(base64:decode(asobi_console_csp:nonce())) >= 16).

%%--------------------------------------------------------------------
%% connect-src, which is configuration
%%--------------------------------------------------------------------

connect_src_is_self_when_unconfigured_test() ->
    with_base(undefined, fun() ->
        application:unset_env(asobi, console_api_base),
        ?assertEqual(
            ~"connect-src 'self'", directive(asobi_console_csp:shell(~"abc"), ~"connect-src")
        )
    end).

connect_src_admits_a_configured_origin_test() ->
    with_base(~"https://env-7.asobi.dev", fun() ->
        ?assertEqual(
            ~"connect-src 'self' https://env-7.asobi.dev",
            directive(asobi_console_csp:shell(~"abc"), ~"connect-src")
        )
    end).

%% A path would be ignored by the browser and would mislead whoever reads the
%% header, so it is refused rather than trimmed.
connect_src_refuses_a_base_with_a_path_test() ->
    with_base(~"https://env-7.asobi.dev/api", fun() ->
        ?assertEqual(none, asobi_console_csp:api_base()),
        ?assertEqual(
            ~"connect-src 'self'", directive(asobi_console_csp:shell(~"abc"), ~"connect-src")
        )
    end).

%% The one that matters: a value carrying a space or a semicolon could close
%% `connect-src` and open a directive of the attacker's choosing.
connect_src_refuses_a_base_that_could_inject_a_directive_test() ->
    [
        ?assertEqual(none, with_base(Base, fun asobi_console_csp:api_base/0), Base)
     || Base <- [
            ~"https://ok.example; script-src 'unsafe-inline'",
            ~"https://ok.example 'unsafe-eval'",
            ~"javascript:alert(1)",
            ~"//evil.example",
            ~"https://",
            ~"*"
        ]
    ].

connect_src_refuses_a_non_binary_base_test() ->
    ?assertEqual(none, with_base("https://string.example", fun asobi_console_csp:api_base/0)).
