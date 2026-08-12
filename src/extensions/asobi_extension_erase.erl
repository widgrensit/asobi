-module(asobi_extension_erase).
-moduledoc """
Runs every installed extension's erase path for one player.

Core's caller holds the transaction; this walks the installed set inside it,
calls `erase_player/1` on each extension that exports one, and stops at the
first failure. See `c:asobi_extension:erase_player/1` for why erasure is atomic
across extensions rather than best-effort, and why the alternative to this
callback is a cascade in the migration rather than a key in `owns/0`.

A caller must **assert the result**, because a bare `{error, _}` returned from
inside `asobi_repo:transaction/1` still commits:

```erlang
asobi_repo:transaction(fun() ->
    ok = asobi_extension_erase:run(PlayerId),
    {ok, _} = asobi_repo:delete_all(...),
    ...
end).
```

The badmatch is what rolls the transaction back; the line naming the extension
is logged here, before the reason is flattened into a badmatch term.

An extension that raises is caught rather than allowed to propagate, so the
failure is attributed to a name before it becomes the caller's problem. Nothing
runs after a catch: the Postgres transaction is already aborted at that point,
and the only correct next statement is the caller's rollback.

Failure reasons carry the shape of what came back - a tag and a size, a
truncated formatted reason, the top stack frame without arguments - never the
term itself. What an extension returns on this path can be the data subject's
personal data, and the reason flows into the log line below and into the
caller's badmatch; neither may hold it. `m:asobi_extension_export` applies the
same rule.
""".

-include_lib("kernel/include/logger.hrl").

-define(MAX_REASON_BYTES, 200).

-export([run/1]).

-doc """
`ok`, or the first extension to fail and why. Nothing is retried and nothing
after it is attempted.
""".
-spec run(binary()) -> ok | {error, {asobi_extension:name(), term()}}.
run(PlayerId) ->
    erase_each(asobi_extensions:resolve(), PlayerId).

erase_each([], _PlayerId) ->
    ok;
erase_each([#{name := Name, module := Module} | Rest], PlayerId) ->
    case erase_one(Module, PlayerId) of
        ok ->
            erase_each(Rest, PlayerId);
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"extension_erase_failed",
                extension => Name,
                player_id => PlayerId,
                reason => Reason,
                detail => ~"this player was not deleted; nothing was erased"
            }),
            {error, {Name, Reason}}
    end.

erase_one(Module, PlayerId) ->
    case erlang:function_exported(Module, erase_player, 1) of
        false ->
            ok;
        true ->
            try Module:erase_player(PlayerId) of
                ok -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {bad_return, kind(Other)}}
            catch
                Class:Reason:Stacktrace ->
                    {error, {raised, Class, reason(Reason), top_frame(Stacktrace)}}
            end
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
