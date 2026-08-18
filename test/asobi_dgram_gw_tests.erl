-module(asobi_dgram_gw_tests).
-include_lib("eunit/include/eunit.hrl").

%% The gateway's role gating and its binding-table owner.

role_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"engine is the default, and it is the whole tree", fun engine_is_the_default/0},
        {"the gateway role starts the gateway and nothing else",
            fun gw_role_starts_only_the_gateway/0},
        {"shards default to the schedulers, capped", fun shard_default/0}
    ]}.

table_test_() ->
    {foreach, fun setup_table/0, fun cleanup_table/1, [
        {"a mint is revocable, synchronously", fun mint_is_revocable/0},
        {"the full handshake binds a downlink", fun handshake_binds/0},
        {"a stale cseq is refused through the owner too", fun stale_cseq_refused/0}
    ]}.

setup() -> application:get_env(asobi, role).
cleanup(undefined) -> application:unset_env(asobi, role);
cleanup({ok, V}) -> application:set_env(asobi, role, V).

setup_table() ->
    {ok, Pid} = asobi_dgram_table:start_link(),
    Pid.

cleanup_table(Pid) ->
    gen_server:stop(Pid).

%% --- Role gating ---

%% A deployment that has never heard of the gateway must get exactly what it had.
engine_is_the_default() ->
    application:unset_env(asobi, role),
    ?assertNot(asobi_dgram_gw_sup:enabled()),
    {ok, {_Flags, Children}} = asobi_sup:init([]),
    Ids = [maps:get(id, C) || C <- Children],
    ?assert(lists:member(asobi_world_sup, Ids)),
    ?assert(lists:member(asobi_lua_sup, Ids)),
    ?assertNot(lists:member(asobi_dgram_gw_sup, Ids)).

%% The isolation that the whole two-role split exists for: the process tree that
%% parses packets from the internet holds no Lua sandbox and no database pool.
%% A regression here is not a feature loss, it is the security property gone.
gw_role_starts_only_the_gateway() ->
    application:set_env(asobi, role, dgram_gw),
    ?assert(asobi_dgram_gw_sup:enabled()),
    {ok, {_Flags, Children}} = asobi_sup:init([]),
    Ids = [maps:get(id, C) || C <- Children],
    ?assertEqual([asobi_dgram_gw_sup], Ids),
    ?assertNot(lists:member(asobi_lua_sup, Ids)),
    ?assertNot(lists:member(asobi_world_sup, Ids)),
    ?assertNot(lists:member(asobi_match_sup, Ids)).

%% One receiver per scheduler is the shape SO_REUSEPORT is for. More sockets than
%% schedulers buys nothing and multiplies the flows a restart breaks, because the
%% shard count cannot change at runtime without reshuffling the kernel's hash.
shard_default() ->
    #{shards := Shards, port := Port} = asobi_dgram_gw_sup:config(),
    ?assert(Shards >= 1),
    ?assert(Shards =< 8),
    ?assertEqual(7777, Port).

%% --- The table owner ---

%% The one thing a registered binding buys over a signed token: a session dying
%% takes its datagram credential with it, before the reply reaches the player.
mint_is_revocable() ->
    ?assertEqual(ok, asobi_dgram_table:register(binding(1))),
    ?assertMatch({ok, _}, asobi_dgram_table:kup_of(1)),
    ?assertEqual({error, duplicate}, asobi_dgram_table:register(binding(1))),
    ?assertEqual(ok, asobi_dgram_table:unregister(1)),
    ?assertEqual(error, asobi_dgram_table:kup_of(1)).

handshake_binds() ->
    ok = asobi_dgram_table:register(binding(2)),
    ?assertEqual(error, asobi_dgram_table:sendable(2)),
    {ok, Challenge} = asobi_dgram_table:hello(2, 1, {handle, a}, <<9:64>>),
    ?assertEqual(<<9:64>>, Challenge),
    ?assertEqual(error, asobi_dgram_table:sendable(2)),
    ?assertEqual(ok, asobi_dgram_table:confirm(2, 2, {handle, a}, Challenge)),
    ?assertEqual({ok, {handle, a}}, asobi_dgram_table:sendable(2)).

stale_cseq_refused() ->
    ok = asobi_dgram_table:register(binding(3)),
    {ok, _} = asobi_dgram_table:hello(3, 5, {handle, a}, <<1:64>>),
    ?assertEqual({error, stale_cseq}, asobi_dgram_table:hello(3, 5, {handle, a}, <<2:64>>)),
    ?assertEqual({error, stale_cseq}, asobi_dgram_table:note_uplink(3, 4)),
    ?assertEqual(ok, asobi_dgram_table:note_uplink(3, 6)).

%% --- Helpers ---

binding(ConnId) ->
    #{
        conn_id => ConnId,
        kup => crypto:strong_rand_bytes(32),
        player_id => ~"p1",
        epoch => 1,
        expires_at => erlang:system_time(millisecond) + 60_000,
        state => registered,
        handle => undefined,
        pending_handle => undefined,
        challenge => undefined,
        cseq => 0,
        rebinds => []
    }.
