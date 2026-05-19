-module(asobi_chat_acl).
-moduledoc """
Authorisation policy for chat channels.

Channel ID schemes:
  dm:<A>:<B>                 - A and B are the only allowed readers
  world:<WorldId>            - must currently be joined to the world
  zone:<WorldId>:<X>,<Y>     - must currently be joined to the world
  prox:<WorldId>:<X>,<Y>     - must currently be joined to the world
  <anything else>            - treated as a group_id; must be a group member

Shared by `asobi_chat_controller` (HTTP history) and `asobi_ws_handler`
(WebSocket `chat.join` / `chat.send`). Keeping a single source of truth
prevents the WS path from drifting and silently allowing DM eavesdropping.
""".

-export([authorized/2]).

-spec authorized(binary(), binary()) -> boolean().
authorized(ChannelId, PlayerId) when is_binary(ChannelId), is_binary(PlayerId) ->
    case classify(ChannelId) of
        {dm, A, B} ->
            PlayerId =:= A orelse PlayerId =:= B;
        {world, WorldId} ->
            player_in_world(PlayerId, WorldId);
        {group, GroupId} ->
            is_group_member(PlayerId, GroupId)
    end.

-spec classify(binary()) -> {dm, binary(), binary()} | {world, binary()} | {group, binary()}.
classify(<<"dm:", Rest/binary>>) ->
    case binary:split(Rest, ~":", [global]) of
        [A, B] when byte_size(A) > 0, byte_size(B) > 0 -> {dm, A, B};
        _ -> {group, <<"dm:", Rest/binary>>}
    end;
classify(<<"world:", WorldId/binary>>) when byte_size(WorldId) > 0 ->
    {world, WorldId};
classify(<<"zone:", Rest/binary>>) ->
    {world, take_until_colon(Rest)};
classify(<<"prox:", Rest/binary>>) ->
    {world, take_until_colon(Rest)};
classify(ChannelId) ->
    {group, ChannelId}.

-spec take_until_colon(binary()) -> binary().
take_until_colon(Bin) ->
    case binary:split(Bin, ~":") of
        [Head, _] -> Head;
        [Head] -> Head
    end.

-spec player_in_world(binary(), binary()) -> boolean().
player_in_world(PlayerId, WorldId) ->
    case asobi_world_server:whereis(WorldId) of
        {ok, Pid} ->
            try asobi_world_server:get_info(Pid) of
                #{players := Players} when is_list(Players) ->
                    lists:member(PlayerId, Players);
                _ ->
                    false
            catch
                _:_ -> false
            end;
        error ->
            false
    end.

-spec is_group_member(binary(), binary()) -> boolean().
is_group_member(PlayerId, GroupId) ->
    Q = kura_query:where(
        kura_query:where(
            kura_query:from(asobi_group_member),
            {group_id, GroupId}
        ),
        {player_id, PlayerId}
    ),
    case asobi_repo:all(Q) of
        {ok, [_ | _]} -> true;
        _ -> false
    end.
