-module(asobi_extension_watch).
-moduledoc """
Says which extension went dark.

An extension that exhausts its own restart budget is not restarted (see
`m:asobi_extension_sup`), so the node keeps serving with one feature missing.
Without this the only trace is an OTP supervisor report, and "a feature
stopped working and nothing said so" is the failure mode the whole tree
exists to make legible.

It monitors rather than links: a monitor cannot influence what it watches.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2]).

-type state() :: #{names := [asobi_extension:name()], monitors := #{reference() => atom()}}.

-spec start_link([asobi_extension:name()]) -> {ok, pid()} | {error, term()}.
start_link(Names) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Names, []).

%% Monitoring happens in handle_continue, not init: `which_children` is a call
%% into the parent supervisor, and the parent is still inside its own init
%% while it starts this child.
-spec init([asobi_extension:name()]) -> {ok, state(), {continue, monitor}}.
init(Names) ->
    {ok, #{names => Names, monitors => #{}}, {continue, monitor}}.

-spec handle_continue(monitor, state()) -> {noreply, state()}.
handle_continue(monitor, #{names := Names} = State) ->
    Monitors = maps:from_list([
        {erlang:monitor(process, Pid), Id}
     || {Id, Pid, _Type, _Modules} <- supervisor:which_children(asobi_extension_sup),
        is_pid(Pid),
        lists:member(Id, Names)
    ]),
    {noreply, State#{monitors => Monitors}}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Ref, process, _Pid, Reason}, #{monitors := Monitors} = State) ->
    case maps:take(Ref, Monitors) of
        {Name, Rest} ->
            ?LOG_ERROR(#{
                msg => ~"extension_down",
                extension => Name,
                reason => Reason,
                detail => ~"this extension is no longer running; the node is otherwise unaffected"
            }),
            {noreply, State#{monitors => Rest}};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, ok, state()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.
