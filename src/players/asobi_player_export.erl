-module(asobi_player_export).
-moduledoc """
Everything core holds about one player, as one map.

The read half of `m:asobi_player_erase`, and it covers the same tables in the
same order, so "what would erasure delete" and "what would export return" stay
one list rather than two that drift.

## Positive allowlists, never `maps:without/2`

Every row goes through a `maps:with/2` projection, modelled on
`asobi_ops_players:project/1`. `players` carries `hashed_password`, so a
subtractive filter is one schema field away from exporting a credential;
`player_tokens` carries live bearer tokens, so the export reports that a
session existed and when, never the token itself.

## The two tables with no foreign key

`match_records.players` is a jsonb list of ids and `votes.votes_cast` is a
jsonb object keyed by voter id. Neither has a foreign key, and both are records
about a player whatever the schema says about referential integrity, so both
are included - by jsonb containment and jsonb key existence respectively.

`votes` is projected differently from every other table here: the row holds
*everybody's* votes, so exporting `votes_cast` whole would hand one player the
private choices of everyone else in the match. Only this player's own `choice`
is lifted out. A privacy feature that leaks is worse than one that is missing.

`zone_snapshots.entities` is deliberately absent. It is opaque game-defined
state whose shape core does not know - a game may key entities by player id or
bury one inside entity state, and there is no projection core could apply to it
that would not either miss the data or export another player's. A game that
puts personal data there owns exporting it, the same way it owns erasing it.

## No extension callback

There is deliberately no `export_player/1` for extensions in this change.
`c:asobi_extension:erase_player/1` earns its keep because the foreign key
physically forces an author to answer it; an export callback has no forcing
function, so an extension that skipped it would produce a silently incomplete
export and nothing would fail. That is a worse contract than no contract. If
one ever ships, the payload must name which installed extensions contributed
and which did not.
""".

-include_lib("kura/include/kura.hrl").

-export([run/1]).

-doc """
Every core row that names `PlayerId`, projected.

`{error, not_found}` when no such player exists - an empty export and a
missing account are different answers to a data-subject request.
""".
-spec run(binary()) -> {ok, map()} | {error, not_found}.
run(PlayerId) when is_binary(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} -> {ok, payload(PlayerId, Player)};
        {error, _Reason} -> {error, not_found}
    end.

%% --- Internal ---

-spec payload(binary(), map()) -> map().
payload(PlayerId, Player) ->
    #{
        player => player(Player),
        identities => rows(by(asobi_player_identity, player_id, PlayerId), fun identity/1),
        stats => rows(by(asobi_player_stats, player_id, PlayerId), fun stats/1),
        tokens => rows(by(asobi_player_token, user_id, PlayerId), fun token/1),
        wallets => rows(by(asobi_wallet, player_id, PlayerId), fun wallet/1),
        transactions => rows(wallet_transactions(PlayerId), fun transaction/1),
        items => rows(by(asobi_player_item, player_id, PlayerId), fun item/1),
        storage => rows(by(asobi_storage, player_id, PlayerId), fun storage/1),
        cloud_saves => rows(by(asobi_cloud_save, player_id, PlayerId), fun cloud_save/1),
        notifications => rows(by(asobi_notification, player_id, PlayerId), fun notification/1),
        leaderboard_entries => rows(
            by(asobi_leaderboard_entry, player_id, PlayerId), fun leaderboard_entry/1
        ),
        chat_messages => rows(by(asobi_chat_message, sender_id, PlayerId), fun chat_message/1),
        group_memberships => rows(by(asobi_group_member, player_id, PlayerId), fun group_member/1),
        groups_created => rows(by(asobi_group, creator_id, PlayerId), fun group/1),
        friendships => rows(friendships(PlayerId), fun friendship/1),
        iap_transactions => rows(
            by(asobi_iap_transaction, player_id, PlayerId), fun iap_transaction/1
        ),
        match_records => rows(match_records(PlayerId), fun match_record/1),
        votes => rows(votes(PlayerId), fun(Row) -> vote(PlayerId, Row) end)
    }.

