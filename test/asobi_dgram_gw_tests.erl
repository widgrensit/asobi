-module(asobi_dgram_gw_tests).
-include_lib("eunit/include/eunit.hrl").

%% The gateway's role gating and its binding-table owner.

role_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"engine is the default, and it is the whole tree", fun engine_is_the_default/0},
        {"the gateway role starts none of the engine", fun gw_role_starts_no_engine/0},
        {"the engine role starts none of the gateway", fun engine_role_starts_no_gateway/0},
        {"the gateway role starts all of the gateway", fun gw_role_starts_the_tree/0},
        {"the gateway application carries nothing that holds credentials",
            fun gateway_application_is_minimal/0},
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
    Ids = [Id || #{id := Id} <- Children],
    ?assert(lists:member(asobi_world_sup, Ids)),
    ?assert(lists:member(asobi_lua_sup, Ids)),
    ?assertNot(lists:member(asobi_dgram_gw_sup, Ids)).

%% Half of the isolation the two-role split exists for: an engine booted into the
%% gateway role starts no zone, no Lua VM and no match. The gateway's own tree is
%% not here either - it belongs to `asobi_dgram_gw_app`, which is what lets it
%% start in a release that has no `asobi` in it at all (asobi#513).
gw_role_starts_no_engine() ->
    application:set_env(asobi, role, dgram_gw),
    ?assert(asobi_dgram_gw_sup:enabled()),
    {ok, {_Flags, Children}} = asobi_sup:init([]),
    ?assertEqual([], Children).

%% The other half, and the one a role switch could never give: what the gateway
%% release is ALLOWED to contain. A process that parses packets from the internet
%% must not have a database driver in its image, let alone an open pool - and no
%% amount of role checking inside `start/2` can achieve that, because OTP starts
%% an application's dependencies before its start callback runs. This list is the
%% boundary; a regression here is the security property gone, not a feature loss.
gateway_application_is_minimal() ->
    _ = application:load(asobi_dgram_gw),
    {ok, Deps} = application:get_key(asobi_dgram_gw, applications),
    ?assertEqual([], Deps -- [kernel, stdlib, crypto, telemetry, seki]),
    [
        ?assertNot(lists:member(Heavy, Deps))
     || Heavy <- [nova, kura, kura_postgres, shigoto, luerl, nova_resilience]
    ],
    %% ...and the engine still depends on it, which is the direction that makes
    %% the codec shared without making the gateway carry the engine.
    _ = application:load(asobi),
    {ok, AsobiDeps} = application:get_key(asobi, applications),
    ?assert(lists:member(asobi_dgram_gw, AsobiDeps)).

%% asobi#530: `asobi` lists `asobi_dgram_gw` in `applications` for the shared
%% codec, so this supervisor's `init/1` runs on every engine. Returning the child
%% list there binds the public UDP port and 7778 inside the process tree holding
%% the Lua sandbox and the tenant credentials - the isolation ADR 0012 decision 14
%% exists to enforce - and crash-loops any real gateway sidecar on eaddrinuse.
%% Worse, without a sidecar the plane keeps working through the engine's
%% in-process gateway, so nothing tells the operator the boundary is gone.
engine_role_starts_no_gateway() ->
    application:unset_env(asobi, role),
    {ok, {_Flags, Children}} = asobi_dgram_gw_sup:init([]),
    ?assertEqual([], Children).

gw_role_starts_the_tree() ->
    application:set_env(asobi, role, dgram_gw),
    {ok, {_Flags, Children}} = asobi_dgram_gw_sup:init([]),
    Ids = [Id || #{id := Id} <- Children],
    ?assertEqual(
        [
            asobi_dgram_limits,
            asobi_dgram_table,
            asobi_dgram_link_server,
            asobi_dgram_sender,
            asobi_dgram_rx_sup,
            asobi_dgram_canary
        ],
        Ids
    ).

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
