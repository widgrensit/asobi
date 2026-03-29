-module(asobi_test_helpers).

-export([start/1, unique_username/1]).

-spec start(list()) -> list().
start(Config) ->
    nova_test:start(asobi) ++ Config.

-spec unique_username(binary()) -> binary().
unique_username(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<Prefix/binary, "_", Suffix/binary>>.
