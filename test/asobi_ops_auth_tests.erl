-module(asobi_ops_auth_tests).

-include_lib("eunit/include/eunit.hrl").

%% The ops plane reads every player and every match record in the deployment.
%% Before ADR 0007 it sat on the player-scoped bearer check, so any
%% authenticated player - guest included - could enumerate it. These tests pin
%% the two properties that closed that: a player token is not a credential
%% here, and an unconfigured deployment admits nobody.

-define(SECRET, ~"7f4c1b9a2e6d8053f1a4c7b0e9d2635847ac1fbe2093d75641c8ba0fe3729d15").

%%--------------------------------------------------------------------
%% Capability classes
%%--------------------------------------------------------------------

class_is_read_for_every_shipped_route_test() ->
    [
        ?assertEqual(read, asobi_ops_caps:class(~"GET", Path))
     || Path <- [
            ~"/api/v1/ops/players",
            ~"/api/v1/ops/matches",
            ~"/api/v1/ops/features",
            ~"/api/v1/ops/leaderboards",
            ~"/api/v1/ops/matchmaker"
        ]
    ].

%% A bound segment is tagged `'_'` and the request carries a real value, so
%% any id must resolve. Without this the route is untagged at runtime and
%% denied, which is the safe failure but still a broken endpoint.
class_resolves_a_bound_segment_test() ->
    [
        ?assertEqual(read, asobi_ops_caps:class(~"GET", Path))
     || Path <- [
            ~"/api/v1/ops/leaderboards/global/entries",
            ~"/api/v1/ops/leaderboards/019fca02-8553-792c-93e0-a0c7f803bc98/entries"
        ]
    ].

%% The wildcard must not widen: it stands for exactly one segment, so neither
%% a missing nor an extra segment may borrow the tag.
class_wildcard_matches_exactly_one_segment_test() ->
    ?assertEqual(undefined, asobi_ops_caps:class(~"GET", ~"/api/v1/ops/leaderboards/entries")),
    ?assertEqual(
        undefined, asobi_ops_caps:class(~"GET", ~"/api/v1/ops/leaderboards/a/b/entries")
    ).

%% routing_tree collapses `//` and edge slashes, so a variant that still
%% routes must still find its tag - otherwise it would be denied as untagged.
class_survives_router_slash_normalisation_test() ->
    [
        ?assertEqual(read, asobi_ops_caps:class(~"GET", Path))
     || Path <- [~"//api/v1/ops/players", ~"/api/v1//ops/players", ~"/api/v1/ops/players/"]
    ].

class_is_undefined_for_an_untagged_ops_path_test() ->
    ?assertEqual(undefined, asobi_ops_caps:class(~"GET", ~"/api/v1/ops/economy")),
    ?assertEqual(undefined, asobi_ops_caps:class(~"GET", ~"/api/v1/ops")).

class_is_undefined_for_a_method_the_route_does_not_carry_test() ->
    ?assertEqual(undefined, asobi_ops_caps:class(~"POST", ~"/api/v1/ops/players")),
    ?assertEqual(undefined, asobi_ops_caps:class(~"OPTIONS", ~"/api/v1/ops/players")).

class_is_undefined_outside_the_ops_prefix_test() ->
    [
        ?assertEqual(undefined, asobi_ops_caps:class(~"GET", Path))
     || Path <- [~"/api/v1/players", ~"/api/v2/ops/players", ~"/ops/players", ~"/"]
    ].

authorised_is_membership_only_test() ->
    ?assert(asobi_ops_caps:authorised(read, [read])),
    ?assert(asobi_ops_caps:authorised(config, [read, player_data, config])),
    ?assertNot(asobi_ops_caps:authorised(config, [read, player_data])),
    ?assertNot(asobi_ops_caps:authorised(player_data, [read])),
    ?assertNot(asobi_ops_caps:authorised(read, [])).

%% An untagged route has no class, and that must deny rather than fall
%% through to a permissive default.
authorised_denies_an_untagged_route_test() ->
    ?assertNot(asobi_ops_caps:authorised(undefined, [read, player_data, config])).

every_shipped_route_carries_exactly_one_class_test() ->
    Routes = [{M, S} || {M, S, _Class} <- asobi_ops_caps:classes()],
    ?assertEqual(lists:usort(Routes), lists:sort(Routes)),
    [
        ?assert(lists:member(Class, [read, player_data, config]))
     || {_M, _S, Class} <- asobi_ops_caps:classes()
    ].

