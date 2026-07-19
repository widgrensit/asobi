-module(asobi_game_join_tests).
-include_lib("eunit/include/eunit.hrl").

%% Two fake game modules: one exporting only join/2, one exporting both.
%% They are defined at the bottom via meck so the dispatch is exercised
%% against real export tables rather than a stub of function_exported/3.

setup() ->
    meck:new(join2_only, [non_strict, no_link]),
    meck:expect(join2_only, join, fun(PlayerId, GS) -> {ok, GS#{joined => PlayerId}} end),
    meck:new(join3_game, [non_strict, no_link]),
    meck:expect(join3_game, join, fun(PlayerId, GS) ->
        {ok, GS#{via => join2, joined => PlayerId}}
    end),
    meck:expect(join3_game, join, fun(PlayerId, Ctx, GS) ->
        case maps:get(~"code", Ctx, undefined) of
            ~"open-sesame" -> {ok, GS#{via => join3, joined => PlayerId}};
            _ -> {error, bad_code}
        end
    end),
    ok.

cleanup(_) ->
    meck:unload(join3_game),
    meck:unload(join2_only),
    ok.

join_dispatch_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"falls back to join/2 when join/3 is not exported", fun falls_back_to_join2/0},
        {"prefers join/3 when exported", fun prefers_join3/0},
        {"join/3 can reject on the context", fun join3_can_reject/0},
        {"a join/2-only module ignores a supplied context", fun join2_ignores_ctx/0}
    ]}.

falls_back_to_join2() ->
    ?assertEqual(
        {ok, #{joined => ~"p1"}},
        asobi_game_join:invoke(join2_only, ~"p1", #{}, #{})
    ).

prefers_join3() ->
    ?assertEqual(
        {ok, #{via => join3, joined => ~"p1"}},
        asobi_game_join:invoke(join3_game, ~"p1", #{~"code" => ~"open-sesame"}, #{})
    ).

join3_can_reject() ->
    ?assertEqual(
        {error, bad_code},
        asobi_game_join:invoke(join3_game, ~"p1", #{~"code" => ~"wrong"}, #{})
    ),
    %% An empty context (matchmaker-spawned join, no client) is rejected by
    %% THIS game, which is the game's choice - core must not special-case it.
    ?assertEqual({error, bad_code}, asobi_game_join:invoke(join3_game, ~"p1", #{}, #{})).

join2_ignores_ctx() ->
    %% A game that has not opted in must be unaffected by a context the
    %% client supplies - no crash, no behaviour change.
    ?assertEqual(
        {ok, #{joined => ~"p1"}},
        asobi_game_join:invoke(join2_only, ~"p1", #{~"code" => ~"whatever"}, #{})
    ).
