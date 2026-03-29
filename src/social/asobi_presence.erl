-module(asobi_presence).
-behaviour(gen_server).

-export([start_link/0]).
-export([track/2, untrack/1, update/2, get_status/1, send/2, online_count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PG_SCOPE, asobi_presence).
-define(PRESENCE_GROUP, asobi_online).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec track(binary(), pid()) -> ok.
track(PlayerId, Pid) ->
    pg:join(?PG_SCOPE, ?PRESENCE_GROUP, Pid),
    pg:join(?PG_SCOPE, {player, PlayerId}, Pid),
    nova_pubsub:broadcast(presence, ~"player_online", #{player_id => PlayerId}),
    ok.

-spec untrack(binary()) -> ok.
untrack(PlayerId) ->
    nova_pubsub:broadcast(presence, ~"player_offline", #{player_id => PlayerId}),
    ok.

-spec update(binary(), map()) -> ok.
update(PlayerId, Status) ->
    nova_pubsub:broadcast(presence, ~"player_status", #{player_id => PlayerId, status => Status}),
    ok.

-spec get_status(binary()) -> online | offline.
get_status(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [] -> offline;
        _ -> online
    end.

-spec send(binary(), term()) -> ok.
send(PlayerId, Message) ->
    Members = pg:get_members(?PG_SCOPE, {player, PlayerId}),
    lists:foreach(fun(Pid) -> Pid ! {asobi_message, Message} end, Members),
    ok.

-spec online_count() -> non_neg_integer().
online_count() ->
    length(pg:get_members(?PG_SCOPE, ?PRESENCE_GROUP)).

-spec init([]) -> {ok, #{}}.
init([]) ->
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.
