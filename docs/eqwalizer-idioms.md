# eqwalizer idioms

Written once so it is not written again at every call site. Five facts about
eqwalizer account for most of the type errors in this tree, and each has one
right answer. Cite this file rather than restating it: a comment at a fix site
should say why *that code* is the way it is, not re-teach the checker.

Context: widgrensit/asobi#435.

## `erlang:min/2` and `max/2` return `term()`

Their specs are `term() -> term()` whatever they are handed, so `max(N, 1)`
fails even when `N :: integer()`. Narrowing the *input* does not help.

Write a small local function that names the rule instead. Not a shared numeric
module: only two of these remain in the whole tree, and `clamp/3` reads better
than the `min(max(...))` it replaced anyway.

```erlang
-spec clamp(number(), number(), number()) -> number().
clamp(V, Lo, _Hi) when V < Lo -> Lo;
clamp(V, _Lo, Hi) when V > Hi -> Hi;
clamp(V, _Lo, _Hi) -> V.
```

## `lists:*` erases element and accumulator types

`foldl`, `foreach`, `usort`, `sort` and `join` all widen their result to
`[term()]`, and the folds erase the accumulator as well. This is the single
largest class of error in the tree.

Two answers, and which one depends on whether the call is doing real work:

**Re-narrow the result.** Preferred when the `lists:` function is worth keeping
- `usort/1` is O(n log n) in C, and hand-rolling it is neither faster nor
clearer. The comprehension restores the type and drops nothing, because the
input already has it:

```erlang
-spec usort_binaries([binary()]) -> [binary()].
usort_binaries(Names) -> [N || N <- lists:usort(Names), is_binary(N)].
```

**Replace the fold with explicit recursion.** Preferred for `foldl`/`foreach`,
where the accumulator is asobi's own and the recursion is usually clearer than
the threading it replaces. This also satisfies the repo's existing no-`foldl`
rule, which turns out to be load-bearing here rather than stylistic:

```erlang
-spec install_fns([{[binary(), ...], function()}], dynamic()) -> dynamic().
install_fns([], St) -> St;
install_fns([{Path, Fn} | Rest], St) ->
    {Enc, St1} = luerl:encode(Fn, St),
    {ok, St2} = luerl:set_table_keys(Path, Enc, St1),
    install_fns(Rest, St2).
```

Do **not** split a `usort/1` into a sort plus a hand-written dedupe. That was
tried: it cost four functions across two modules and two O(n^2) loops on a
per-connection path.

**Watch the filter order.** A narrowing guard placed before an existing
validator silently eats the case the validator was there to log:

```erlang
%% Wrong: is_binary/1 runs first, so valid_global_name/1 never logs.
[N || N <- Names, is_binary(N), valid_global_name(N)]
%% Right.
[N || N <- Names, valid_global_name(N), is_binary(N)]
```

## `maybe ... end` needs an explicit `else`

Without one, eqwalizer cannot type the short circuit and reports the *first*
`?=` as returning the wrong type. Adding the clause the block already implies
fixes it, and is behaviour-identical when every `?=` answers
`{ok, _} | {error, _}` - which is the only shape that can reach it:

```erlang
maybe
    {ok, Raw} ?= read_manifest(Dir),
    ...
else
    {error, _} = Error -> Error
end.
```

Verified with a probe: the same block without `else` fails, with `else` is
clean.

## The `?LOG_*` macros return `term()`

They expand to `erlang:apply(logger, macro_log, ...)`, so a function spec'd
`-> ok` fails on its last expression. End with `ok`:

```erlang
log_it(V) ->
    ?LOG_ERROR(#{msg => ~"...", value => describe(V)}),
    ok.
```

## `lists:keyfind/3` cannot narrow, a comprehension can

`keyfind/3` wants `[tuple()]`, and the term lists it is usually pointed at -
`file:consult/1` output, a decoded Lua table, a literal config table - are
`[term()]`. A tuple pattern in a generator narrows both the list and the value
in one step:

```erlang
%% was: {profiles, Profiles} = lists:keyfind(profiles, 1, Terms)
[Profiles] = [V || {K, V} <- Terms, K =:= profiles, is_list(V)],
```

## `dynamic()` is for boundaries, and only for boundaries

Permitted where a value genuinely has no static type on our side: Luerl returns
and Luerl state, `persistent_term:get/1`, ETS reads, raw `cowboy_req`.
Everywhere else the answer is a real type or a narrowing clause.

`dynamic()` is not `eqwalizer:fixme`, so it does not break the no-suppression
rule - but reaching for it on a value that has a knowable type is the same
suppression wearing a different hat.

Two rules that keep it honest:

- **`dynamic()` may enter a bridge function; it must not leave one.**
  `decode_args([dynamic()], dynamic()) -> [term()]` is the right direction.
- **Widening a parameter from `term()` to `dynamic()` loses checking.** It is
  occasionally correct - `cache_and_return/3` takes a module Luerl produced -
  but it is also exactly the shape a suppression takes. Justify it in a comment
  at that site.

Luerl's `luerlstate()` and `luerldata()` are defined in its header but exported
by no module, so there is no `luerl:luerlstate()` to write and `dynamic()` is
the only honest answer. Exporting those types upstream would remove a whole
category of these.

## A narrowing clause is a behaviour change

Adding a guard turns a value that previously flowed through into a
`function_clause`. Before adding one, ask what reaches it:

- **Asobi's own state or ETS content** - guard freely, the shape is ours.
- **A cast, a call, or config from outside** - guard, but give the clause a
  fallback, and check whether the enclosing `gen_server`/`gen_statem` has a
  catch-all. Turning a malformed message into a dead supervisor tree is not
  defence in depth.
- **Anything a game script or operator supplies** - validate and fall back to a
  default, and *log the rejection*. A silent fallback is the failure mode this
  whole exercise exists to remove.

Every narrowing that changes what a malformed input does gets a test that feeds
it a malformed input.
