-module(asobi_terrain_store_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Mock terrain provider ---

-behaviour(asobi_terrain_provider).
-export([init/1, load_chunk/2, generate_chunk/3]).

init(Config) ->
    {ok, Config}.

load_chunk(Coords, #{chunks := Chunks} = State) ->
    case maps:get(Coords, Chunks, undefined) of
        undefined -> {error, not_found};
        Data -> {ok, Data, State}
    end;
load_chunk(_Coords, State) ->
    {error, not_found, State}.

generate_chunk({X, Y}, Seed, State) ->
    Bin = asobi_terrain:compress_chunk(
        asobi_terrain:encode_chunk([{0, 0, X + Y + Seed, 0, 0}])
    ),
    {ok, Bin, State}.

%% --- Helpers ---

start_store(ProviderArgs) ->
    {ok, Pid} = asobi_terrain_store:start_link(#{
        provider => {?MODULE, ProviderArgs},
        seed => 42
    }),
    unlink(Pid),
    Pid.

stop_store(Pid) ->
    catch exit(Pid, shutdown),
    timer:sleep(10).

%% --- Tests ---

cache_miss_loads_from_provider_test() ->
    Chunk = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk([{0, 0, 1, 0, 0}])),
    Pid = start_store(#{chunks => #{{5, 5} => Chunk}}),
    ?assertEqual({ok, Chunk}, asobi_terrain_store:get_chunk(Pid, {5, 5})),
    stop_store(Pid).

cache_hit_returns_same_data_test() ->
    Chunk = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk([{0, 0, 1, 0, 0}])),
    Pid = start_store(#{chunks => #{{0, 0} => Chunk}}),
    {ok, D1} = asobi_terrain_store:get_chunk(Pid, {0, 0}),
    {ok, D2} = asobi_terrain_store:get_chunk(Pid, {0, 0}),
    ?assertEqual(D1, D2),
    #{misses := 1} = asobi_terrain_store:stats(Pid),
    stop_store(Pid).

generate_fallback_test() ->
    Pid = start_store(#{chunks => #{}}),
    {ok, Data} = asobi_terrain_store:get_chunk(Pid, {3, 4}),
    ?assert(is_binary(Data)),
    Decoded = asobi_terrain:decode_chunk(asobi_terrain:decompress_chunk(Data)),
    ?assert(lists:member({0, 0, 3 + 4 + 42, 0, 0}, Decoded)),
    stop_store(Pid).

evict_test() ->
    Chunk = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk([{0, 0, 1, 0, 0}])),
    Pid = start_store(#{chunks => #{{0, 0} => Chunk}}),
    {ok, _} = asobi_terrain_store:get_chunk(Pid, {0, 0}),
    #{cached_chunks := 1} = asobi_terrain_store:stats(Pid),
    ok = asobi_terrain_store:evict_chunk(Pid, {0, 0}),
    timer:sleep(10),
    #{cached_chunks := 0} = asobi_terrain_store:stats(Pid),
    stop_store(Pid).

preload_test() ->
    C1 = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk([{0, 0, 1, 0, 0}])),
    C2 = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk([{0, 0, 2, 0, 0}])),
    Pid = start_store(#{chunks => #{{0, 0} => C1, {1, 0} => C2}}),
    ok = asobi_terrain_store:preload_chunks(Pid, [{0, 0}, {1, 0}]),
    timer:sleep(50),
    #{cached_chunks := 2} = asobi_terrain_store:stats(Pid),
    stop_store(Pid).

stats_memory_test() ->
    Pid = start_store(#{chunks => #{}}),
    #{memory_bytes := Mem} = asobi_terrain_store:stats(Pid),
    ?assert(Mem > 0),
    stop_store(Pid).
