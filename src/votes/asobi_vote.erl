-module(asobi_vote).
-behaviour(kura_schema).
-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0]).

-spec table() -> binary().
table() -> ~"votes".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = match_id, type = uuid, nullable = false},
        #kura_field{name = template, type = string, nullable = false},
        #kura_field{name = method, type = string, nullable = false},
        #kura_field{name = options, type = jsonb, nullable = false, default = []},
        #kura_field{name = votes_cast, type = jsonb, default = #{}},
        #kura_field{name = result, type = jsonb, default = #{}},
        #kura_field{name = distribution, type = jsonb, default = #{}},
        #kura_field{name = turnout, type = float, default = 0.0},
        #kura_field{name = eligible_count, type = integer, default = 0},
        #kura_field{name = window_ms, type = integer, nullable = false},
        #kura_field{name = opened_at, type = utc_datetime},
        #kura_field{name = closed_at, type = utc_datetime},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[match_id], #{}},
        {[template], #{}}
    ].
