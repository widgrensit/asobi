-module(asobi_world_chat_tests).
-include_lib("eunit/include/eunit.hrl").

channel_id_test_() ->
    [
        {"world channel id", fun() ->
            ?assertEqual(
                ~"world:w1",
                asobi_world_chat:channel_id(~"w1", world, undefined)
            )
        end},
        {"zone channel id", fun() ->
            ?assertEqual(
                ~"zone:w1:3,5",
                asobi_world_chat:channel_id(~"w1", zone, {3, 5})
            )
        end},
        {"proximity channel id", fun() ->
            ?assertEqual(
                ~"prox:w1:0,0",
                asobi_world_chat:channel_id(~"w1", proximity, {0, 0})
            )
        end}
    ].

init_test_() ->
    [
        {"init returns chat state with config", fun() ->
            Config = #{chat => #{world => true, zone => true}},
            State = asobi_world_chat:init(~"w1", Config),
            ?assertEqual(~"w1", maps:get(world_id, State)),
            ChatConfig = maps:get(chat_config, State),
            ?assertEqual(true, maps:get(world, ChatConfig)),
            ?assertEqual(true, maps:get(zone, ChatConfig))
        end},
        {"init with empty config", fun() ->
            State = asobi_world_chat:init(~"w1", #{}),
            ?assertEqual(#{}, maps:get(chat_config, State))
        end}
    ].

integration_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"player join creates world chat channel", fun join_world_chat/0},
        {"player join creates zone chat channel", fun join_zone_chat/0},
        {"player leave cleans up channels", fun leave_cleans_up/0},
        {"zone change swaps zone chat", fun zone_change_swaps_chat/0},
        {"proximity chat subscribes to nearby zones", fun proximity_chat/0},
        {"no chat config means no channels", fun no_chat_config/0},
        {"a declared global channel is joined on world join and left on world leave",
            fun global_chat_joined_and_left/0},
        {"a player with no live session never joins as the calling process",
            fun no_live_session_does_not_join_as_caller/0}
    ]}.

setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    case whereis(asobi_chat_sup) of
        undefined ->
            {ok, Pid} = asobi_chat_sup:start_link(),
            unlink(Pid);
        _ ->
            ok
    end,
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    ok.

cleanup(_) ->
    meck:unload(asobi_repo),
    ok.

%% Registers THIS process under a shared-scope key, so leaving is not optional:
%% `nova_scope` and `{player, Id}` are global across every module in the run,
%% and a registration that outlives its test is lent to any later test using
%% the same id.
%%
%% This module was NOT the donor for the zone-integration false pass - every
%% `unregister_player()` here was paired, so a green run left nothing behind.
%% That was `asobi_match_server_tests`, which had two `_`-prefixed sessions on
%% the same id that were never killed at all. What this module had was the
%% failure path: these tests assert in the middle, and a failing assertion
%% skipped a trailing unregister. Hence `try ... after`.
with_registered_player(Fun) ->
    ok = pg:join(nova_scope, {player, ~"p1"}, self()),
    try
        Fun()
    after
        pg:leave(nova_scope, {player, ~"p1"}, self()),
        leave_chat_channels()
    end.

%% The bodies join this process to `{chat, ChannelId}` groups as a side effect
%% of `player_joined/3`, and only leave them on the success path. World-scoped
%% ids bound the damage, but the global tier deliberately carries NO world id
%% (widgrensit/asobi#299) - `global:general` is the single most shared key in
%% the system.
%%
%% The strand lasts for the rest of this MODULE, not the whole run: the eunit
%% runner is per module group and pg reaps its memberships when it dies. That
%% is still worth closing - a membership from one test was measured visible in
%% a later test of the same module - but the cross-MODULE vector is a spawned
%% session outliving its creator, not this.
%%
%% Drains rather than leaving once. `pg:join` twice registers twice and one
%% `pg:leave` removes one, and `global_chat_joined_and_left/0` deliberately
%% joins `global:general` through two worlds - so a single leave would
%% under-clean in exactly the case that motivates the sweep.
leave_chat_channels() ->
    Self = self(),
    lists:foreach(
        fun
            ({chat, _} = Group) -> drain_membership(Group, Self);
            (_Group) -> ok
        end,
        pg:which_groups(nova_scope)
    ).

drain_membership(Group, Self) ->
    case lists:member(Self, pg:get_members(nova_scope, Group)) of
        true ->
            _ = pg:leave(nova_scope, Group, Self),
            drain_membership(Group, Self);
        false ->
            ok
    end.

join_world_chat() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc1", #{chat => #{world => true}}),
        asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState),
        ChannelId = asobi_world_chat:channel_id(~"wc1", world, undefined),
        Members = pg:get_members(nova_scope, {chat, ChannelId}),
        ?assert(lists:member(self(), Members))
    end).

join_zone_chat() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc2", #{chat => #{zone => true}}),
        asobi_world_chat:player_joined(~"p1", {2, 3}, ChatState),
        ChannelId = asobi_world_chat:channel_id(~"wc2", zone, {2, 3}),
        Members = pg:get_members(nova_scope, {chat, ChannelId}),
        ?assert(lists:member(self(), Members))
    end).

