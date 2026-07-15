-module(asobi_body_cap_plugin_tests).
-include_lib("eunit/include/eunit.hrl").

%% H2 (2026-05-19): the body cap plugin must short-circuit oversized requests
%% before any body bytes are buffered. We meck cowboy_req so the test does not
%% need a real socket — the plugin should only call has_body/1, body_length/1
%% and (on reject) reply/4.

%% Cast a fake req map through dynamic() so eqwalizer accepts it as
%% cowboy_req:req() for the duration of the test. The plugin only touches the
%% three meck'd cowboy_req accessors above, so the underlying shape is fine.
-spec fake_req(map()) -> dynamic().
fake_req(M) -> M.

body_cap_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun no_body_passes/0,
        fun small_body_passes/0,
        fun oversized_body_rejected_413/0,
        fun chunked_without_length_rejected_411/0,
        fun chunked_allowed_when_opt_off/0
    ]}.

setup() ->
    meck:new(cowboy_req, [no_link, passthrough]),
    meck:expect(cowboy_req, reply, fun(Status, _Hdrs, _Body, Req) ->
        Req#{reply_status => Status}
    end),
    ok.

teardown(_) ->
    meck:unload(cowboy_req),
    ok.

no_body_passes() ->
    meck:expect(cowboy_req, has_body, fun(_) -> false end),
    Req = fake_req(#{method => ~"GET"}),
    ?assertMatch(
        {ok, _, undefined},
        asobi_body_cap_plugin:pre_request(Req, #{}, #{}, undefined)
    ).

small_body_passes() ->
    meck:expect(cowboy_req, has_body, fun(_) -> true end),
    meck:expect(cowboy_req, body_length, fun(_) -> 1024 end),
    Req = fake_req(#{method => ~"POST"}),
    ?assertMatch(
        {ok, _, undefined},
        asobi_body_cap_plugin:pre_request(Req, #{}, #{max_body => 1048576}, undefined)
    ).

oversized_body_rejected_413() ->
    meck:expect(cowboy_req, has_body, fun(_) -> true end),
    meck:expect(cowboy_req, body_length, fun(_) -> 2 * 1048576 end),
    Req = fake_req(#{method => ~"POST"}),
    {stop, ReplyReq, undefined} = asobi_body_cap_plugin:pre_request(
        Req, #{}, #{max_body => 1048576}, undefined
    ),
    ?assertEqual(413, maps:get(reply_status, ReplyReq)).

chunked_without_length_rejected_411() ->
    meck:expect(cowboy_req, has_body, fun(_) -> true end),
    meck:expect(cowboy_req, body_length, fun(_) -> undefined end),
    Req = fake_req(#{method => ~"POST"}),
    {stop, ReplyReq, undefined} = asobi_body_cap_plugin:pre_request(
        Req, #{}, #{require_content_length => true}, undefined
    ),
    ?assertEqual(411, maps:get(reply_status, ReplyReq)).

chunked_allowed_when_opt_off() ->
    meck:expect(cowboy_req, has_body, fun(_) -> true end),
    meck:expect(cowboy_req, body_length, fun(_) -> undefined end),
    Req = fake_req(#{method => ~"POST"}),
    ?assertMatch(
        {ok, _, undefined},
        asobi_body_cap_plugin:pre_request(
            Req, #{}, #{require_content_length => false}, undefined
        )
    ).
