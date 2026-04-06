-module(asobi_stats_sync_worker).
-moduledoc """
Background worker that processes finished match records and updates player stats.

Finds match records with status "finished", calculates Glicko-2 rating updates
for each participant, increments win/loss/games_played counters, then marks the
record as "synced".
""".
-behaviour(shigoto_worker).

-export([perform/1, queue/0, priority/0, max_attempts/1]).

-include_lib("kura/include/kura.hrl").

-spec queue() -> binary().
queue() -> ~"default".

-spec priority() -> integer().
priority() -> 50.

-spec max_attempts(map()) -> pos_integer().
max_attempts(_Args) -> 3.

-spec perform(map()) -> ok.
perform(_Args) ->
    Q = kura_query:limit(
        kura_query:where(kura_query:from(asobi_match_record), {status, ~"finished"}),
        100
    ),
    case asobi_repo:all(Q) of
        {ok, []} ->
            ok;
        {ok, Records} ->
            [sync_record(R) || R <- Records],
            logger:info(#{msg => ~"stats_synced", count => length(Records)});
        {error, Reason} ->
            logger:error(#{msg => ~"stats_sync_failed", error => Reason}),
            ok
    end.

-spec sync_record(map()) -> ok.
sync_record(#{id := RecordId, players := Players, result := Result}) ->
    Winners = maps:get(~"winners", Result, maps:get(winners, Result, [])),
    WinnerList = ensure_list(Winners),
    PlayerIds = ensure_binary_list(ensure_list(Players)),
    sync_players(PlayerIds, WinnerList),
    mark_synced(RecordId),
    ok.

-spec sync_players([binary()], [term()]) -> ok.
sync_players([], _Winners) ->
    ok;
sync_players([PlayerId | Rest], Winners) ->
    Won = lists:member(PlayerId, Winners),
    update_player_stats(PlayerId, Won, Rest),
    sync_players(Rest, Winners).

-spec update_player_stats(binary(), boolean(), [binary()]) -> ok.
update_player_stats(PlayerId, Won, Opponents) ->
    case asobi_repo:get(asobi_player_stats, PlayerId) of
        {ok, Stats} ->
            OpponentRatings = load_opponent_ratings(Opponents),
            Score =
                case Won of
                    true -> 1.0;
                    false -> 0.0
                end,
            Outcomes = [#{opponent => OR, score => Score} || OR <- OpponentRatings],
            PlayerRating = #{
                rating => to_float(maps:get(rating, Stats)),
                deviation => to_float(maps:get(rating_deviation, Stats)),
                volatility => maps:get(
                    volatility, maps:get(metadata, Stats, #{}), asobi_glicko2:default_volatility()
                )
            },
            NewRating = asobi_glicko2:rate(PlayerRating, Outcomes),
            WinInc =
                case Won of
                    true -> 1;
                    false -> 0
                end,
            LossInc =
                case Won of
                    true -> 0;
                    false -> 1
                end,
            CS = kura_changeset:cast(
                asobi_player_stats,
                Stats,
                #{
                    games_played => maps:get(games_played, Stats) + 1,
                    wins => maps:get(wins, Stats) + WinInc,
                    losses => maps:get(losses, Stats) + LossInc,
                    rating => maps:get(rating, NewRating),
                    rating_deviation => maps:get(deviation, NewRating),
                    metadata => (maps:get(metadata, Stats, #{}))#{
                        volatility => maps:get(volatility, NewRating)
                    },
                    updated_at => erlang:system_time(second)
                },
                [games_played, wins, losses, rating, rating_deviation, metadata, updated_at]
            ),
            case asobi_repo:update(CS) of
                {ok, _} ->
                    ok;
                {error, Err} ->
                    logger:warning(#{
                        msg => ~"stats_update_failed", player_id => PlayerId, error => Err
                    }),
                    ok
            end;
        {error, not_found} ->
            ok;
        {error, Err} ->
            logger:warning(#{msg => ~"stats_lookup_failed", player_id => PlayerId, error => Err}),
            ok
    end.

-spec load_opponent_ratings([binary()]) -> [asobi_glicko2:rating()].
load_opponent_ratings(PlayerIds) ->
    lists:filtermap(
        fun(Id) ->
            case asobi_repo:get(asobi_player_stats, Id) of
                {ok, S} ->
                    {true, #{
                        rating => to_float(maps:get(rating, S)),
                        deviation => to_float(maps:get(rating_deviation, S)),
                        volatility => maps:get(
                            volatility,
                            maps:get(metadata, S, #{}),
                            asobi_glicko2:default_volatility()
                        )
                    }};
                _ ->
                    {true, #{
                        rating => asobi_glicko2:default_rating(),
                        deviation => asobi_glicko2:default_deviation(),
                        volatility => asobi_glicko2:default_volatility()
                    }}
            end
        end,
        PlayerIds
    ).

-spec mark_synced(term()) -> ok.
mark_synced(RecordId) ->
    case asobi_repo:get(asobi_match_record, RecordId) of
        {ok, Record} ->
            CS = kura_changeset:cast(
                asobi_match_record,
                Record,
                #{status => ~"synced"},
                [status]
            ),
            _ = asobi_repo:update(CS),
            ok;
        _ ->
            ok
    end.

-spec ensure_list(term()) -> [term()].
ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

-spec ensure_binary_list([term()]) -> [binary()].
ensure_binary_list(L) ->
    [X || X <- L, is_binary(X)].

-spec to_float(term()) -> float().
to_float(V) when is_integer(V) -> V * 1.0;
to_float(V) when is_float(V) -> V;
to_float(_) -> 0.0.
