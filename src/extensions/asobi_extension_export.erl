-module(asobi_extension_export).
-moduledoc """
Collects every installed extension's export section for one player.

The read half of `m:asobi_extension_erase`, and shaped on it: walk
`asobi_extensions:resolve/0`, call `export_player/1` on each extension that
exports one, and stop at the first failure. The result names **every**
installed extension - one without the callback contributes a `skipped` marker
rather than nothing, so a skipped extension is visible in the artefact a data
subject or auditor reads, not an absence nobody can detect. See
`c:asobi_extension:export_player/1` for why the marker is the forcing function
that let this callback ship at all.

A missing callback is a marker; a failing callback fails the export. An
extension that exports the callback and then returns `{error, _}` or raises
promised data and could not deliver it - exactly the silent incompleteness the
marker exists to prevent - so the caller must produce no artefact. Fail loudly
and retry beats a partial export presented as complete. A section
`json:encode/1` refuses is the same failure: the export is served as one JSON
object, so an unencodable term would otherwise become an unattributed 500
after the payload had already left the controller.

No transaction: core's own export is a sequence of plain reads with no
transaction around them, and wrapping only this walk in one would buy
consistency with nothing. An extension that raises is caught rather than
allowed to propagate, so the failure is attributed to a name before it becomes
the caller's problem.

Failure reasons carry the shape of what came back - a tag and a size, a
truncated formatted reason, the top stack frame without arguments - never the
term itself. What an extension returns on this path is the data subject's
personal data, and a reason term flows into the log line below and into the
caller's error; neither may hold what the export refused to produce.
""".

-include_lib("kernel/include/logger.hrl").

-define(MAX_REASON_BYTES, 200).

-export([run/1]).

-doc """
Every installed extension by name: `#{data => ...}` from one that exported,
`#{skipped => ...}` for one without the callback. Or the first extension to
fail and why; nothing is retried and nothing after it is attempted.
""".
-spec run(binary()) ->
    {ok, #{asobi_extension:name() => map()}}
    | {error, {asobi_extension:name(), term()}}.
run(PlayerId) ->
    export_each(asobi_extensions:resolve(), PlayerId, #{}).

export_each([], _PlayerId, Sections) ->
    {ok, Sections};
export_each([#{name := Name, module := Module} | Rest], PlayerId, Sections) ->
    case export_one(Module, PlayerId) of
        {ok, Section} ->
            export_each(Rest, PlayerId, Sections#{Name => Section});
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"extension_export_failed",
                extension => Name,
                player_id => PlayerId,
                reason => Reason,
                detail => ~"no export was produced"
            }),
            {error, {Name, Reason}}
    end.

export_one(Module, PlayerId) ->
    case erlang:function_exported(Module, export_player, 1) of
        false ->
            {ok, #{skipped => ~"export_player/1 not exported"}};
        true ->
            try Module:export_player(PlayerId) of
                {ok, Data} when is_map(Data) -> encodable(Data);
                {error, Reason} -> {error, Reason};
                Other -> {error, {bad_return, kind(Other)}}
            catch
                Class:Reason:Stacktrace ->
                    {error, {raised, Class, reason(Reason), top_frame(Stacktrace)}}
            end
    end.

encodable(Data) ->
    try
        _ = json:encode(Data),
        {ok, #{data => Data}}
    catch
        error:Reason -> {error, {not_encodable, reason(Reason)}}
    end.

kind(Term) when is_tuple(Term), tuple_size(Term) > 0 -> {element(1, Term), tuple_size(Term)};
kind(Term) when length(Term) >= 0 -> {list, length(Term)};
kind(Term) when is_map(Term) -> {map, map_size(Term)};
kind(_Term) -> other.

reason(Reason) when is_binary(Reason) -> truncate(Reason);
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason(Reason) -> truncate(iolist_to_binary(io_lib:format("~0p", [Reason]))).

truncate(Bin) when byte_size(Bin) =< ?MAX_REASON_BYTES -> Bin;
truncate(Bin) -> <<(binary:part(Bin, 0, ?MAX_REASON_BYTES))/binary, "...">>.

top_frame([{Module, Function, Arity, _Location} | _]) when is_integer(Arity) ->
    {Module, Function, Arity};
top_frame([{Module, Function, Args, _Location} | _]) when is_list(Args) ->
    {Module, Function, length(Args)};
top_frame(_Stacktrace) ->
    undefined.