%% A failed read is an empty list rather than a crash only where it cannot be
%% mistaken for an answer: it cannot, because `run/1` has already established
%% the player exists and any error here is logged by the repo.
-spec rows(#kura_query{}, fun((map()) -> map())) -> [map()].
rows(Query, Project) ->
    case asobi_repo:all(Query) of
        {ok, Found} -> [Project(Row) || Row <- Found];
        {error, _Reason} -> []
    end.

%% `hashed_password` is the field this projection exists to keep out.
-spec player(map()) -> map().
player(Row) ->
    maps:with(
        [id, username, display_name, avatar_url, metadata, banned_at, inserted_at, updated_at],
        Row
    ).

-spec identity(map()) -> map().
identity(Row) ->
    maps:with(
        [
            id,
            provider,
            provider_uid,
            provider_email,
            provider_display_name,
            provider_metadata,
            inserted_at,
            updated_at
        ],
        Row
    ).

-spec stats(map()) -> map().
stats(Row) ->
    maps:with(
        [player_id, games_played, wins, losses, rating, rating_deviation, metadata, updated_at], Row
    ).

%% `token` is a live bearer credential and never leaves the database. What a
%% player is owed here is that a session existed, not the key to it.
-spec token(map()) -> map().
token(Row) ->
    maps:with([id, context, family_id, used_at, inserted_at], Row).

-spec wallet(map()) -> map().
wallet(Row) ->
    maps:with([id, currency, balance, inserted_at, updated_at], Row).

-spec transaction(map()) -> map().
transaction(Row) ->
    maps:with(
        [
            id,
            wallet_id,
            amount,
            balance_after,
            reason,
            reference_type,
            reference_id,
            metadata,
            inserted_at
        ],
        Row
    ).

-spec item(map()) -> map().
item(Row) ->
    maps:with([id, item_def_id, quantity, metadata, acquired_at, updated_at], Row).

-spec storage(map()) -> map().
storage(Row) ->
    maps:with([id, collection, key, value, version, read_perm, write_perm, updated_at], Row).

-spec cloud_save(map()) -> map().
cloud_save(Row) ->
    maps:with([id, slot, data, version, updated_at], Row).

-spec notification(map()) -> map().
notification(Row) ->
    maps:with([id, type, subject, content, read, sent_at], Row).

-spec leaderboard_entry(map()) -> map().
leaderboard_entry(Row) ->
    maps:with([id, leaderboard_id, score, sub_score, metadata, updated_at], Row).

-spec chat_message(map()) -> map().
chat_message(Row) ->
    maps:with([id, channel_type, channel_id, content, metadata, sent_at], Row).

-spec group_member(map()) -> map().
group_member(Row) ->
    maps:with([id, group_id, role, joined_at], Row).

-spec group(map()) -> map().
group(Row) ->
    maps:with([id, name, description, max_members, open, metadata, inserted_at, updated_at], Row).

-spec friendship(map()) -> map().
friendship(Row) ->
    maps:with([id, player_id, friend_id, status, inserted_at, updated_at], Row).

-spec iap_transaction(map()) -> map().
iap_transaction(Row) ->
    maps:with(
        [id, provider, transaction_id, original_transaction_id, product_id, inserted_at], Row
    ).

-spec match_record(map()) -> map().
match_record(Row) ->
    maps:with([id, mode, status, result, metadata, started_at, finished_at, inserted_at], Row).

%% Only this player's own vote. `votes_cast` is `#{VoterId => OptionId}` for
%% every voter in the match, so it never leaves this function - the projection
%% lifts out the one key and drops the map. `distribution` and `turnout` are
%% aggregates over the whole match and name nobody, which is why they can stay.
-spec vote(binary(), map()) -> map().
vote(PlayerId, Row) ->
    Cast = maps:get(votes_cast, Row, #{}),
    Base = maps:with(
        [id, match_id, template, method, options, distribution, turnout, opened_at, closed_at],
        Row
    ),
    Base#{choice => choice(PlayerId, Cast)}.

%% jsonb decodes to a map with binary keys; anything else means the column was
%% not the shape this function expects, and guessing would be worse than `null`.
-spec choice(binary(), term()) -> term().
choice(PlayerId, Cast) when is_map(Cast) -> maps:get(PlayerId, Cast, null);
choice(_PlayerId, _Cast) -> null.

-spec by(module(), atom(), binary()) -> #kura_query{}.
by(Schema, Field, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {Field, PlayerId}).

-spec friendships(binary()) -> #kura_query{}.
friendships(PlayerId) ->
    kura_query:where(
        kura_query:from(asobi_friendship),
        {'or', [{player_id, PlayerId}, {friend_id, PlayerId}]}
    ).

-spec wallet_transactions(binary()) -> #kura_query{}.
wallet_transactions(PlayerId) ->
    Wallets = kura_query:select(by(asobi_wallet, player_id, PlayerId), [id]),
    kura_query:where(kura_query:from(asobi_transaction), {wallet_id, in, {subquery, Wallets}}).

%% No foreign key to lean on: `players` is a jsonb array of ids, so this is a
%% containment test rather than an equality one.
-spec match_records(binary()) -> #kura_query{}.
match_records(PlayerId) ->
    Contains = iolist_to_binary(json:encode([PlayerId])),
    kura_query:where(
        kura_query:from(asobi_match_record), {fragment, ~"\"players\" @> ?::jsonb", [Contains]}
    ).

%% `votes_cast` is a jsonb *object* keyed by voter id, so this asks whether the
%% key exists rather than testing containment. `jsonb_exists/2` and not the `?`
%% operator that is its infix form: `?` is the parameter placeholder in a kura
%% fragment, so the operator spelling is ambiguous here.
-spec votes(binary()) -> #kura_query{}.
votes(PlayerId) ->
    kura_query:where(
        kura_query:from(asobi_vote), {fragment, ~"jsonb_exists(\"votes_cast\", ?)", [PlayerId]}
    ).
