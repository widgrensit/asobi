-module(asobi_ops_economy).
-moduledoc """
Economy reads for the ops plane: the item catalogue, and the store listings.

`/economy/listings` is the endpoint the integration plan singles out. The
console query it replaces had no `ORDER BY` at all, so Postgres was free to
return the rows in whatever order the plan produced them and offset paging
over that can repeat one row while skipping another - a store the operator
scrolls past without ever seeing the listing they went looking for. Both
orders here end on `id`.

`store_listings` carries no `inserted_at`, so the default order is `id`
descending rather than a timestamp. That is still newest-first: ids are
UUIDv7 and their high bits are a millisecond clock (`asobi_id`).
""".

-include_lib("kura/include/kura.hrl").

-export([items_query/1, listings_query/1]).
-export([project_item/1, project_listing/1]).
-export([items_sortable/0, listings_sortable/0]).

-define(ITEMS_SORTABLE, [
    {~"id", id},
    {~"slug", slug},
    {~"name", name},
    {~"category", category},
    {~"rarity", rarity},
    {~"inserted_at", inserted_at},
    {~"updated_at", updated_at}
]).

-define(ITEMS_FILTERS, [
    {~"category", category, equals},
    {~"rarity", rarity, equals},
    {~"q", [slug, name], ilike}
]).

-define(LISTINGS_SORTABLE, [
    {~"id", id},
    {~"item_def_id", item_def_id},
    {~"currency", currency},
    {~"price", price},
    {~"active", active},
    {~"valid_from", valid_from},
    {~"valid_until", valid_until}
]).

%% No `q` here on purpose: a listing holds no prose. Its columns are a
%% foreign key, a currency name and two dates, and every one of them is
%% better asked for exactly than matched case-insensitively. Search the
%% catalogue instead and filter listings by the item id it returns.
-define(LISTINGS_FILTERS, [
    {~"item_def_id", item_def_id, uuid},
    {~"currency", currency, equals},
    {~"active", active, boolean}
]).

-doc "Wire-name to column mapping the item catalogue accepts in `?sort=`.".
-spec items_sortable() -> asobi_ops_params:sort_allowlist().
items_sortable() -> ?ITEMS_SORTABLE.

-doc "Wire-name to column mapping the store listings accept in `?sort=`.".
-spec listings_sortable() -> asobi_ops_params:sort_allowlist().
listings_sortable() -> ?LISTINGS_SORTABLE.

-spec items_query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
items_query(Params) ->
    query(asobi_item_def, Params, ?ITEMS_SORTABLE, [{inserted_at, desc}], ?ITEMS_FILTERS).

-spec listings_query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
listings_query(Params) ->
    query(asobi_store_listing, Params, ?LISTINGS_SORTABLE, [{id, desc}], ?LISTINGS_FILTERS).

-spec query(
    module(),
    asobi_ops_params:params(),
    asobi_ops_params:sort_allowlist(),
    asobi_ops_params:sort_spec(),
    [asobi_ops_filters:spec()]
) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
query(Schema, Params, Sortable, Default, Filters) ->
    case asobi_ops_params:sort(Params, Sortable, Default) of
        {ok, Orders} ->
            case asobi_ops_filters:build(kura_query:from(Schema), Params, Filters) of
                {ok, Query} -> {ok, kura_query:order_by(Query, Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Positive allowlist of the fields an item definition may carry off this
endpoint.

`metadata` stays. On an item definition it is the operator-authored half of
the catalogue - icons, tuning, whatever the game reads - and an economy
screen that cannot show it cannot tell two items apart.
""".
-spec project_item(map()) -> map().
project_item(Item) ->
    maps:with(
        [id, slug, name, category, rarity, stackable, metadata, inserted_at, updated_at],
        Item
    ).

-doc "Positive allowlist of the fields a store listing may carry off this endpoint.".
-spec project_listing(map()) -> map().
project_listing(Listing) ->
    maps:with(
        [id, item_def_id, currency, price, active, valid_from, valid_until, metadata],
        Listing
    ).