%%--------------------------------------------------------------------
%% verify/1
%%--------------------------------------------------------------------

verify_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun admits_the_configured_secret/0,
        fun admitted_actor_has_the_adr_shape/0,
        fun rejects_a_player_bearer_token/0,
        fun never_consults_the_player_token_cache/0,
        fun rejects_a_wrong_secret/0,
        fun rejects_a_secret_prefix/0,
        fun rejects_a_missing_header/0,
        fun rejects_a_non_bearer_scheme/0,
        fun rejects_an_empty_bearer_token/0,
        fun rejects_an_untagged_ops_route/0,
        fun rejects_a_path_outside_the_ops_prefix/0,
        fun denial_is_403_and_says_nothing_about_the_cause/0
    ]}.

setup() ->
    Original = application:get_env(asobi, ops_secret),
    application:set_env(asobi, ops_secret, ?SECRET),
    meck:new(asobi_auth_cache, [passthrough]),
    meck:expect(asobi_auth_cache, resolve_token, fun(_) -> {ok, #{id => ~"p1"}} end),
    Original.

cleanup(Original) ->
    catch meck:unload(asobi_auth_cache),
    case Original of
        {ok, Value} -> application:set_env(asobi, ops_secret, Value);
        undefined -> application:unset_env(asobi, ops_secret)
    end.

req(Path, Headers) -> #{method => ~"GET", path => Path, headers => Headers}.

bearer(Token) -> #{~"authorization" => <<"Bearer ", Token/binary>>}.

ops_req(Token) -> req(~"/api/v1/ops/players", bearer(Token)).

admits_the_configured_secret() ->
    ?assertMatch({true, #{ops_actor := #{}}}, asobi_ops_auth:verify(ops_req(?SECRET))).

admitted_actor_has_the_adr_shape() ->
    {true, #{ops_actor := Actor}} = asobi_ops_auth:verify(ops_req(?SECRET)),
    ?assertEqual([attested, caps, display, id, source], lists:sort(maps:keys(Actor))),
    ?assertEqual(static_secret, maps:get(source, Actor)),
    ?assertEqual([read, player_data, config], maps:get(caps, Actor)),
    ?assertEqual(false, maps:get(attested, Actor)),
    ?assertEqual(~"operator", maps:get(display, Actor)).

%% The hole this closes: `asobi_auth_cache:resolve_token/1` does not
%% discriminate, so a player - or a guest - holding any live token could read
%% the whole deployment while these routes sat on the player check.
rejects_a_player_bearer_token() ->
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(ops_req(~"a-live-player-token"))).

never_consults_the_player_token_cache() ->
    _ = asobi_ops_auth:verify(ops_req(~"a-live-player-token")),
    _ = asobi_ops_auth:verify(ops_req(?SECRET)),
    ?assertEqual(0, meck:num_calls(asobi_auth_cache, resolve_token, '_')).

rejects_a_wrong_secret() ->
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(ops_req(~"not-the-secret"))).

rejects_a_secret_prefix() ->
    <<Prefix:32/binary, _/binary>> = ?SECRET,
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(ops_req(Prefix))).

rejects_a_missing_header() ->
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(req(~"/api/v1/ops/players", #{}))).

rejects_a_non_bearer_scheme() ->
    Req = req(~"/api/v1/ops/players", #{~"authorization" => <<"Basic ", ?SECRET/binary>>}),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(Req)).

rejects_an_empty_bearer_token() ->
    Req = req(~"/api/v1/ops/players", #{~"authorization" => ~"Bearer "}),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(Req)).

%% A future ops route added to the router but not to the class table must be
%% closed, not open.
rejects_an_untagged_ops_route() ->
    Req = req(~"/api/v1/ops/economy", bearer(?SECRET)),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(Req)).

rejects_a_path_outside_the_ops_prefix() ->
    Req = req(~"/api/v1/players/p1", bearer(?SECRET)),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(Req)).

denial_is_403_and_says_nothing_about_the_cause() ->
    Denials = [
        asobi_ops_auth:verify(ops_req(~"not-the-secret")),
        asobi_ops_auth:verify(req(~"/api/v1/ops/players", #{})),
        asobi_ops_auth:verify(req(~"/api/v1/ops/economy", bearer(?SECRET)))
    ],
    ?assertEqual(1, length(lists:usort(Denials))),
    [{false, Status, Headers, Body} | _] = Denials,
    ?assertEqual(403, Status),
    ?assertEqual(#{~"content-type" => ~"application/json"}, Headers),
    ?assertMatch(
        #{~"error" := #{~"code" := ~"forbidden", ~"message" := _, ~"details" := #{}}},
        json:decode(Body)
    ).

%%--------------------------------------------------------------------
%% Failing closed with no secret configured
%%--------------------------------------------------------------------

unconfigured_test_() ->
    {foreach, fun unconfigured_setup/0, fun cleanup/1, [
        fun rejects_every_request_when_no_secret_is_configured/0,
        fun rejects_an_empty_secret/0,
        fun rejects_a_non_binary_secret/0
    ]}.

unconfigured_setup() ->
    Original = application:get_env(asobi, ops_secret),
    application:unset_env(asobi, ops_secret),
    Original.

%% ADR 0007 ships no default credential. An operator who never configures one
%% gets a plane nobody can read, not one everybody can.
rejects_every_request_when_no_secret_is_configured() ->
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(ops_req(~""))),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(ops_req(~"anything"))),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(req(~"/api/v1/ops/players", #{}))),
    ?assertEqual({error, not_configured}, asobi_ops_auth:resolve(ops_req(~"anything"))).

rejects_an_empty_secret() ->
    application:set_env(asobi, ops_secret, ~""),
    ?assertEqual({error, not_configured}, asobi_ops_auth:resolve(ops_req(~""))).

rejects_a_non_binary_secret() ->
    application:set_env(asobi, ops_secret, "a-string-not-a-binary"),
    ?assertEqual(
        {error, not_configured}, asobi_ops_auth:resolve(ops_req(~"a-string-not-a-binary"))
    ).

%%--------------------------------------------------------------------
%% The x-asobi-operator label
%%--------------------------------------------------------------------

label_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun label_names_the_actor_but_is_never_attested/0,
        fun label_grants_no_capability/0,
        fun multi_valued_label_is_dropped/0,
        fun oversized_label_is_dropped/0,
        fun control_characters_in_a_label_are_dropped/0,
        fun empty_label_is_dropped/0,
        fun label_is_ignored_without_a_credential/0
    ]}.

labelled(Token, Label) ->
    req(~"/api/v1/ops/players", maps:put(~"x-asobi-operator", Label, bearer(Token))).

display_of(Req) ->
    {true, #{ops_actor := #{display := Display}}} = asobi_ops_auth:verify(Req),
    Display.

label_names_the_actor_but_is_never_attested() ->
    {true, #{ops_actor := Actor}} = asobi_ops_auth:verify(labelled(?SECRET, ~"kaito")),
    ?assertEqual(~"kaito", maps:get(display, Actor)),
    ?assertEqual(false, maps:get(attested, Actor)).

%% Spoofing the label must buy false attribution and never privilege: the caps
%% are the same whether it is present, absent or forged.
label_grants_no_capability() ->
    {true, #{ops_actor := #{caps := Plain}}} = asobi_ops_auth:verify(ops_req(?SECRET)),
    {true, #{ops_actor := #{caps := Labelled}}} = asobi_ops_auth:verify(
        labelled(?SECRET, ~"root")
    ),
    ?assertEqual(Plain, Labelled).

%% Cowboy joins repeated headers with a comma, so a comma is how a
%% multi-valued label arrives.
multi_valued_label_is_dropped() ->
    ?assertEqual(~"operator", display_of(labelled(?SECRET, ~"kaito, mei"))).

oversized_label_is_dropped() ->
    ?assertEqual(~"operator", display_of(labelled(?SECRET, binary:copy(~"k", 65)))),
    ?assertEqual(binary:copy(~"k", 64), display_of(labelled(?SECRET, binary:copy(~"k", 64)))).

%% The label lands in audit rows and logs, so a newline or an escape sequence
%% must not survive into them.
control_characters_in_a_label_are_dropped() ->
    [
        ?assertEqual(~"operator", display_of(labelled(?SECRET, Label)))
     || Label <- [~"kaito\nadmin", ~"kaito\r\nx", ~"kaito\e[31m", ~"kaito\0"]
    ].

empty_label_is_dropped() ->
    ?assertEqual(~"operator", display_of(labelled(?SECRET, ~""))).

label_is_ignored_without_a_credential() ->
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(labelled(~"wrong", ~"kaito"))),
    Req = req(~"/api/v1/ops/players", #{~"x-asobi-operator" => ~"kaito"}),
    ?assertMatch({false, 403, _, _}, asobi_ops_auth:verify(Req)).
