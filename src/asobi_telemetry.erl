-module(asobi_telemetry).

-export([setup/0, execute/3]).

-spec setup() -> ok.
setup() ->
    opentelemetry_kura:setup(asobi_repo),
    opentelemetry_nova:setup(),
    opentelemetry_shigoto:setup(),
    ok.

-spec execute([atom()], map(), map()) -> ok.
execute(EventName, Measurements, Metadata) ->
    telemetry:execute([asobi | EventName], Measurements, Metadata).
