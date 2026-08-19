-module(asobi_steam_tests).
-include_lib("eunit/include/eunit.hrl").

steam_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun ok_ticket_returns_claims/0,
        fun vac_ban_is_surfaced_not_rejected/0,
        fun family_sharing_owner_is_carried/0,
        fun publisher_banned_rejected/0,
        fun identity_param_included_when_configured/0,
        fun outbound_call_sets_tls_options/0
    ]}.

setup() ->
    application:set_env(asobi, steam_api_key, ~"test-key"),
    application:set_env(asobi, steam_app_id, ~"480"),
    application:unset_env(asobi, steam_identity),
    meck:new(httpc, [unstick, no_link]),
    ok.

cleanup(_) ->
    meck:unload(httpc),
    application:unset_env(asobi, steam_api_key),
    application:unset_env(asobi, steam_app_id),
    application:unset_env(asobi, steam_identity),
    ok.

%% The two Steam-specific claims live under `provider_metadata` with binary keys,
%% because that is the identity field they are written to and it is jsonb
%% (asobi#520). Loose at the top level they were computed and dropped.
ok_ticket_returns_claims() ->
    stub_steam(#{~"result" => ~"OK", ~"steamid" => ~"123", ~"ownersteamid" => ~"123"}),
    {ok, Claims} = asobi_steam:validate_ticket(~"deadbeef"),
    ?assertEqual(~"123", maps:get(provider_uid, Claims)),
    ?assertEqual(
        #{~"owner_steamid" => ~"123", ~"vac_banned" => false},
        maps:get(provider_metadata, Claims)
    ).

%% A VAC ban is not a rejection - it is Valve's verdict about another game, and
%% only publisherbanned (this app) refuses the login. Carrying it lets a title
%% decide for itself.
vac_ban_is_surfaced_not_rejected() ->
    stub_steam(#{~"result" => ~"OK", ~"steamid" => ~"123", ~"vacbanned" => true}),
    {ok, Claims} = asobi_steam:validate_ticket(~"deadbeef"),
    ?assertEqual(true, maps:get(~"vac_banned", maps:get(provider_metadata, Claims))).

%% Family Sharing: the ticket is authenticated against the borrower, the licence
%% belongs to the owner. Without the owner id the two are indistinguishable.
family_sharing_owner_is_carried() ->
    stub_steam(#{~"result" => ~"OK", ~"steamid" => ~"borrower", ~"ownersteamid" => ~"owner"}),
    {ok, Claims} = asobi_steam:validate_ticket(~"deadbeef"),
    Meta = maps:get(provider_metadata, Claims),
    ?assertEqual(~"borrower", maps:get(provider_uid, Claims)),
    ?assertEqual(~"owner", maps:get(~"owner_steamid", Meta)).

publisher_banned_rejected() ->
    stub_steam(#{~"result" => ~"OK", ~"steamid" => ~"123", ~"publisherbanned" => true}),
    ?assertEqual({error, ~"publisher_banned"}, asobi_steam:validate_ticket(~"deadbeef")).

identity_param_included_when_configured() ->
    application:set_env(asobi, steam_identity, ~"asobi-prod"),
    Self = self(),
    meck:expect(httpc, request, fun(get, {Url, _H}, _O, _P) ->
        Self ! {url, list_to_binary(Url)},
        {ok, {{"HTTP/1.1", 200, "OK"}, [], auth_body(#{~"result" => ~"OK", ~"steamid" => ~"1"})}}
    end),
    _ = asobi_steam:validate_ticket(~"deadbeef"),
    receive
        {url, Url} -> ?assert(binary:match(Url, ~"&identity=asobi-prod") =/= nomatch)
    after 1000 -> ?assert(false)
    end.

%% The outbound call must go through asobi_tls_client, so verify_peer TLS
%% options reach httpc rather than the fail-open default (#171).
outbound_call_sets_tls_options() ->
    Self = self(),
    meck:expect(httpc, request, fun(get, {_Url, _H}, Opts, _P) ->
        Self ! {opts, Opts},
        {ok, {{"HTTP/1.1", 200, "OK"}, [], auth_body(#{~"result" => ~"OK", ~"steamid" => ~"1"})}}
    end),
    _ = asobi_steam:validate_ticket(~"deadbeef"),
    receive
        {opts, Opts} ->
            {ssl, Ssl} = lists:keyfind(ssl, 1, Opts),
            ?assertEqual(verify_peer, proplists:get_value(verify, Ssl))
    after 1000 -> ?assert(false)
    end.

%% Route both Steam calls (ticket auth + optional profile fetch) to canned bodies.
stub_steam(Params) ->
    meck:expect(httpc, request, fun(get, {Url, _H}, _O, _P) ->
        Body =
            case binary:match(list_to_binary(Url), ~"GetPlayerSummaries") of
                nomatch -> auth_body(Params);
                _ -> ~"{\"response\":{\"players\":[]}}"
            end,
        {ok, {{"HTTP/1.1", 200, "OK"}, [], Body}}
    end).

auth_body(Params) ->
    iolist_to_binary(json:encode(#{~"response" => #{~"params" => Params}})).
