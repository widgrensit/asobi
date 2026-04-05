-module(asobi_security_headers_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
pre_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec post_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    Req1 = cowboy_req:set_resp_headers(
        #{
            ~"x-content-type-options" => ~"nosniff",
            ~"x-frame-options" => ~"DENY",
            ~"x-xss-protection" => ~"0",
            ~"referrer-policy" => ~"strict-origin-when-cross-origin",
            ~"permissions-policy" => ~"camera=(), microphone=(), geolocation=()",
            ~"strict-transport-security" => ~"max-age=31536000; includeSubDomains"
        },
        Req
    ),
    {ok, Req1, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Security Headers",
        version => ~"1.0.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Adds standard security headers to all HTTP responses"
    }.
