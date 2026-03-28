-module(asobi_health_controller).

-export([check/1]).

-spec check(cowboy_req:req()) -> {json, map()}.
check(_Req) ->
    {json, #{
        status => ~"ok",
        online_players => asobi_presence:online_count(),
        node => atom_to_binary(node()),
        timestamp => erlang:system_time(millisecond)
    }}.
