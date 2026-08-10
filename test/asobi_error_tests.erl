-module(asobi_error_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- The object shape ---

%% The whole point of the module: one shape, every time. A client that
%% branches on `error.code` must never have to test for a missing key.
object_always_has_code_message_and_details_test() ->
    #{error := Error} = asobi_error:object(~"storage.not_found"),
    ?assertEqual([code, details, message], lists:sort(maps:keys(Error))),
    ?assertEqual(~"storage.not_found", maps:get(code, Error)),
    ?assert(is_binary(maps:get(message, Error))).

%% `details` is a map even when empty, so no client needs a null branch.
empty_details_is_a_map_not_null_test() ->
    #{error := #{details := Details}} = asobi_error:object(~"rate_limited"),
    ?assertEqual(#{}, Details),
    ?assertEqual(
        #{~"details" => #{}},
        maps:with([~"details"], json:decode(iolist_to_binary(json:encode(#{details => Details}))))
    ).

details_are_carried_through_test() ->
    #{error := #{details := Details}} =
        asobi_error:object(~"save.version_conflict", #{current_version => 4}),
    ?assertEqual(#{current_version => 4}, Details).

explicit_message_overrides_the_registered_one_test() ->
    #{error := #{message := Message}} =
        asobi_error:object(~"internal", ~"Bespoke.", #{}),
    ?assertEqual(~"Bespoke.", Message).

%% --- Keys a route already sent stay where they were ---

%% The one compatibility rule of the rollout: converting a route replaces
%% `error` and touches nothing else. A client reading `fields` keeps reading
%% `fields`, and the same map is the object's `details` for new code.
legacy_keeps_the_top_level_keys_test() ->
    Body = asobi_error:legacy_body(~"validation_failed", #{fields => #{username => [~"taken"]}}),
    ?assertEqual(#{username => [~"taken"]}, maps:get(fields, Body)),
    ?assertMatch(
        #{error := #{code := ~"validation_failed", details := #{fields := _}}},
        Body
    ),
    ?assertEqual([error, fields], lists:sort(maps:keys(Body))).

legacy_takes_its_status_from_the_code_test() ->
    ?assertMatch(
        {json, 429, #{}, #{error := #{code := ~"rate_limited"}, retry_after := 30}},
        asobi_error:legacy(~"rate_limited", #{retry_after => 30})
    ).

%% A legacy body with nothing to add is still the plain object, `details` and
%% all - no empty extra keys, no missing ones.
legacy_with_no_extra_keys_is_the_object_test() ->
    ?assertEqual(
        asobi_error:object(~"forbidden"),
        asobi_error:legacy_body(~"forbidden", #{})
    ).

%% --- The code table ---

status_comes_from_the_code_test() ->
    ?assertEqual(404, asobi_error:status(~"storage.not_found")),
    ?assertEqual(429, asobi_error:status(~"rate_limited")),
    ?assertEqual(409, asobi_error:status(~"save.version_conflict")),
    ?assertEqual(503, asobi_error:status(~"matchmaker.queue_full")).

%% An undefined code is a server bug, not a client error: 500, and a message
%% that says so rather than a crash or an empty body.
undefined_code_is_a_500_test() ->
    ?assertEqual(500, asobi_error:status(~"storage.not_fund")),
    ?assertMatch(
        #{error := #{code := ~"storage.not_fund", details := #{}}},
        asobi_error:object(~"storage.not_fund")
    ),
    ?assertNotEqual(asobi_error:message(~"storage.not_found"), asobi_error:message(~"nope")).

codes_are_unique_test() ->
    Codes = asobi_error:codes(),
    ?assertEqual(lists:sort(Codes), lists:usort(Codes)).

%% Codes are the wire contract: lowercase ASCII, dot-namespaced at most once,
%% no whitespace. A code that needs quoting or case-folding is a bug.
codes_are_wire_safe_test() ->
    [
        ?assert(is_wire_safe_code(Code))
     || Code <- asobi_error:codes()
    ].

%% --- WebSocket reason mapping ---

%% Guards the mapping against a typo: every reason must resolve to a code
%% that actually exists, or the ws path would emit an undefined code.
every_mapped_ws_reason_resolves_to_a_defined_code_test() ->
    Codes = asobi_error:codes(),
    [
        ?assert(lists:member(Code, Codes))
     || {_Reason, Code} <- asobi_error:ws_reasons()
    ].

known_ws_reason_maps_to_its_code_test() ->
    ?assertMatch(
        #{error := #{code := ~"match.not_in_match", details := #{}}},
        asobi_error:from_ws_reason(~"not_in_match")
    ),
    ?assertMatch(
        #{error := #{code := ~"world.not_found"}},
        asobi_error:from_ws_reason(~"world_not_found")
    ).

%% The guide promises one code set across both surfaces: the same failure must
%% not be `dm.blocked` over REST and `ws.request_failed` on the socket.
ws_reason_and_rest_agree_on_the_code_test() ->
    Shared = [
        {~"blocked", ~"dm.blocked"},
        {~"content_empty", ~"dm.content_empty"},
        {~"content_too_large", ~"dm.content_too_large"},
        {~"not_owner", ~"forbidden"}
    ],
    [
        ?assertMatch(#{error := #{code := Code}}, asobi_error:from_ws_reason(Reason))
     || {Reason, Code} <- Shared
    ].

%% A closed match and a full one are the same 409 but different codes: a
%% client retries the second and gives up on the first.
match_join_failures_have_their_own_codes_test() ->
    ?assertMatch(
        #{error := #{code := ~"match.full"}}, asobi_error:from_ws_reason(match_full)
    ),
    ?assertMatch(
        #{error := #{code := ~"match.locked"}}, asobi_error:from_ws_reason(match_locked)
    ),
    ?assertMatch(
        #{error := #{code := ~"match.join_refused"}},
        asobi_error:from_ws_reason(~"join_refused")
    ).

%% The game's own refusal string is carried as a detail. It must never
%% displace the code - that is the whole reason details exist.
refusal_detail_rides_along_without_minting_a_code_test() ->
    ?assertEqual(
        #{
            error => #{
                code => ~"match.join_refused",
                message => asobi_error:message(~"match.join_refused"),
                details => #{refused_reason => ~"wrong_code"}
            }
        },
        asobi_error:from_ws_reason(~"join_refused", #{refused_reason => ~"wrong_code"})
    ).

details_do_not_rescue_an_unmapped_reason_test() ->
    ?assertMatch(
        #{error := #{code := ~"ws.request_failed", details := #{reason := ~"nope"}}},
        asobi_error:from_ws_reason(~"nope", #{extra => 1})
    ).

ws_reason_accepts_an_atom_test() ->
    ?assertEqual(
        asobi_error:from_ws_reason(~"queue_full"),
        asobi_error:from_ws_reason(queue_full)
    ).

%% An unmapped reason - including anything a Lua game script returns - must
%% not mint a code. It lands under a known one with the raw string in details.
unmapped_ws_reason_cannot_mint_a_code_test() ->
    ?assertEqual(
        #{
            error => #{
                code => ~"ws.request_failed",
                message => asobi_error:message(~"ws.request_failed"),
                details => #{reason => ~"my_game_said_no"}
            }
        },
        asobi_error:from_ws_reason(~"my_game_said_no")
    ).

%% The SDKs dispatch-test against priv/protocol/fixtures. A fixture still
%% showing only `reason` would have every SDK asserting a shape the server no
%% longer sends.
error_fixture_matches_the_emitted_shape_test() ->
    {ok, Bin} = file:read_file("priv/protocol/fixtures/error.json"),
    #{~"payload" := #{~"reason" := Reason, ~"error" := Fixture}} = json:decode(Bin),
    #{error := #{code := Code, message := Message, details := Details}} =
        asobi_error:from_ws_reason(Reason),
    ?assertEqual(
        #{~"code" => Code, ~"message" => Message, ~"details" => Details},
        Fixture
    ).

%% --- The Nova return handler ---

handler_test_() ->
    {setup, fun set_json_lib/0, fun restore_json_lib/1, [
        fun status_comes_from_the_code_tuple/0,
        fun details_reach_the_body/0,
        fun explicit_status_overrides_the_code/0,
        fun body_is_json_with_the_error_object/0
    ]}.

status_comes_from_the_code_tuple() ->
    {ok, Req} = asobi_error:handle({asobi_error, ~"storage.not_found"}, callback(), #{}),
    ?assertMatch(#{resp_status_code := 404}, Req).

details_reach_the_body() ->
    {ok, Req} = asobi_error:handle(
        {asobi_error, ~"save.version_conflict", #{current_version => 7}}, callback(), #{}
    ),
    ?assertMatch(#{resp_status_code := 409}, Req),
    ?assertMatch(
        #{~"error" := #{~"details" := #{~"current_version" := 7}}},
        decode_body(Req)
    ).

explicit_status_overrides_the_code() ->
    {ok, Req} = asobi_error:handle({asobi_error, 418, ~"internal", #{}}, callback(), #{}),
    ?assertMatch(#{resp_status_code := 418}, Req).

body_is_json_with_the_error_object() ->
    {ok, Req} = asobi_error:handle({asobi_error, ~"storage.forbidden"}, callback(), #{}),
    ?assertMatch(
        #{
            ~"error" := #{
                ~"code" := ~"storage.forbidden",
                ~"message" := _,
                ~"details" := #{}
            }
        },
        decode_body(Req)
    ),
    ?assertMatch(
        #{resp_headers := #{~"content-type" := ~"application/json"}},
        Req
    ).

%% --- Helpers ---

callback() ->
    fun(_) -> ok end.

decode_body(#{resp_body := Body}) ->
    json:decode(iolist_to_binary(Body)).

%% nova_basic_handler:handle_json/3 encodes with the bootstrap application's
%% `json_lib`. Point it at the same OTP `json` the release configures, so the
%% test exercises the real encoder rather than nova's thoas default.
set_json_lib() ->
    Previous = {
        application:get_env(nova, bootstrap_application),
        application:get_env(asobi, json_lib)
    },
    application:set_env(nova, bootstrap_application, asobi),
    application:set_env(asobi, json_lib, json),
    Previous.

restore_json_lib({Bootstrap, JsonLib}) ->
    restore(nova, bootstrap_application, Bootstrap),
    restore(asobi, json_lib, JsonLib).

restore(App, Key, undefined) -> application:unset_env(App, Key);
restore(App, Key, {ok, Value}) -> application:set_env(App, Key, Value).

is_wire_safe_code(Code) ->
    Chars = binary_to_list(Code),
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse C =:= $_ orelse C =:= $. end, Chars) andalso
        length([C || C <- Chars, C =:= $.]) =< 1.
