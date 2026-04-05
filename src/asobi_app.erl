-module(asobi_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    setup_telemetry(),
    case kura_migrator:migrate(asobi_repo) of
        {ok, Applied} ->
            logger:notice(#{msg => ~"migrations_applied", versions => Applied});
        {error, MigErr} ->
            logger:error(#{msg => ~"migration_failed", error => MigErr})
    end,
    case asobi_config:maybe_load_game_config() of
        ok ->
            ok;
        {error, ConfigErr} ->
            logger:error(#{msg => ~"game_config_failed", error => ConfigErr}),
            error({game_config_failed, ConfigErr})
    end,
    case asobi_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        ignore -> {error, supervisor_ignored};
        {error, _} = Err -> Err
    end.

setup_telemetry() ->
    asobi_telemetry:setup(),
    ok.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
