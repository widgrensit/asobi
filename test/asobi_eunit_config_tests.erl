-module(asobi_eunit_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi #279: without a scale factor, EUnit's 5s default per-test timeout kills
%% the enclosing group's runner on a slow CI machine, cancelling every test after
%% it and turning a green suite red at random.
scale_timeouts_configured_test() ->
    {ok, Terms} = file:consult("rebar.config"),
    Profiles = section(profiles, Terms),
    TestProfile = section(test, Profiles),
    EunitOpts = section(eunit_opts, TestProfile),
    ?assert(int_opt(scale_timeouts, EunitOpts, 1) >= 2).

%% A comprehension rather than lists:keyfind/3: file:consult/1 answers
%% [term()], keyfind wants [tuple()], and the tuple pattern in a generator
%% narrows where keyfind cannot. See docs/eqwalizer-idioms.md.
-spec section(atom(), [term()]) -> [term()].
section(Key, Terms) ->
    [Section] = [V || {K, V} <- Terms, K =:= Key, is_list(V)],
    Section.

-spec int_opt(atom(), [term()], integer()) -> integer().
int_opt(Key, Opts, Default) ->
    case [V || {K, V} <- Opts, K =:= Key, is_integer(V)] of
        [V | _] -> V;
        [] -> Default
    end.
