-module(asobi_iap_controller).

-export([verify_apple/1, verify_google/1]).

%% POST /api/v1/iap/apple
%% Body: {"signed_transaction": "<JWS string>"}
-spec verify_apple(cowboy_req:req()) -> {json, integer(), map(), map()}.
verify_apple(
    #{json := #{~"signed_transaction" := SignedTxn}, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(SignedTxn), is_binary(PlayerId) ->
    case asobi_iap:verify_apple(SignedTxn) of
        {ok, Result} ->
            record(PlayerId, ~"apple", maps:get(transaction_id, Result, undefined), Result);
        {error, Reason} ->
            {json, 422, #{}, #{error => Reason}}
    end;
verify_apple(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% POST /api/v1/iap/google
%% Body: {"product_id": "...", "purchase_token": "..."}
-spec verify_google(cowboy_req:req()) -> {json, integer(), map(), map()}.
verify_google(#{json := Params, auth_data := #{player_id := PlayerId}} = _Req) when
    is_map(Params), is_binary(PlayerId)
->
    case asobi_iap:verify_google(Params) of
        {ok, Result} ->
            record(PlayerId, ~"google", maps:get(order_id, Result, undefined), Result);
        {error, Reason} ->
            {json, 422, #{}, #{error => Reason}}
    end;
verify_google(_Req) ->
    {json, 400, #{}, #{error => ~"missing_required_fields"}}.

%% --- Internal ---

%% Persist the verified transaction bound to the player, exactly once.
%% Re-submitting the same receipt is idempotent for the owner (`duplicate` =>
%% true) and rejected for anyone else — a receipt can be claimed by one player.
-spec record(binary(), binary(), binary() | undefined, map()) -> {json, integer(), map(), map()}.
record(_PlayerId, _Provider, undefined, _Result) ->
    {json, 422, #{}, #{error => ~"missing_transaction_id"}};
record(PlayerId, Provider, TxnId, Result) when is_binary(TxnId) ->
    case existing(Provider, TxnId) of
        {ok, #{player_id := PlayerId}} ->
            {json, 200, #{}, Result#{duplicate => true}};
        {ok, _Other} ->
            {json, 409, #{}, #{error => ~"transaction_already_claimed"}};
        none ->
            insert_new(PlayerId, Provider, TxnId, Result)
    end.

-spec insert_new(binary(), binary(), binary(), map()) -> {json, integer(), map(), map()}.
insert_new(PlayerId, Provider, TxnId, Result) ->
    CS = asobi_iap_transaction:changeset(#{}, #{
        player_id => PlayerId,
        provider => Provider,
        transaction_id => TxnId,
        original_transaction_id => maps:get(original_transaction_id, Result, undefined),
        product_id => maps:get(product_id, Result, undefined)
    }),
    case asobi_repo:insert(CS) of
        {ok, _} ->
            {json, 200, #{}, Result#{duplicate => false}};
        {error, _Reason} ->
            %% Most likely the unique index firing on a concurrent submit of the
            %% same receipt. Re-check: if it now exists it was a race, else a
            %% genuine store failure.
            case existing(Provider, TxnId) of
                {ok, _} -> {json, 409, #{}, #{error => ~"transaction_already_claimed"}};
                none -> {json, 500, #{}, #{error => ~"record_failed"}}
            end
    end.

-spec existing(binary(), binary()) -> {ok, map()} | none.
existing(Provider, TxnId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_iap_transaction), {provider, Provider}),
        {transaction_id, TxnId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Row | _]} -> {ok, Row};
        _ -> none
    end.
