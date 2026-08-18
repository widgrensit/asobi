-module(asobi_dgram_gw_logger).
-moduledoc """
A JSON log formatter for the gateway release.

The rest of asobi logs through `nova_jsonlogger`, and the gateway cannot: that
module lives inside the `nova` application, and pulling nova in for a formatter
would bring cowboy, ranch, erlydtl and routing_tree with it - the whole point of
the gateway being its own release is that none of them are in its image
(asobi#513).

So this is the same contract in the smallest form that honours it: one JSON
object per line on stdout, carrying the fields the observability guide tells
operators to build queries on - `msg`, `level`, `mfa`, `file`, `line` - with the
report's own keys merged alongside. A log shipper reading both containers sees
one format.

Encoded with OTP's `json`, which is the only JSON this project uses.
""".

-export([format/2]).

-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(#{level := Level, msg := {report, Report}, meta := Meta}, _Config) when is_map(Report) ->
    line(maps:merge(meta_fields(Meta), Report#{level => Level}));
format(#{msg := {report, KeyVal}} = Event, Config) when is_list(KeyVal) ->
    %% A keyword-list report. Comprehended rather than handed straight to
    %% maps:from_list/1 so a malformed entry is dropped instead of raising in the
    %% formatter, which would take the handler down and silence the node.
    Pairs = [{K, V} || {K, V} <- KeyVal],
    format(Event#{msg := {report, maps:from_list(Pairs)}}, Config);
format(#{msg := {string, String}} = Event, Config) ->
    Text = unicode:characters_to_binary(io_lib:format("~ts", [String])),
    format(Event#{msg := {report, #{msg => Text}}}, Config);
format(#{msg := {Format, Args}} = Event, Config) ->
    format(Event#{msg := {string, io_lib:format(Format, Args)}}, Config).

%% --- Internal ---

%% The four the guide names, and nothing else. A logger's metadata carries pids,
%% references and the whole gen_server state on a crash report; shipping all of it
%% turns one bad line into a megabyte.
-spec meta_fields(logger:metadata()) -> map().
meta_fields(Meta) ->
    Fields = #{
        time => timestamp(Meta),
        mfa => mfa(Meta),
        file => maps:get(file, Meta, undefined),
        line => maps:get(line, Meta, undefined)
    },
    maps:filter(fun(_K, V) -> V =/= undefined end, Fields).

timestamp(#{time := Micros}) when is_integer(Micros) ->
    iolist_to_binary(calendar:system_time_to_rfc3339(Micros, [{unit, microsecond}, {offset, "Z"}]));
timestamp(_Meta) ->
    undefined.

mfa(#{mfa := {M, F, A}}) -> iolist_to_binary(io_lib:format("~ts:~ts/~w", [M, F, A]));
mfa(_Meta) -> undefined.

line(Data) ->
    [json:encode(printable(Data)), $\n].

%% A report can hold any term at all - a pid, a socket, a tuple - and `json`
%% raises on anything it has no encoding for. A formatter that can crash takes the
%% logger handler down with it and the node goes quiet, which is a worse outcome
%% than an approximate line.
printable(Map) when is_map(Map) ->
    maps:from_list([{key(K), printable(V)} || K := V <- Map]);
printable(V) when is_binary(V); is_number(V); is_boolean(V); V =:= null ->
    V;
printable(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
printable(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [printable(E) || E <- V]
    end;
printable(V) ->
    iolist_to_binary(io_lib:format("~0p", [V])).

key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K;
key(K) -> iolist_to_binary(io_lib:format("~0p", [K])).
