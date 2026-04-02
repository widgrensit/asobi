-module(asobi_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, Options, State) ->
    Limiter = maps:get(limiter, Options, asobi_api),
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
                _ -> peer_ip(Req)
            end;
        _ ->
            peer_ip(Req)
    end.

-spec peer_ip(cowboy_req:req()) -> binary().
peer_ip(Req) ->
    {IP, _Port} = cowboy_req:peer(Req),
    case inet:ntoa(IP) of
        Addr when is_list(Addr) -> list_to_binary(Addr);
        _ -> ~"unknown"
    end.
