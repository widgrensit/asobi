-module(asobi_dgram_rpc_tests).
-include_lib("eunit/include/eunit.hrl").

%% The player-facing mint, and the built-in method table it arrives through.

rpc_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"the mint is reachable as a built-in rpc method", fun reachable_as_builtin/0},
        {"an unconfigured plane is unavailable, not unknown", fun unavailable_not_unknown/0},
        {"a built-in cannot be shadowed by an extension", fun not_shadowable/0},
        {"close refuses a missing conn_id", fun close_refuses_bad_params/0}
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

%% --- Helpers ---

call(Method, Params) ->
    #{~"protocol" => 1, ~"method" => Method, ~"params" => Params}.

caller() ->
    #{player_id => ~"p1", session => self(), transport => ws}.
