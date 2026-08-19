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

-export([start_link/0, lend_to/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Asks every live receiver to lend its socket to `To`, which is always the sender.

The receivers are the only sockets bound to the public port, which is why this
lives here: a reply that does not leave from the port the client sent to is
dropped by conntrack and filtered by any SDK that `connect()`s its socket, and a
second socket bound there purely to send would join the `SO_REUSEPORT` group and
swallow every flow the kernel hashed onto it (asobi#515).

Each shard offers its socket unprompted when it starts, so this is only for the
case the offer cannot cover: a sender that restarted after the shards did, and
so was not listening when they spoke. Asking all of them rather than one means
the answer does not depend on which shard happens to be healthy. Which one wins
does not matter - they are all bound to the same port, so the source port is the
same whichever answers first.
""".
-spec lend_to(pid()) -> ok.
lend_to(To) ->
    try
        lists:foreach(
            fun
                ({_Id, Pid, _Type, _Mods}) when is_pid(Pid) -> asobi_dgram_shard:lend_to(Pid, To);
                (_Restarting) -> ok
            end,
            supervisor:which_children(?MODULE)
        )
    catch
        %% No receivers yet, or the whole tree is on its way down. Either way
        %% there is nothing to reply through and the caller drops the datagram.
        exit:_ -> ok
    end.

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
