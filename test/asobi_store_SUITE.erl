-module(asobi_store_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    list_store_empty/1,
    list_store_with_listings/1,
    list_store_filter_currency/1,
    purchase_success/1,
    purchase_insufficient_funds/1,
    purchase_inactive_listing/1,
    inventory_after_purchase/1,
    consume_item/1,
    consume_item_fully/1,
    consume_insufficient_quantity/1,
    consume_not_found/1,
    consume_other_player/1,
    inventory_empty/1
]).

all() -> [{group, store_browse}, {group, purchase_flow}, {group, inventory}].

groups() ->
    [
        {store_browse, [sequence], [
            list_store_empty, list_store_with_listings, list_store_filter_currency
        ]},
        {purchase_flow, [sequence], [
            purchase_success, purchase_insufficient_funds, purchase_inactive_listing
        ]},
        {inventory, [sequence], [
            inventory_empty,
            inventory_after_purchase,
            consume_item,
            consume_item_fully,
            consume_insufficient_quantity,
            consume_not_found,
            consume_other_player
        ]}
    ].

init_per_suite(Config) ->
    Config0 = asobi_test_helpers:start(Config),
    U1 = asobi_test_helpers:unique_username(~"store_p1"),
    U2 = asobi_test_helpers:unique_username(~"store_p2"),
    {ok, R1} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    B2 = nova_test:json(R2),
    #{~"player_id" := P1Id, ~"session_token" := P1Token} = B1,
    #{~"player_id" := P2Id, ~"session_token" := P2Token} = B2,
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    ItemCS = asobi_item_def:changeset(#{}, #{
        slug => iolist_to_binary([~"test_sword_", Suffix]),
        name => ~"Test Sword",
        category => ~"weapon",
        rarity => ~"rare"
    }),
    {ok, ItemDef} = asobi_repo:insert(ItemCS),
    ItemDefId = maps:get(id, ItemDef),
    ListingCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gold",
        price => 500,
        active => true
    }),
    {ok, Listing} = asobi_repo:insert(ListingCS),
    InactiveCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gold",
        price => 100,
        active => false
    }),
    {ok, InactiveListing} = asobi_repo:insert(InactiveCS),
    GemsCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gems",
        price => 10,
        active => true
    }),
    {ok, _GemsListing} = asobi_repo:insert(GemsCS),
    [
        {player1_id, P1Id},
        {player1_token, P1Token},
        {player2_id, P2Id},
        {player2_token, P2Token},
        {item_def_id, ItemDefId},
        {listing_id, maps:get(id, Listing)},
        {inactive_listing_id, maps:get(id, InactiveListing)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    {Key, Token} = lists:keyfind(Key, 1, Config),
    true = is_binary(Token),
    [{~"authorization", <<"Bearer ", Token/binary>>}].

%% --- Store Browse ---

list_store_empty(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/store?currency=nonexistent",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"listings" := []}, Resp),
    Config.

list_store_with_listings(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/store",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"listings" := Listings} = nova_test:json(Resp),
    true = is_list(Listings),
    ?assert(length(Listings) >= 2),
    Config.

list_store_filter_currency(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/store?currency=gems",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"listings" := Listings} = nova_test:json(Resp),
    true = is_list(Listings),
    ?assert(length(Listings) >= 1),
    lists:foreach(
        fun(L) when is_map(L) -> ?assertEqual(~"gems", maps:get(~"currency", L)) end,
        Listings
    ),
    Config.

%% --- Purchase Flow ---

purchase_success(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    {listing_id, ListingId} = lists:keyfind(listing_id, 1, Config),
    true = is_binary(PlayerId),
    true = is_binary(ListingId),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"success" := true} = nova_test:json(Resp),
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    [GoldWallet | _] = [W || W <- Wallets, is_map(W), maps:get(currency, W) =:= ~"gold"],
    true = is_map(GoldWallet),
    ?assertEqual(500, maps:get(balance, GoldWallet)),
    Config.

purchase_insufficient_funds(Config) ->
    {listing_id, ListingId} = lists:keyfind(listing_id, 1, Config),
    {ok, Resp} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player2),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    ?assertStatus(402, Resp),
    Config.

purchase_inactive_listing(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    {inactive_listing_id, InactiveId} = lists:keyfind(inactive_listing_id, 1, Config),
    true = is_binary(PlayerId),
    true = is_binary(InactiveId),
    _ = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Resp} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => InactiveId}
        },
        Config
    ),
    ?assertStatus(400, Resp),
    Config.

%% --- Inventory ---

inventory_empty(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"items" := []}, Resp),
    Config.

