-module(asobi_world_chat).

%% Manages chat channel lifecycle for world instances.
%%
%% Chat channels are configured per game mode:
%%
%% ```erlang
%% {game_modes, #{
%%     ~"galaxy" => #{
%%         type => world,
%%         chat => #{
%%             world => true,       %% global channel for all players in the world
%%             zone => true,        %% auto-join/leave as players move between zones
%%             proximity => 2       %% chat with players within N zones (uses interest radius)
%%         }
%%     }
%% }}
%% ```
%%
%% Federation chat is handled separately by the social system.

-export([init/2]).
-export([player_joined/3, player_left/3, player_zone_changed/5]).
-export([channel_id/3]).

-spec init(binary(), map()) -> map().
init(WorldId, Config) ->
    ChatConfig = maps:get(chat, Config, #{}),
    #{
        world_id => WorldId,
        chat_config => ChatConfig
    }.

-spec player_joined(binary(), {integer(), integer()}, map()) -> ok.
player_joined(PlayerId, ZoneCoords, #{world_id := WorldId, chat_config := ChatConfig}) ->
    PlayerPid = find_player_pid(PlayerId),
    case maps:get(world, ChatConfig, false) of
        true ->
            ChannelId = channel_id(WorldId, world, undefined),
            asobi_chat_channel:join(ChannelId, PlayerPid);
        false ->
            ok
    end,
    join_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig),
    ok.

-spec player_left(binary(), {integer(), integer()}, map()) -> ok.
player_left(PlayerId, ZoneCoords, #{world_id := WorldId, chat_config := ChatConfig}) ->
    PlayerPid = find_player_pid(PlayerId),
    case maps:get(world, ChatConfig, false) of
        true ->
            ChannelId = channel_id(WorldId, world, undefined),
            asobi_chat_channel:leave(ChannelId, PlayerPid);
        false ->
            ok
    end,
    leave_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig),
    ok.

-spec player_zone_changed(
    binary(), {integer(), integer()}, {integer(), integer()}, non_neg_integer(), map()
) -> ok.
player_zone_changed(
    PlayerId, OldZoneCoords, NewZoneCoords, GridSize, #{
        world_id := WorldId, chat_config := ChatConfig
    }
) ->
    PlayerPid = find_player_pid(PlayerId),
    case maps:get(zone, ChatConfig, false) of
        true ->
            OldChannelId = channel_id(WorldId, zone, OldZoneCoords),
            NewChannelId = channel_id(WorldId, zone, NewZoneCoords),
            asobi_chat_channel:leave(OldChannelId, PlayerPid),
            asobi_chat_channel:join(NewChannelId, PlayerPid);
        false ->
            ok
    end,
    case maps:get(proximity, ChatConfig, false) of
        false ->
            ok;
        Radius when is_integer(Radius) ->
            OldProx = proximity_zones(OldZoneCoords, Radius, GridSize),
            NewProx = proximity_zones(NewZoneCoords, Radius, GridSize),
            LeaveProx = OldProx -- NewProx,
            JoinProx = NewProx -- OldProx,
            lists:foreach(
                fun(Coords) ->
                    asobi_chat_channel:leave(channel_id(WorldId, proximity, Coords), PlayerPid)
                end,
                LeaveProx
            ),
            lists:foreach(
                fun(Coords) ->
                    asobi_chat_channel:join(channel_id(WorldId, proximity, Coords), PlayerPid)
                end,
                JoinProx
            )
    end,
    ok.

%% --- Channel ID generation ---

-spec channel_id(binary(), atom(), term()) -> binary().
channel_id(WorldId, world, _) ->
    iolist_to_binary([~"world:", WorldId]);
channel_id(WorldId, zone, {X, Y}) when is_integer(X), is_integer(Y) ->
    iolist_to_binary([~"zone:", WorldId, ~":", integer_to_binary(X), ~",", integer_to_binary(Y)]);
channel_id(WorldId, proximity, {X, Y}) when is_integer(X), is_integer(Y) ->
    iolist_to_binary([~"prox:", WorldId, ~":", integer_to_binary(X), ~",", integer_to_binary(Y)]).

%% --- Internal ---

join_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig) ->
    case maps:get(zone, ChatConfig, false) of
        true ->
            asobi_chat_channel:join(channel_id(WorldId, zone, ZoneCoords), PlayerPid);
        false ->
            ok
    end,
    case maps:get(proximity, ChatConfig, false) of
        false ->
            ok;
        Radius when is_integer(Radius) ->
            GridSize = maps:get(grid_size, ChatConfig, 10),
            Zones = proximity_zones(ZoneCoords, Radius, GridSize),
            lists:foreach(
                fun(Coords) ->
                    asobi_chat_channel:join(channel_id(WorldId, proximity, Coords), PlayerPid)
                end,
                Zones
            )
    end,
    ignore_result(PlayerId).

leave_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig) ->
    case maps:get(zone, ChatConfig, false) of
        true ->
            asobi_chat_channel:leave(channel_id(WorldId, zone, ZoneCoords), PlayerPid);
        false ->
            ok
    end,
    case maps:get(proximity, ChatConfig, false) of
        false ->
            ok;
        Radius when is_integer(Radius) ->
            GridSize = maps:get(grid_size, ChatConfig, 10),
            Zones = proximity_zones(ZoneCoords, Radius, GridSize),
            lists:foreach(
                fun(Coords) ->
                    asobi_chat_channel:leave(channel_id(WorldId, proximity, Coords), PlayerPid)
                end,
                Zones
            )
    end,
    ignore_result(PlayerId).

proximity_zones({ZX, ZY}, Radius, GridSize) when is_integer(ZX), is_integer(ZY) ->
    [
        {X, Y}
     || X <- lists:seq(clamp_lo(ZX - Radius), min(GridSize - 1, ZX + Radius)),
        Y <- lists:seq(clamp_lo(ZY - Radius), min(GridSize - 1, ZY + Radius))
    ].

-spec clamp_lo(integer()) -> non_neg_integer().
clamp_lo(N) when N < 0 -> 0;
clamp_lo(N) -> N.

find_player_pid(PlayerId) ->
    case pg:get_members(nova_scope, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> self()
    end.

ignore_result(_) -> ok.
