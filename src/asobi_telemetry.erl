-module(asobi_telemetry).

-export([execute/3]).

-spec execute([atom()], map(), map()) -> ok.
execute(EventName, Measurements, Metadata) ->
    telemetry:execute([asobi | EventName], Measurements, Metadata).
