-module(asobi_season).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, indexes/0, generate_id/0]).
-export([current/0, config/1, upcoming/0, history/0, time_remaining/0]).

-spec table() -> binary().
table() -> ~"seasons".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        #kura_field{name = starts_at, type = bigint, nullable = false},
        #kura_field{name = ends_at, type = bigint, nullable = false},
        #kura_field{name = status, type = string, default = ~"upcoming"},
        #kura_field{name = config, type = jsonb, default = #{}},
        #kura_field{name = ranked, type = jsonb, default = #{}},
        #kura_field{name = rewards, type = jsonb, default = #{}},
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
        {[starts_at], #{}},
        {[ends_at], #{}}
    ].

%% --- Query API ---

-spec current() -> {ok, map()} | {error, no_active_season}.
current() ->
    Q = kura_query:limit(kura_query:where(kura_query:from(asobi_season), {status, ~"active"}), 1),
    case asobi_repo:all(Q) of
        {ok, [Season | _]} -> {ok, Season};
        _ -> {error, no_active_season}
    end.

-spec config(binary()) -> term().
config(Key) ->
    case current() of
        {ok, #{config := Config}} -> maps:get(Key, Config, undefined);
        _ -> undefined
    end.

-spec upcoming() -> [map()].
upcoming() ->
    Q = kura_query:order_by(
        kura_query:where(kura_query:from(asobi_season), {status, ~"upcoming"}),
        [{starts_at, asc}]
    ),
    case asobi_repo:all(Q) of
        {ok, Seasons} -> Seasons;
        _ -> []
    end.

-spec history() -> [map()].
history() ->
    Q = kura_query:limit(
        kura_query:order_by(
            kura_query:where(kura_query:from(asobi_season), {status, ~"ended"}),
            [{ends_at, desc}]
        ),
        20
    ),
    case asobi_repo:all(Q) of
        {ok, Seasons} -> Seasons;
        _ -> []
    end.

-spec time_remaining() -> pos_integer() | infinity.
time_remaining() ->
    case current() of
        {ok, #{ends_at := EndsAt}} ->
            Now = erlang:system_time(millisecond),
            max(0, EndsAt - Now);
        _ ->
            infinity
    end.
