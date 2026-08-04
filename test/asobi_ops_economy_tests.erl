-module(asobi_ops_economy_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%%--------------------------------------------------------------------
%% Item catalogue
%%--------------------------------------------------------------------

items_default_order_is_deterministic_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_economy:items_query(#{}),
    ?assertEqual([{inserted_at, desc}, {id, desc}], Orders).

items_sort_uses_allowlisted_atom_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_economy:items_query(#{~"sort" => ~"slug"}),
    ?assertEqual([{slug, asc}, {id, desc}], Orders).

items_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"price"}},
        asobi_ops_economy:items_query(#{~"sort" => ~"price"})
    ).

items_search_covers_slug_and_name_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_economy:items_query(#{~"q" => ~"sword"}),
    ?assertEqual(
        [{'or', [{slug, ilike, ~"%sword%"}, {name, ilike, ~"%sword%"}]}],
        Wheres
    ).

items_filters_are_equality_on_columns_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_economy:items_query(#{
        ~"category" => ~"weapon", ~"rarity" => ~"epic"
    }),
    ?assertEqual([{category, ~"weapon"}, {rarity, ~"epic"}], Wheres).

items_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_economy:project_item(sample_item())),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_economy:items_sortable()
    ].

sample_item() ->
    #{
        id => ~"0197f3d0-1c2b-7000-8000-000000000001",
        slug => ~"iron-sword",
        name => ~"Iron Sword",
        category => ~"weapon",
        rarity => ~"common",
        stackable => false,
        metadata => #{~"damage" => 7},
        inserted_at => {{2026, 8, 3}, {12, 0, 0}},
        updated_at => {{2026, 8, 3}, {12, 0, 0}}
    }.

%%--------------------------------------------------------------------
%% Store listings
%%--------------------------------------------------------------------

%% The endpoint the plan singles out: it had no `ORDER BY` at all, so offset
%% paging over it could repeat one row and skip another. `store_listings`
%% carries no timestamp, so the order ends - and starts - on the id.
listings_have_a_deterministic_order_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_economy:listings_query(#{}),
    ?assertEqual([{id, desc}], Orders).

listings_every_sort_still_ends_on_the_unique_key_test() ->
    [
        begin
            {ok, #kura_query{order_bys = Orders}} = asobi_ops_economy:listings_query(#{
                ~"sort" => Wire
            }),
            ?assertMatch({id, _Direction}, lists:last(Orders))
        end
     || {Wire, _Column} <- asobi_ops_economy:listings_sortable()
    ].

listings_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"metadata"}},
        asobi_ops_economy:listings_query(#{~"sort" => ~"metadata"})
    ).

listings_reject_unknown_order_test() ->
    ?assertEqual(
        {error, {unknown_order, ~"sideways"}},
        asobi_ops_economy:listings_query(#{~"sort" => ~"price", ~"order" => ~"sideways"})
    ).

listings_active_filter_is_a_boolean_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_economy:listings_query(#{~"active" => ~"true"}),
    ?assertEqual([{active, true}], Wheres).

listings_item_filter_must_be_a_uuid_test() ->
    ?assertEqual(
        {error, {invalid_filter, ~"item_def_id"}},
        asobi_ops_economy:listings_query(#{~"item_def_id" => ~"iron-sword"})
    ).

listings_item_filter_accepts_a_uuid_test() ->
    Id = asobi_id:generate(),
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_economy:listings_query(#{~"item_def_id" => Id}),
    ?assertEqual([{item_def_id, Id}], Wheres).

listings_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_economy:project_listing(sample_listing())),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_economy:listings_sortable()
    ].

sample_listing() ->
    #{
        id => ~"0197f3d0-1c2b-7000-8000-000000000002",
        item_def_id => ~"0197f3d0-1c2b-7000-8000-000000000001",
        currency => ~"gold",
        price => 250,
        active => true,
        valid_from => undefined,
        valid_until => undefined,
        metadata => #{}
    }.
