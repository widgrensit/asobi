-module(asobi_dgram_rpc_tests).
-include_lib("eunit/include/eunit.hrl").

%% The capture handler the dispatcher calls back into.
-export([capture/2]).

%% The player-facing mint, and the built-in method table it arrives through.

rpc_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"the mint is reachable as a built-in rpc method", fun reachable_as_builtin/0},
        {"an unconfigured plane is unavailable, not unknown", fun unavailable_not_unknown/0},
        {"a built-in cannot be shadowed by an extension", fun not_shadowable/0},
        {"close refuses a missing conn_id", fun close_refuses_bad_params/0},
        {"the negotiated wire reaches the handler", fun wire_reaches_the_handler/0},
        {"a caller without a wire is json", fun wireless_caller_is_json/0}
    ]}.

%% The mint sits behind the same readiness guard as every other RPC method, which
%% is correct: an engine still starting has no session to bind a credential to.
setup() -> asobi_readiness:mark_ready().
cleanup(_) -> asobi_readiness:reset().

%% The whole point of putting the mint on rpc.call: the datagram plane adds ZERO
%% frame types to the JSON wire, because rpc.call / rpc.ok / rpc.error are already
%% frozen and already implemented in every SDK.
reachable_as_builtin() ->
    ?assertMatch(
        {_Cid, {error, #{error := #{code := ~"datagram_unavailable"}}}},
        asobi_rpc:handle(~"c-1", call(~"asobi.datagram.open", #{}), caller())
    ).

%% An unconfigured plane answers "not available" rather than "no such method". A
%% client must be able to tell "this server has no datagram plane today" from
%% "this server is too old to have one", because the first is worth retrying and
%% the second is not.
unavailable_not_unknown() ->
    {_Cid, Outcome} = asobi_rpc:handle(~"c-2", call(~"asobi.datagram.open", #{}), caller()),
    ?assertNotMatch({error, #{error := #{code := ~"rpc.unknown_method"}}}, Outcome).

%% The reserved prefix. An extension declaring asobi.datagram.open must not be
%% able to intercept the mint, so built-ins are looked up first.
not_shadowable() ->
    meck:new(asobi_extensions, [passthrough, non_strict]),
    try
        meck:expect(asobi_extensions, rpc_methods, 0, #{
            ~"asobi.datagram.open" => {?MODULE, hijacked, 2}
        }),
        {_Cid, Outcome} = asobi_rpc:handle(~"c-3", call(~"asobi.datagram.open", #{}), caller()),
        ?assertNotMatch({ok, hijacked}, Outcome)
    after
        meck:unload(asobi_extensions)
    end.

%% close/2 validates its own params rather than trusting the caller, like every
%% other method on this surface.
close_refuses_bad_params() ->
    ?assertEqual({error, ~"rpc.invalid_params"}, asobi_dgram_rpc:close(#{}, caller())),
    ?assertEqual(
        {error, ~"rpc.invalid_params"},
        asobi_dgram_rpc:close(#{~"conn_id" => ~"not a number"}, caller())
    ).

%% asobi#527: `invoke/5` rebuilds the ctx from a whitelist, so a key the socket
%% deliberately put on the caller is dropped unless it is on that list. `wire`
%% was not, and the mint records "can this connection resolve a pose?" from it,
%% so every binary-wire session was minted as JSON and no pose was ever sent.
wire_reaches_the_handler() ->
    Ctx = dispatch_to_capture((caller())#{wire => ~"binary"}),
    ?assertEqual(~"binary", maps:get(wire, Ctx, undefined)).

%% An HTTP caller has no WebSocket and therefore no wire. It is the same answer
%% as the text wire - mint, but never a pose target - so it defaults rather than
%% being absent, which would make every handler re-state the default.
wireless_caller_is_json() ->
    Ctx = dispatch_to_capture(caller()),
    ?assertEqual(~"json", maps:get(wire, Ctx, undefined)).

%% --- Helpers ---

%% Dispatches through the real table to a handler that hands its ctx back, which
%% is the only way to see what the whitelist actually let through.
dispatch_to_capture(Caller) ->
    meck:new(asobi_extensions, [passthrough, non_strict]),
    try
        meck:expect(asobi_extensions, rpc_methods, 0, #{
            ~"capture.ctx" => {?MODULE, capture, 2}
        }),
        {_Cid, {ok, _}} = asobi_rpc:handle(~"c-4", call(~"capture.ctx", #{}), Caller),
        receive
            {captured, Ctx} -> Ctx
        after 1000 -> erlang:error(handler_never_ran)
        end
    after
        meck:unload(asobi_extensions)
    end.

capture(_Params, Ctx) ->
    self() ! {captured, Ctx},
    {ok, #{}}.

call(Method, Params) ->
    #{~"protocol" => 1, ~"method" => Method, ~"params" => Params}.

caller() ->
    #{player_id => ~"p1", session => self(), transport => ws}.
