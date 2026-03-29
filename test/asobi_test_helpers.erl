-module(asobi_test_helpers).

-export([start/1, unique_username/1]).

-spec start(list()) -> list().
start(Config) ->
    Config0 = nova_test:start(asobi) ++ Config,
    %% Ensure pg scopes are started (may not be auto-started in test)
    lists:foreach(fun(Scope) ->
        case pg:start(Scope) of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end
    end, [asobi_presence, asobi_chat]),
    Config0.

-spec unique_username(binary()) -> binary().
unique_username(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<Prefix/binary, "_", Suffix/binary>>.
