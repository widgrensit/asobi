-module(asobi_lua_vm_spike_bench).
-moduledoc """
#536 spike bench: one zone-tick's worth of work through today's copying path
and through the state-owning VM process, across state sizes.

The shape mirrors `asobi_lua_world:zone_tick/2` - encode the entity map, call
the script, decode what came back - because that is the loop whose cost is
being argued about.
""".
-include_lib("eunit/include/eunit.hrl").

-define(REPS, 20).

fixture(N) ->
    filename:join([code:lib_dir(asobi), "..", "..", "..", "..", "test", "fixtures", "lua", N]).

entities(N) ->
    #{
        integer_to_binary(I) => #{~"x" => I, ~"y" => I, ~"type" => ~"npc", ~"hp" => 100}
     || I <- lists:seq(1, N)
    }.

state(Rows) ->
    {ok, St} = asobi_lua_loader:new(fixture("gc_zone.lua")),
    {ok, [GS | _], St1} = asobi_lua_loader:call(big_state, [Rows], St),
    {St1, GS}.

%% Today: one worker per callback, the whole state copied in and back.
tick_copying(St0, GS, Ents) ->
    {Enc, St1} = luerl:encode(Ents, St0),
    {ok, [Ents1 | _], St2} = asobi_lua_loader:call(zone_tick, [Enc, GS], St1, 5000),
    _ = luerl:decode(Ents1, St2),
    St2.

%% Spike: three small messages, the state never leaves its process.
tick_owned(Vm, GS, Ents) ->
    Enc = asobi_lua_vm_spike:encode(Vm, Ents),
    {ok, [Ents1 | _]} = asobi_lua_vm_spike:call(Vm, zone_tick, [Enc, GS]),
    _ = asobi_lua_vm_spike:decode(Vm, Ents1),
    ok.

bench_test_() ->
    {timeout, 900, fun() ->
        application:set_env(asobi, max_heap_words, 5_000_000),
        Ents = entities(50),
        io:format(user, "~n  state | copying (call/4) | owned VM | speedup~n", []),
        [
            begin
                {St, GS} = state(Rows),
                Mb = (erts_debug:flat_size(St) * erlang:system_info(wordsize)) div 1048576,
                {TCopy, _} = timer:tc(fun() ->
                    lists:foldl(fun(_, S) -> tick_copying(S, GS, Ents) end, St, lists:seq(1, ?REPS))
                end),
                {ok, Vm} = asobi_lua_vm_spike:start_link(St),
                {TOwn, _} = timer:tc(fun() ->
                    [tick_owned(Vm, GS, Ents) || _ <- lists:seq(1, ?REPS)]
                end),
                asobi_lua_vm_spike:stop(Vm),
                io:format(user, "  ~4w MB | ~13.2f ms | ~6.3f ms | ~wx~n", [
                    Mb,
                    TCopy / (?REPS * 1000),
                    TOwn / (?REPS * 1000),
                    round(TCopy / max(TOwn, 1))
                ])
            end
         || Rows <- [500, 5_000, 20_000, 60_000, 120_000]
        ],
        ok
    end}.
