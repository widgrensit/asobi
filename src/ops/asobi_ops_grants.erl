-module(asobi_ops_grants).
-moduledoc """
Operator currency grants: the `player_data` mutation that moves money.

Everything here exists because a grant over HTTP is retried. The console
times out, the operator presses the button again, and without a key the
second press is a second credit that nobody can tell from a deliberate one
afterwards. So the key is **required** rather than optional: a grant that
arrives without one is refused with `ops.idempotency_key_required` and
nothing is written. Making it optional would mean the safe path is the one
the caller has to remember, which is how double credits happen.

`m:asobi_economy`'s `grant_once/5` is what makes the key mean anything - the
duplicate check runs inside the same transaction that holds the wallet's
advisory lock, so two concurrent retries serialise rather than both finding
nothing.

The outcome distinguishes the two cases without inventing a shape: a grant
that moved money is `{ok, [PlayerId], []}` and a replay is `{ok, [], []}` -
succeeded, acted on nobody. Both store `outcome = ok`; `succeeded_count`
tells them apart in a plain column query, which is what an audit reconciled
against the ledger needs. A ledger with one transaction row under two audit
rows is then explainable rather than suspicious.

The amount is capped. `?MAX_AMOUNT` is not an economic opinion, it is a
typo guard: a mis-pasted balance is the difference between a grant and a
destroyed economy, and no legitimate single operator grant needs more.
""".

-export([grant/5]).

-define(ACTION, ~"economy.grant").
-define(TARGET_TYPE, ~"player").
-define(CLASS, player_data).
-define(REASON, ~"ops_grant").
-define(REFERENCE_TYPE, ~"ops_grant").

-define(MAX_AMOUNT, 1000000000).
-define(MAX_CURRENCY_BYTES, 64).
-define(MAX_KEY_BYTES, 128).

-doc """
Grant `Amount` of `Currency` to `PlayerId` as `Actor`, at most once per `Key`.

`{ok, [PlayerId], []}` when the money moved, `{ok, [], []}` when `Key` had
already been granted, `{error, Reason}` when nothing was attempted.
""".
-spec grant(asobi_ops_auth:actor(), binary(), binary(), term(), term()) ->
    asobi_ops_audit:outcome().
grant(#{caps := Caps} = Actor, PlayerId, Currency, Amount, Key) ->
    asobi_ops_audit:mutation(Actor, ?ACTION, {?TARGET_TYPE, PlayerId}, fun() ->
        case asobi_ops_caps:authorised(?CLASS, Caps) of
            true -> checked(Actor, PlayerId, Currency, Amount, Key);
            false -> {error, forbidden}
        end
    end).

-spec checked(asobi_ops_auth:actor(), binary(), term(), term(), term()) ->
    asobi_ops_audit:outcome().
checked(Actor, PlayerId, Currency, Amount, Key) ->
    case problem(Currency, Amount, Key) of
        none -> exists(Actor, PlayerId, Currency, Amount, Key);
        Problem -> {error, Problem}
    end.

%% A grant to an id that is not a player would otherwise succeed: the wallet
%% is created on demand, so a mistyped uuid buys an orphan wallet holding real
%% currency and no way to notice. The read is one indexed lookup.
-spec exists(asobi_ops_auth:actor(), binary(), binary(), pos_integer(), binary()) ->
    asobi_ops_audit:outcome().
exists(Actor, PlayerId, Currency, Amount, Key) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, _Player} -> apply_grant(Actor, PlayerId, Currency, Amount, Key);
        {error, not_found} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec apply_grant(asobi_ops_auth:actor(), binary(), binary(), pos_integer(), binary()) ->
    asobi_ops_audit:outcome().
apply_grant(#{id := ActorId, display := Display}, PlayerId, Currency, Amount, Key) ->
    Opts = #{
        reason => ?REASON,
        reference_type => ?REFERENCE_TYPE,
        metadata => #{actor_id => ActorId, actor_display => Display}
    },
    case asobi_economy:grant_once(PlayerId, Currency, Amount, Opts, Key) of
        {ok, applied, _Wallet} -> {ok, [PlayerId], []};
        {ok, duplicate, _Wallet} -> {ok, [], []};
        {error, Reason} -> {ok, [], [{PlayerId, Reason}]}
    end.

%% Validation is a positive check on every field rather than a guard on the
%% clause head: `grant_once/5`'s own guard would answer `invalid_grant` for
%% all three, and an operator who typed a currency needs to be told it was the
%% currency.
-spec problem(term(), term(), term()) -> none | atom().
problem(Currency, Amount, Key) ->
    case {currency_ok(Currency), amount_ok(Amount), key_ok(Key)} of
        {false, _, _} -> invalid_currency;
        {_, false, _} -> invalid_amount;
        {_, _, false} -> invalid_idempotency_key;
        {true, true, true} -> none
    end.

-spec currency_ok(term()) -> boolean().
currency_ok(Currency) ->
    is_binary(Currency) andalso Currency =/= ~"" andalso
        byte_size(Currency) =< ?MAX_CURRENCY_BYTES.

-spec amount_ok(term()) -> boolean().
amount_ok(Amount) ->
    is_integer(Amount) andalso Amount > 0 andalso Amount =< ?MAX_AMOUNT.

-spec key_ok(term()) -> boolean().
key_ok(Key) ->
    is_binary(Key) andalso Key =/= ~"" andalso byte_size(Key) =< ?MAX_KEY_BYTES.
