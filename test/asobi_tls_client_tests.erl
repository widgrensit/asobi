-module(asobi_tls_client_tests).

-include_lib("eunit/include/eunit.hrl").

verifies_peer_test() ->
    Ssl = asobi_tls_client:ssl_options(),
    ?assertEqual(verify_peer, proplists:get_value(verify, Ssl)).

uses_system_trust_store_test() ->
    Ssl = asobi_tls_client:ssl_options(),
    CaCerts = proplists:get_value(cacerts, Ssl),
    ?assert(is_list(CaCerts)),
    ?assert(length(CaCerts) > 0).

checks_hostname_test() ->
    Ssl = asobi_tls_client:ssl_options(),
    Customize = proplists:get_value(customize_hostname_check, Ssl),
    ?assertMatch([{match_fun, F}] when is_function(F, 2), Customize).

restricts_to_modern_tls_test() ->
    Ssl = asobi_tls_client:ssl_options(),
    ?assertEqual(['tlsv1.3', 'tlsv1.2'], proplists:get_value(versions, Ssl)).

http_options_carry_ssl_test() ->
    Opts = asobi_tls_client:http_options(),
    ?assertEqual(asobi_tls_client:ssl_options(), proplists:get_value(ssl, Opts)),
    ?assertEqual(10000, proplists:get_value(timeout, Opts)),
    ?assert(is_integer(proplists:get_value(connect_timeout, Opts))).

http_options_honours_timeout_test() ->
    ?assertEqual(2500, proplists:get_value(timeout, asobi_tls_client:http_options(2500))).
