-module(asobi_chat_controller).

-export([history/1]).

-define(MAX_HISTORY_LIMIT, 200).
-define(DEFAULT_HISTORY_LIMIT, 50).

-spec history(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()} | {status, 403}.
history(
    #{
        bindings := #{~"channel_id" := ChannelId},
        qs := Qs,
        auth_data := #{player_id := PlayerId}
    } = _Req
) when
    is_binary(ChannelId), is_binary(Qs), is_binary(PlayerId)
->
    case authorized(ChannelId, PlayerId) of
        true ->
            Params = cow_qs:parse_qs(Qs),
            Limit = asobi_qs:integer(
                ~"limit", Params, ?DEFAULT_HISTORY_LIMIT, 1, ?MAX_HISTORY_LIMIT
            ),
            Q = kura_query:limit(
                kura_query:order_by(
                    kura_query:where(kura_query:from(asobi_chat_message), {channel_id, ChannelId}),
                    [{sent_at, desc}]
                ),
                Limit
            ),
            {ok, Messages} = asobi_repo:all(Q),
            {json, #{messages => lists:reverse(Messages)}};
        false ->
            {status, 403}
    end;
history(_Req) ->
    {json, 400, #{}, #{error => ~"invalid_request"}}.

%% Channel ID schemes (see asobi_dm:channel_id/2 and asobi_world_chat:channel_id/3):
%%   dm:<A>:<B>                     — A and B are the only allowed readers
%%   world:<WorldId>                — must be currently joined to the world
%%   zone:<WorldId>:<X>,<Y>         — must be currently joined to the world
%%   prox:<WorldId>:<X>,<Y>         — must be currently joined to the world
%%   <anything else>                — treated as a group_id; must be a group member
-spec authorized(binary(), binary()) -> boolean().
authorized(ChannelId, PlayerId) ->
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
