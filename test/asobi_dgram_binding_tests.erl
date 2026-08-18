-module(asobi_dgram_binding_tests).
-include_lib("eunit/include/eunit.hrl").

%% The datagram plane's binding table and two-phase challenge (ADR 0012,
%% decisions 5, 6 and 7). Every security-critical transition is a function call,
%% which is the whole reason this module holds no processes.

-define(CONN, 4711).
-define(A, {handle, a}).
-define(B, {handle, b}).
-define(CHALLENGE, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(OTHER, <<8, 7, 6, 5, 4, 3, 2, 1>>).

%% --- Registration ---

%% A duplicate conn_id is refused rather than overwritten. An overwrite would
%% silently re-point a live connection's credential, and a collision is a
%% generator defect worth seeing rather than absorbing.
duplicate_conn_id_is_refused_test() ->
    {ok, T} = asobi_dgram_binding:register(binding(?CONN), asobi_dgram_binding:new()),
    ?assertEqual({error, duplicate}, asobi_dgram_binding:register(binding(?CONN), T)).

%% --- No state frame precedes return-routability ---

%% The property the whole two-phase exchange exists for: a freshly registered
%% connection, and one that has only said hello, have nowhere to send. A gateway
%% that sent pose to a candidate handle would be an amplifier.
nothing_is_sendable_until_a_challenge_completes_test() ->
    T0 = minted(),
    ?assertEqual(error, asobi_dgram_binding:sendable(?CONN, T0)),

    {ok, ?CHALLENGE, T1} = asobi_dgram_binding:hello(?CONN, 1, ?A, 0, ?CHALLENGE, T0),
    ?assertEqual(error, asobi_dgram_binding:sendable(?CONN, T1)),

    {ok, T2} = asobi_dgram_binding:confirm(?CONN, 2, ?A, ?CHALLENGE, T1),
    ?assertEqual({ok, ?A}, asobi_dgram_binding:sendable(?CONN, T2)).

%% The echo must match the challenge AND come from the handle it was minted to.
%% Either alone is not enough: the right challenge from a different handle is
%% exactly the reflection this prevents.
confirm_needs_both_the_challenge_and_the_handle_test() ->
    {ok, ?CHALLENGE, T} = asobi_dgram_binding:hello(?CONN, 1, ?A, 0, ?CHALLENGE, minted()),
    ?assertMatch({error, bad_challenge, _}, asobi_dgram_binding:confirm(?CONN, 2, ?A, ?OTHER, T)),
    ?assertMatch(
        {error, bad_challenge, _}, asobi_dgram_binding:confirm(?CONN, 3, ?B, ?CHALLENGE, T)
    ).

%% Cleared on success, so a captured echo cannot be replayed against whatever
%% challenge happens to be outstanding later.
a_used_challenge_cannot_be_replayed_test() ->
    {ok, ?CHALLENGE, T1} = asobi_dgram_binding:hello(?CONN, 1, ?A, 0, ?CHALLENGE, minted()),
    {ok, T2} = asobi_dgram_binding:confirm(?CONN, 2, ?A, ?CHALLENGE, T1),
    ?assertMatch(
        {error, bad_challenge, _}, asobi_dgram_binding:confirm(?CONN, 3, ?A, ?CHALLENGE, T2)
    ).

%% --- cseq ---

%% Strictly advancing, never equal: equality admits an exact replay, which is the
%% attack this counter exists to stop.
cseq_must_strictly_advance_test() ->
    {ok, ?CHALLENGE, T} = asobi_dgram_binding:hello(?CONN, 5, ?A, 0, ?CHALLENGE, minted()),
    ?assertMatch({error, stale_cseq, _}, asobi_dgram_binding:hello(?CONN, 5, ?A, 0, ?OTHER, T)),
    ?assertMatch({error, stale_cseq, _}, asobi_dgram_binding:hello(?CONN, 4, ?A, 0, ?OTHER, T)),
    ?assertMatch({ok, _, _}, asobi_dgram_binding:hello(?CONN, 6, ?A, 0, ?OTHER, T)).

%% Checked BEFORE the rebind path is entered. A rebind decision taken ahead of it
%% would be taken on ordering nothing has authenticated, so a captured hello could
%% move a challenge to an attacker's handle without ever advancing the counter.
cseq_is_checked_before_the_rebind_path_test() ->
    T = bound(),
    %% A replayed hello from a DIFFERENT handle must be refused on cseq, and must
    %% not have consumed any of the rebind budget on its way there.
    ?assertMatch({error, stale_cseq, _}, asobi_dgram_binding:hello(?CONN, 1, ?B, 0, ?OTHER, T)),
    {ok, Binding} = asobi_dgram_binding:lookup(?CONN, T),
    ?assertEqual([], maps:get(rebinds, Binding)).

%% Every uplink advances it, so a replayed input or ping is refused on the same
%% rule that protects the handshake rather than on a weaker rule of its own.
every_uplink_advances_the_counter_test() ->
    T = bound(),
    {ok, _, T1} = asobi_dgram_binding:note_uplink(?CONN, 10, T),
    ?assertMatch({error, stale_cseq, _}, asobi_dgram_binding:note_uplink(?CONN, 10, T1)),
    ?assertMatch({ok, _, _}, asobi_dgram_binding:note_uplink(?CONN, 11, T1)).

%% --- Rebind ---

%% A hello from a new handle is a HINT, never an authority. Through a rewriting
%% middlebox the server cannot see a path change, so acting on one would let any
%% party who can reach the port move a victim's downlink to itself.
a_hello_from_a_new_handle_does_not_move_the_downlink_test() ->
    T = bound(),
    {ok, ?OTHER, T1} = asobi_dgram_binding:hello(?CONN, 10, ?B, 1000, ?OTHER, T),
    %% Still going to the old handle: the rebind takes effect on its OWN echo.
    ?assertEqual({ok, ?A}, asobi_dgram_binding:sendable(?CONN, T1)),
    {ok, T2} = asobi_dgram_binding:confirm(?CONN, 11, ?B, ?OTHER, T1),
    ?assertEqual({ok, ?B}, asobi_dgram_binding:sendable(?CONN, T2)).

%% Bounded at 3 per 60 s, then teardown. A client whose path genuinely flaps is
%% degraded rather than served, because the WebSocket carries everything anyway.
rebinds_are_bounded_then_the_connection_is_torn_down_test() ->
    T0 = bound(),
    {ok, _, T1} = asobi_dgram_binding:hello(?CONN, 10, ?B, 1000, ?OTHER, T0),
    {ok, _, T2} = asobi_dgram_binding:hello(?CONN, 11, {handle, c}, 1100, ?OTHER, T1),
    {ok, _, T3} = asobi_dgram_binding:hello(?CONN, 12, {handle, d}, 1200, ?OTHER, T2),
    ?assertMatch(
        {error, rebind_limit, _},
        asobi_dgram_binding:hello(?CONN, 13, {handle, e}, 1300, ?OTHER, T3)
    ),
    %% The window rolls: the same attempt a minute later is allowed again.
    ?assertMatch(
        {ok, _, _}, asobi_dgram_binding:hello(?CONN, 14, {handle, e}, 1300 + 60_000, ?OTHER, T3)
    ).

%% Re-saying hello from the SAME handle is a keepalive-driven refresh, not a path
%% change, and must not spend the budget - otherwise a quiet client on a stable
%% path tears itself down.
refreshing_from_the_same_handle_is_not_a_rebind_test() ->
    T = lists:foldl(
        fun(N, Acc) ->
            {ok, _, Next} = asobi_dgram_binding:hello(?CONN, N, ?A, N * 100, ?OTHER, Acc),
            Next
        end,
        bound(),
        lists:seq(10, 20)
    ),
    {ok, Binding} = asobi_dgram_binding:lookup(?CONN, T),
    ?assertEqual([], maps:get(rebinds, Binding)).

%% --- Teardown ---

%% Synchronously, and the handle mapping goes with it. A handle left behind is a
%% downlink the next client assigned that NAT mapping would inherit.
teardown_drops_the_handle_mapping_too_test() ->
    T = bound(),
    ?assertEqual({ok, ?A}, asobi_dgram_binding:sendable(?CONN, T)),
    T1 = asobi_dgram_binding:unregister(?CONN, T),
    ?assertEqual(error, asobi_dgram_binding:sendable(?CONN, T1)),
    ?assertEqual(error, asobi_dgram_binding:lookup(?CONN, T1)),
    ?assertEqual(0, asobi_dgram_binding:size(T1)),

    %% And a fresh connection that inherits the same handle inherits nothing: it
    %% has to complete its own challenge like anyone else.
    {ok, T2} = asobi_dgram_binding:register(binding(9999), T1),
    ?assertEqual(error, asobi_dgram_binding:sendable(9999, T2)).

%% A rebind must not leave the OLD handle mapped, or teardown by handle would
%% resolve to a connection that has moved on.
a_completed_rebind_releases_the_old_handle_test() ->
    {ok, _, T1} = asobi_dgram_binding:hello(?CONN, 10, ?B, 1000, ?OTHER, bound()),
    {ok, T2} = asobi_dgram_binding:confirm(?CONN, 11, ?B, ?OTHER, T1),
    ?assertEqual(#{?B => ?CONN}, maps:get(by_handle, T2)).

expiry_drops_only_what_has_expired_test() ->
    {ok, T0} = asobi_dgram_binding:register(binding(?CONN, 500), asobi_dgram_binding:new()),
    {ok, T1} = asobi_dgram_binding:register(binding(1234, 1500), T0),
    {Dead, T2} = asobi_dgram_binding:expire(1000, T1),
    ?assertEqual([?CONN], Dead),
    ?assertEqual(1, asobi_dgram_binding:size(T2)),
    ?assertMatch({ok, _}, asobi_dgram_binding:lookup(1234, T2)).

%% An unknown conn_id is a miss on every path, and it must never be the thing that
%% creates a binding - registration happens over TLS or not at all.
an_unknown_conn_id_never_creates_a_binding_test() ->
    T = asobi_dgram_binding:new(),
    ?assertMatch({error, unknown_conn, _}, asobi_dgram_binding:hello(1, 1, ?A, 0, ?CHALLENGE, T)),
    ?assertMatch({error, unknown_conn, _}, asobi_dgram_binding:confirm(1, 1, ?A, ?CHALLENGE, T)),
    ?assertMatch({error, unknown_conn, _}, asobi_dgram_binding:note_uplink(1, 1, T)),
    ?assertEqual(0, asobi_dgram_binding:size(T)).

%% --- Helpers ---

binding(ConnId) -> binding(ConnId, 1_000_000).

binding(ConnId, ExpiresAt) ->
    #{
        conn_id => ConnId,
        kup => crypto:strong_rand_bytes(32),
        player_id => ~"p1",
        epoch => 1,
        expires_at => ExpiresAt,
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    }.

minted() ->
    {ok, T} = asobi_dgram_binding:register(binding(?CONN), asobi_dgram_binding:new()),
    T.

bound() ->
    {ok, ?CHALLENGE, T1} = asobi_dgram_binding:hello(?CONN, 1, ?A, 0, ?CHALLENGE, minted()),
    {ok, T2} = asobi_dgram_binding:confirm(?CONN, 2, ?A, ?CHALLENGE, T1),
    T2.
