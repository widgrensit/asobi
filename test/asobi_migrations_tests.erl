-module(asobi_migrations_tests).

-include_lib("eunit/include/eunit.hrl").

%% Dropping a table drops its indexes, so a drop_index for a table the same
%% down/0 drops raises 42704 and the rollback fails half way. rebar3_kura
%% v0.16.1 stopped generating those, but the migrations written before it did,
%% and nothing here would have noticed: down/0 only runs on a rollback.

every_down_is_runnable_test_() ->
    [
        {atom_to_list(Mod), fun() -> assert_no_index_of_dropped_table(Mod) end}
     || Mod <- migration_modules()
    ].

assert_no_index_of_dropped_table(Mod) ->
    Ops = Mod:down(),
    Dropped = [T || {drop_table, T} <- Ops],
    Redundant = [
        Name
     || {drop_index, Name} <- Ops,
        T <- Dropped,
        binary:longest_common_prefix([Name, <<T/binary, "_">>]) =:= byte_size(T) + 1
    ],
    ?assertEqual([], Redundant).

migration_modules() ->
    _ = application:load(asobi),
    {ok, Mods} = application:get_key(asobi, modules),
    [M || M <- Mods, is_migration(M)].

is_migration(Mod) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, up, 0) andalso erlang:function_exported(Mod, down, 0).
