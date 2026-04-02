-module(asobi_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

-define(ETS_TABLE, asobi_rate_limits).
-define(DEFAULT_LIMIT, 100).
-define(DEFAULT_WINDOW, 60000).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, Options, State) ->
    Limit = maps:get(limit, Options, ?DEFAULT_LIMIT),
    Window = maps:get(window, Options, ?DEFAULT_WINDOW),
    Key = rate_limit_key(Req),
    case check_rate(Key, Limit, Window) of
        ok ->
            {ok, Req, State};
        rate_limited ->
            Body = json:encode(#{~"error" => ~"rate_limited", ~"retry_after" => Window div 1000}),
            Req1 = cowboy_req:reply(429, #{~"content-type" => ~"application/json"}, Body, Req),
            {break, Req1, State}
    end.

-spec post_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Rate Limiter",
        version => ~"1.0.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Token bucket rate limiting per player/IP"
    }.

%% --- Internal ---

-spec rate_limit_key(cowboy_req:req()) -> {binary(), binary()}.
rate_limit_key(Req) ->
    PlayerId =
        case cowboy_req:header(~"authorization", Req) of
            <<"Bearer ", _/binary>> ->
                case maps:get(auth_data, Req, undefined) of
                    #{player_id := Id} when is_binary(Id) -> Id;
                    _ -> peer_ip(Req)
                end;
            _ ->
                peer_ip(Req)
        end,
    Path = cowboy_req:path(Req),
    {PlayerId, Path}.

-spec peer_ip(cowboy_req:req()) -> binary().
peer_ip(Req) ->
    {IP, _Port} = cowboy_req:peer(Req),
    case inet:ntoa(IP) of
        Addr when is_list(Addr) -> list_to_binary(Addr);
        _ -> ~"unknown"
    end.

-spec check_rate({binary(), binary()}, pos_integer(), pos_integer()) -> ok | rate_limited.
check_rate(Key, Limit, Window) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?ETS_TABLE, Key) of
        [{Key, _Count, WindowStart}] when (Now - WindowStart) >= Window ->
            ets:insert(?ETS_TABLE, {Key, 1, Now}),
            ok;
        [{Key, _Count, _WindowStart}] ->
            NewCount = ets:update_counter(?ETS_TABLE, Key, {2, 1}),
            case NewCount > Limit of
                true ->
                    _ = ets:update_counter(?ETS_TABLE, Key, {2, -1}),
                    rate_limited;
                false ->
                    ok
            end;
        [] ->
            ets:insert(?ETS_TABLE, {Key, 1, Now}),
            ok
    end.
