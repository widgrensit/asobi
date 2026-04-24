-module(asobi_terrain_store).
-behaviour(gen_server).

%% ETS-backed terrain chunk cache with lazy loading from a provider.

-export([start_link/1]).
-export([get_chunk/2, preload_chunks/2, evict_chunk/2, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% --- Public API ---

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec get_chunk(pid(), {integer(), integer()}) ->
    {ok, binary()} | {error, term()}.
get_chunk(Pid, Coords) ->
    case gen_server:call(Pid, {get_chunk, Coords}) of
        {ok, Data} when is_binary(Data) -> {ok, Data};
        {error, _} = Err -> Err
    end.

-spec preload_chunks(pid(), [{integer(), integer()}]) -> ok.
preload_chunks(Pid, CoordsList) ->
    gen_server:cast(Pid, {preload, CoordsList}).

-spec evict_chunk(pid(), {integer(), integer()}) -> ok.
evict_chunk(Pid, Coords) ->
    gen_server:cast(Pid, {evict, Coords}).

-spec stats(pid()) -> map().
stats(Pid) ->
    case gen_server:call(Pid, stats) of
        M when is_map(M) -> M
    end.

%% --- gen_server callbacks ---

-spec init(map()) -> {ok, map()}.
init(Opts) ->
    {ProvMod, ProvArgs} = maps:get(provider, Opts),
    {ok, ProvState} = ProvMod:init(ProvArgs),
    Tab = ets:new(asobi_terrain_cache, [set, public, {read_concurrency, true}]),
    {ok, #{
        ets_tab => Tab,
        provider_mod => ProvMod,
        provider_state => ProvState,
        seed => maps:get(seed, Opts, 0),
        hits => 0,
        misses => 0
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({get_chunk, Coords}, _From, #{ets_tab := Tab} = State) ->
    case ets:lookup(Tab, Coords) of
        [{Coords, Data}] ->
            {reply, {ok, Data}, inc_hits(State)};
        [] ->
            case load_from_provider(Coords, State) of
                {ok, Data, State1} ->
                    ets:insert(Tab, {Coords, Data}),
                    {reply, {ok, Data}, inc_misses(State1)};
                {error, Reason, State1} ->
                    {reply, {error, Reason}, State1}
            end
    end;
handle_call(stats, _From, #{ets_tab := Tab, hits := H, misses := M} = State) ->
    MemWords =
        case ets:info(Tab, memory) of
            N when is_integer(N) -> N;
            _ -> 0
        end,
    {reply,
        #{
            cached_chunks => ets:info(Tab, size),
            memory_bytes => MemWords * erlang:system_info(wordsize),
            hits => H,
            misses => M
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({preload, CoordsList}, #{ets_tab := Tab} = State) when is_list(CoordsList) ->
    State1 = preload_chunks_do(CoordsList, Tab, State),
    {noreply, State1};
handle_cast({evict, Coords}, #{ets_tab := Tab} = State) ->
    ets:delete(Tab, Coords),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{ets_tab := Tab}) ->
    ets:delete(Tab),
    ok.

%% --- Internal ---

load_from_provider(Coords, #{provider_mod := Mod, provider_state := PS} = State) ->
    case Mod:load_chunk(Coords, PS) of
        {ok, Data, PS1} ->
            {ok, Data, State#{provider_state => PS1}};
        {error, not_found, PS1} ->
            generate_fallback(Coords, State#{provider_state => PS1});
        {error, not_found} ->
            generate_fallback(Coords, State);
        {error, Reason, PS1} ->
            {error, Reason, State#{provider_state => PS1}};
        {error, Reason} ->
            {error, Reason, State}
    end.

generate_fallback(Coords, #{provider_mod := Mod, provider_state := PS, seed := Seed} = State) ->
    case erlang:function_exported(Mod, generate_chunk, 3) of
        true ->
            case Mod:generate_chunk(Coords, Seed, PS) of
                {ok, Data, PS1} ->
                    {ok, Data, State#{provider_state => PS1}};
                {error, Reason} ->
                    {error, Reason, State}
            end;
        false ->
            {error, not_found, State}
    end.

inc_hits(#{hits := H} = State) -> State#{hits => H + 1}.
inc_misses(#{misses := M} = State) -> State#{misses => M + 1}.

-spec preload_chunks_do([term()], ets:tid(), map()) -> map().
preload_chunks_do([], _Tab, State) ->
    State;
preload_chunks_do([Coords | Rest], Tab, State) ->
    State1 =
        case ets:lookup(Tab, Coords) of
            [{_, _}] ->
                State;
            [] ->
                case load_from_provider(Coords, State) of
                    {ok, Data, S1} ->
                        ets:insert(Tab, {Coords, Data}),
                        S1;
                    {error, _, S1} ->
                        S1
                end
        end,
    preload_chunks_do(Rest, Tab, State1).
