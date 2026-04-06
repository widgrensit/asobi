-module(asobi_glicko2_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test values from Glickman's paper (Example calculation, Section 4)
%% Player: rating 1500, RD 200, vol 0.06
%% Opponents:
%%   1. rating 1400, RD 30,  score 1.0 (win)
%%   2. rating 1550, RD 100, score 0.0 (loss)
%%   3. rating 1700, RD 300, score 0.0 (loss)

paper_example_test() ->
    Player = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Outcomes = [
        #{opponent => #{rating => 1400.0, deviation => 30.0, volatility => 0.06}, score => 1.0},
        #{opponent => #{rating => 1550.0, deviation => 100.0, volatility => 0.06}, score => 0.0},
        #{opponent => #{rating => 1700.0, deviation => 300.0, volatility => 0.06}, score => 0.0}
    ],
    Result = asobi_glicko2:rate(Player, Outcomes),
    #{rating := R, deviation := RD, volatility := Vol} = Result,
    %% Expected from the paper: R ≈ 1464.06, RD ≈ 151.52, vol ≈ 0.05999
    ?assert(abs(R - 1464.06) < 1.0),
    ?assert(abs(RD - 151.52) < 1.0),
    ?assert(abs(Vol - 0.05999) < 0.001).

defaults_test() ->
    ?assertEqual(1500.0, asobi_glicko2:default_rating()),
    ?assertEqual(350.0, asobi_glicko2:default_deviation()),
    ?assertEqual(0.06, asobi_glicko2:default_volatility()).

no_games_increases_deviation_test() ->
    Player = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Result = asobi_glicko2:rate(Player, []),
    ?assert(maps:get(deviation, Result) > 200.0),
    ?assertEqual(1500.0, maps:get(rating, Result)).

win_increases_rating_test() ->
    Player = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Opp = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Result = asobi_glicko2:rate(Player, [#{opponent => Opp, score => 1.0}]),
    ?assert(maps:get(rating, Result) > 1500.0).

loss_decreases_rating_test() ->
    Player = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Opp = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Result = asobi_glicko2:rate(Player, [#{opponent => Opp, score => 0.0}]),
    ?assert(maps:get(rating, Result) < 1500.0).

draw_against_equal_keeps_rating_test() ->
    Player = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Opp = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Result = asobi_glicko2:rate(Player, [#{opponent => Opp, score => 0.5}]),
    ?assert(abs(maps:get(rating, Result) - 1500.0) < 1.0).

deviation_shrinks_with_games_test() ->
    Player = #{rating => 1500.0, deviation => 350.0, volatility => 0.06},
    Opp = #{rating => 1500.0, deviation => 200.0, volatility => 0.06},
    Result = asobi_glicko2:rate(Player, [#{opponent => Opp, score => 1.0}]),
    ?assert(maps:get(deviation, Result) < 350.0).

upset_win_gives_bigger_boost_test() ->
    Player = #{rating => 1200.0, deviation => 200.0, volatility => 0.06},
    StrongOpp = #{rating => 1800.0, deviation => 100.0, volatility => 0.06},
    WeakOpp = #{rating => 1200.0, deviation => 100.0, volatility => 0.06},
    R1 = asobi_glicko2:rate(Player, [#{opponent => StrongOpp, score => 1.0}]),
    R2 = asobi_glicko2:rate(Player, [#{opponent => WeakOpp, score => 1.0}]),
    ?assert(maps:get(rating, R1) > maps:get(rating, R2)).
