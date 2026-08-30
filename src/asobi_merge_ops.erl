-module(asobi_merge_ops).

-moduledoc """
The operator vocabulary shared by `game.kv.merge` and `game.storage.update`.

A merge is a map of field names to a single-key operator table:

```lua
{
  hull   = { min = 40 },       -- lowest wins
  dead   = { latch = true },   -- once true, stays true
  shed   = { max = 4 },        -- highest wins
  kills  = { incr = 1 },       -- add
  name   = { set = "Kestrel" } -- last writer wins
}
```

Operators rather than a read-modify-write is the whole point. Every operator
here except `set` is commutative and idempotent-under-reordering, so two zones
that both hold the same entity - which the engine allows on purpose, until it
is `rehome_margin` past the boundary - can each apply what they saw with no
lock, no version and no lost write. Two schedulers, no ordering, same answer.

`set` is the exception and is honest about it: it is last-writer-wins, so it
belongs on a field only one writer owns.

An unknown operator, a field whose value is not a single-key operator table,
or an operator applied to the wrong type is an error naming the field. Silently
treating a malformed entry as `set` is the failure mode this exists to avoid:
it would look exactly like a working merge and lose writes.
""".

-export([apply_ops/2, operators/0]).

-export_type([ops/0, operator/0]).

-type operator() :: set | set_if_absent | incr | min | max | latch.
-type ops() :: #{binary() => map()}.

-doc "Every operator name, as it is written in Lua.".
-spec operators() -> [binary(), ...].
operators() ->
    [~"set", ~"set_if_absent", ~"incr", ~"min", ~"max", ~"latch"].

-doc """
Apply `Ops` to `Value`, returning the merged map or the first field that did
not make sense.
""".
-spec apply_ops(map(), map()) -> {ok, map()} | {error, binary()}.
apply_ops(Value, Ops) when is_map(Value), is_map(Ops) ->
    apply_each(maps:to_list(Ops), Value);
apply_ops(_Value, _Ops) ->
    {error, ~"merge requires a table of field operators"}.

%% Explicit recursion: see docs/eqwalizer-idioms.md.
-spec apply_each([{term(), term()}], map()) -> {ok, map()} | {error, binary()}.
apply_each([], Value) ->
    {ok, Value};
apply_each([{Field, Op} | Rest], Value) when is_binary(Field) ->
    case apply_one(Field, Op, Value) of
        {ok, Value1} -> apply_each(Rest, Value1);
        {error, _} = Err -> Err
    end;
apply_each([{Field, _Op} | _Rest], _Value) ->
    {error, <<"merge field is not a name: ", (format_term(Field))/binary>>}.

-spec apply_one(binary(), term(), map()) -> {ok, map()} | {error, binary()}.
apply_one(Field, Op, Value) when is_map(Op), map_size(Op) =:= 1 ->
    [{OpName, Arg}] = maps:to_list(Op),
    case lists:member(OpName, operators()) of
        true -> operate(OpName, Field, Arg, Value);
        false -> {error, <<"unknown merge operator on ", Field/binary>>}
    end;
apply_one(Field, _Op, _Value) ->
    {error,
        <<"merge field ", Field/binary,
            " must be a table naming exactly one operator, e.g. { min = 40 }">>}.

-spec operate(term(), binary(), term(), map()) -> {ok, map()} | {error, binary()}.
operate(~"set", Field, Arg, Value) ->
    {ok, Value#{Field => Arg}};
operate(~"set_if_absent", Field, Arg, Value) ->
    case maps:is_key(Field, Value) of
        true -> {ok, Value};
        false -> {ok, Value#{Field => Arg}}
    end;
operate(~"incr", Field, Arg, Value) when is_number(Arg) ->
    case maps:get(Field, Value, 0) of
        Current when is_number(Current) -> {ok, Value#{Field => Current + Arg}};
        _ -> {error, <<"incr on a non-numeric field: ", Field/binary>>}
    end;
operate(~"min", Field, Arg, Value) when is_number(Arg) ->
    case maps:get(Field, Value, Arg) of
        Current when is_number(Current) -> {ok, Value#{Field => min(Current, Arg)}};
        _ -> {error, <<"min on a non-numeric field: ", Field/binary>>}
    end;
operate(~"max", Field, Arg, Value) when is_number(Arg) ->
    case maps:get(Field, Value, Arg) of
        Current when is_number(Current) -> {ok, Value#{Field => max(Current, Arg)}};
        _ -> {error, <<"max on a non-numeric field: ", Field/binary>>}
    end;
operate(~"latch", Field, Arg, Value) when is_boolean(Arg) ->
    Current = maps:get(Field, Value, false),
    {ok, Value#{Field => Current =:= true orelse Arg}};
operate(OpName, Field, _Arg, _Value) when is_binary(OpName) ->
    {error, <<OpName/binary, " on ", Field/binary, " got the wrong kind of value">>}.

-spec format_term(term()) -> binary().
format_term(T) ->
    iolist_to_binary(io_lib:format("~0p", [T])).
