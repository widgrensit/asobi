-module(asobi_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, Options, State) ->
    %% F-19: select a limiter based on the request path so
    %% `/api/v1/auth/*` runs through `asobi_auth_limiter` (low limit)
    %% and `/api/v1/iap/*` through `asobi_iap_limiter`. Everything else
    %% falls back to `asobi_api_limiter`. Configured via Options first,
    %% then path-derived, then default.
    Limiter =
        case maps:get(limiter, Options, undefined) of
            undefined -> select_limiter(Req);
            L -> L
        end,
    Key = rate_limit_key(Req),
    case seki:check(Limiter, Key) of
        {allow, #{remaining := Remaining, reset := Reset}} ->
            Req1 = cowboy_req:set_resp_header(
                ~"x-ratelimit-remaining", integer_to_binary(Remaining), Req
            ),
            Req2 = cowboy_req:set_resp_header(~"x-ratelimit-reset", integer_to_binary(Reset), Req1),
            {ok, Req2, State};
        {deny, #{retry_after := RetryAfter}} ->
            %% `retry_after` stays a top-level key and is the object's
            %% `details` too - see asobi_error:legacy_body/2.
            Body = json:encode(
                asobi_error:legacy_body(~"rate_limited", #{
                    ~"retry_after" => RetryAfter div 1000
                })
            ),
            Req1 = cowboy_req:set_resp_header(
                ~"retry-after", integer_to_binary(RetryAfter div 1000), Req
            ),
            Req2 = cowboy_req:reply(429, #{~"content-type" => ~"application/json"}, Body, Req1),
            {break, Req2, State}
    end.

-spec post_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Rate Limiter",
        version => ~"2.0.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Rate limiting via Seki (token bucket / sliding window)"
    }.

%% --- Internal ---

-spec rate_limit_key(cowboy_req:req()) -> binary().
rate_limit_key(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", _/binary>> ->
            case maps:get(auth_data, Req, undefined) of
                #{player_id := Id} when is_binary(Id) -> Id;
                _ -> asobi_peer:client_ip(Req)
            end;
        _ ->
            asobi_peer:client_ip(Req)
    end.

-spec select_limiter(cowboy_req:req()) -> atom().
select_limiter(Req) ->
    %% Match on normalised path segments, not the raw byte string: cowboy
    %% leaves `path` verbatim but the router (routing_tree) collapses `//`
    %% and leading/trailing slashes, so a literal compare would let e.g.
    %% `/api/v1//auth/register` reach the register handler yet miss this
    %% limiter. `trim_all` collapses the same way the router does. Do not
    %% urldecode - routing_tree does not either, so encoded paths 404
    %% before the handler. register runs the password KDF and gets its own
    %% tighter bucket (asobi#157); it must match before the /auth/ prefix.
    case binary:split(cowboy_req:path(Req), ~"/", [global, trim_all]) of
        [~"api", ~"v1", ~"auth", ~"register"] -> asobi_register_limiter;
        %% Account erasure runs the KDF too, on a path nothing else serves.
        [~"api", ~"v1", ~"players", ~"me", ~"erase"] -> asobi_erase_limiter;
        [~"api", ~"v1", ~"auth" | _] -> asobi_auth_limiter;
        [~"api", ~"v1", ~"iap" | _] -> asobi_iap_limiter;
        %% The console login trades a shared secret for a session, so it is
        %% the one place in the deployment where guessing pays. It shares the
        %% auth bucket rather than getting its own: same threat, same shape,
        %% one fewer knob to leave unset.
        [~"console", ~"session"] -> asobi_auth_limiter;
        _ -> asobi_api_limiter
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% select_limiter/1 only reads `path` via cowboy_req:path/1, so a bare map is
%% fine at runtime - this just tells eqwalizer to trust it as a
%% cowboy_req:req() for the duration of the test (mirrors asobi_body_cap_plugin_tests).
-spec fake_req(map()) -> dynamic().
fake_req(M) -> M.

select_limiter_test_() ->
    [
        ?_assertEqual(
            asobi_register_limiter, select_limiter(fake_req(#{path => ~"/api/v1/auth/register"}))
        ),
        ?_assertEqual(
            asobi_auth_limiter, select_limiter(fake_req(#{path => ~"/api/v1/auth/login"}))
        ),
        ?_assertEqual(
            asobi_auth_limiter, select_limiter(fake_req(#{path => ~"/api/v1/auth/refresh"}))
        ),
        ?_assertEqual(
            asobi_iap_limiter, select_limiter(fake_req(#{path => ~"/api/v1/iap/purchase"}))
        ),
        ?_assertEqual(asobi_api_limiter, select_limiter(fake_req(#{path => ~"/api/v1/friends"}))),
        ?_assertEqual(
            asobi_erase_limiter, select_limiter(fake_req(#{path => ~"/api/v1/players/me/erase"}))
        ),
        %% A player id that is not the literal `me` is an ordinary read.
        ?_assertEqual(
            asobi_api_limiter,
            select_limiter(fake_req(#{path => ~"/api/v1/players/0198c0de-0000-7000-8000-0000"}))
        ),
        %% asobi#157 regression: slash-normalisation variants that the
        %% router folds onto /auth/register must not escape the register
        %% bucket onto the looser auth (5/s) or api (300/s) limiter.
        ?_assertEqual(
            asobi_register_limiter,
            select_limiter(fake_req(#{path => ~"/api/v1/auth//register"}))
        ),
        ?_assertEqual(
            asobi_register_limiter,
            select_limiter(fake_req(#{path => ~"/api/v1/auth/register/"}))
        ),
        ?_assertEqual(
            asobi_register_limiter,
            select_limiter(fake_req(#{path => ~"/api/v1//auth/register"}))
        ),
        ?_assertEqual(
            asobi_register_limiter, select_limiter(fake_req(#{path => ~"//api/v1/auth/register"}))
        )
    ].

-define(PEER_IP, ~"198.51.100.7").

peer_req(Extra) ->
    Base = #{peer => {{198, 51, 100, 7}, 41234}},
    fake_req(maps:merge(Base, Extra)).

%% Which bucket a request counts against decides whether one abusive
%% player throttles only themselves or everyone sharing their egress IP,
%% and a regression here is invisible until a CGNAT or CDN customer
%% complains. Pin both branches and every way the authenticated branch
%% can fail open to the IP.
rate_limit_key_test_() ->
    Authed = fun(AuthData) ->
        peer_req(#{
            headers => #{~"authorization" => ~"Bearer t"},
            auth_data => AuthData
        })
    end,
    [
        %% An authenticated player is bucketed by identity, so their
        %% neighbours on the same IP are unaffected.
        ?_assertEqual(~"player-1", rate_limit_key(Authed(#{player_id => ~"player-1"}))),
        %% Anonymous traffic has no identity to bucket on: fall back to IP.
        ?_assertEqual(?PEER_IP, rate_limit_key(peer_req(#{headers => #{}}))),
        %% A non-Bearer scheme is not an asobi session, so it must not
        %% reach the auth_data branch at all.
        ?_assertEqual(
            ?PEER_IP,
            rate_limit_key(
                peer_req(#{
                    headers => #{~"authorization" => ~"Basic dXNlcjpwYXNz"},
                    auth_data => #{player_id => ~"player-1"}
                })
            )
        ),
        %% Bearer present but the auth plugin never populated auth_data,
        %% or populated it with a non-binary id: fail closed onto the IP
        %% bucket rather than crashing or sharing a bucket.
        ?_assertEqual(?PEER_IP, rate_limit_key(Authed(undefined))),
        ?_assertEqual(?PEER_IP, rate_limit_key(Authed(#{}))),
        ?_assertEqual(?PEER_IP, rate_limit_key(Authed(#{player_id => undefined}))),
        ?_assertEqual(?PEER_IP, rate_limit_key(Authed(#{player_id => 12345})))
    ].
-endif.
