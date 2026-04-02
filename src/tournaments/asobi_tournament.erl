-module(asobi_tournament).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).
-export([changeset/2]).

-spec table() -> binary().
table() -> ~"tournaments".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        #kura_field{name = leaderboard_id, type = string, nullable = false},
        #kura_field{name = max_entries, type = integer},
        #kura_field{name = entry_fee, type = jsonb, default = #{}},
        #kura_field{name = rewards, type = jsonb, default = #{}},
        #kura_field{name = status, type = string, default = ~"pending", nullable = false},
        #kura_field{name = start_at, type = utc_datetime, nullable = false},
        #kura_field{name = end_at, type = utc_datetime, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[status], #{}},
        {[start_at], #{}}
    ].

-spec changeset(map(), map()) -> #kura_changeset{}.
changeset(Data, Params) ->
    CS = kura_changeset:cast(
        ?MODULE,
        Data,
        Params,
        [name, leaderboard_id, max_entries, entry_fee, rewards, status, start_at, end_at, metadata]
    ),
    CS1 = kura_changeset:validate_required(CS, [name, leaderboard_id, start_at, end_at]),
    kura_changeset:validate_inclusion(CS1, status, [
        ~"pending", ~"active", ~"finished", ~"cancelled"
    ]).
