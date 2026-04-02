-module(asobi_match_record).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).

-spec table() -> binary().
table() -> ~"match_records".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = mode, type = string},
        #kura_field{name = status, type = string, nullable = false},
        #kura_field{name = players, type = jsonb, default = []},
        #kura_field{name = result, type = jsonb, default = #{}},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = started_at, type = utc_datetime},
        #kura_field{name = finished_at, type = utc_datetime},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() -> [].

-spec indexes() -> [{[atom()], map()}].
indexes() ->
    [
        {[mode], #{}},
        {[status], #{}}
    ].
