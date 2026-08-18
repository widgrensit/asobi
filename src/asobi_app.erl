-module(asobi_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    %% Before the router compiles: whether the console routes exist at all is
    %% read from the `console` key, so the environment has to have been folded
    %% in by now.
    asobi_console_env:apply(),
    %% Guest retention is read the same way and for the same reason, but it is
    %% not console configuration, so it gets its own module rather than a
    %% second meaning for that one. Order does not matter: the reaper reads the
    %% key at sweep time, not at start.
    asobi_guest_env:apply(),
    %% Before asobi_sup reads `role`, because the role decides which supervision
    %% tree starts at all. Without this the whole datagram plane is unreachable
    %% from the published image, which is configured by environment variables
    %% rather than by a sys.config nobody using that image can edit.
    asobi_dgram_env:apply(),
    setup_telemetry(),
    asobi_error:register_handler(),
    case asobi_dgram_gw_sup:enabled() of
        true -> start_gateway();
        false -> start_engine()
    end,
    case asobi_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, supervisor_ignored};
        {error, _} = Err -> Err
    end.

%% The gateway role exists to shrink the internet-facing surface, and an HTTP API
%% is surface. Nothing behind it starts in this role - no auth limiter, no session
%% store, no database - so every request it answered was a 500 out of a
%% half-booted plugin chain, and in a shared network namespace (the only topology
%% where the loopback link actually connects) it also raced the engine for the
%% port and sometimes won (asobi#511).
%%
%% Stopped rather than never started: nova is an application dependency and binds
%% its listener before asobi's start callback runs, so this is the first moment
%% the role is known. The window is one boot, not the life of the container.
start_gateway() ->
    _ =
        case cowboy:stop_listener(nova_listener) of
            ok ->
                logger:notice(#{msg => ~"http_listener_stopped", reason => ~"role=dgram_gw"});
            {error, Reason} ->
                logger:warning(#{msg => ~"http_listener_stop_failed", error => Reason})
        end,
    ok.

%% Everything the gateway role must not do: it has no database, no Lua runtime and
%% no extensions, and running any of it there is either a crash or a connection to
%% a database the role is specifically built not to hold credentials for.
start_engine() ->
    register_lua_game_modes(),
    report_extensions(),
    case kura_migrator:migrate(asobi_repo) of
        {ok, Applied} ->
            logger:notice(#{msg => ~"migrations_applied", versions => Applied}),
            asobi_readiness:mark_ready();
        {error, MigErr} ->
            logger:error(#{msg => ~"migration_failed", error => MigErr})
    end,
    asobi_registration:log_mode(),
    ok.

setup_telemetry() ->
    asobi_telemetry:setup(),
    ok.

%% asobi_game_modes resolves `{lua, Script}` modes through a provider registry
%% (#333) rather than hardcoded atoms, and returns `lua_runtime_unavailable`
%% when a kind has no provider. The writer used to be asobi_lua's own
%% application-start callback; the merge (#339) removed that application without
%% moving the registration, so every Lua mode resolved to
%% `lua_runtime_unavailable`. Registering here rather than from asobi_lua_sup
%% keeps it ahead of every asobi_sup child, including the matchmaker.
register_lua_game_modes() ->
    asobi_lua_sup:register_game_modes().

%% A host can add an extension to the release and forget the dependency, or
%% the reverse. Reporting the resolved set makes the mismatch visible instead
%% of silent. `resolve/0` is memoised and the router has usually called it
%% already, from inside Nova's boot; this call is here so the set is also
%% known before migrations run.
report_extensions() ->
    Extensions = [
        #{name => Name, app => App, extension_version => Version}
     || #{name := Name, app := App, extension_version := Version} <- asobi_extensions:resolve()
    ],
    logger:notice(#{msg => ~"extensions_resolved", extensions => Extensions}).

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
