-module(asobi_security_headers_plugin_tests).

-include_lib("eunit/include/eunit.hrl").

%% Every header below is load-bearing and removable in one line. Without
%% an assertion, dropping HSTS or relaxing x-frame-options is a silent
%% change that no suite notices, so the set is pinned by value.

-define(EXPECTED, #{
    ~"x-content-type-options" => ~"nosniff",
    ~"x-frame-options" => ~"DENY",
    ~"x-xss-protection" => ~"0",
    ~"referrer-policy" => ~"strict-origin-when-cross-origin",
    ~"permissions-policy" => ~"camera=(), microphone=(), geolocation=()",
    ~"strict-transport-security" => ~"max-age=31536000; includeSubDomains"
}).

post_request_sets_every_security_header_test() ->
    {ok, Req, _State} = asobi_security_headers_plugin:post_request(#{}, #{}, #{}, state),
    ?assertEqual(?EXPECTED, maps:get(resp_headers, Req)).

post_request_preserves_existing_headers_test() ->
    Req0 = #{resp_headers => #{~"content-type" => ~"application/json"}},
    {ok, Req, _State} = asobi_security_headers_plugin:post_request(Req0, #{}, #{}, state),
    Headers = maps:get(resp_headers, Req),
    ?assertEqual(~"application/json", maps:get(~"content-type", Headers)),
    ?assertEqual(~"DENY", maps:get(~"x-frame-options", Headers)).

%% A controller that has already set one of these headers must not have it
%% silently overridden with a weaker default, nor the reverse - pin which
%% way the merge goes so a cowboy change cannot flip it unnoticed.
post_request_overrides_a_weaker_value_test() ->
    Req0 = #{resp_headers => #{~"x-frame-options" => ~"SAMEORIGIN"}},
    {ok, Req, _State} = asobi_security_headers_plugin:post_request(Req0, #{}, #{}, state),
    ?assertEqual(~"DENY", maps:get(~"x-frame-options", maps:get(resp_headers, Req))).

post_request_passes_the_state_through_test() ->
    ?assertMatch(
        {ok, _, my_state}, asobi_security_headers_plugin:post_request(#{}, #{}, #{}, my_state)
    ).

pre_request_is_a_passthrough_test() ->
    Req0 = #{resp_headers => #{~"content-type" => ~"application/json"}},
    ?assertEqual(
        {ok, Req0, my_state}, asobi_security_headers_plugin:pre_request(Req0, #{}, #{}, my_state)
    ).

plugin_info_is_complete_test() ->
    Info = asobi_security_headers_plugin:plugin_info(),
    [?assert(maps:is_key(K, Info)) || K <- [title, version, url, authors, description]].
