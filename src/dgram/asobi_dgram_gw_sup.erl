-module(asobi_dgram_gw_sup).
-moduledoc """
The datagram gateway's supervision tree (ADR 0012, decision 14).

Started only when `asobi.role` is `dgram_gw`, which is what keeps hostile
internet packets out of the process tree holding the Lua sandbox and the tenant
database credentials. One image, two roles, two containers: the engine role never
binds a UDP port and the gateway role never starts a zone, a Lua VM or a database
pool.

    {asobi, [{role, dgram_gw}, {dgram, #{port => 7777, shards => 4}}]}

`role` defaults to `engine`, so an existing deployment that has never heard of
this gets exactly what it had.

## Shape

    asobi_dgram_gw_sup  (one_for_one)
      asobi_dgram_limits    the rate-limit tiers, registered once
      asobi_dgram_table     the binding table's owner
      asobi_dgram_sender    owns the send socket
      asobi_dgram_rx_sup    one receiver per SO_REUSEPORT shard

`one_for_one` and not `rest_for_one`: a receiver crashing must not take down the
binding table, because the table holds every live connection's credential and
rebuilding it means every player re-minting over TLS. The receivers are the
processes touching hostile bytes and so the ones most likely to crash, which is
exactly why they must be the cheapest thing to restart.

**Shard count is fixed at boot.** Adding or removing a socket reshuffles the
kernel's `SO_REUSEPORT` hash and breaks every existing flow, so there is no
runtime rescaling and no configuration reload path. That is a property of the
kernel, not a limitation worth working around.
""".

-behaviour(supervisor).

-export([start_link/0, enabled/0, config/0]).
-export([init/1]).

-define(DEFAULT_PORT, 7777).

-doc "Whether this node runs the gateway rather than the engine.".
-spec enabled() -> boolean().
enabled() -> application:get_env(asobi, role, engine) =:= dgram_gw.

-doc """
The gateway's configuration, defaulted.

`shards` defaults to the scheduler count, capped: one receiver per scheduler is
the shape `SO_REUSEPORT` is for, and more sockets than schedulers buys nothing
while multiplying the flows a restart would break.
""".
-spec config() -> #{port := inet:port_number(), shards := pos_integer()}.
config() ->
    Configured =
        case application:get_env(asobi, dgram, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    #{port => port(Configured), shards => shards(Configured)}.

%% Narrowed with guards rather than taken from maps:get/3, which returns term()
%% over an operator-supplied map. A port that is not a port and a shard count that
%% is not a count are configuration typos, and falling back to the default beats
%% crashing the boot with a badmatch nobody can read.
port(#{port := P}) when is_integer(P), P > 0, P =< 65535 -> P;
port(_) -> ?DEFAULT_PORT.

shards(#{shards := N}) when is_integer(N), N > 0, N =< 64 -> N;
shards(_) -> min(erlang:system_info(schedulers_online), 8).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    %% Order matters on the way up and is the reason this is a list rather than
    %% a set: limiters before anything can be received, the table before a
    %% datagram can name a conn_id, and the sender before a receiver can need to
    %% answer one. The receivers come last because they are the only child that
    %% can be handed work by someone outside the node.
    {ok, {SupFlags, [limits_spec(), table_spec(), sender_spec(), rx_sup_spec()]}}.

%% --- Internal ---

%% Registered before anything can receive a packet. `temporary` and `ignore`ing:
%% seki owns the limiters' own processes, so this child exists to run the
%% registration once in the right order, not to be supervised.
limits_spec() ->
    #{
        id => asobi_dgram_limits,
        start => {erlang, apply, [fun asobi_dgram_limits:register/0, []]},
        restart => temporary
    }.

sender_spec() ->
    #{
        id => asobi_dgram_sender,
        start => {asobi_dgram_sender, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [asobi_dgram_sender]
    }.

rx_sup_spec() ->
    #{
        id => asobi_dgram_rx_sup,
        start => {asobi_dgram_rx_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [asobi_dgram_rx_sup]
    }.

table_spec() ->
    #{
        id => asobi_dgram_table,
        start => {asobi_dgram_table, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [asobi_dgram_table]
    }.
