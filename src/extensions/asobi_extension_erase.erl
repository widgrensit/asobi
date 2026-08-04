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
""".

-include_lib("kernel/include/logger.hrl").

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
                Other -> {error, {bad_return, Other}}
            catch
                Class:Reason:Stacktrace -> {error, {raised, Class, Reason, Stacktrace}}
            end
    end.
