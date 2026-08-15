-module(asobi_guest_purge_tests).

-include_lib("eunit/include/eunit.hrl").

sql(Cutoff) ->
    Q = kura_query:where(kura_query:from(asobi_player), asobi_guest_purge:clause(Cutoff)),
    {SQL, Params, _} = kura_dialect_pg:to_sql_from(Q, 1),
    {iolist_to_binary(SQL), Params}.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

%%--------------------------------------------------------------------
%% The literal table names in the subqueries
%%--------------------------------------------------------------------

%% `clause/1` names both tables as literal SQL because a join would be
%% ambiguous. That is only safe while the schema modules still agree, so a
%% rename has to fail here rather than at 3am against a table that no longer
%% exists.
players_table_is_still_called_players_test() ->
    ?assertEqual(~"players", asobi_player:table()).

identities_table_is_still_called_player_identities_test() ->
    ?assertEqual(~"player_identities", asobi_player_identity:table()).

%%--------------------------------------------------------------------
%% The predicate
%%--------------------------------------------------------------------

clause_has_three_conditions_test() ->
    {'and', Conditions} = asobi_guest_purge:clause(undefined),
    ?assertEqual(3, length(Conditions)).

%% A claimed guest has a password, so the erasure can never reach one.
clause_requires_no_password_test() ->
    {'and', Conditions} = asobi_guest_purge:clause(undefined),
    ?assert(lists:member({hashed_password, is_nil}, Conditions)).

clause_requires_a_guest_identity_test() ->
    {SQL, _Params} = sql(undefined),
    ?assert(contains(SQL, ~"EXISTS (SELECT 1 FROM \"player_identities\"")).

%% The one that stops a guest who linked an OAuth account from being swept up
%% with the abandoned devices.
clause_excludes_any_other_provider_test() ->
    {SQL, _Params} = sql(undefined),
    ?assert(contains(SQL, ~"NOT EXISTS (SELECT 1 FROM \"player_identities\"")).

clause_correlates_to_the_outer_player_test() ->
    {SQL, _Params} = sql(undefined),
    ?assert(contains(SQL, ~"\"player_identities\".\"player_id\" = \"players\".\"id\"")).

%% Every value is bound, none interpolated: the provider name reaches Postgres
%% as a parameter, and the SQL text never carries it.
clause_binds_the_provider_test() ->
    {SQL, Params} = sql(undefined),
    ?assertEqual([~"guest", ~"guest"], Params),
    ?assertNot(contains(SQL, ~"'guest'")).

%%--------------------------------------------------------------------
%% The cutoff
%%--------------------------------------------------------------------

cutoff_reads_last_seen_not_signup_test() ->
    {SQL, _Params} = sql({{2026, 1, 1}, {0, 0, 0}}),
    ?assert(contains(SQL, ~"\"player_identities\".\"updated_at\" <=")),
    ?assertNot(contains(SQL, ~"inserted_at")).

%% The boundary is inclusive on purpose, and a strict `<` here is a real bug
%% rather than an off-by-one: `erlang:universaltime/0` has whole-second
%% resolution, so `inactive_for_seconds: 0` would spare every guest whose
%% identity was written during the current second - "clear all guest users"
%% silently keeping the ones who just arrived. Caught by
%% `asobi_guest_purge_SUITE:zero_seconds_takes_every_unclaimed_guest/1` against
%% a real database; pinned here so it fails in eunit first.
cutoff_boundary_is_inclusive_test() ->
    {SQL, _Params} = sql({{2026, 1, 1}, {0, 0, 0}}),
    ?assert(contains(SQL, ~"\"updated_at\" <= ")),
    ?assertNot(contains(SQL, ~"\"updated_at\" < $")).

cutoff_is_bound_alongside_the_provider_test() ->
    Cutoff = {{2026, 1, 1}, {0, 0, 0}},
    {_SQL, Params} = sql(Cutoff),
    ?assertEqual([~"guest", Cutoff, ~"guest"], Params).

undefined_cutoff_drops_only_the_cutoff_test() ->
    {SQL, _Params} = sql(undefined),
    ?assertNot(contains(SQL, ~"\"updated_at\" <")),
    ?assert(contains(SQL, ~"\"player_identities\".\"provider\"")).

%% Zero seconds is "everyone, including the guest who signed in a moment ago",
%% which is the whole point of making the caller name it.
zero_seconds_is_now_test() ->
    Before = erlang:universaltime(),
    Cutoff = asobi_guest_purge:cutoff(0),
    After = erlang:universaltime(),
    ?assert(Cutoff >= Before andalso Cutoff =< After).

cutoff_subtracts_the_seconds_test() ->
    Now = calendar:datetime_to_gregorian_seconds(asobi_guest_purge:cutoff(0)),
    Hour = calendar:datetime_to_gregorian_seconds(asobi_guest_purge:cutoff(3600)),
    ?assert(Now - Hour >= 3600 andalso Now - Hour =< 3601).

%%--------------------------------------------------------------------
%% Batch bounds
%%--------------------------------------------------------------------

default_limit_is_below_the_ceiling_test() ->
    ?assert(asobi_guest_purge:default_limit() =< asobi_guest_purge:max_limit()).

limits_are_positive_test() ->
    ?assert(asobi_guest_purge:default_limit() > 0),
    ?assert(asobi_guest_purge:max_limit() > 0).
