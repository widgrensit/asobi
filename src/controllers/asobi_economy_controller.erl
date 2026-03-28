-module(asobi_economy_controller).

-export([wallets/1, history/1, store/1, purchase/1]).

-spec wallets(cowboy_req:req()) -> {json, map()}.
wallets(#{auth_data := #{player_id := PlayerId}} = _Req) ->
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    {json, #{wallets => [maps:with([currency, balance], W) || W <- Wallets]}}.

-spec history(cowboy_req:req()) -> {json, map()}.
history(
    #{bindings := #{~"currency" := Currency}, auth_data := #{player_id := PlayerId}, qs := Qs} =
        _Req
) ->
    Params = cow_qs:parse_qs(Qs),
    Limit = binary_to_integer(proplists:get_value(~"limit", Params, ~"50")),
    {ok, Transactions} = asobi_economy:get_history(PlayerId, Currency, #{limit => Limit}),
    {json, #{transactions => Transactions}}.

-spec store(cowboy_req:req()) -> {json, map()}.
store(#{qs := Qs} = _Req) ->
    Params = cow_qs:parse_qs(Qs),
    Q0 = kura_query:where(kura_query:from(asobi_store_listing), {active, true}),
    Q1 =
        case proplists:get_value(~"currency", Params) of
            undefined -> Q0;
            Currency -> kura_query:where(Q0, {currency, Currency})
        end,
    {ok, Listings} = asobi_repo:all(Q1),
    {json, #{listings => Listings}}.

-spec purchase(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
purchase(#{json := #{~"listing_id" := ListingId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    case asobi_economy:purchase(PlayerId, ListingId) of
        {ok, Item} ->
            {json, #{success => true, item => Item}};
        {error, insufficient_funds} ->
            {json, 402, #{}, #{error => ~"insufficient_funds"}};
        {error, listing_inactive} ->
            {json, 400, #{}, #{error => ~"listing_inactive"}};
        {error, _Reason} ->
            {json, 500, #{}, #{error => ~"purchase_failed"}}
    end.
