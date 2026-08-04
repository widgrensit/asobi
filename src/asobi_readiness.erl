-module(asobi_readiness).
-moduledoc """
Whether the node is ready to serve extension traffic.

There is a window in which an extension endpoint exists but its tables do not.
The dispatch tree is compiled during Nova's boot, inside `nova_sup:init/1`;
`kura_migrator:migrate/1` runs later, from `asobi_app:start/2`. Anything
listening in between would reach a handler whose tables have not been created.

So core signals readiness once, after migrations, and the seam below fails
closed until then.

## The seam

`guard/0` is what the RPC dispatcher calls before dispatching:

```erlang
case asobi_readiness:guard() of
    ok -> dispatch(Method, Params);
    {error, Object} -> {asobi_error, 503, Object}
end.
```

The dispatcher itself is Wave 2b and does not exist yet. `guard/0` and the
`not_ready` code do, and they are tested, so the dispatcher inherits a
readiness contract rather than inventing one.

`persistent_term` rather than a process: the read is on the dispatch path,
it happens once per call, and the value is written exactly once at boot.
""".

-export([guard/0, ready/0, mark_ready/0]).
-ifdef(TEST).
-export([reset/0]).
-endif.

-define(KEY, {?MODULE, ready}).
-define(CODE, ~"not_ready").

-doc """
`ok` when the node may serve extension traffic, otherwise the error object to
return with HTTP 503.
""".
-spec guard() -> ok | {error, asobi_error:object()}.
guard() ->
    case ready() of
        true -> ok;
        false -> {error, asobi_error:object(?CODE)}
    end.

-doc "Whether migrations have run to completion on this node.".
-spec ready() -> boolean().
ready() ->
    persistent_term:get(?KEY, false) =:= true.

-doc """
Called once from `asobi_app:start/2`, after `kura_migrator:migrate/1` returns
`{ok, _}`. A failed migration deliberately leaves the node not ready.
""".
-spec mark_ready() -> ok.
mark_ready() ->
    persistent_term:put(?KEY, true).

-ifdef(TEST).
-spec reset() -> ok.
reset() ->
    _ = persistent_term:erase(?KEY),
    ok.
-endif.
