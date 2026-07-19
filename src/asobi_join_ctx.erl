-module(asobi_join_ctx).
-moduledoc """
Bounds on the client-supplied join context.

The context is opaque to asobi - only the game module interprets it - but
it is still attacker-controlled input handed to game code, so its shape is
constrained here: a flat map, binary keys, scalar values, no nesting.

asobi never interprets, echoes, or logs the context. See
`c:asobi_match:join/3`.
""".

-export([parse/1]).

-define(MAX_KEYS, 8).
-define(MAX_KEY_BYTES, 64).
-define(MAX_VALUE_BYTES, 256).

-doc """
Extract and validate `ctx` from a request payload.

Absent context is `{ok, #{}}` rather than an error: most joins carry none,
and a game that requires one rejects the empty map itself.

Takes `term()`, not `map()`: the caller passes a decoded JSON payload, and
a client is free to send `"payload": "a string"`, so a non-map reaching
here is untrusted input rather than a caller bug.
""".
-spec parse(term()) -> {ok, map()} | {error, binary()}.
parse(Payload) when is_map(Payload) ->
    case maps:get(~"ctx", Payload, undefined) of
        undefined ->
            {ok, #{}};
        Ctx when is_map(Ctx), map_size(Ctx) =< ?MAX_KEYS ->
            validate(maps:to_list(Ctx), #{});
        Ctx when is_map(Ctx) ->
            {error, ~"join_ctx_too_many_keys"};
        _ ->
            {error, ~"invalid_join_ctx"}
    end;
parse(_) ->
    {ok, #{}}.

-spec validate([{term(), term()}], map()) -> {ok, map()} | {error, binary()}.
validate([], Acc) ->
    {ok, Acc};
validate([{K, V} | Rest], Acc) when is_binary(K), byte_size(K) =< ?MAX_KEY_BYTES ->
    case validate_value(V) of
        ok -> validate(Rest, Acc#{K => V});
        {error, _} = Err -> Err
    end;
validate([{K, _} | _], _) when is_binary(K) ->
    {error, ~"join_ctx_key_too_long"};
validate(_, _) ->
    {error, ~"invalid_join_ctx_key"}.

-spec validate_value(term()) -> ok | {error, binary()}.
validate_value(V) when is_binary(V), byte_size(V) =< ?MAX_VALUE_BYTES -> ok;
validate_value(V) when is_binary(V) -> {error, ~"join_ctx_value_too_long"};
validate_value(V) when is_boolean(V) -> ok;
validate_value(V) when is_integer(V) -> ok;
validate_value(_) -> {error, ~"invalid_join_ctx_value"}.
