-module(asobi_bot_spawner_tests_stub).
-moduledoc "A minimal gen_server standing in for asobi_bot in removal tests.".
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

init([]) -> {ok, #{}}.

handle_call(_Msg, _From, State) -> {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
