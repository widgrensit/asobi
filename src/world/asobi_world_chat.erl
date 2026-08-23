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
%%             global => [~"general"], %% game-wide, spans every world (#299)
%%             world => true,          %% one channel for all players in the world
%%             zone => true,           %% auto-join/leave as players move between zones
%%             proximity => 2          %% chat with players within N zones (uses interest radius)
%%         }
%%     }
%% }}
%% ```
%%
%% Federation chat is handled separately by the social system.

-include_lib("kernel/include/logger.hrl").

-export([init/2]).
-export([player_joined/3, player_left/3, player_zone_changed/5]).
-export([channel_id/3, global_channel_id/1, global_channels/1]).

-define(MAX_GLOBAL_NAME_BYTES, 64).

-spec init(binary(), map()) -> map().
init(WorldId, Config) ->
    ChatConfig = maps:get(chat, Config, #{}),
    #{
        world_id => WorldId,
        chat_config => ChatConfig
    }.

-spec player_joined(binary(), {integer(), integer()}, map()) -> ok.
player_joined(PlayerId, ZoneCoords, #{world_id := WorldId, chat_config := ChatConfig}) ->
    case find_player_pid(PlayerId) of
        undefined ->
            %% asobi#277: no live session for this player - nothing to join
            %% to a chat channel. Falling back to self() here (as this used
            %% to) would have joined the world server's own pid instead.
            ok;
        PlayerPid ->
            case maps:get(world, ChatConfig, false) of
                true ->
                    ChannelId = channel_id(WorldId, world, undefined),
                    asobi_chat_channel:join(ChannelId, PlayerPid);
                false ->
                    ok
            end,
            join_globals(global_channels(ChatConfig), PlayerPid),
            join_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig),
            ok
    end.

-spec player_left(binary(), {integer(), integer()}, map()) -> ok.
player_left(PlayerId, ZoneCoords, #{world_id := WorldId, chat_config := ChatConfig}) ->
    case find_player_pid(PlayerId) of
        undefined ->
            %% asobi#277: routine on a real disconnect - the session is
            %% already gone from pg by the time leave runs. Nothing to
            %% remove from a chat channel.
            ok;
        PlayerPid ->
            case maps:get(world, ChatConfig, false) of
                true ->
                    ChannelId = channel_id(WorldId, world, undefined),
                    asobi_chat_channel:leave(ChannelId, PlayerPid);
                false ->
                    ok
            end,
            leave_globals(global_channels(ChatConfig), PlayerPid),
            leave_zone_chats(PlayerId, PlayerPid, WorldId, ZoneCoords, ChatConfig),
            ok
    end.

-spec player_zone_changed(
    binary(), {integer(), integer()}, {integer(), integer()}, non_neg_integer(), map()
) -> ok.
player_zone_changed(
    PlayerId, OldZoneCoords, NewZoneCoords, GridSize, #{
        world_id := WorldId, chat_config := ChatConfig
    }
) ->
    case find_player_pid(PlayerId) of
        undefined ->
            %% asobi#277: no live session - nothing to move between chat
            %% channels.
            ok;
        PlayerPid ->
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
                            asobi_chat_channel:leave(
                                channel_id(WorldId, proximity, Coords), PlayerPid
                            )
                        end,
                        LeaveProx
                    ),
                    lists:foreach(
                        fun(Coords) ->
                            asobi_chat_channel:join(
                                channel_id(WorldId, proximity, Coords), PlayerPid
                            )
                        end,
                        JoinProx
                    )
            end,
            ok
    end.

%% --- Channel ID generation ---

-spec channel_id(binary(), atom(), term()) -> binary().
channel_id(WorldId, world, _) ->
    iolist_to_binary([~"world:", WorldId]);
channel_id(WorldId, zone, {X, Y}) when is_integer(X), is_integer(Y) ->
    iolist_to_binary([~"zone:", WorldId, ~":", integer_to_binary(X), ~",", integer_to_binary(Y)]);
channel_id(WorldId, proximity, {X, Y}) when is_integer(X), is_integer(Y) ->
    iolist_to_binary([~"prox:", WorldId, ~":", integer_to_binary(X), ~",", integer_to_binary(Y)]).

-doc "Channel id of a game-wide chat channel. Deliberately carries no world id.".
-spec global_channel_id(binary()) -> binary().
global_channel_id(Name) when is_binary(Name) ->
    <<"global:", Name/binary>>.

-doc """
The game-wide channel names a chat config declares, deduplicated.

Shared with `asobi_game_modes:global_chat_channels/0`, which the chat ACL
consults, so a name is auto-joined here exactly when it is authorised there.
Malformed names are dropped loudly rather than silently minting a channel
nothing can join.
""".
%% Explicit recursion rather than lists:foreach/2, which erases the element
%% type just as the folds do - the channel name arrived as term().
-spec join_globals([binary()], pid()) -> ok.
join_globals([], _PlayerPid) ->
    ok;
join_globals([Name | Rest], PlayerPid) ->
    asobi_chat_channel:join(global_channel_id(Name), PlayerPid),
    join_globals(Rest, PlayerPid).

-spec leave_globals([binary()], pid()) -> ok.
leave_globals([], _PlayerPid) ->
    ok;
leave_globals([Name | Rest], PlayerPid) ->
    asobi_chat_channel:leave(global_channel_id(Name), PlayerPid),
    leave_globals(Rest, PlayerPid).

%% lists:sort/1 widens its result to [term()] under eqwalizer; the comprehension
%% re-narrows it, and never drops anything because the input is already
%% binaries. The sorted order is asserted by asobi_world_chat_tests - usort/1
%% sorted as well as deduped, and splitting the two has to keep both halves.
-spec sorted([binary()]) -> [binary()].
sorted(Names) -> [N || N <- lists:sort(Names), is_binary(N)].

%% Was the dedupe half of lists:usort/1.
-spec dedupe_names([binary()]) -> [binary()].
dedupe_names([]) -> [];
dedupe_names([N | Rest]) -> [N | dedupe_names([M || M <- Rest, M =/= N])].

-spec global_channels(term()) -> [binary()].
global_channels(#{global := Names}) when is_list(Names) ->
    %% is_binary inline as well as inside valid_global_name/1: eqwalizer cannot
    %% narrow through a call, so without it the list stays [term()] and every
    %% caller of this function widens with it.
    dedupe_names(sorted([Name || Name <- Names, is_binary(Name), valid_global_name(Name)]));
global_channels(#{global := Other}) ->
    ?LOG_WARNING(#{event => invalid_global_chat_config, value => Other}),
    [];
global_channels(_) ->
    [].

-spec valid_global_name(term()) -> boolean().
valid_global_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    case byte_size(Name) =< ?MAX_GLOBAL_NAME_BYTES andalso is_name_chars(Name) of
        true ->
            true;
        false ->
            ?LOG_WARNING(#{event => invalid_global_chat_channel_name, name => Name}),
            false
    end;
valid_global_name(Name) ->
    ?LOG_WARNING(#{event => invalid_global_chat_channel_name, name => Name}),
    false.

is_name_chars(<<>>) -> true;
is_name_chars(<<C, Rest/binary>>) when C >= $a, C =< $z -> is_name_chars(Rest);
is_name_chars(<<C, Rest/binary>>) when C >= $A, C =< $Z -> is_name_chars(Rest);
is_name_chars(<<C, Rest/binary>>) when C >= $0, C =< $9 -> is_name_chars(Rest);
is_name_chars(<<C, Rest/binary>>) when C =:= $_; C =:= $-; C =:= $. -> is_name_chars(Rest);
is_name_chars(_) -> false.

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

%% Callers feed a pos_to_zone/3 result; ring/3 owns the malformed-centre
%% degrade (widgrensit/asobi#248).
proximity_zones(Coords, Radius, GridSize) ->
    asobi_zone_grid:ring(Coords, Radius, GridSize).

%% asobi#277: used to fall back to self() (the caller's own pid, which is
%% asobi_world_server since that's who calls player_joined/left/zone_changed)
%% when a player had no live pg registration. All three call sites now check
%% for undefined instead.
-spec find_player_pid(binary()) -> pid() | undefined.
find_player_pid(PlayerId) ->
    case pg:get_members(nova_scope, {player, PlayerId}) of
        [Pid | _] -> Pid;
        [] -> undefined
    end.

ignore_result(_) -> ok.
