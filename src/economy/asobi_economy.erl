-module(asobi_economy).

-export([
    get_or_create_wallet/2,
    grant/4,
    debit/4,
    purchase/2,
    get_wallets/1,
    get_history/3
]).

-spec get_or_create_wallet(binary(), binary()) -> {ok, map()} | {error, term()}.
get_or_create_wallet(PlayerId, Currency) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_wallet), {player_id, PlayerId}),
        {currency, Currency}
    ),
    case asobi_repo:all(Q) of
        {ok, [Wallet]} ->
            {ok, Wallet};
        {ok, []} ->
            CS = kura_changeset:cast(
                asobi_wallet,
                #{},
                #{
                    player_id => PlayerId,
                    currency => Currency,
                    balance => 0
                },
                [player_id, currency, balance]
            ),
            case asobi_repo:insert(CS) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} ->
                    %% Unique constraint race — another process created it first
                    case asobi_repo:all(Q) of
                        {ok, [Wallet]} -> {ok, Wallet};
                        Other -> Other
                    end
            end;
        {error, _} = Err ->
            Err
    end.

-spec grant(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
grant(PlayerId, Currency, Amount, Opts) when Amount > 0 ->
    asobi_repo:transaction(fun() ->
        {ok, Wallet} = get_or_create_wallet(PlayerId, Currency),
        NewBalance = maps:get(balance, Wallet) + Amount,
        WalletCS = kura_changeset:cast(asobi_wallet, Wallet, #{balance => NewBalance}, [balance]),
        {ok, UpdatedWallet} = asobi_repo:update(WalletCS),
        TxCS = kura_changeset:cast(
            asobi_transaction,
            #{},
            #{
                wallet_id => maps:get(id, Wallet),
                amount => Amount,
                balance_after => NewBalance,
                reason => maps:get(reason, Opts, ~"admin_grant"),
                reference_type => maps:get(reference_type, Opts, undefined),
                reference_id => maps:get(reference_id, Opts, undefined),
                metadata => maps:get(metadata, Opts, #{})
            },
            [wallet_id, amount, balance_after, reason, reference_type, reference_id, metadata]
        ),
        {ok, _Tx} = asobi_repo:insert(TxCS),
        {ok, UpdatedWallet}
    end).

-spec debit(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
debit(PlayerId, Currency, Amount, Opts) when Amount > 0 ->
    asobi_repo:transaction(fun() ->
        {ok, Wallet} = get_or_create_wallet(PlayerId, Currency),
        Balance = maps:get(balance, Wallet),
        case Balance >= Amount of
            false ->
                {error, insufficient_funds};
            true ->
                NewBalance = Balance - Amount,
                WalletCS = kura_changeset:cast(asobi_wallet, Wallet, #{balance => NewBalance}, [
                    balance
                ]),
                {ok, UpdatedWallet} = asobi_repo:update(WalletCS),
                TxCS = kura_changeset:cast(
                    asobi_transaction,
                    #{},
                    #{
                        wallet_id => maps:get(id, Wallet),
                        amount => -Amount,
                        balance_after => NewBalance,
                        reason => maps:get(reason, Opts, ~"purchase"),
                        reference_type => maps:get(reference_type, Opts, undefined),
                        reference_id => maps:get(reference_id, Opts, undefined),
                        metadata => maps:get(metadata, Opts, #{})
                    },
                    [
                        wallet_id,
                        amount,
                        balance_after,
                        reason,
                        reference_type,
                        reference_id,
                        metadata
                    ]
                ),
                {ok, _Tx} = asobi_repo:insert(TxCS),
                {ok, UpdatedWallet}
        end
    end).

-spec purchase(binary(), binary()) -> {ok, map()} | {error, term()}.
purchase(PlayerId, ListingId) ->
    case asobi_repo:get(asobi_store_listing, ListingId) of
        {ok,
            #{active := true, currency := Currency, price := Price, item_def_id := ItemDefId} =
                _Listing} ->
            asobi_repo:transaction(fun() ->
                case debit(PlayerId, Currency, Price, #{
                    reason => ~"purchase",
                    reference_type => ~"store_listing",
                    reference_id => ListingId
                }) of
                    {error, insufficient_funds} ->
                        {error, insufficient_funds};
                    {ok, _Wallet} ->
                        ItemCS = kura_changeset:cast(
                            asobi_player_item,
                            #{},
                            #{
                                item_def_id => ItemDefId,
                                player_id => PlayerId,
                                quantity => 1,
                                acquired_at => calendar:universal_time()
                            },
                            [item_def_id, player_id, quantity, acquired_at]
                        ),
                        asobi_repo:insert(ItemCS)
                end
            end);
        {ok, _} ->
            {error, listing_inactive};
        {error, _} = Err ->
            Err
    end.

-spec get_wallets(binary()) -> {ok, [map()]} | {error, term()}.
get_wallets(PlayerId) ->
    Q = kura_query:where(kura_query:from(asobi_wallet), {player_id, PlayerId}),
    asobi_repo:all(Q).

-spec get_history(binary(), binary(), map()) -> {ok, [map()]} | {error, term()}.
get_history(PlayerId, Currency, Opts) ->
    case get_or_create_wallet(PlayerId, Currency) of
        {ok, Wallet} ->
            Limit = maps:get(limit, Opts, 50),
            Q = kura_query:limit(
                kura_query:order_by(
                    kura_query:where(
                        kura_query:from(asobi_transaction), {wallet_id, maps:get(id, Wallet)}
                    ),
                    [{inserted_at, desc}]
                ),
                Limit
            ),
            asobi_repo:all(Q);
        {error, _} = Err ->
            Err
    end.
