-module(asobi_iap_controller_tests).
-include_lib("eunit/include/eunit.hrl").

iap_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun first_purchase_recorded/0,
        fun duplicate_same_player_idempotent/0,
        fun cross_account_replay_rejected/0,
        fun unauthenticated_rejected/0,
        fun verify_failure_surfaced/0,
        fun google_uses_order_id/0
    ]}.

setup() ->
    meck:new(asobi_iap, [no_link]),
    meck:new(asobi_repo, [no_link]),
    ok.

cleanup(_) ->
    meck:unload(asobi_iap),
    meck:unload(asobi_repo),
    ok.

first_purchase_recorded() ->
    stub_apple(#{transaction_id => ~"t1", product_id => ~"coins", original_transaction_id => ~"t1"}),
    no_existing(),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    {json, 200, _, Body} = asobi_iap_controller:verify_apple(apple_req(~"p1")),
    ?assertEqual(false, maps:get(duplicate, Body)),
    ?assert(meck:called(asobi_repo, insert, '_')).

duplicate_same_player_idempotent() ->
    stub_apple(#{transaction_id => ~"t1", product_id => ~"coins"}),
    meck:expect(asobi_repo, all, fun(_Q) -> {ok, [#{player_id => ~"p1"}]} end),
    {json, 200, _, Body} = asobi_iap_controller:verify_apple(apple_req(~"p1")),
    ?assertEqual(true, maps:get(duplicate, Body)),
    ?assertNot(meck:called(asobi_repo, insert, '_')).

cross_account_replay_rejected() ->
    stub_apple(#{transaction_id => ~"t1", product_id => ~"coins"}),
    meck:expect(asobi_repo, all, fun(_Q) -> {ok, [#{player_id => ~"someone-else"}]} end),
    ?assertMatch(
        {json, 409, _, #{error := ~"transaction_already_claimed"}},
        asobi_iap_controller:verify_apple(apple_req(~"p1"))
    ).

unauthenticated_rejected() ->
    Req = #{json => #{~"signed_transaction" => ~"jws"}},
    ?assertMatch({json, 400, _, _}, asobi_iap_controller:verify_apple(Req)).

verify_failure_surfaced() ->
    meck:expect(asobi_iap, verify_apple, fun(_) -> {error, ~"bundle_id_mismatch"} end),
    ?assertMatch(
        {json, 422, _, #{error := ~"bundle_id_mismatch"}},
        asobi_iap_controller:verify_apple(apple_req(~"p1"))
    ).

google_uses_order_id() ->
    meck:expect(asobi_iap, verify_google, fun(_) ->
        {ok, #{order_id => ~"GPA.1", product_id => ~"coins"}}
    end),
    no_existing(),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    Req = #{
        json => #{~"product_id" => ~"coins", ~"purchase_token" => ~"tok"},
        auth_data => #{player_id => ~"p1"}
    },
    {json, 200, _, Body} = asobi_iap_controller:verify_google(Req),
    ?assertEqual(false, maps:get(duplicate, Body)).

%% Helpers

apple_req(PlayerId) ->
    #{json => #{~"signed_transaction" => ~"jws"}, auth_data => #{player_id => PlayerId}}.

stub_apple(Result) ->
    meck:expect(asobi_iap, verify_apple, fun(_) -> {ok, Result} end).

no_existing() ->
    meck:expect(asobi_repo, all, fun(_Q) -> {ok, []} end).
