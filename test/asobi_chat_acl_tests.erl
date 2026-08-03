-module(asobi_chat_acl_tests).
-include_lib("eunit/include/eunit.hrl").

%% H1 (2026-05-19): chat ACL must reject third parties on DMs. World and
%% group channels require live processes / DB and are exercised via
%% asobi_chat_SUITE; here we cover the dm path that the WS handler gates
%% `chat.join` and `chat.send` through. #305 made the dm path DB-backed
%% (the non-caller participant must resolve to a real player), so these
%% now mock asobi_repo:get/2 the same way asobi_social_controller's
%% "friend id must exist" check is exercised elsewhere in this suite.

setup() ->
    meck:new(asobi_repo, [no_link]),
    ok.

cleanup(_) ->
    meck:unload(asobi_repo),
    ok.

dm_acl_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"both named participants are authorized when the other is a real player",
            fun dm_member_authorized/0},
        {"a third party is rejected regardless of player-registry state",
            fun dm_third_party_rejected/0},
        {"a channel id that merely contains PlayerId as a substring is rejected",
            fun dm_substring_does_not_grant_access/0},
        {"#305: an unknown/arbitrary other-participant segment is rejected",
            fun dm_unknown_participant_rejected/0}
    ]}.

dm_member_authorized() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {ok, #{}} end),
    ?assert(asobi_chat_acl:authorized(~"dm:alice:bob", ~"alice")),
    ?assert(asobi_chat_acl:authorized(~"dm:alice:bob", ~"bob")).

dm_third_party_rejected() ->
    %% Neither "eve" nor "" is a named participant, so dm_authorized/3 must
    %% short-circuit to `false` without ever consulting the player registry.
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> error(should_not_be_called) end),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"eve")),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"")).

dm_substring_does_not_grant_access() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> error(should_not_be_called) end),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"ali")),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:bob", ~"alicee")).

%% #305: without this, `PlayerId =:= A orelse PlayerId =:= B` let any
%% authenticated player mint an unbounded number of `dm:<self>:<anything>`
%% channel ids by varying the second segment - none of them a real player.
dm_unknown_participant_rejected() ->
    meck:expect(asobi_repo, get, fun(asobi_player, _Id) -> {error, not_found} end),
    ?assertNot(asobi_chat_acl:authorized(~"dm:alice:not_a_real_player", ~"alice")),
    ?assertNot(asobi_chat_acl:authorized(~"dm:not_a_real_player:alice", ~"alice")).

%% #299: the one scheme that spans worlds. Any signed-in player may join a
%% declared name; an undeclared one must not authorise, or `chat.join` would
%% mint unbounded channel processes.
global_acl_test_() ->
    {setup, fun global_setup/0, fun global_cleanup/1, [
        {"a declared global channel authorises any player", fun global_declared_authorized/0},
        {"an undeclared global channel authorises nobody", fun global_undeclared_rejected/0},
        {"names are collected across every configured mode", fun global_union_across_modes/0},
        {"a bare `global:` prefix is denied", fun global_empty_name_rejected/0},
        {"the `global:` prefix passes channel-id validation", fun global_prefix_validates/0}
    ]}.

global_setup() ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        ~"galaxy" => #{type => world, chat => #{global => [~"general"], world => true}},
        ~"arena" => #{chat => #{global => [~"trade", ~"general"]}},
        ~"quiet" => #{chat => #{world => true}}
    }),
    Prev.

global_cleanup({ok, Prev}) ->
    application:set_env(asobi, game_modes, Prev);
global_cleanup(undefined) ->
    application:unset_env(asobi, game_modes).

global_declared_authorized() ->
    ?assert(asobi_chat_acl:authorized(~"global:general", ~"alice")),
    ?assert(asobi_chat_acl:authorized(~"global:general", ~"bob")).

global_undeclared_rejected() ->
    ?assertNot(asobi_chat_acl:authorized(~"global:not-declared", ~"alice")),
    ?assertNot(asobi_chat_acl:authorized(~"global:general:extra", ~"alice")).

global_union_across_modes() ->
    ?assert(asobi_chat_acl:authorized(~"global:trade", ~"alice")),
    ?assertEqual([~"general", ~"trade"], asobi_game_modes:global_chat_channels()).

global_empty_name_rejected() ->
    ?assertNot(asobi_chat_acl:authorized(~"global:", ~"alice")),
    ?assertNot(asobi_chat_acl:validate_channel_id(~"global")).

global_prefix_validates() ->
    ?assert(asobi_chat_acl:validate_channel_id(~"global:general")).
