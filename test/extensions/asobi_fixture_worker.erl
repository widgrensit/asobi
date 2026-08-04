-module(asobi_fixture_worker).
-moduledoc "A supervised child an extension fixture can declare, and a test can crash on demand.".
-behaviour(gen_server).

-export([start_link/1, crash/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-spec start_link(atom()) -> {ok, pid()} | {error, term()}.
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

-spec crash(atom()) -> ok.
crash(Name) ->
    gen_server:cast(Name, crash).

-spec init([]) -> {ok, #{}}.
init([]) ->
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), #{}) -> {reply, ok, #{}}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), #{}) -> {noreply, #{}} | {stop, term(), #{}}.
handle_cast(crash, State) ->
    {stop, fixture_crash, State};
handle_cast(_Request, State) ->
    {noreply, State}.
