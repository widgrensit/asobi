-module(asobi_world_registry).
-behaviour(gen_server).

%% Tracks active worlds and provides lookup by world_id.
%% Uses pg groups for cross-node discovery (via asobi_world_server),
%% this module provides additional metadata tracking.

-export([start_link/0]).
-export([register_world/2, unregister_world/1, get_world/1, list_worlds/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_world(binary(), map()) -> ok.
register_world(WorldId, Meta) ->
    gen_server:cast(?MODULE, {register, WorldId, Meta}).

-spec unregister_world(binary()) -> ok.
unregister_world(WorldId) ->
    gen_server:cast(?MODULE, {unregister, WorldId}).

-spec get_world(binary()) -> {ok, map()} | error.
get_world(WorldId) ->
    gen_server:call(?MODULE, {get, WorldId}).

-spec list_worlds() -> [map()].
list_worlds() ->
    gen_server:call(?MODULE, list).

-spec init([]) -> {ok, map()}.
init([]) ->
    {ok, #{worlds => #{}}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({get, WorldId}, _From, #{worlds := Worlds} = State) ->
    case Worlds of
        #{WorldId := Meta} -> {reply, {ok, Meta}, State};
        _ -> {reply, error, State}
    end;
handle_call(list, _From, #{worlds := Worlds} = State) ->
    {reply, maps:values(Worlds), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({register, WorldId, Meta}, #{worlds := Worlds} = State) ->
    {noreply, State#{worlds => Worlds#{WorldId => Meta}}};
handle_cast({unregister, WorldId}, #{worlds := Worlds} = State) ->
    {noreply, State#{worlds => maps:remove(WorldId, Worlds)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.
