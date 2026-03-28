-module(asobi_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/2, post_request/2, plugin_info/0]).

-define(ETS_TABLE, asobi_rate_limits).
-define(DEFAULT_LIMIT, 100).
-define(DEFAULT_WINDOW, 60000).

-spec pre_request(cowboy_req:req(), map()) ->
    {ok, cowboy_req:req()} | {stop, cowboy_req:req()}.
pre_request(Req, Options) ->
    Limit = maps:get(limit, Options, ?DEFAULT_LIMIT),
    Window = maps:get(window, Options, ?DEFAULT_WINDOW),
    Key = rate_limit_key(Req),
    case check_rate(Key, Limit, Window) of
        ok ->
            {ok, Req};
        rate_limited ->
            Body = json:encode(#{~"error" => ~"rate_limited", ~"retry_after" => Window div 1000}),
            Req1 = cowboy_req:reply(429, #{~"content-type" => ~"application/json"}, Body, Req),
            {stop, Req1}
    end.

-spec post_request(cowboy_req:req(), map()) -> {ok, cowboy_req:req()}.
post_request(Req, _Options) ->
    {ok, Req}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        name => ~"Rate Limiter",
        version => ~"1.0.0",
        description => ~"Token bucket rate limiting per player/IP"
    }.

%% --- Internal ---

-spec rate_limit_key(cowboy_req:req()) -> {binary(), binary()}.
rate_limit_key(Req) ->
    PlayerId =
        case cowboy_req:header(~"authorization", Req) of
            <<"Bearer ", _/binary>> ->
                case maps:get(auth_data, Req, undefined) of
                    #{player_id := Id} -> Id;
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
    list_to_binary(inet:ntoa(IP)).

-spec check_rate({binary(), binary()}, pos_integer(), pos_integer()) -> ok | rate_limited.
check_rate(Key, Limit, Window) ->
    ensure_table(),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?ETS_TABLE, Key) of
        [{Key, Count, WindowStart}] when (Now - WindowStart) < Window ->
            case Count >= Limit of
                true ->
                    rate_limited;
                false ->
                    ets:update_counter(?ETS_TABLE, Key, {2, 1}),
                    ok
            end;
        _ ->
            ets:insert(?ETS_TABLE, {Key, 1, Now}),
            ok
    end.

-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?ETS_TABLE) of
        undefined ->
            ?ETS_TABLE = ets:new(?ETS_TABLE, [named_table, public, set, {write_concurrency, true}]),
            ok;
        _ ->
            ok
    end.
