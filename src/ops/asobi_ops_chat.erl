-module(asobi_ops_chat).
-moduledoc """
Chat reads for the ops plane: the live channel list, and one channel's
messages.

Two different sources, and they answer two different questions. The channel
list is process state - which rooms exist right now and how many players are
in them - so it is sorted and paged in memory like the matchmaker queue. The
message history is in Postgres and is paged by the database like every other
list here, because moderation means reading past the last screenful.

Searching message content is the reason this endpoint exists rather than a
raw `LIMIT`: an operator acting on a report needs to find one message, and
the console this replaces could only offer the newest fifty.
""".

-include_lib("kura/include/kura.hrl").

-export([channels/1, messages_query/2]).
-export([project_channel/1, project_message/1]).
-export([channels_sortable/0, messages_sortable/0]).

-define(CHANNELS_SORTABLE, [
    {~"channel_id", channel_id},
    {~"members", members}
]).

-define(MESSAGES_SORTABLE, [
    {~"id", id},
    {~"channel_type", channel_type},
    {~"sender_id", sender_id},
    {~"sent_at", sent_at}
]).

-define(MESSAGES_FILTERS, [
    {~"sender_id", sender_id, uuid},
    {~"channel_type", channel_type, equals},
    {~"q", content, ilike}
]).

-doc "Wire-name to column mapping the channel list accepts in `?sort=`.".
-spec channels_sortable() -> asobi_ops_params:sort_allowlist().
channels_sortable() -> ?CHANNELS_SORTABLE.

-doc "Wire-name to column mapping the message list accepts in `?sort=`.".
-spec messages_sortable() -> asobi_ops_params:sort_allowlist().
messages_sortable() -> ?MESSAGES_SORTABLE.

-doc """
The live channel rows and the order to page them in.

Busiest first, since a channel with two hundred people in it is the one an
operator is being asked about. `channel_id` is unique across the rows and
ends the order, so the offset window cannot repeat one.
""".
-spec channels(asobi_ops_params:params()) ->
    {ok, {[map()], asobi_ops_params:sort_spec()}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
channels(Params) ->
    case asobi_ops_params:sort(Params, ?CHANNELS_SORTABLE, [{members, desc}], {channel_id, asc}) of
        {ok, Orders} -> {ok, {search(asobi_chat_channel:channels(), Params), Orders}};
        {error, _} = Error -> Error
    end.

%% `q` matches the channel id case-insensitively, the in-memory equivalent of
%% the `ilike` the message list runs.
-spec search([map()], asobi_ops_params:params()) -> [map()].
search(Rows, Params) ->
    case asobi_ops_params:search(Params, ~"q") of
        none ->
            Rows;
        {ok, Term} ->
            Needle = string:lowercase(Term),
            [
                Row
             || #{channel_id := Id} = Row <- Rows,
                string:find(string:lowercase(Id), Needle) =/= nomatch
            ]
    end.

-doc "One channel's persisted messages as an ordered query for the shared paginator.".
-spec messages_query(binary(), asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
messages_query(ChannelId, Params) ->
    case asobi_ops_params:sort(Params, ?MESSAGES_SORTABLE, [{sent_at, desc}]) of
        {ok, Orders} ->
            Scoped = kura_query:where(
                kura_query:from(asobi_chat_message), {channel_id, ChannelId}
            ),
            case asobi_ops_filters:build(Scoped, Params, ?MESSAGES_FILTERS) of
                {ok, Query} -> {ok, kura_query:order_by(Query, Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc "Positive allowlist of the fields a channel row may carry off this endpoint.".
-spec project_channel(map()) -> map().
project_channel(Channel) ->
    maps:with([channel_id, members], Channel).

-doc """
Positive allowlist of the fields a message may carry off this endpoint.

`content` stays: a moderation screen that cannot show what was said is not
one. `metadata` is game-authored and does not leave, the same rule
`asobi_ops_matches` applies to a match record.
""".
-spec project_message(map()) -> map().
project_message(Message) ->
    maps:with([id, channel_type, channel_id, sender_id, content, sent_at], Message).
