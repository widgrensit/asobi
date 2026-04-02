-module(asobi_session_cache).
-behaviour(gen_server).

-export([start_link/0, get/1, put/2, invalidate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, asobi_session_cache).
-define(DEFAULT_TTL, 300_000).
-define(CLEANUP_INTERVAL, 60_000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(binary()) -> {ok, map()} | miss.
get(Token) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, Token) of
        [{Token, Player, ExpiresAt}] when Now < ExpiresAt -> {ok, Player};
        [{Token, _, _}] ->
            ets:delete(?TABLE, Token),
            miss;
        [] ->
            miss
    end.

-spec put(binary(), map()) -> ok.
put(Token, Player) ->
    TTL =
        case application:get_env(asobi, session_cache_ttl, ?DEFAULT_TTL) of
            T when is_integer(T) -> T;
            _ -> ?DEFAULT_TTL
        end,
    ExpiresAt = erlang:monotonic_time(millisecond) + TTL,
    ets:insert(?TABLE, {Token, Player, ExpiresAt}),
    ok.

-spec invalidate(binary()) -> ok.
invalidate(Token) ->
    ets:delete(?TABLE, Token),
    ok.

-spec init([]) -> {ok, #{}}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
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
    Now = erlang:monotonic_time(millisecond),
    cleanup_expired(ets:first(?TABLE), Now),
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

cleanup_expired('$end_of_table', _Now) ->
    ok;
cleanup_expired(Key, Now) ->
    Next = ets:next(?TABLE, Key),
    case ets:lookup(?TABLE, Key) of
        [{Key, _, ExpiresAt}] when Now >= ExpiresAt -> ets:delete(?TABLE, Key);
        _ -> ok
    end,
    cleanup_expired(Next, Now).
