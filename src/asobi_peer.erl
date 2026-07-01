-module(asobi_peer).
-moduledoc """
Client-IP extraction shared across HTTP and WebSocket entry points, used as
the rate-limiter key.

By default this returns `cowboy_req:peer/1` (the socket peer). When the engine
runs behind a trusted reverse proxy (Traefik/ingress/LB), the socket peer is
the proxy, so every client collapses into one rate-limit bucket. Configure the
proxy's address range so the real client is read from `X-Forwarded-For`:

    {asobi, [{trusted_proxies, [~"10.0.0.0/8", ~"::1/128"]}]}

`X-Forwarded-For` is honored ONLY when the socket peer is itself within a
configured trusted range; otherwise it is ignored (an untrusted client must
not be able to choose its own rate-limit key). With no `trusted_proxies`
configured, behavior is identical to reading the socket peer directly.
""".

-export([client_ip/1]).

-spec client_ip(cowboy_req:req() | map()) -> binary().
client_ip(Req) ->
    Peer = peer_ip(Req),
    case parsed_trusted_proxies() of
        [] ->
            Peer;
        Cidrs ->
            case ip_in_any(Peer, Cidrs) of
                true -> forwarded_client(Req, Cidrs, Peer);
                false -> Peer
            end
    end.

%% --- Internal ---

-spec peer_ip(cowboy_req:req() | map()) -> binary().
peer_ip(Req) ->
    try cowboy_req:peer(Req) of
        {IP, _Port} ->
            case inet:ntoa(IP) of
                Addr when is_list(Addr) -> list_to_binary(Addr);
                _ -> ~"unknown"
            end
    catch
        _:_ -> ~"unknown"
    end.

%% Peer is a trusted proxy: the real client is the right-most X-Forwarded-For
%% entry that is not itself a trusted proxy (walk right-to-left, strip our own
%% proxy hops). Falls back to the peer if XFF is absent or all-trusted.
-spec forwarded_client(cowboy_req:req() | map(), [cidr()], binary()) -> binary().
forwarded_client(Req, Cidrs, Peer) ->
    case cowboy_req:header(~"x-forwarded-for", Req) of
        Xff when is_binary(Xff), Xff =/= <<>> ->
            Hops = lists:reverse([trim(P) || P <- binary:split(Xff, ~",", [global])]),
            case first_untrusted(Hops, Cidrs) of
                {ok, Ip} -> Ip;
                none -> Peer
            end;
        _ ->
            Peer
    end.

-spec first_untrusted([binary()], [cidr()]) -> {ok, binary()} | none.
first_untrusted([], _Cidrs) ->
    none;
first_untrusted([Ip | Rest], Cidrs) ->
    case is_ip(Ip) andalso not ip_in_any(Ip, Cidrs) of
        true -> {ok, Ip};
        false -> first_untrusted(Rest, Cidrs)
    end.

-type cidr() :: {inet:ip_address(), non_neg_integer()}.

-spec parsed_trusted_proxies() -> [cidr()].
parsed_trusted_proxies() ->
    Raw = application:get_env(asobi, trusted_proxies, []),
    lists:filtermap(fun parse_cidr/1, to_list(Raw)).

-spec parse_cidr(binary() | string()) -> {true, cidr()} | false.
parse_cidr(C0) ->
    case binary:split(to_bin(C0), ~"/") of
        [AddrB, BitsB] ->
            case {inet:parse_address(binary_to_list(AddrB)), to_int(BitsB)} of
                {{ok, IP}, Bits} when is_integer(Bits), Bits >= 0 -> {true, {IP, Bits}};
                _ -> false
            end;
        [AddrB] ->
            case inet:parse_address(binary_to_list(AddrB)) of
                {ok, IP} -> {true, {IP, width(IP)}};
                _ -> false
            end
    end.

-spec ip_in_any(binary(), [cidr()]) -> boolean().
ip_in_any(IpBin, Cidrs) ->
    case inet:parse_address(binary_to_list(IpBin)) of
        {ok, IP} -> lists:any(fun(C) -> ip_in_cidr(IP, C) end, Cidrs);
        _ -> false
    end.

-spec ip_in_cidr(inet:ip_address(), cidr()) -> boolean().
ip_in_cidr(IP, {Net, Bits}) when tuple_size(IP) =:= tuple_size(Net) ->
    Width = width(IP),
    Shift = Width - min(Bits, Width),
    (ip_to_int(IP) bsr Shift) =:= (ip_to_int(Net) bsr Shift);
ip_in_cidr(_IP, _Cidr) ->
    false.

-spec ip_to_int(inet:ip_address()) -> non_neg_integer().
ip_to_int(IP) ->
    ElemBits = elem_bits(IP),
    lists:foldl(fun(E, Acc) -> (Acc bsl ElemBits) bor E end, 0, tuple_to_list(IP)).

-spec width(inet:ip_address()) -> 32 | 128.
width(IP) -> tuple_size(IP) * elem_bits(IP).

-spec elem_bits(inet:ip_address()) -> 8 | 16.
elem_bits(IP) when tuple_size(IP) =:= 4 -> 8;
elem_bits(_IP) -> 16.

-spec is_ip(binary()) -> boolean().
is_ip(Bin) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, _} -> true;
        _ -> false
    end.

-spec to_list(term()) -> list().
to_list(L) when is_list(L) -> L;
to_list(_) -> [].

-spec to_bin(binary() | string()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

-spec to_int(binary()) -> integer() | error.
to_int(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> error
    end.

-spec trim(binary()) -> binary().
trim(B) -> string:trim(B).
