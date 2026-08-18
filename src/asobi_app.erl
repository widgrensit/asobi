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
    case asobi_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, supervisor_ignored};
        {error, _} = Err -> Err
    end.

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
