-module(asobi_fixture_log_handler).
-moduledoc "Forwards log events to a test process, so a log line can be asserted on.".

-export([log/2]).

-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {log_event, Event},
    ok.
