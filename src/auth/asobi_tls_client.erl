-module(asobi_tls_client).

-export([http_options/0, http_options/1, ssl_options/0]).

-define(DEFAULT_TIMEOUT, 10000).
-define(CONNECT_TIMEOUT, 5000).

%% Explicit TLS options for outbound calls to fixed high-trust endpoints
%% (Steam, Google). Without these, httpc falls back to ssl defaults that on
%% older OTP do not verify the peer, so a MITM or mis-issued cert would
%% silently validate a forged receipt/token. We verify against the OS trust
%% store and enforce the https hostname check; leaf/CA pinning is deliberately
%% omitted because these providers rotate certificates and a stale pin is a
%% self-inflicted outage.
-type http_option() ::
    {timeout, timeout()} | {connect_timeout, timeout()} | {ssl, [ssl:tls_option()]}.

-spec http_options() -> [http_option()].
http_options() ->
    http_options(?DEFAULT_TIMEOUT).

-spec http_options(timeout()) -> [http_option()].
http_options(Timeout) ->
    [
        {timeout, Timeout},
        {connect_timeout, ?CONNECT_TIMEOUT},
        {ssl, ssl_options()}
    ].

-spec ssl_options() -> [ssl:tls_option()].
ssl_options() ->
    [
        {verify, verify_peer},
        {cacerts, cacerts()},
        {depth, 4},
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%% cacerts_get/0 re-parses the OS trust store on every call and raises when the
%% image ships without one. Load once and cache so an auth request neither pays
%% the re-parse nor crashes mid-flight on a misconfigured host.
-spec cacerts() -> dynamic().
cacerts() ->
    case persistent_term:get({?MODULE, cacerts}, undefined) of
        undefined ->
            Certs = public_key:cacerts_get(),
            persistent_term:put({?MODULE, cacerts}, Certs),
            Certs;
        Certs when is_list(Certs) ->
            Certs
    end.
