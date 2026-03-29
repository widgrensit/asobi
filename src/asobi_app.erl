-module(asobi_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    case kura_migrator:migrate(asobi_repo) of
        {ok, Applied} ->
            logger:notice(#{msg => <<"migrations_applied">>, versions => Applied});
        {error, MigErr} ->
            logger:error(#{msg => <<"migration_failed">>, error => MigErr})
    end,
    asobi_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
