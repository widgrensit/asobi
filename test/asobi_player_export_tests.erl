-module(asobi_player_export_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

-define(PLAYER, ~"01960000-0000-7000-8000-000000000001").
-define(OTHER_VOTER, ~"01960000-0000-7000-8000-0000000000ff").

export_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a missing player is not_found", fun missing_player/0},
        {"the credential fields never leave", fun credentials_are_withheld/0},
        {"every table erasure covers is exported", fun covers_the_same_tables/0},
        {"match records are matched by containment", fun match_records_by_containment/0},
        {"votes are matched by jsonb key existence", fun votes_by_key_existence/0},
        {"a vote exports this player's choice and nobody else's",
            fun votes_do_not_leak_other_voters/0}
    ]}.

setup() ->
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) -> {ok, player_row()} end),
    meck:expect(asobi_repo, all, fun(#kura_query{from = Schema}) -> {ok, [row(Schema)]} end),
    ok.

cleanup(_) ->
    meck:unload(asobi_repo),
    ok.

%% Everything a projection could leak, on the two rows that carry one.
player_row() ->
    #{
        id => ?PLAYER,
        username => ~"kaito",
        display_name => ~"Kaito",
        avatar_url => undefined,
        metadata => #{},
        banned_at => undefined,
        hashed_password => ~"pbkdf2-sha512$...",
        inserted_at => {{2026, 1, 1}, {0, 0, 0}},
        updated_at => {{2026, 1, 1}, {0, 0, 0}}
    }.

row(asobi_player_token) ->
    #{
        id => ~"t-1",
        user_id => ?PLAYER,
        token => ~"a-live-bearer-token",
        context => ~"access",
        family_id => ~"f-1",
        used_at => undefined,
        inserted_at => {{2026, 1, 1}, {0, 0, 0}}
    };
row(asobi_vote) ->
    #{
        id => ~"v-1",
        match_id => ~"m-1",
        template => ~"kick",
        method => ~"majority",
        options => [~"yes", ~"no"],
        votes_cast => #{?PLAYER => ~"yes", ?OTHER_VOTER => ~"no"},
        result => #{~"winner" => ~"yes"},
        distribution => #{~"yes" => 1, ~"no" => 1},
        turnout => 1.0,
        opened_at => {{2026, 1, 1}, {0, 0, 0}},
        closed_at => {{2026, 1, 1}, {0, 0, 30}}
    };
row(Schema) ->
    #{id => atom_to_binary(Schema), player_id => ?PLAYER}.

missing_player() ->
    meck:expect(asobi_repo, get, fun(asobi_player, ?PLAYER) -> {error, not_found} end),
    ?assertEqual({error, not_found}, asobi_player_export:run(?PLAYER)).

%% Positive allowlists, never `maps:without/2`: `players` carries
%% `hashed_password` and `player_tokens` carries a live bearer credential, so a
%% subtractive filter is one schema field away from exporting either.
credentials_are_withheld() ->
    {ok, #{player := Player, tokens := [Token]}} = asobi_player_export:run(?PLAYER),
    ?assertNot(maps:is_key(hashed_password, Player)),
    ?assertEqual(~"kaito", maps:get(username, Player)),
    ?assertNot(maps:is_key(token, Token)),
    ?assertEqual(~"access", maps:get(context, Token)).

%% The export and the erasure describe the same footprint. Two lists that drift
%% mean an operator answering an access request under-reports what a deletion
%% request would remove.
covers_the_same_tables() ->
    {ok, Payload} = asobi_player_export:run(?PLAYER),
    Queried = lists:usort([
        Schema
     || {_Pid, {asobi_repo, all, [#kura_query{from = Schema}]}, _R} <- meck:history(asobi_repo)
    ]),
    ?assertEqual(
        lists:usort([
            asobi_chat_message,
            asobi_cloud_save,
            asobi_friendship,
            asobi_group,
            asobi_group_member,
            asobi_iap_transaction,
            asobi_leaderboard_entry,
            asobi_match_record,
            asobi_notification,
            asobi_player_identity,
            asobi_player_item,
            asobi_player_stats,
            asobi_player_token,
            asobi_storage,
            asobi_transaction,
            asobi_vote,
            asobi_wallet
        ]),
        Queried
    ),
    ?assertEqual(18, map_size(Payload)).

%% `match_records.players` is a jsonb id list with no foreign key, so a match a
%% player took part in is only reachable by containment.
match_records_by_containment() ->
    {ok, _} = asobi_player_export:run(?PLAYER),
    [Wheres] = [
        W
     || {_Pid, {asobi_repo, all, [#kura_query{from = asobi_match_record, wheres = W}]}, _R} <-
            meck:history(asobi_repo)
    ],
    ?assertMatch([{fragment, ~"\"players\" @> ?::jsonb", [_]}], Wheres),
    [{fragment, _, [Json]}] = Wheres,
    ?assertEqual([?PLAYER], json:decode(Json)).

%% `votes_cast` is a jsonb object keyed by voter id, not a list, so containment
%% is the wrong test - the key has to be probed. `jsonb_exists/2` rather than
%% its `?` infix form, because `?` is the parameter placeholder in a fragment.
votes_by_key_existence() ->
    {ok, _} = asobi_player_export:run(?PLAYER),
    [Wheres] = [
        W
     || {_Pid, {asobi_repo, all, [#kura_query{from = asobi_vote, wheres = W}]}, _R} <-
            meck:history(asobi_repo)
    ],
    ?assertEqual([{fragment, ~"jsonb_exists(\"votes_cast\", ?)", [?PLAYER]}], Wheres).

%% The one table here whose row is about several people at once. Exporting
%% `votes_cast` as stored would hand the requester every other voter's private
%% choice - a data-subject request turned into a disclosure of everyone else.
votes_do_not_leak_other_voters() ->
    {ok, #{votes := [Vote]}} = asobi_player_export:run(?PLAYER),
    ?assertEqual(~"yes", maps:get(choice, Vote)),
    ?assertNot(maps:is_key(votes_cast, Vote)),
    %% Belt and braces: no other voter's id appears anywhere in the projection,
    %% however the row is reshaped later.
    Flat = iolist_to_binary(io_lib:format("~p", [Vote])),
    ?assertEqual(nomatch, binary:match(Flat, ?OTHER_VOTER)),
    %% Aggregates name nobody, so they survive and keep the vote readable.
    ?assertEqual(1.0, maps:get(turnout, Vote)),
    ?assertEqual(#{~"yes" => 1, ~"no" => 1}, maps:get(distribution, Vote)),
    %% A player who did not vote in a row that reached the projection is `null`,
    %% not a crash and not a missing key.
    ?assertEqual(null, maps:get(choice, asobi_player_export_probe(~"nobody"))).

%% The projection applied to the same row for a player who never voted in it.
asobi_player_export_probe(PlayerId) ->
    meck:expect(asobi_repo, get, fun(asobi_player, _) -> {ok, player_row()} end),
    {ok, #{votes := [Vote]}} = asobi_player_export:run(PlayerId),
    Vote.
