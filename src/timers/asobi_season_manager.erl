-module(asobi_season_manager).
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).

%% Periodically checks season boundaries and manages transitions.

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CHECK_INTERVAL, 60_000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, map()}.
init([]) ->
    erlang:send_after(?CHECK_INTERVAL, self(), check_seasons),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(check_seasons, State) ->
    check_and_transition(),
    erlang:send_after(?CHECK_INTERVAL, self(), check_seasons),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) ->
    ok.

%% --- Internal ---

-spec check_and_transition() -> ok.
check_and_transition() ->
    Now = erlang:system_time(millisecond),
    activate_upcoming(Now),
    end_expired(Now).

-spec activate_upcoming(pos_integer()) -> ok.
activate_upcoming(Now) ->
    Q = kura_query:where(kura_query:from(asobi_season), {status, ~"upcoming"}),
    case asobi_repo:all(Q) of
        {ok, Seasons} ->
            lists:foreach(
                fun(#{id := Id, starts_at := StartsAt} = Season) ->
                    case Now >= StartsAt of
                        true ->
                            CS = kura_changeset:cast(
                                asobi_season, Season, #{status => ~"active"}, [status]
                            ),
                            _ = asobi_repo:update(CS),
                            ?LOG_NOTICE(#{
                                msg => ~"season_activated",
                                season_id => Id,
                                name => maps:get(name, Season)
                            });
                        false ->
                            ok
                    end
                end,
                Seasons
            );
        _ ->
            ok
    end.

-spec end_expired(pos_integer()) -> ok.
end_expired(Now) ->
    Q = kura_query:where(kura_query:from(asobi_season), {status, ~"active"}),
    case asobi_repo:all(Q) of
        {ok, Seasons} ->
            lists:foreach(
                fun(#{id := Id, ends_at := EndsAt} = Season) ->
                    case Now >= EndsAt of
                        true ->
                            CS = kura_changeset:cast(
                                asobi_season, Season, #{status => ~"ended"}, [status]
                            ),
                            _ = asobi_repo:update(CS),
                            ?LOG_NOTICE(#{
                                msg => ~"season_ended",
                                season_id => Id,
                                name => maps:get(name, Season)
                            });
                        false ->
                            ok
                    end
                end,
                Seasons
            );
        _ ->
            ok
    end.
