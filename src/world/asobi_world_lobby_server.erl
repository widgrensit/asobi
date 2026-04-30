-module(asobi_world_lobby_server).
-moduledoc """
Single point of serialization for `asobi_world_lobby:find_or_create/1`.

The naive `find_or_create` implementation has a TOCTOU race: two
clients calling at the same time both see `list_worlds(...) = []`
because neither has finished `create_world/1` yet, and both end up
spawning a new world for the same mode. Customer-visible symptom:
two players opening barrow at the same instant land in different
hub worlds and never see each other.

This gen_server forces all `find_or_create` calls through a single
process. The handler runs the existing `list_worlds` + `create_world`
sequence atomically with respect to other callers, so the second
caller sees the world the first one just spawned.

Calls are sequential, but `create_world/1` is the slowest step and
takes <100ms in practice; for the small number of distinct modes a
typical deployment supports, the queue stays empty.
""".
-behaviour(gen_server).

-export([start_link/0, find_or_create/1, find_or_create/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(CALL_TIMEOUT, 30000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Atomic version of `asobi_world_lobby:find_or_create/1`. Public
callers should always go through this — calling the inner function
directly is racy.
""".
-spec find_or_create(binary()) -> {ok, pid(), map()} | {error, term()}.
find_or_create(Mode) ->
    find_or_create(Mode, undefined).

-spec find_or_create(binary(), binary() | undefined) ->
    {ok, pid(), map()} | {error, term()}.
find_or_create(Mode, PlayerId) ->
    case gen_server:call(?MODULE, {find_or_create, Mode, PlayerId}, ?CALL_TIMEOUT) of
        {ok, Pid, Meta} when is_pid(Pid), is_map(Meta) -> {ok, Pid, Meta};
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_reply, Other}}
    end.

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

-spec init([]) -> {ok, #{}}.
init([]) ->
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) ->
    {reply, term(), map()}.
handle_call({find_or_create, Mode, PlayerId}, _From, State) when
    is_binary(Mode), (is_binary(PlayerId) orelse PlayerId =:= undefined)
->
    Result = asobi_world_lobby:find_or_create_unsafe(Mode, PlayerId),
    {reply, Result, State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.
