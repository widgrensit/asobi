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
    leave_group/1,
    update_member_role/1,
    kick_member/1,
    list_members/1,
    update_group/1
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
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    Q2 = kura_query:limit(Q1, Limit),
    {ok, Friendships} = asobi_repo:all(Q2),
    {json, #{friends => Friendships}}.

-type response() ::
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}.

-spec add_friend(cowboy_req:req()) -> response().
add_friend(
    #{json := #{~"friend_id" := FriendId}, auth_data := #{player_id := PlayerId}} = _Req
) when
    is_binary(FriendId), is_binary(PlayerId)
->
    %% F-23: reject self-add and verify the target player actually exists.
    case FriendId =:= PlayerId of
        true ->
            {asobi_error, ~"social.cannot_friend_self"};
        false ->
            case asobi_repo:get(asobi_player, FriendId) of
                {error, not_found} ->
                    {asobi_error, ~"social.friend_not_found"};
                {ok, _} ->
                    insert_friendship(PlayerId, FriendId)
            end
    end;
add_friend(_Req) ->
    {asobi_error, ~"invalid_payload"}.

%% F-23: idempotent — re-adding an existing friendship returns the row
%% rather than producing an opaque insert error.
-spec insert_friendship(binary(), binary()) -> response().
insert_friendship(PlayerId, FriendId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_friendship), {player_id, PlayerId}),
        {friend_id, FriendId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Existing | _]} ->
            {json, 200, #{}, Existing};
        _ ->
            CS = asobi_friendship:changeset(#{}, #{
                player_id => PlayerId,
                friend_id => FriendId,
                status => ~"pending"
            }),
            case asobi_repo:insert(CS) of
                {ok, Friendship} ->
                    {json, 200, #{}, Friendship};
                {error, CS1} when is_record(CS1, kura_changeset) ->
                    changeset_errors(CS1);
                {error, _Other} ->
                    {asobi_error, ~"social.already_friend"}
            end
    end.

-spec update_friend(cowboy_req:req()) -> response().
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
            {asobi_error, ~"social.friendship_not_found"}
    end.

-spec remove_friend(cowboy_req:req()) -> response().
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
            {asobi_error, ~"social.friendship_not_found"}
    end.

%% --- Groups ---

-spec create_group(cowboy_req:req()) -> response().
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
            changeset_errors(CS1)
    end.

-spec show_group(cowboy_req:req()) -> response().
show_group(#{bindings := #{~"id" := GroupId}} = _Req) ->
    case asobi_repo:get(asobi_group, GroupId) of
        {ok, Group} -> {json, Group};
        {error, not_found} -> {asobi_error, ~"social.group_not_found"}
    end.

-spec join_group(cowboy_req:req()) -> response().
join_group(
    #{bindings := #{~"id" := GroupId}, auth_data := #{player_id := PlayerId}} = _Req
) when is_binary(GroupId), is_binary(PlayerId) ->
    %% F-12: closed groups (`open=false`) require an invite (not implemented yet
    %% — for now reject with 403); enforce `max_members` via a count query.
    case asobi_repo:get(asobi_group, GroupId) of
        {error, not_found} ->
            {asobi_error, ~"social.group_not_found"};
        {ok, Group} ->
            case maps:get(open, Group, false) of
                false ->
                    {asobi_error, ~"social.group_closed"};
                true ->
                    Max = maps:get(max_members, Group, 50),
                    case current_member_count(GroupId) >= Max of
                        true ->
                            {asobi_error, ~"social.group_full"};
                        false ->
                            insert_group_member(GroupId, PlayerId)
                    end
            end
    end.

-spec insert_group_member(binary(), binary()) -> response().
insert_group_member(GroupId, PlayerId) ->
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
            {asobi_error, ~"social.already_member"}
    end.

-spec current_member_count(binary()) -> non_neg_integer().
current_member_count(GroupId) ->
    Q = kura_query:where(kura_query:from(asobi_group_member), {group_id, GroupId}),
    case asobi_repo:all(Q) of
        {ok, Members} when is_list(Members) -> length(Members);
        _ -> 0
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

%% --- Group Management ---

-spec list_members(cowboy_req:req()) -> response().
list_members(#{bindings := #{~"id" := GroupId}} = _Req) ->
    Q = kura_query:where(kura_query:from(asobi_group_member), {group_id, GroupId}),
    case asobi_repo:all(Q) of
        {ok, Members} -> {json, #{members => Members}};
        _ -> {asobi_error, ~"social.group_not_found"}
    end.

-spec update_member_role(cowboy_req:req()) -> response().
update_member_role(#{
    bindings := #{~"id" := GroupId, ~"player_id" := TargetPlayerId},
    json := #{~"role" := NewRole},
    auth_data := #{player_id := ActorId}
}) when is_binary(NewRole) ->
    case asobi_group_roles:valid_role(NewRole) of
        false ->
            {asobi_error, ~"social.invalid_role"};
        true ->
            case {get_member(GroupId, ActorId), get_member(GroupId, TargetPlayerId)} of
                {{ok, #{role := ActorRole}}, {ok, #{role := TargetRole} = Target}} ->
                    case asobi_group_roles:can_promote(ActorRole, TargetRole, NewRole) of
                        true ->
                            CS = kura_changeset:cast(
                                asobi_group_member, Target, #{role => NewRole}, [role]
                            ),
                            {ok, Updated} = asobi_repo:update(CS),
                            {json, 200, #{}, Updated};
                        false ->
                            {asobi_error, ~"forbidden"}
                    end;
                _ ->
                    {asobi_error, ~"social.member_not_found"}
            end
    end.

-spec kick_member(cowboy_req:req()) -> response().
kick_member(#{
    bindings := #{~"id" := GroupId, ~"player_id" := TargetPlayerId},
    auth_data := #{player_id := ActorId}
}) ->
    case {get_member(GroupId, ActorId), get_member(GroupId, TargetPlayerId)} of
        {{ok, #{role := ActorRole}}, {ok, #{role := TargetRole} = Target}} ->
            case asobi_group_roles:can_kick(ActorRole, TargetRole) of
                true ->
                    _ = asobi_repo:delete(asobi_group_member, Target),
                    {json, 200, #{}, #{success => true}};
                false ->
                    {asobi_error, ~"forbidden"}
            end;
        _ ->
            {asobi_error, ~"social.member_not_found"}
    end.

-spec update_group(cowboy_req:req()) -> response().
update_group(#{
    bindings := #{~"id" := GroupId},
    json := Params,
    auth_data := #{player_id := ActorId}
}) when is_map(Params) ->
    case get_member(GroupId, ActorId) of
        {ok, #{role := Role}} ->
            case asobi_group_roles:can_update_group(Role) of
                true ->
                    case asobi_repo:get(asobi_group, GroupId) of
                        {ok, Group} ->
                            Updates = maps:with(
                                [~"name", ~"description", ~"max_members", ~"open"], Params
                            ),
                            Atomized = atomize_keys(maps:to_list(Updates)),
                            CS = asobi_group:changeset(Group, Atomized),
                            {ok, Updated} = asobi_repo:update(CS),
                            {json, 200, #{}, Updated};
                        _ ->
                            {asobi_error, ~"social.group_not_found"}
                    end;
                false ->
                    {asobi_error, ~"forbidden"}
            end;
        _ ->
            {asobi_error, ~"forbidden"}
    end.

%% --- Internal ---

%% `errors` was the whole body before the shared object existed and stays a
%% top-level key; it is the object's `details` too (asobi_error:legacy/2).
-spec changeset_errors(#kura_changeset{}) -> {json, integer(), map(), map()}.
changeset_errors(CS) ->
    Errors = kura_changeset:traverse_errors(CS, fun(_F, M) -> M end),
    asobi_error:legacy(~"validation_failed", #{errors => Errors}).

get_member(GroupId, PlayerId) ->
    Q = kura_query:where(
        kura_query:where(kura_query:from(asobi_group_member), {group_id, GroupId}),
        {player_id, PlayerId}
    ),
    case asobi_repo:all(Q) of
        {ok, [Member]} -> {ok, Member};
        _ -> {error, not_found}
    end.

-spec atomize_keys([{term(), term()}]) -> #{atom() => term()}.
atomize_keys([]) ->
    #{};
atomize_keys([{K, V} | Rest]) when is_binary(K) ->
    Acc = atomize_keys(Rest),
    Acc#{binary_to_existing_atom(K) => V};
atomize_keys([_ | Rest]) ->
    atomize_keys(Rest).
