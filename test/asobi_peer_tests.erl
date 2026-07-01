-module(asobi_peer_tests).
-include_lib("eunit/include/eunit.hrl").

peer_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun no_trusted_returns_peer/0,
        fun untrusted_peer_ignores_xff/0,
        fun trusted_peer_uses_xff/0,
        fun strips_trusted_hops/0,
        fun trusted_peer_no_xff_returns_peer/0,
        fun ipv6_trusted_proxy/0
    ]}.

setup() ->
    application:unset_env(asobi, trusted_proxies),
    ok.

cleanup(_) ->
    application:unset_env(asobi, trusted_proxies),
    ok.

no_trusted_returns_peer() ->
    ?assertEqual(
        ~"203.0.113.5",
        asobi_peer:client_ip(req({{203, 0, 113, 5}, 1234}, ~"1.2.3.4"))
    ).

untrusted_peer_ignores_xff() ->
    application:set_env(asobi, trusted_proxies, [~"10.0.0.0/8"]),
    %% Peer is NOT a trusted proxy, so the client-supplied XFF must be ignored.
    ?assertEqual(
        ~"203.0.113.5",
        asobi_peer:client_ip(req({{203, 0, 113, 5}, 1234}, ~"1.2.3.4"))
    ).

trusted_peer_uses_xff() ->
    application:set_env(asobi, trusted_proxies, [~"10.0.0.0/8"]),
    ?assertEqual(
        ~"203.0.113.9",
        asobi_peer:client_ip(req({{10, 1, 2, 3}, 1234}, ~"203.0.113.9"))
    ).

strips_trusted_hops() ->
    application:set_env(asobi, trusted_proxies, [~"10.0.0.0/8"]),
    %% Right-most untrusted hop is the real client.
    ?assertEqual(
        ~"203.0.113.9",
        asobi_peer:client_ip(req({{10, 0, 0, 1}, 1234}, ~"203.0.113.9, 10.0.0.5"))
    ).

trusted_peer_no_xff_returns_peer() ->
    application:set_env(asobi, trusted_proxies, [~"10.0.0.0/8"]),
    ?assertEqual(
        ~"10.0.0.1",
        asobi_peer:client_ip(req({{10, 0, 0, 1}, 1234}, undefined))
    ).

ipv6_trusted_proxy() ->
    application:set_env(asobi, trusted_proxies, [~"::1/128"]),
    ?assertEqual(
        ~"2001:db8::1",
        asobi_peer:client_ip(req({{0, 0, 0, 0, 0, 0, 0, 1}, 1234}, ~"2001:db8::1"))
    ).

req(Peer, undefined) ->
    #{peer => Peer, headers => #{}};
req(Peer, Xff) ->
    #{peer => Peer, headers => #{~"x-forwarded-for" => Xff}}.