leave_cleans_up() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc3", #{chat => #{world => true, zone => true}}),
        asobi_world_chat:player_joined(~"p1", {1, 1}, ChatState),
        asobi_world_chat:player_left(~"p1", {1, 1}, ChatState),
        WorldChannel = asobi_world_chat:channel_id(~"wc3", world, undefined),
        ZoneChannel = asobi_world_chat:channel_id(~"wc3", zone, {1, 1}),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, WorldChannel}))),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ZoneChannel})))
    end).

zone_change_swaps_chat() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc4", #{chat => #{zone => true, grid_size => 10}}),
        asobi_world_chat:player_joined(~"p1", {1, 1}, ChatState),
        OldChannel = asobi_world_chat:channel_id(~"wc4", zone, {1, 1}),
        ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, OldChannel}))),
        asobi_world_chat:player_zone_changed(~"p1", {1, 1}, {2, 2}, 10, ChatState),
        NewChannel = asobi_world_chat:channel_id(~"wc4", zone, {2, 2}),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, OldChannel}))),
        ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, NewChannel})))
    end).

proximity_chat() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc5", #{chat => #{proximity => 1, grid_size => 5}}),
        asobi_world_chat:player_joined(~"p1", {2, 2}, ChatState),
        Center = asobi_world_chat:channel_id(~"wc5", proximity, {2, 2}),
        Corner = asobi_world_chat:channel_id(~"wc5", proximity, {1, 1}),
        Far = asobi_world_chat:channel_id(~"wc5", proximity, {4, 4}),
        ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, Center}))),
        ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, Corner}))),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, Far})))
    end).

no_chat_config() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc6", #{}),
        asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState),
        WorldChannel = asobi_world_chat:channel_id(~"wc6", world, undefined),
        ZoneChannel = asobi_world_chat:channel_id(~"wc6", zone, {0, 0}),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, WorldChannel}))),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ZoneChannel})))
    end).

%% #299: the global tier carries no world id, so two worlds of the same game
%% resolve the same channel process.
global_chat_joined_and_left() ->
    with_registered_player(fun() ->
        ChatState = asobi_world_chat:init(~"wc8", #{chat => #{global => [~"general"]}}),
        ChatState2 = asobi_world_chat:init(~"wc9", #{chat => #{global => [~"general"]}}),
        ChannelId = asobi_world_chat:global_channel_id(~"general"),
        ?assertEqual(~"global:general", ChannelId),
        asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState),
        ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, ChannelId}))),
        asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState2),
        asobi_world_chat:player_left(~"p1", {0, 0}, ChatState2),
        asobi_world_chat:player_left(~"p1", {0, 0}, ChatState),
        ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ChannelId})))
    end).

global_channels_test_() ->
    [
        {"names are deduplicated", fun() ->
            ?assertEqual(
                [~"general", ~"trade"],
                asobi_world_chat:global_channels(#{global => [~"trade", ~"general", ~"trade"]})
            )
        end},
        {"malformed names are dropped", fun() ->
            ?assertEqual(
                [~"general"],
                asobi_world_chat:global_channels(#{
                    global => [~"general", ~"has:colon", ~"", "not-a-binary", 42]
                })
            )
        end},
        {"an over-long name is dropped", fun() ->
            Long = binary:copy(~"a", 65),
            ?assertEqual([], asobi_world_chat:global_channels(#{global => [Long]}))
        end},
        {"a non-list global is dropped", fun() ->
            ?assertEqual([], asobi_world_chat:global_channels(#{global => true}))
        end},
        {"no global key means no channels", fun() ->
            ?assertEqual([], asobi_world_chat:global_channels(#{world => true}))
        end}
    ].

%% Regression for widgrensit/asobi#277: find_player_pid/1 in this module used
%% to fall back to self() (the caller's own pid - asobi_world_server in
%% production) when a player had no live pg registration. Deliberately not
%% calling register_player/0 here - a player with no session must not join,
%% leave, or move any channel using the calling process's own pid.
no_live_session_does_not_join_as_caller() ->
    %% Same class as the two #277/#280 twins: this asserts the SESSION-LESS
    %% path, and `find_player_pid/1` takes the head of the group - so a leaked
    %% session under this id would be joined instead, and the assertion would
    %% still pass while the degraded path went untested.
    ok = asobi_test_helpers:assert_no_session(~"ghost"),
    ChatState = asobi_world_chat:init(~"wc7", #{
        chat => #{world => true, zone => true, proximity => 1, grid_size => 5}
    }),
    ok = asobi_world_chat:player_joined(~"ghost", {2, 2}, ChatState),
    WorldChannel = asobi_world_chat:channel_id(~"wc7", world, undefined),
    ZoneChannel = asobi_world_chat:channel_id(~"wc7", zone, {2, 2}),
    ProxChannel = asobi_world_chat:channel_id(~"wc7", proximity, {2, 2}),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, WorldChannel}))),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ZoneChannel}))),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ProxChannel}))),
    %% zone_changed and left must also degrade cleanly, not crash.
    ok = asobi_world_chat:player_zone_changed(~"ghost", {2, 2}, {3, 3}, 5, ChatState),
    ok = asobi_world_chat:player_left(~"ghost", {3, 3}, ChatState).
