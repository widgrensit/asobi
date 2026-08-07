-module(asobi_economy).

-export([
    get_or_create_wallet/2,
    grant/4,
    debit/4,
    purchase/2,
    get_wallets/1,
    get_history/3
]).

-ifdef(TEST).
-export([grant_inner/4, debit_inner/4]).
-endif.

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
                        {ok, _} -> {error, wallet_not_found};
                        {error, _} = Err2 -> Err2
                    end
            end;
        {error, _} = Err ->
            Err
    end.

-spec grant(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
grant(PlayerId, Currency, Amount, Opts) when
    is_integer(Amount), Amount > 0, is_binary(PlayerId), is_binary(Currency)
->
    asobi_telemetry:economy_transaction(
        PlayerId,
        Currency,
        Amount,
        maps:get(reason, Opts, ~"admin_grant")
    ),
    case
        asobi_repo:transaction(fun() ->
            ok = acquire_wallet_lock(PlayerId, Currency),
            grant_inner(PlayerId, Currency, Amount, Opts)
        end)
    of
        {ok, W} when is_map(W) -> {ok, W};
        {error, _} = Err -> Err;
        _ -> {error, transaction_failed}
    end.

-spec debit(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
debit(PlayerId, Currency, Amount, Opts) when
    is_integer(Amount), Amount > 0, is_binary(PlayerId), is_binary(Currency)
->
    asobi_telemetry:economy_transaction(
        PlayerId,
        Currency,
        -Amount,
        maps:get(reason, Opts, ~"purchase")
    ),
    case
        asobi_repo:transaction(fun() ->
            ok = acquire_wallet_lock(PlayerId, Currency),
            debit_inner(PlayerId, Currency, Amount, Opts)
        end)
    of
        {ok, W} when is_map(W) -> {ok, W};
        {error, _} = Err -> Err;
        _ -> {error, transaction_failed}
    end.

%% Single transaction for the whole purchase flow: acquire the wallet
%% lock once, then debit + grant the item inline. F-22 (nested
%% transactions) is closed as a side-effect — `debit_inner/4` doesn't
%% open its own transaction.
-spec purchase(binary(), binary()) -> {ok, map()} | {error, term()}.
purchase(PlayerId, ListingId) when is_binary(PlayerId), is_binary(ListingId) ->
    case asobi_repo:get(asobi_store_listing, ListingId) of
        {ok,
            #{active := true, currency := Currency, price := Price, item_def_id := ItemDefId} =
                _Listing} ->
            case
                asobi_repo:transaction(fun() ->
                    ok = acquire_wallet_lock(PlayerId, Currency),
                    case
                        debit_inner(PlayerId, Currency, Price, #{
                            reason => ~"purchase",
                            reference_type => ~"store_listing",
                            reference_id => ListingId
                        })
                    of
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
                end)
            of
                {ok, Item} when is_map(Item) -> {ok, Item};
                {error, _} = Err -> Err;
                _ -> {error, transaction_failed}
            end;
        {ok, _} ->
            {error, listing_inactive};
        {error, _} = Err ->
            Err
    end.

%% --- Internal ---

%% Postgres advisory transaction lock keyed by (player_id, currency) —
%% blocks any concurrent transaction trying the same wallet until ours
%% commits or rolls back. Closes F-5 (wallet double-spend race) without
%% requiring a `SELECT … FOR UPDATE` rewrite of the kura query layer.
%% Must be called inside an open transaction.
-spec acquire_wallet_lock(binary(), binary()) -> ok.
acquire_wallet_lock(PlayerId, Currency) ->
    %% pg_advisory_xact_lock returns void, which the driver can't decode -
    %% wrap it in a subselect so the row it sees is plain int.
    SQL =
        ~"SELECT 1 AS locked FROM (SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))) AS _l",
    #{rows := [_ | _]} = kura_db:query(asobi_repo, SQL, [PlayerId, Currency]),
    ok.

%% asobi#216 security review (M1 on #255): grant/4 and debit/4 have no
%% in-repo caller that threads client data into Opts.metadata today, but
%% they are exported library entry points into a money-adjacent audit
%% table the same way asobi_player:registration_changeset/2 is (#169 M3) -
%% the cap travels with the write path, not with today's callers staying
%% disciplined. Checked before any wallet write, so a rejected blob is a
%% clean {error, _} return with nothing to roll back.
-spec metadata_within_limit(dynamic()) -> boolean().
metadata_within_limit(Metadata) ->
    asobi_jsonb:within_limit(Metadata, asobi_jsonb:default_metadata_bytes()).

-spec grant_inner(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
grant_inner(PlayerId, Currency, Amount, Opts) ->
    Metadata = maps:get(metadata, Opts, #{}),
    case metadata_within_limit(Metadata) of
        false ->
            {error, metadata_too_large};
        true ->
            {ok, Wallet} = get_or_create_wallet(PlayerId, Currency),
            NewBalance = maps:get(balance, Wallet) + Amount,
            WalletCS = kura_changeset:cast(
                asobi_wallet, Wallet, #{balance => NewBalance}, [balance]
            ),
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
                    metadata => Metadata
                },
                [wallet_id, amount, balance_after, reason, reference_type, reference_id, metadata]
            ),
            {ok, _Tx} = asobi_repo:insert(TxCS),
            {ok, UpdatedWallet}
    end.

-spec debit_inner(binary(), binary(), pos_integer(), map()) -> {ok, map()} | {error, term()}.
debit_inner(PlayerId, Currency, Amount, Opts) ->
    Metadata = maps:get(metadata, Opts, #{}),
    case metadata_within_limit(Metadata) of
        false ->
            {error, metadata_too_large};
        true ->
            debit_inner_checked(PlayerId, Currency, Amount, Opts, Metadata)
    end.

-spec debit_inner_checked(binary(), binary(), pos_integer(), map(), dynamic()) ->
    {ok, map()} | {error, term()}.
debit_inner_checked(PlayerId, Currency, Amount, Opts, Metadata) ->
    {ok, Wallet} = get_or_create_wallet(PlayerId, Currency),
    Balance = maps:get(balance, Wallet),
    case Balance >= Amount of
        false ->
            {error, insufficient_funds};
        true ->
            NewBalance = Balance - Amount,
            WalletCS = kura_changeset:cast(
                asobi_wallet, Wallet, #{balance => NewBalance}, [balance]
            ),
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
                    metadata => Metadata
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
