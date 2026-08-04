-module(asobi_ops_notifications).
-moduledoc """
The operator-attributed notification broadcast.

This is the mutation half of the console's notifications screen, moved into
core so the audit wraps it rather than the handler remembering to. The
console keeps parsing, deduplicating and capping the recipient list - those
are presentation concerns - and calls this for the part that changes player
state.

It is not a route. The ops plane is read-only, and this does not change that;
it is the Erlang entry point the existing console mutation calls, which is
what lets `{ok, Succeeded, Failed}` reach an audit row instead of being
flattened into a list of survivors on the way out.

Because there is no route, there is no route-level capability check either -
so the check happens here, through the same `asobi_ops_caps:authorised/2`
that the router's security callback uses. One function still authorises; it
is simply called from the entry point an in-process caller actually reaches.
""".

-export([broadcast/5]).

-define(ACTION, ~"notifications.broadcast").
-define(CLASS, player_data).

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
