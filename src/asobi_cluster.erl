-module(asobi_cluster).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_POLL_INTERVAL, 10000).

-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case application:get_env(asobi, cluster) of
        {ok, _Config} ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        undefined ->
            ignore
    end.

-spec init([]) -> {ok, map()}.
init([]) ->
    {ok, Config} = application:get_env(asobi, cluster),
    Interval = maps:get(poll_interval, Config, ?DEFAULT_POLL_INTERVAL),
    self() ! discover,
    {ok, #{config => Config, poll_interval => Interval}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, ok, map()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(discover, #{config := Config, poll_interval := Interval} = State) ->
    Strategy = maps:get(strategy, Config, dns),
    case Strategy of
        dns ->
            Hostname = maps:get(dns_name, Config, ~""),
            discover_dns(Hostname);
        epmd ->
            Hosts = maps:get(hosts, Config, []),
            discover_epmd(Hosts)
    end,
    erlang:send_after(Interval, self(), discover),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

-spec discover_dns(binary()) -> ok.
discover_dns(<<>>) ->
    ok;
discover_dns(Hostname) ->
    case inet:getaddrs(binary_to_list(Hostname), inet) of
        {ok, IPs} ->
            BaseName = node_basename(),
            lists:foreach(
                fun(IP) ->
                    Node = list_to_atom(BaseName ++ "@" ++ inet:ntoa(IP)),
                    maybe_connect(Node)
                end,
                IPs
            );
        {error, _} ->
            ok
    end.

-spec discover_epmd([atom()]) -> ok.
discover_epmd(Hosts) ->
    BaseName = node_basename(),
    lists:foreach(
        fun(Host) ->
            Node = list_to_atom(BaseName ++ "@" ++ atom_to_list(Host)),
            maybe_connect(Node)
        end,
        Hosts
    ).

-spec maybe_connect(node()) -> ok.
maybe_connect(Node) when Node =:= node() ->
    ok;
maybe_connect(Node) ->
    case lists:member(Node, nodes()) of
        true ->
            ok;
        false ->
            case net_adm:ping(Node) of
                pong ->
                    logger:info(#{msg => ~"cluster node connected", node => Node});
                pang ->
                    ok
            end
    end.

-spec node_basename() -> string().
node_basename() ->
    [Name | _] = string:split(atom_to_list(node()), "@"),
    Name.
