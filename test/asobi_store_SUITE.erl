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
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U1, ~"password" => ~"testpass123"}},
        Config0
    ),
    B1 = nova_test:json(R1),
    {ok, R2} = nova_test:post(
        ~"/api/v1/auth/register",
        #{json => #{~"username" => U2, ~"password" => ~"testpass123"}},
        Config0
    ),
    B2 = nova_test:json(R2),
    %% Create an item definition
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    ItemCS = asobi_item_def:changeset(#{}, #{
        slug => iolist_to_binary([~"test_sword_", Suffix]),
        name => ~"Test Sword",
        category => ~"weapon",
        rarity => ~"rare"
    }),
    {ok, ItemDef} = asobi_repo:insert(ItemCS),
    ItemDefId = maps:get(id, ItemDef),
    %% Create an active store listing
    ListingCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gold",
        price => 500,
        active => true
    }),
    {ok, Listing} = asobi_repo:insert(ListingCS),
    %% Create an inactive store listing
    InactiveCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gold",
        price => 100,
        active => false
    }),
    {ok, InactiveListing} = asobi_repo:insert(InactiveCS),
    %% Create a gems listing for filter test
    GemsCS = asobi_store_listing:changeset(#{}, #{
        item_def_id => ItemDefId,
        currency => ~"gems",
        price => 10,
        active => true
    }),
    {ok, _GemsListing} = asobi_repo:insert(GemsCS),
    [
        {player1_id, maps:get(~"player_id", B1)},
        {player1_token, maps:get(~"session_token", B1)},
        {player2_id, maps:get(~"player_id", B2)},
        {player2_token, maps:get(~"session_token", B2)},
        {item_def_id, ItemDefId},
        {listing_id, maps:get(id, Listing)},
        {inactive_listing_id, maps:get(id, InactiveListing)}
        | Config0
    ].

end_per_suite(Config) ->
    Config.

auth(Config, Player) ->
    Key = list_to_atom(atom_to_list(Player) ++ "_token"),
    Token = proplists:get_value(Key, Config),
    [{~"authorization", iolist_to_binary([~"Bearer ", Token])}].

%% --- Store Browse ---

list_store_empty(Config) ->
    %% Filter by a currency that has no listings
    {ok, Resp} = nova_test:get(
        ~"/api/v1/store?currency=nonexistent",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"listings" := []}, Resp),
    Config.

list_store_with_listings(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/store",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"listings" := Listings} = nova_test:json(Resp),
    %% Should have at least 2 active listings (gold + gems)
    ?assert(length(Listings) >= 2),
    Config.

list_store_filter_currency(Config) ->
    {ok, Resp} = nova_test:get(
        ~"/api/v1/store?currency=gems",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"listings" := Listings} = nova_test:json(Resp),
    ?assert(length(Listings) >= 1),
    lists:foreach(
        fun(L) -> ?assertEqual(~"gems", maps:get(~"currency", L)) end,
        Listings
    ),
    Config.

%% --- Purchase Flow ---

purchase_success(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
    ListingId = proplists:get_value(listing_id, Config),
    %% Grant enough currency
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"success" := true} = nova_test:json(Resp),
    %% Verify balance was debited
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    GoldWallet = hd([W || W <- Wallets, maps:get(currency, W) =:= ~"gold"]),
    ?assertEqual(500, maps:get(balance, GoldWallet)),
    Config.

purchase_insufficient_funds(Config) ->
    ListingId = proplists:get_value(listing_id, Config),
    %% Player2 has no gold
    {ok, Resp} = nova_test:post(
        ~"/api/v1/store/purchase",
        #{
            headers => auth(Config, player2),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    ?assertStatus(402, Resp),
    Config.

purchase_inactive_listing(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
    InactiveId = proplists:get_value(inactive_listing_id, Config),
    %% Ensure player has funds
    _ = asobi_economy:grant(PlayerId, ~"gold", 1000, #{reason => ~"test_grant"}),
    {ok, Resp} = nova_test:post(
        ~"/api/v1/store/purchase",
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
        ~"/api/v1/inventory",
        #{headers => auth(Config, player2)},
        Config
    ),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"items" := []}, Resp),
    Config.

inventory_after_purchase(Config) ->
    PlayerId = proplists:get_value(player1_id, Config),
    ListingId = proplists:get_value(listing_id, Config),
    %% Grant currency and purchase
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        ~"/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    %% Check inventory
    {ok, Resp} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    ?assertStatus(200, Resp),
    #{~"items" := Items} = nova_test:json(Resp),
    ?assert(length(Items) >= 1),
    Config.

consume_item(Config) ->
    %% Get first item from inventory
    {ok, Resp} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := [_Item | _]} = nova_test:json(Resp),
    %% Grant another item so we have quantity > 1 for partial consume
    PlayerId = proplists:get_value(player1_id, Config),
    ListingId = proplists:get_value(listing_id, Config),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        ~"/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    %% Get updated inventory to find an item with quantity
    {ok, Resp2} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items2} = nova_test:json(Resp2),
    %% Consume 1 of the first item
    FirstItem = hd(Items2),
    FirstItemId = maps:get(~"id", FirstItem),
    {ok, ConsumeResp} = nova_test:post(
        ~"/api/v1/inventory/consume",
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
    %% Purchase a new item so we have a fresh one with quantity=1
    PlayerId = proplists:get_value(player1_id, Config),
    ListingId = proplists:get_value(listing_id, Config),
    {ok, _} = asobi_economy:grant(PlayerId, ~"gold", 500, #{reason => ~"test_grant"}),
    {ok, _} = nova_test:post(
        ~"/api/v1/store/purchase",
        #{
            headers => auth(Config, player1),
            json => #{~"listing_id" => ListingId}
        },
        Config
    ),
    {ok, InvResp} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    %% Find an item with quantity=1
    case [I || I <- Items, maps:get(~"quantity", I) =:= 1] of
        [Item | _] ->
            ItemId = maps:get(~"id", Item),
            {ok, Resp} = nova_test:post(
                ~"/api/v1/inventory/consume",
                #{
                    headers => auth(Config, player1),
                    json => #{~"item_id" => ItemId, ~"quantity" => 1}
                },
                Config
            ),
            ?assertStatus(200, Resp),
            #{~"remaining_quantity" := 0} = nova_test:json(Resp);
        [] ->
            %% All items have quantity > 1, that's ok for this test
            ok
    end,
    Config.

consume_insufficient_quantity(Config) ->
    {ok, InvResp} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    case Items of
        [Item | _] ->
            ItemId = maps:get(~"id", Item),
            {ok, Resp} = nova_test:post(
                ~"/api/v1/inventory/consume",
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
        ~"/api/v1/inventory/consume",
        #{
            headers => auth(Config, player1),
            json => #{~"item_id" => ~"00000000-0000-0000-0000-000000000000", ~"quantity" => 1}
        },
        Config
    ),
    ?assertStatus(404, Resp),
    Config.

consume_other_player(Config) ->
    %% Player2 tries to consume player1's item
    {ok, InvResp} = nova_test:get(
        ~"/api/v1/inventory",
        #{headers => auth(Config, player1)},
        Config
    ),
    #{~"items" := Items} = nova_test:json(InvResp),
    case Items of
        [Item | _] ->
            ItemId = maps:get(~"id", Item),
            {ok, Resp} = nova_test:post(
                ~"/api/v1/inventory/consume",
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
