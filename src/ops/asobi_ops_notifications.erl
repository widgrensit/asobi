-module(asobi_ops_notifications).
-moduledoc """
The notifications screen: the sent-notification list, and the
operator-attributed broadcast.

`query/1` is the read half and it *is* a route, tagged `read` like every
other list here. It answers the question a broadcast raises and nothing else
could: which players actually received the last send, and how many of them
have opened it.

`broadcast/5` is the mutation half, moved into core so the audit wraps it
rather than the handler remembering to. The console keeps parsing,
deduplicating and capping the recipient list - those are presentation
concerns - and calls this for the part that changes player state.

`broadcast/5` is deliberately *not* a route. The ops plane is read-only and
this does not change that; it is the Erlang entry point the existing console
mutation calls, which is what lets `{ok, Succeeded, Failed}` reach an audit
row instead of being flattened into a list of survivors on the way out.

Because it has no route, it gets no route-level capability check either - so
the check happens inside it, through the same `asobi_ops_caps:authorised/2`
the router's security callback uses. One function still authorises; it is
simply called from the entry point an in-process caller actually reaches.
""".

-include_lib("kura/include/kura.hrl").

-export([broadcast/5]).
-export([query/1, project/1, sortable/0]).

-define(ACTION, ~"notifications.broadcast").
-define(CLASS, player_data).

-define(SORTABLE, [
    {~"id", id},
    {~"player_id", player_id},
    {~"type", type},
    {~"subject", subject},
    {~"read", read},
    {~"sent_at", sent_at}
]).

-define(FILTERS, [
    {~"player_id", player_id, uuid},
    {~"type", type, equals},
    {~"read", read, boolean},
    {~"q", subject, ilike}
]).

-doc "Wire-name to column mapping this endpoint accepts in `?sort=`.".
-spec sortable() -> asobi_ops_params:sort_allowlist().
sortable() -> ?SORTABLE.

-spec query(asobi_ops_params:params()) ->
    {ok, #kura_query{}}
    | {error, {unknown_sort, binary()} | {unknown_order, binary()} | {invalid_filter, binary()}}.
query(Params) ->
    case asobi_ops_params:sort(Params, ?SORTABLE, [{sent_at, desc}]) of
        {ok, Orders} ->
            case asobi_ops_filters:build(kura_query:from(asobi_notification), Params, ?FILTERS) of
                {ok, Query} -> {ok, kura_query:order_by(Query, Orders)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Positive allowlist of the fields a notification may carry off this endpoint.

`content` stays. It is the body of a message an operator or the game sent,
and the same field the receiving player already reads back from
`asobi_notification_controller:index/1`; a send-history screen that cannot
show what was sent cannot answer the one question it exists for.
""".
-spec project(map()) -> map().
project(Notification) ->
    maps:with([id, player_id, type, subject, content, read, sent_at], Notification).

-doc """
Send `Subject` to every id in `PlayerIds` as `Actor`, and audit the result.

Returns the widened outcome unchanged, so a caller can report exactly what
happened. The audit row is written whatever the outcome, including the
all-failed case and the refusal.
""".
-spec broadcast(asobi_ops_auth:actor(), binary(), binary(), map(), [binary()]) ->
    asobi_ops_audit:outcome().
broadcast(#{caps := Caps} = Actor, Type, Subject, Content, PlayerIds) ->
    asobi_ops_audit:mutation(Actor, ?ACTION, {~"player", undefined}, fun() ->
        case asobi_ops_caps:authorised(?CLASS, Caps) of
            true -> asobi_notify:send_many(PlayerIds, Type, Subject, Content);
            false -> {error, forbidden}
        end
    end).
