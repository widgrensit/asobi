-module(asobi_chat_acl).
-moduledoc """
Authorisation policy for chat channels.

Channel ID schemes:
  dm:<A>:<B>                 - A and B are the only allowed readers, and B
                                (the participant that isn't the caller) must
                                resolve to a real player id (see #305 below)
  world:<WorldId>            - must currently be joined to the world
  zone:<WorldId>:<X>,<Y>     - must currently be joined to the world
  prox:<WorldId>:<X>,<Y>     - must currently be joined to the world
  room:<GroupId>             - the `room:` prefix is stripped; GroupId must
                                be a canonical lowercase-hyphenated uuid (the
                                shape `asobi_id:generate/0` always emits) and
                                the caller must be a member of that group
  <anything else>            - treated as a group_id; must be a group member

A `room:` channel is closed by default: a group id that isn't a canonical
uuid is denied outright (rather than falling through to a membership lookup
that merely happens to miss), and a group id that doesn't exist or that the
caller isn't a member of yields `false`. Requiring the canonical uuid shape
also prevents one group from acquiring unbounded alias channel ids (dashes
stripped, different case, padded/garbage-prefixed hex) that a lossy uuid
decode downstream would otherwise all resolve to the same group - each alias
would otherwise be a distinct, unmoderated channel process.

#306: for a group with `open=true`, membership (checked here) is easy to
get - anyone can join without an invite - but membership is still what
gates reading. Once joined, a member sees the group's full retained
history, including messages sent before they joined; this is intentional
(see `guides/websocket-protocol.md`), not a gap to close here.

#305: `dm:<A>:<B>` had the same unbounded-minting shape as the pre-fix
`room:` scheme — `classify/1` authorised `dm:<self>:<anything>` for any
value of `<anything>`, and `chat.send`/`send_message/3` start a channel
process on demand with no prior `chat.join`, so `MAX_JOINED_CHANNELS_PER_CONN`
never bounded it. The other participant must now resolve to a real,
currently-known player id (checked against the `players` table via
`asobi_repo:get/2`, the same lookup `asobi_social_controller` already uses
to verify a friend id is real). This bounds minting to O(known players)
instead of unbounded arbitrary strings. Checking "is a real player" rather
than "is currently online" is deliberate: the other participant is very
often offline (that's when you send someone a DM), so an online-only check
would break ordinary DMing, not just close the abuse case.

Shared by `asobi_chat_controller` (HTTP history) and `asobi_ws_handler`
(WebSocket `chat.join` / `chat.send`). Keeping a single source of truth
prevents the WS path from drifting and silently allowing DM eavesdropping.
""".

-include_lib("kernel/include/logger.hrl").

-export([authorized/2, validate_channel_id/1]).

-define(MAX_CHANNEL_ID_BYTES, 256).

-spec authorized(binary(), binary()) -> boolean().
authorized(ChannelId, PlayerId) when is_binary(ChannelId), is_binary(PlayerId) ->
    case classify(ChannelId) of
        deny ->
            false;
        {dm, A, B} ->
            dm_authorized(PlayerId, A, B);
        {world, WorldId} ->
            player_in_world(PlayerId, WorldId);
        {group, GroupId} ->
            is_group_member(PlayerId, GroupId)
    end.

%% #305: PlayerId must be one of the two named participants, and the OTHER
%% participant must resolve to a real, currently-known player - otherwise
%% PlayerId could mint `dm:<self>:<anything>` for any value of `<anything>`.
-spec dm_authorized(binary(), binary(), binary()) -> boolean().
dm_authorized(PlayerId, PlayerId, Other) ->
    is_known_player(Other);
dm_authorized(PlayerId, Other, PlayerId) ->
    is_known_player(Other);
dm_authorized(_PlayerId, _A, _B) ->
    false.

-spec is_known_player(binary()) -> boolean().
is_known_player(PlayerId) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, _} -> true;
        {error, _} -> false
    end.

-doc """
Validate a channel id shape before it is used at all: bounded length and
one of the known channel-id prefixes. Shared by the WS `chat.join`/`chat.send`
path and the HTTP chat-history path so neither can be tricked into treating
an unprefixed bare id (which `classify/1`'s catch-all clause would otherwise
happily route to a group lookup) as a valid channel id.
""".
-spec validate_channel_id(binary()) -> boolean().
validate_channel_id(ChannelId) when is_binary(ChannelId) ->
    byte_size(ChannelId) > 0 andalso
        byte_size(ChannelId) =< ?MAX_CHANNEL_ID_BYTES andalso
        valid_channel_prefix(ChannelId).

valid_channel_prefix(<<"dm:", _/binary>>) -> true;
valid_channel_prefix(<<"world:", _/binary>>) -> true;
valid_channel_prefix(<<"zone:", _/binary>>) -> true;
valid_channel_prefix(<<"prox:", _/binary>>) -> true;
valid_channel_prefix(<<"room:", _/binary>>) -> true;
valid_channel_prefix(_) -> false.

-spec classify(binary()) ->
    {dm, binary(), binary()} | {world, binary()} | {group, binary()} | deny.
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
classify(<<"room:", GroupId/binary>>) ->
    case is_uuid(GroupId) of
        true -> {group, GroupId};
        false -> deny
    end;
classify(ChannelId) ->
    {group, ChannelId}.

-spec is_uuid(binary()) -> boolean().
is_uuid(<<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-, E:12/binary>>) ->
    lists:all(fun is_hex/1, binary_to_list(<<A/binary, B/binary, C/binary, D/binary, E/binary>>));
is_uuid(_) ->
    false.

is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(_) -> false.

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
        {ok, [_ | _]} ->
            true;
        {ok, []} ->
            false;
        {error, Reason} ->
            ?LOG_WARNING(#{event => group_member_lookup_failed, reason => Reason}),
            false
    end.
