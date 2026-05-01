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
            Body = json:encode(#{
                ~"error" => ~"rate_limited",
                ~"retry_after" => RetryAfter div 1000
            }),
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
    Path = cowboy_req:path(Req),
    case Path of
        <<"/api/v1/auth/", _/binary>> -> asobi_auth_limiter;
        <<"/api/v1/iap/", _/binary>> -> asobi_iap_limiter;
        _ -> asobi_api_limiter
    end.
