-module(asobi_player_erase_SUITE).

%% Erasure against a real database.
%%
%% The unit tests for this module meck `asobi_repo`, which is exactly how the
%% bug this module exists to fix stayed hidden: `asobi_guest_reaper` deleted
%% four of fourteen child tables for months, and
%% `test/asobi_guest_reaper_tests.erl` could not see it because it mecked
%% `delete/2` to always return `{ok, #{}}`. The database is the only party that
%% knows a row is still referenced, and it was not in the test.
%%
%% So this suite exists to be the opposite: insert a row in EVERY table with a
%% foreign key into `players.id`, then erase, then assert the player is gone.
%% All 15 of those keys are `ON DELETE NO ACTION`, so a table this module
%% forgets makes the final delete raise - which is the point. Adding a
%% player-referencing table without teaching `asobi_player_erase` about it
%% fails here rather than in a self-hoster's reaper log.

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    erases_a_player_with_a_row_in_every_child_table/1,
    severs_rather_than_deletes_the_purchase_record/1,
    leaves_a_group_standing_when_its_creator_is_erased/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kura/include/kura.hrl").

all() ->
    [
        erases_a_player_with_a_row_in_every_child_table,
        severs_rather_than_deletes_the_purchase_record,
        leaves_a_group_standing_when_its_creator_is_erased
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------

erases_a_player_with_a_row_in_every_child_table(_Config) ->
    PlayerId = a_player(),
    ok = a_row_in_every_child_table(PlayerId),

    {ok, _} = asobi_player_erase:run(PlayerId),

    ?assertEqual({error, not_found}, asobi_repo:get(asobi_player, PlayerId)),
    [
        ?assertEqual(
            {ok, []},
            asobi_repo:all(by(Schema, Field, PlayerId)),
            unicode:characters_to_list(io_lib:format("~p rows survived erasure", [Schema]))
        )
     || {Schema, Field} <- deleted_children()
    ],
    ok.

%% A purchase record outlives the account: a refund or chargeback dispute needs
%% the provider transaction id, and statutory retention beats erasure for it.
%% The link to the person is what goes.
severs_rather_than_deletes_the_purchase_record(_Config) ->
    PlayerId = a_player(),
    {ok, Txn} = insert(asobi_iap_transaction, #{
        player_id => PlayerId,
        provider => ~"apple",
        transaction_id => unique(~"txn"),
        product_id => ~"coins_100",
        status => ~"verified"
    }),
    TxnId = maps:get(id, Txn),

    {ok, _} = asobi_player_erase:run(PlayerId),

    {ok, Kept} = asobi_repo:get(asobi_iap_transaction, TxnId),
    ?assertEqual(undefined, maps:get(player_id, Kept, undefined)),
    ?assertEqual(~"apple", maps:get(provider, Kept)),
    ok.

%% Deleting the group to free the foreign key would destroy every other
%% member's data, so the group stands and loses its creator.
leaves_a_group_standing_when_its_creator_is_erased(_Config) ->
    PlayerId = a_player(),
    {ok, Group} = insert(asobi_group, #{
        name => unique(~"group"),
        creator_id => PlayerId
    }),
    GroupId = maps:get(id, Group),

    {ok, _} = asobi_player_erase:run(PlayerId),

    {ok, Standing} = asobi_repo:get(asobi_group, GroupId),
    ?assertEqual(undefined, maps:get(creator_id, Standing, undefined)),
    ok.

%%--------------------------------------------------------------------

%% Every schema this module is expected to clear, with the column carrying the
%% player id. Keep it in step with asobi_player_erase:steps/1 - a table added
%% there and forgotten here is a test that passes for the wrong reason.
deleted_children() ->
    [
        {asobi_player_stats, player_id},
        {asobi_player_token, user_id},
        {asobi_player_identity, player_id},
        {asobi_wallet, player_id},
        {asobi_player_item, player_id},
        {asobi_storage, player_id},
        {asobi_cloud_save, player_id},
        {asobi_notification, player_id},
        {asobi_chat_message, sender_id},
        {asobi_group_member, player_id},
        {asobi_leaderboard_entry, player_id}
    ].

a_player() ->
    Username = unique(~"erase"),
    {ok, Player} = insert(asobi_player, #{
        username => Username,
        display_name => Username,
        hashed_password => ~"x"
    }),
    maps:get(id, Player).

a_row_in_every_child_table(PlayerId) ->
    {ok, _} = insert(asobi_player_stats, #{player_id => PlayerId, matches_played => 1}),
    {ok, _} = insert(asobi_player_token, #{
        user_id => PlayerId, token => unique(~"tok"), context => ~"refresh"
    }),
    {ok, _} = insert(asobi_player_identity, #{
        player_id => PlayerId,
        provider => ~"guest",
        provider_uid => unique(~"pid")
    }),
    {ok, _} = insert(asobi_wallet, #{player_id => PlayerId, currency => ~"coins", balance => 1}),
    {ok, Item} = insert(asobi_item_def, #{
        slug => unique(~"sword"), name => ~"Sword", category => ~"weapon"
    }),
    {ok, _} = insert(asobi_player_item, #{
        player_id => PlayerId,
        item_def_id => maps:get(id, Item),
        quantity => 1,
        acquired_at => calendar:universal_time()
    }),
    {ok, _} = insert(asobi_storage, #{
        player_id => PlayerId, collection => ~"c", key => ~"k", value => #{}
    }),
    {ok, _} = insert(asobi_cloud_save, #{player_id => PlayerId, slot => ~"1", data => #{}}),
    {ok, _} = insert(asobi_notification, #{
        player_id => PlayerId,
        type => ~"t",
        subject => ~"s",
        sent_at => calendar:universal_time()
    }),
    {ok, _} = insert(asobi_chat_message, #{
        sender_id => PlayerId,
        channel_type => ~"global",
        channel_id => unique(~"chan"),
        content => ~"hello",
        sent_at => calendar:universal_time()
    }),
    {ok, Group} = insert(asobi_group, #{name => unique(~"g"), creator_id => PlayerId}),
    {ok, _} = insert(asobi_group_member, #{
        group_id => maps:get(id, Group),
        player_id => PlayerId,
        joined_at => calendar:universal_time()
    }),
    {ok, _} = insert(asobi_leaderboard_entry, #{
        leaderboard_id => unique(~"board"),
        player_id => PlayerId,
        score => 1
    }),
    ok.

%% The repo takes a changeset, not a bare struct - `kura_changeset:cast/4` is
%% what applies the schema's types and defaults.
insert(Schema, Attrs) ->
    asobi_repo:insert(kura_changeset:cast(Schema, #{}, Attrs, maps:keys(Attrs))).

by(Schema, Field, PlayerId) ->
    kura_query:where(kura_query:from(Schema), {Field, PlayerId}).

unique(Prefix) ->
    <<Prefix/binary, "_", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>.
