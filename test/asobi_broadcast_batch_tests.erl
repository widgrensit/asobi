-module(asobi_broadcast_batch_tests).
-include_lib("eunit/include/eunit.hrl").

pre_encoded_binary_is_valid_json_test() ->
    Deltas = [{added, ~"e1", #{~"x" => 10, ~"y" => 20}}, {removed, ~"e2"}],
    EncodedDeltas = [encode_delta(D) || D <- Deltas],
    Payload = #{
        ~"type" => ~"world.tick", ~"payload" => #{~"tick" => 1, ~"updates" => EncodedDeltas}
    },
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    ?assert(is_binary(PreEncoded)),
    Decoded = json:decode(PreEncoded),
    ?assertMatch(#{~"type" := ~"world.tick", ~"payload" := _}, Decoded),
    #{~"payload" := #{~"tick" := 1, ~"updates" := UpdatesRaw}} = Decoded,
    Updates = as_list(UpdatesRaw),
    ?assertEqual(2, length(Updates)),
    [First, Second] = Updates,
    FirstMap = as_map(First),
    SecondMap = as_map(Second),
    ?assertEqual(~"a", maps:get(~"op", FirstMap)),
    ?assertEqual(~"e1", maps:get(~"id", FirstMap)),
    ?assertEqual(~"r", maps:get(~"op", SecondMap)),
    ?assertEqual(~"e2", maps:get(~"id", SecondMap)).

pre_encoded_empty_deltas_test() ->
    Payload = #{~"type" => ~"world.tick", ~"payload" => #{~"tick" => 5, ~"updates" => []}},
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    Decoded = json:decode(PreEncoded),
    #{~"payload" := #{~"updates" := []}} = Decoded.

pre_encoded_update_delta_test() ->
    Deltas = [{updated, ~"e3", #{~"hp" => 50}}],
    EncodedDeltas = [encode_delta(D) || D <- Deltas],
    Payload = #{
        ~"type" => ~"world.tick", ~"payload" => #{~"tick" => 7, ~"updates" => EncodedDeltas}
    },
    PreEncoded = iolist_to_binary(json:encode(Payload)),
    Decoded = json:decode(PreEncoded),
    #{~"payload" := #{~"updates" := [UpdateRaw]}} = Decoded,
    Update = as_map(UpdateRaw),
    ?assertEqual(~"u", maps:get(~"op", Update)),
    ?assertEqual(~"e3", maps:get(~"id", Update)),
    ?assertEqual(50, maps:get(~"hp", Update)).

%% Mirror of asobi_zone:encode_delta/1
encode_delta({updated, Id, Diff}) ->
    Diff#{~"op" => ~"u", ~"id" => Id};
encode_delta({added, Id, FullState}) ->
    FullState#{~"op" => ~"a", ~"id" => Id};
encode_delta({removed, Id}) ->
    #{~"op" => ~"r", ~"id" => Id}.

-spec as_map(term()) -> map().
as_map(M) when is_map(M) -> M.

-spec as_list(term()) -> list().
as_list(L) when is_list(L) -> L.
