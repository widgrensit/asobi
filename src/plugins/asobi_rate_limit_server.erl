-module(asobi_rate_limit_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(ETS_TABLE, asobi_rate_limits).
-define(CLEANUP_INTERVAL, 60000).
-define(DEFAULT_WINDOW, 60000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, #{}}.
init([]) ->
    ?ETS_TABLE = ets:new(?ETS_TABLE, [named_table, public, set, {write_concurrency, true}]),
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(cleanup, State) ->
    Now = erlang:system_time(millisecond),
    cleanup_expired(ets:first(?ETS_TABLE), Now),
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

-spec cleanup_expired(term(), integer()) -> ok.
cleanup_expired('$end_of_table', _Now) ->
    ok;
cleanup_expired(Key, Now) ->
    Next = ets:next(?ETS_TABLE, Key),
    case ets:lookup(?ETS_TABLE, Key) of
        [{Key, _Count, WindowStart}] when (Now - WindowStart) >= ?DEFAULT_WINDOW ->
            ets:delete(?ETS_TABLE, Key);
        _ ->
            ok
    end,
    cleanup_expired(Next, Now).
