-module(asobi_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    setup_telemetry(),
    asobi_error:register_handler(),
    register_lua_game_modes(),
    case kura_migrator:migrate(asobi_repo) of
        {ok, Applied} ->
            logger:notice(#{msg => ~"migrations_applied", versions => Applied});
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

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
