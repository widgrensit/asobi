-module(asobi_qs).
-moduledoc """
Query-string parsing helpers shared across controllers.

The previous per-controller `qs_integer/3` helpers called
`binary_to_integer/1` directly; bad input (`?limit=abc`) raised `badarg`,
Cowboy's default error handler returned 500, and an attacker could
flood the error logs.

`integer/3` returns the default on parse failure. `integer/5` additionally
clamps to `[Min, Max]` so a malicious `?limit=10000000` cannot pull
megabytes of rows. F-15 / F-21.
""".

-export([integer/3, integer/5]).

-spec integer(binary(), proplists:proplist(), integer()) -> integer().
integer(Key, Params, Default) when is_binary(Key), is_integer(Default) ->
    case proplists:get_value(Key, Params) of
        V when is_binary(V) ->
            try binary_to_integer(V) of
                N when is_integer(N) -> N
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

-spec integer(binary(), proplists:proplist(), integer(), integer(), integer()) -> integer().
integer(Key, Params, Default, Min, Max) when
    is_integer(Default), is_integer(Min), is_integer(Max), Min =< Max
->
    N0 = integer(Key, Params, Default),
    clamp(N0, Min, Max).

-spec clamp(integer(), integer(), integer()) -> integer().
clamp(N, Min, _Max) when N < Min -> Min;
clamp(N, _Min, Max) when N > Max -> Max;
clamp(N, _Min, _Max) -> N.
