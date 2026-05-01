-module(asobi_app).
-include_lib("kernel/include/logger.hrl").
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    setup_telemetry(),
    case kura_migrator:migrate(asobi_repo) of
        {ok, Applied} ->
            ?LOG_NOTICE(#{msg => ~"migrations_applied", versions => Applied});
        {error, MigErr} ->
            ?LOG_ERROR(#{msg => ~"migration_failed", error => MigErr})
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
