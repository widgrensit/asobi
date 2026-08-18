-module(asobi_dgram_rx_sup).
-moduledoc """
One receiver per `SO_REUSEPORT` shard.

`one_for_one`, so a shard that crashes on a datagram the pipeline could not
survive takes only its own socket with it. Its flows move to the surviving
shards until it rebinds, which costs nothing: this plane keeps no per-flow state
anywhere, which is precisely why losing a shard is survivable and why the whole
design is worth having.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    #{port := Port, shards := Shards} = asobi_dgram_gw_sup:config(),
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    {ok, {SupFlags, [shard_spec(I, Port) || I <- lists:seq(1, Shards)]}}.

%% --- Internal ---

shard_spec(Index, Port) ->
    #{
        id => {asobi_dgram_shard, Index},
        start => {asobi_dgram_shard, start_link, [Index, Port]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [asobi_dgram_shard]
    }.
