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
        {"no chat config means no channels", fun no_chat_config/0}
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

register_player() ->
    pg:join(nova_scope, {player, ~"p1"}, self()).

unregister_player() ->
    pg:leave(nova_scope, {player, ~"p1"}, self()).

join_world_chat() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc1", #{chat => #{world => true}}),
    asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState),
    ChannelId = asobi_world_chat:channel_id(~"wc1", world, undefined),
    Members = pg:get_members(nova_scope, {chat, ChannelId}),
    ?assert(lists:member(self(), Members)),
    unregister_player().

join_zone_chat() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc2", #{chat => #{zone => true}}),
    asobi_world_chat:player_joined(~"p1", {2, 3}, ChatState),
    ChannelId = asobi_world_chat:channel_id(~"wc2", zone, {2, 3}),
    Members = pg:get_members(nova_scope, {chat, ChannelId}),
    ?assert(lists:member(self(), Members)),
    unregister_player().

leave_cleans_up() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc3", #{chat => #{world => true, zone => true}}),
    asobi_world_chat:player_joined(~"p1", {1, 1}, ChatState),
    asobi_world_chat:player_left(~"p1", {1, 1}, ChatState),
    WorldChannel = asobi_world_chat:channel_id(~"wc3", world, undefined),
    ZoneChannel = asobi_world_chat:channel_id(~"wc3", zone, {1, 1}),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, WorldChannel}))),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ZoneChannel}))),
    unregister_player().

zone_change_swaps_chat() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc4", #{chat => #{zone => true, grid_size => 10}}),
    asobi_world_chat:player_joined(~"p1", {1, 1}, ChatState),
    OldChannel = asobi_world_chat:channel_id(~"wc4", zone, {1, 1}),
    ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, OldChannel}))),
    asobi_world_chat:player_zone_changed(~"p1", {1, 1}, {2, 2}, 10, ChatState),
    NewChannel = asobi_world_chat:channel_id(~"wc4", zone, {2, 2}),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, OldChannel}))),
    ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, NewChannel}))),
    unregister_player().

proximity_chat() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc5", #{chat => #{proximity => 1, grid_size => 5}}),
    asobi_world_chat:player_joined(~"p1", {2, 2}, ChatState),
    Center = asobi_world_chat:channel_id(~"wc5", proximity, {2, 2}),
    Corner = asobi_world_chat:channel_id(~"wc5", proximity, {1, 1}),
    Far = asobi_world_chat:channel_id(~"wc5", proximity, {4, 4}),
    ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, Center}))),
    ?assert(lists:member(self(), pg:get_members(nova_scope, {chat, Corner}))),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, Far}))),
    unregister_player().

no_chat_config() ->
    register_player(),
    ChatState = asobi_world_chat:init(~"wc6", #{}),
    asobi_world_chat:player_joined(~"p1", {0, 0}, ChatState),
    WorldChannel = asobi_world_chat:channel_id(~"wc6", world, undefined),
    ZoneChannel = asobi_world_chat:channel_id(~"wc6", zone, {0, 0}),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, WorldChannel}))),
    ?assertNot(lists:member(self(), pg:get_members(nova_scope, {chat, ZoneChannel}))),
    unregister_player().
