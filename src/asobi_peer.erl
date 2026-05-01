-module(asobi_peer).
-moduledoc """
Client-IP extraction shared across HTTP and WebSocket entry points.

Reads `cowboy_req:peer/1` and renders the address as a binary. Returns
`~"unknown"` for any unexpected shape so callers can use the result as
a rate-limiter key without crashing the request.

This module deliberately does **not** honor `X-Forwarded-For` today —
trusting `XFF` blindly lets any client choose its own rate-limit key,
which defeats the limiter. Honoring `XFF` correctly requires a
deployer-configured CIDR trust list and is a follow-up.
""".

-export([client_ip/1]).

-spec client_ip(cowboy_req:req() | map()) -> binary().
client_ip(Req) ->
    try cowboy_req:peer(Req) of
        {IP, _Port} ->
            case inet:ntoa(IP) of
                Addr when is_list(Addr) -> list_to_binary(Addr);
                _ -> ~"unknown"
            end
    catch
        _:_ -> ~"unknown"
    end.
