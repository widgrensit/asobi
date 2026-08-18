-module(asobi_dgram_gw_app).
-moduledoc """
The gateway application, and the reason it is one.

ADR 0012 decision 14 splits the datagram gateway from the engine because the
gateway parses packets from anyone on the internet and must not share a process
tree with the Lua sandbox or the tenant database credentials. Until this
application existed that split was a role switch read inside `asobi_app:start/2`,
which is too late to matter: `kura`, `kura_postgres` and `shigoto` are entries in
asobi's `applications` list, so OTP had already opened a pool with the tenant
credentials, run migrations and started job workers before the role was known
(asobi#513). A role cannot un-start an application dependency; only a release
that never listed it can.

So the gateway is its own OTP application with its own dependency list - kernel,
stdlib and telemetry - and its own release. There is no nova in it, no kura, no
shigoto, no luerl. The credentials are not in the container because the code that
would read them is not in the container.

## It also starts nothing in the engine

`asobi` depends on this application for the shared codec, so the engine loads it
too. Starting the gateway's tree there would bind a UDP port on every engine, so
the role is read here as well and the engine gets an empty supervisor. One
application, two roles, and the release decides which one can happen.
""".

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    %% Before the supervisor reads the role, exactly as `asobi_app` does it: the
    %% published image is configured with environment variables, and the role
    %% decides which tree starts at all.
    asobi_dgram_env:apply(),
    case asobi_dgram_gw_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, supervisor_ignored};
        {error, _} = Err -> Err
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