inventory_after_purchase(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    {listing_id, ListingId} = lists:keyfind(listing_id, 1, Config),
    true = is_binary(PlayerId),
    true = is_binary(ListingId),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    {ok, Resp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"items" := Items} = nova_test:json(Resp),
    true = is_list(Items),
    ?assert(length(Items) >= 1),
    Config.

consume_item(Config) ->
    {ok, Resp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := [_Item | _]} = nova_test:json(Resp),
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    {listing_id, ListingId} = lists:keyfind(listing_id, 1, Config),
    true = is_binary(PlayerId),
    true = is_binary(ListingId),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    {ok, Resp2} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := [FirstItem | _]} = nova_test:json(Resp2),
    #{~"id" := FirstItemId} = FirstItem,
    {ok, ConsumeResp} = nova_test:post(
        "/api/v1/inventory/consume",
        #{
            headers => auth(Config, player1),
            json => #{~"item_id" => FirstItemId, ~"quantity" => 1}
        },
        Config
    ),
    ConsumeBody = nova_test:json(ConsumeResp),
    ?assertMatch(#{~"success" := true}, ConsumeBody),
    [{test_item_id, FirstItemId} | Config].

consume_item_fully(Config) ->
    {player1_id, PlayerId} = lists:keyfind(player1_id, 1, Config),
    {listing_id, ListingId} = lists:keyfind(listing_id, 1, Config),
    true = is_binary(PlayerId),
    true = is_binary(ListingId),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        "/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    {ok, InvResp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    true = is_list(Items),
    case [I || I <- Items, is_map(I), maps:get(~"quantity", I) =:= 1] of
        [#{~"id" := ItemId} | _] ->
            {ok, ConsumeResp} = nova_test:post(
                "/api/v1/inventory/consume",
                #{
                    headers => auth(Config, player1),
                    json => #{~"item_id" => ItemId, ~"quantity" => 1}
                },
                Config
            ),
            ?assertStatus(200, ConsumeResp),
            #{~"remaining_quantity" := 0} = nova_test:json(ConsumeResp);
        [] ->
            ok
    end,
    Config.

consume_insufficient_quantity(Config) ->
    {ok, InvResp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    case Items of
        [#{~"id" := ItemId} | _] ->
            {ok, Resp} = nova_test:post(
                "/api/v1/inventory/consume",
                #{
                    headers => auth(Config, player1),
                    json => #{~"item_id" => ItemId, ~"quantity" => 99999}
                },
                Config
            ),
            ?assertStatus(400, Resp);
        [] ->
            ok
    end,
    Config.

consume_not_found(Config) ->
    {ok, Resp} = nova_test:post(
        "/api/v1/inventory/consume",
        #{
            headers => auth(Config, player1),
            json => #{~"item_id" => ~"00000000-0000-0000-0000-000000000000", ~"quantity" => 1}
        },
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

consume_other_player(Config) ->
    {ok, InvResp} = nova_test:get(
        "/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    case Items of
        [#{~"id" := ItemId} | _] ->
            {ok, Resp} = nova_test:post(
                "/api/v1/inventory/consume",
                #{
                    headers => auth(Config, player2),
                    json => #{~"item_id" => ItemId, ~"quantity" => 1}
                },
                Config
            ),
            ?assertStatus(403, Resp);
        [] ->
            ok
    end,
    Config.
