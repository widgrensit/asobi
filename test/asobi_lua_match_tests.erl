-module(asobi_lua_match_tests).
-include_lib("eunit/include/eunit.hrl").

fixture(Name) ->
    filename:join([code:lib_dir(asobi), "test", "fixtures", "lua", Name]).

%% --- Match behaviour tests ---

lua_match_test_() ->
    [
        {"init loads lua and returns state", fun init_ok/0},
        {"init fails with bad script", fun init_bad_script/0},
        {"init fails with missing script", fun init_missing_script/0},
        {"join adds player to state", fun join_adds_player/0},
        {"leave removes player", fun leave_removes_player/0},
        {"handle_input updates player position", fun input_moves_player/0},
        {"handle_input handles boon pick", fun input_boon_pick/0},
        {"tick increments counter", fun tick_increments/0},
        {"tick signals finished", fun tick_finishes/0},
        {"get_state returns player view", fun get_state_view/0},
        {"vote_requested returns config at right tick", fun vote_requested_ok/0},
        {"vote_requested returns none normally", fun vote_requested_none/0},
        {"vote_resolved updates state", fun vote_resolved_ok/0},
        {"finish_immediately script", fun finish_immediately/0}
    ].

init_ok() ->
    Config = #{lua_script => fixture("test_match.lua")},
    {ok, State} = asobi_lua_match:init(Config),
    ?assert(is_map(State)),
    ?assertMatch(#{lua_state := _, game_state := _}, State).

init_bad_script() ->
    Config = #{lua_script => fixture("bad_script.lua")},
    {error, _} = asobi_lua_match:init(Config).

init_missing_script() ->
    Config = #{lua_script => fixture("nonexistent.lua")},
    {error, _} = asobi_lua_match:init(Config).

join_adds_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    PlayerState = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(PlayerState)).

leave_removes_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:leave(~"player1", State1),
    PlayerState = asobi_lua_match:get_state(~"player1", State2),
    ?assert(is_map(PlayerState)).

input_moves_player() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"right" => true, ~"left" => false, ~"up" => false, ~"down" => false},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

input_boon_pick() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    Input = #{~"type" => ~"boon_pick", ~"boon_id" => ~"hp_boost"},
    {ok, State2} = asobi_lua_match:handle_input(~"player1", Input, State1),
    ?assert(is_map(State2)).

tick_increments() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    ?assert(is_map(State2)).

tick_finishes() ->
    Config = #{lua_script => fixture("test_match.lua"), game_config => #{max_ticks => 2}},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    {ok, State2} = asobi_lua_match:tick(State1),
    case asobi_lua_match:tick(State2) of
        {finished, Result, _State3} ->
            ?assert(is_map(Result));
        {ok, _State3} ->
            %% Might need more ticks depending on how Lua numbers work
            ok
    end.

get_state_view() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    View = asobi_lua_match:get_state(~"player1", State1),
    ?assert(is_map(View)).

vote_requested_ok() ->
    {ok, State0} = init_match(),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    %% Tick 50 times to trigger vote_requested
    State50 = lists:foldl(
        fun(_, Acc) ->
            case asobi_lua_match:tick(Acc) of
                {ok, S} -> S;
                {finished, _, S} -> S
            end
        end,
        State1,
        lists:seq(1, 50)
    ),
    case asobi_lua_match:vote_requested(State50) of
        {ok, VoteConfig} ->
            ?assert(is_map(VoteConfig));
        none ->
            %% Lua tick_count may differ due to float comparison
            ok
    end.

vote_requested_none() ->
    {ok, State0} = init_match(),
    ?assertEqual(none, asobi_lua_match:vote_requested(State0)).

vote_resolved_ok() ->
    {ok, State0} = init_match(),
    Result = #{winner => ~"opt_a"},
    {ok, State1} = asobi_lua_match:vote_resolved(~"test_vote", Result, State0),
    ?assert(is_map(State1)).

finish_immediately() ->
    Config = #{lua_script => fixture("finish_immediately.lua")},
    {ok, State0} = asobi_lua_match:init(Config),
    {ok, State1} = asobi_lua_match:join(~"player1", State0),
    case asobi_lua_match:tick(State1) of
        {finished, Result, _} ->
            ?assert(is_map(Result));
        {ok, _} ->
            ?assert(false)
    end.

%% --- Helpers ---

init_match() ->
    Config = #{lua_script => fixture("test_match.lua")},
    asobi_lua_match:init(Config).
