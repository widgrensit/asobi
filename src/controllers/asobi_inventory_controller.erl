-module(asobi_inventory_controller).

-export([index/1, consume/1]).

-spec index(cowboy_req:req()) -> {json, map()}.
index(#{auth_data := #{player_id := PlayerId}, qs := Qs} = _Req) when
    is_binary(PlayerId), is_binary(Qs)
->
    Params = cow_qs:parse_qs(Qs),
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    Q0 = kura_query:where(kura_query:from(asobi_player_item), {player_id, PlayerId}),
    Q1 = kura_query:limit(kura_query:order_by(Q0, [{acquired_at, desc}]), Limit),
    {ok, Items} = asobi_repo:all(Q1),
    {json, #{items => Items}}.

%% Per-call upper bound on `quantity` — defensive against an integer
%% overflow style attack where a very large positive number would still
%% pass guards but then exhaust DB resources or wrap somewhere later.
-define(MAX_CONSUME_QTY, 1000000).

-spec consume(cowboy_req:req()) ->
    {json, integer(), map(), map()} | {status, integer()}.
consume(
    #{json := #{~"item_id" := ItemId, ~"quantity" := Qty}, auth_data := #{player_id := PlayerId}} =
        _Req
) when is_integer(Qty), Qty > 0, Qty =< ?MAX_CONSUME_QTY ->
    case asobi_repo:get(asobi_player_item, ItemId) of
        {ok, #{player_id := PlayerId, quantity := Current} = Item} ->
            case Current >= Qty of
                true when Current =:= Qty ->
                    _ = asobi_repo:delete(asobi_player_item, Item),
                    {json, 200, #{}, #{success => true, remaining_quantity => 0}};
                true ->
                    CS = kura_changeset:cast(
                        asobi_player_item, Item, #{quantity => Current - Qty}, [quantity]
                    ),
                    {ok, Updated} = asobi_repo:update(CS),
                    {json, 200, #{}, #{
                        success => true, remaining_quantity => maps:get(quantity, Updated)
                    }};
                false ->
                    {json, 400, #{}, #{error => ~"insufficient_quantity"}}
            end;
        {ok, _} ->
            {status, 403};
        {error, not_found} ->
            {status, 404}
    end;
consume(_) ->
    {json, 400, #{}, #{error => ~"invalid_quantity"}}.
