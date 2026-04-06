-module(asobi_glicko2).
-moduledoc """
Glicko-2 rating system implementation.

Based on Mark Glickman's paper:
http://www.glicko.net/glicko/glicko2.pdf

Default values:
- Initial rating: 1500
- Initial deviation: 350
- Initial volatility: 0.06
- System constant (tau): 0.5
""".

-export([rate/2, rate/3]).
-export([default_rating/0, default_deviation/0, default_volatility/0]).

-define(DEFAULT_RATING, 1500.0).
-define(DEFAULT_DEVIATION, 350.0).
-define(DEFAULT_VOLATILITY, 0.06).
-define(TAU, 0.5).
-define(CONVERGENCE_TOLERANCE, 0.000001).
-define(GLICKO2_SCALE, 173.7178).

-type rating() :: #{
    rating := float(),
    deviation := float(),
    volatility := float()
}.

-type outcome() :: #{
    opponent := rating(),
    score := float()
}.

-export_type([rating/0, outcome/0]).

-spec default_rating() -> float().
default_rating() -> ?DEFAULT_RATING.

-spec default_deviation() -> float().
default_deviation() -> ?DEFAULT_DEVIATION.

-spec default_volatility() -> float().
default_volatility() -> ?DEFAULT_VOLATILITY.

-doc """
Update a player's rating given a list of match outcomes.

Each outcome contains the opponent's rating and the score (1.0 = win, 0.5 = draw, 0.0 = loss).
""".
-spec rate(rating(), [outcome()]) -> rating().
rate(Player, Outcomes) ->
    rate(Player, Outcomes, ?TAU).

-spec rate(rating(), [outcome()], float()) -> rating().
rate(Player, [], _Tau) ->
    #{deviation := RD, volatility := Vol} = Player,
    RD2 = to_glicko2_rd(RD),
    NewRD2 = math:sqrt(RD2 * RD2 + Vol * Vol),
    Player#{deviation => from_glicko2_rd(NewRD2)};
rate(Player, Outcomes, Tau) ->
    #{rating := R, deviation := RD, volatility := Vol} = Player,
    Mu = to_glicko2(R),
    Phi = to_glicko2_rd(RD),
    OpponentData = [
        {
            to_glicko2(maps:get(rating, maps:get(opponent, O))),
            to_glicko2_rd(maps:get(deviation, maps:get(opponent, O))),
            maps:get(score, O)
        }
     || O <- Outcomes
    ],
    V = compute_v(Mu, OpponentData),
    Delta = compute_delta(Mu, OpponentData, V),
    NewVol = compute_new_volatility(Phi, V, Delta, Vol, Tau),
    PhiStar = math:sqrt(Phi * Phi + NewVol * NewVol),
    NewPhi = 1.0 / math:sqrt(1.0 / (PhiStar * PhiStar) + 1.0 / V),
    NewMu = Mu + NewPhi * NewPhi * sum_g_e(Mu, OpponentData),
    #{
        rating => from_glicko2(NewMu),
        deviation => from_glicko2_rd(NewPhi),
        volatility => NewVol
    }.

%% --- Internal ---

-spec to_glicko2(float()) -> float().
to_glicko2(R) -> (R - ?DEFAULT_RATING) / ?GLICKO2_SCALE.

-spec from_glicko2(float()) -> float().
from_glicko2(Mu) -> Mu * ?GLICKO2_SCALE + ?DEFAULT_RATING.

-spec to_glicko2_rd(float()) -> float().
to_glicko2_rd(RD) -> RD / ?GLICKO2_SCALE.

-spec from_glicko2_rd(float()) -> float().
from_glicko2_rd(Phi) -> Phi * ?GLICKO2_SCALE.

-spec g(float()) -> float().
g(Phi) ->
    1.0 / math:sqrt(1.0 + 3.0 * Phi * Phi / (math:pi() * math:pi())).

-spec e(float(), float(), float()) -> float().
e(Mu, MuJ, PhiJ) ->
    1.0 / (1.0 + math:exp(-g(PhiJ) * (Mu - MuJ))).

-spec compute_v(float(), [{float(), float(), float()}]) -> float().
compute_v(Mu, Opponents) ->
    1.0 / compute_v_sum(Mu, Opponents, 0.0).

-spec compute_v_sum(float(), [{float(), float(), float()}], float()) -> float().
compute_v_sum(_Mu, [], Acc) ->
    Acc;
compute_v_sum(Mu, [{MuJ, PhiJ, _S} | Rest], Acc) ->
    GPhiJ = g(PhiJ),
    EVal = e(Mu, MuJ, PhiJ),
    compute_v_sum(Mu, Rest, Acc + GPhiJ * GPhiJ * EVal * (1.0 - EVal)).

-spec sum_g_e(float(), [{float(), float(), float()}]) -> float().
sum_g_e(Mu, Opponents) ->
    sum_g_e(Mu, Opponents, 0.0).

-spec sum_g_e(float(), [{float(), float(), float()}], float()) -> float().
sum_g_e(_Mu, [], Acc) ->
    Acc;
sum_g_e(Mu, [{MuJ, PhiJ, S} | Rest], Acc) ->
    sum_g_e(Mu, Rest, Acc + g(PhiJ) * (S - e(Mu, MuJ, PhiJ))).

-spec compute_delta(float(), [{float(), float(), float()}], float()) -> float().
compute_delta(Mu, Opponents, V) ->
    V * sum_g_e(Mu, Opponents).

-spec compute_new_volatility(float(), float(), float(), float(), float()) -> float().
compute_new_volatility(Phi, V, Delta, Sigma, Tau) ->
    A = math:log(Sigma * Sigma),
    F = fun(X) ->
        Ex = math:exp(X),
        Num1 = Ex * (Delta * Delta - Phi * Phi - V - Ex),
        Den1 = 2.0 * (Phi * Phi + V + Ex) * (Phi * Phi + V + Ex),
        Num1 / Den1 - (X - A) / (Tau * Tau)
    end,
    B =
        case Delta * Delta > Phi * Phi + V of
            true ->
                math:log(Delta * Delta - Phi * Phi - V);
            false ->
                find_initial_b(A, Tau, F, 1)
        end,
    FA = F(A),
    FB = F(B),
    illinois_method(A, B, FA, FB, F).

-spec find_initial_b(float(), float(), fun((float()) -> float()), pos_integer()) -> float().
find_initial_b(A, Tau, F, K) ->
    Val = A - K * Tau,
    case F(Val) < 0 of
        true -> find_initial_b(A, Tau, F, K + 1);
        false -> Val
    end.

-spec illinois_method(float(), float(), float(), float(), fun((float()) -> float())) -> float().
illinois_method(A, B, FA, FB, F) ->
    case abs(B - A) > ?CONVERGENCE_TOLERANCE of
        true ->
            C = A + (A - B) * FA / (FB - FA),
            FC = F(C),
            case FC * FB =< 0 of
                true ->
                    illinois_method(B, C, FB, FC, F);
                false ->
                    illinois_method(A, C, FA / 2.0, FC, F)
            end;
        false ->
            math:exp(A / 2.0)
    end.
