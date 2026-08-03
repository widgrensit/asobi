-module(asobi_player_stats).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, associations/0, generate_id/0]).
-export([init/1, record_match/2]).

-include_lib("kernel/include/logger.hrl").

%% Create the stats row for a newly-created player. Shared by the register,
%% OAuth, and guest paths. Logs and swallows insert errors so a stats blip
%% never blocks account creation, but leaves a trace (F-25).
-spec init(binary()) -> ok.
init(PlayerId) ->
    CS = kura_changeset:cast(?MODULE, #{}, #{player_id => PlayerId}, [player_id]),
    case asobi_repo:insert(CS) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{
                event => player_stats_init_failed, player_id => PlayerId, reason => Reason
            }),
            ok
    end.

-doc """
Fold one finished match into every participant's stats row (asobi#329).

`games_played` moves for every participant. `wins` and `losses` come from
the result map the game module returned with `{finished, Result, State}`,
which asobi reads for exactly these keys - accepted as atoms or binaries,
because a Lua game's result arrives with binary keys:

- `winners` (list of player ids) or `winner` (one player id)
- `losers` (list of player ids) or `loser` (one player id)

Ids that are not in the match roster are ignored. When winners are
declared and losers are not, every other participant is recorded as a
loss; declare `losers => []` for a game where losing is not a thing. A
result declaring neither only moves `games_played`, which is what a draw,
a co-op run, or an unscored sandbox should do.

`rating` and `rating_deviation` are deliberately untouched - asobi has no
rating algorithm, and the column names imply a specific one.

Must be called inside `asobi_repo:transaction/1` alongside the write that
makes the match final, so the counters cannot drift from the match record.
""".
-spec record_match([binary()], map()) -> ok.
record_match([], _Result) ->
    ok;
record_match(Participants, Result) ->
    Winners = in_roster(Participants, declared(Result, winners, winner)),
    Losers = losers(Participants, Winners, Result),
    lists:foreach(
        fun(PlayerId) ->
            bump(PlayerId, tally(PlayerId, Winners), tally(PlayerId, Losers))
        end,
        Participants
    ).

-spec table() -> binary().
table() -> ~"player_stats".

-spec fields() -> [#kura_field{}].
fields() ->
    [
        #kura_field{name = player_id, type = uuid, primary_key = true, nullable = false},
        #kura_field{name = games_played, type = integer, default = 0, nullable = false},
        #kura_field{name = wins, type = integer, default = 0, nullable = false},
        #kura_field{name = losses, type = integer, default = 0, nullable = false},
        #kura_field{name = rating, type = float, default = 1500.0, nullable = false},
        #kura_field{name = rating_deviation, type = float, default = 350.0, nullable = false},
        #kura_field{name = metadata, type = jsonb, default = #{}},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].

-spec generate_id() -> binary().
generate_id() -> asobi_id:generate().

-spec associations() -> [#kura_assoc{}].
associations() ->
    [
        #kura_assoc{
            name = player, type = belongs_to, schema = asobi_player, foreign_key = player_id
        }
    ].

%% --- Internal ---

%% A single UPDATE per participant, so the increment is relative to the
%% committed row rather than to one this process read earlier - kura's
%% update_all/2 can only SET literals, and a read-modify-write would need
%% the wallet's advisory-lock dance to stay correct under concurrent
%% matches.
-spec bump(binary(), 0 | 1, 0 | 1) -> ok.
bump(PlayerId, Win, Loss) ->
    SQL = [
        ~"UPDATE player_stats SET games_played = games_played + 1, ",
        ~"wins = wins + $2, losses = losses + $3, updated_at = now() ",
        ~"WHERE player_id = $1"
    ],
    case kura_db:query(asobi_repo, SQL, [PlayerId, Win, Loss]) of
        #{num_rows := 0} ->
            ?LOG_WARNING(#{event => player_stats_row_missing, player_id => PlayerId});
        #{num_rows := _} ->
            ok;
        Other ->
            ?LOG_WARNING(#{
                event => player_stats_update_failed, player_id => PlayerId, reason => Other
            })
    end,
    ok.

-spec declared(map(), atom(), atom()) -> [dynamic()] | undefined.
declared(Result, Plural, Singular) ->
    case {value(Result, Plural), value(Result, Singular)} of
        {Ids, _} when is_list(Ids) -> Ids;
        {_, Id} when is_binary(Id) -> [Id];
        _ -> undefined
    end.

-spec value(map(), atom()) -> dynamic().
value(Result, Key) ->
    case maps:get(Key, Result, undefined) of
        undefined -> maps:get(atom_to_binary(Key, utf8), Result, undefined);
        Value -> Value
    end.

-spec in_roster([binary()], [dynamic()] | undefined) -> [binary()].
in_roster(_Participants, undefined) -> [];
in_roster(Participants, Ids) -> [Id || Id <- Ids, lists:member(Id, Participants)].

-spec losers([binary()], [binary()], map()) -> [binary()].
losers(Participants, Winners, Result) ->
    case declared(Result, losers, loser) of
        undefined when Winners =/= [] -> Participants -- Winners;
        undefined -> [];
        Declared -> in_roster(Participants, Declared)
    end.

-spec tally(binary(), [binary()]) -> 0 | 1.
tally(PlayerId, Ids) ->
    case lists:member(PlayerId, Ids) of
        true -> 1;
        false -> 0
    end.
