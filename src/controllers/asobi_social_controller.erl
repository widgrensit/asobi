-module(asobi_social_controller).

-include_lib("kura/include/kura.hrl").

-export([
    friends/1,
    add_friend/1,
    update_friend/1,
    remove_friend/1,
    create_group/1,
    show_group/1,
    join_group/1,
    leave_group/1
]).

%% --- Friends ---

-spec friends(cowboy_req:req()) -> {json, map()}.
friends(#{auth_data := #{player_id := PlayerId}, qs := Qs} = _Req) when
    is_binary(PlayerId), is_binary(Qs)
->
    Params = cow_qs:parse_qs(Qs),
    Q0 = kura_query:where(kura_query:from(asobi_friendship), {player_id, PlayerId}),
    Q1 =
        case proplists:get_value(~"status", Params) of
            undefined -> Q0;
            Status -> kura_query:where(Q0, {status, Status})
        end,
    Limit = qs_integer(~"limit", Params, 50),
    Q2 = kura_query:limit(Q1, Limit),
    {ok, Friendships} = asobi_repo:all(Q2),
    {json, #{friends => Friendships}}.

-spec add_friend(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
add_friend(#{json := #{~"friend_id" := FriendId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    CS = asobi_friendship:changeset(#{}, #{
        player_id => PlayerId,
        friend_id => FriendId,
        status => ~"pending"
    }),
    case asobi_repo:insert(CS) of
        {ok, Friendship} ->
            {json, 200, #{}, Friendship};
        {error, CS1} when is_record(CS1, kura_changeset) ->
            {json, 422, #{}, #{errors => kura_changeset:traverse_errors(CS1, fun(_F, M) -> M end)}}
    end.

-spec update_friend(cowboy_req:req()) -> {json, map()} | {status, integer()}.
update_friend(
    #{
        bindings := #{~"friend_id" := FriendId},
        json := #{~"status" := Status},
        auth_data := #{player_id := PlayerId}
    } = _Req
) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_friendship), {player_id, FriendId}),
        {friend_id, PlayerId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Friendship]} ->
            CS = asobi_friendship:changeset(Friendship, #{status => Status}),
            {ok, Updated} = asobi_repo:update(CS),
            {json, Updated};
        _ ->
            {status, 404}
    end.

-spec remove_friend(cowboy_req:req()) -> {json, map()} | {status, integer()}.
remove_friend(
    #{bindings := #{~"friend_id" := FriendId}, auth_data := #{player_id := PlayerId}} = _Req
) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_friendship), {player_id, PlayerId}),
        {friend_id, FriendId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Friendship]} ->
            _ = asobi_repo:delete(asobi_friendship, Friendship),
            {json, #{success => true}};
        _ ->
            {status, 404}
    end.

%% --- Groups ---

-spec create_group(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
create_group(#{json := Params, auth_data := #{player_id := PlayerId}} = _Req) when
    is_map(Params), is_binary(PlayerId)
->
    GroupParams = #{
        name => maps:get(~"name", Params),
        description => maps:get(~"description", Params, undefined),
        max_members => maps:get(~"max_members", Params, 50),
        open => maps:get(~"open", Params, false),
        creator_id => PlayerId
    },
    CS = asobi_group:changeset(#{}, GroupParams),
    case asobi_repo:insert(CS) of
        {ok, Group} ->
            MemberCS = kura_changeset:cast(
                asobi_group_member,
                #{},
                #{
                    group_id => maps:get(id, Group),
                    player_id => PlayerId,
                    role => ~"owner",
                    joined_at => calendar:universal_time()
                },
                [group_id, player_id, role, joined_at]
            ),
            _ = asobi_repo:insert(MemberCS),
            {json, 200, #{}, Group};
        {error, CS1} when is_record(CS1, kura_changeset) ->
            {json, 422, #{}, #{errors => kura_changeset:traverse_errors(CS1, fun(_F, M) -> M end)}}
    end.

-spec show_group(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show_group(#{bindings := #{~"id" := GroupId}} = _Req) ->
    case asobi_repo:get(asobi_group, GroupId) of
        {ok, Group} -> {json, Group};
        {error, not_found} -> {status, 404}
    end.

-spec join_group(cowboy_req:req()) -> {json, map()} | {json, integer(), map(), map()}.
join_group(#{bindings := #{~"id" := GroupId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    CS = kura_changeset:cast(
        asobi_group_member,
        #{},
        #{
            group_id => GroupId,
            player_id => PlayerId,
            role => ~"member",
            joined_at => calendar:universal_time()
        },
        [group_id, player_id, role, joined_at]
    ),
    case asobi_repo:insert(CS) of
        {ok, _Member} ->
            {json, 200, #{}, #{success => true, group_id => GroupId}};
        {error, _} ->
            {json, 409, #{}, #{error => ~"already_member"}}
    end.

-spec leave_group(cowboy_req:req()) -> {json, integer(), map(), map()}.
leave_group(#{bindings := #{~"id" := GroupId}, auth_data := #{player_id := PlayerId}} = _Req) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_group_member), {group_id, GroupId}),
        {player_id, PlayerId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Member]} ->
            _ = asobi_repo:delete(asobi_group_member, Member),
            {json, 200, #{}, #{success => true}};
        _ ->
            {json, 200, #{}, #{success => true}}
    end.

qs_integer(Key, Params, Default) ->
    case proplists:get_value(Key, Params) of
        V when is_binary(V) -> binary_to_integer(V);
        _ -> Default
    end.
