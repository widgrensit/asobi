-module(asobi_matchmaker_skill).
-behaviour(asobi_matchmaker_strategy).

-doc """
Skill-based strategy — sorts by skill and pairs adjacent players
within a configurable skill window that expands over wait time.

Config keys:
- match_size: players per match (default 2)
- skill_window: initial skill difference allowed (default 200)
- skill_expand_rate: window expansion per 5 seconds of wait (default 50)
""".

-export([match/2]).

-spec match([map()], map()) -> {[[map()]], [map()]}.
match(Tickets, Config) ->
    Size = maps:get(match_size, Config, 2),
    Window = maps:get(skill_window, Config, 200),
    ExpandRate = maps:get(skill_expand_rate, Config, 50),
    Sorted = lists:sort(fun(A, B) -> skill(A) =< skill(B) end, Tickets),
    match_groups(Sorted, Size, Window, ExpandRate, [], []).

-spec match_groups([map()], pos_integer(), integer(), integer(), [[map()]], [map()]) ->
    {[[map()]], [map()]}.
match_groups([], _Size, _Window, _Rate, Matched, Unmatched) ->
    {lists:reverse(Matched), Unmatched};
match_groups(Tickets, Size, _Window, _Rate, Matched, Unmatched) when length(Tickets) < Size ->
    {lists:reverse(Matched), Tickets ++ Unmatched};
match_groups(Tickets, Size, Window, Rate, Matched, Unmatched) ->
    {Candidate, Rest} = lists:split(Size, Tickets),
    case group_within_window(Candidate, Window, Rate) of
        true ->
            match_groups(Rest, Size, Window, Rate, [Candidate | Matched], Unmatched);
        false ->
            [First | Remaining] = Tickets,
            match_groups(Remaining, Size, Window, Rate, Matched, [First | Unmatched])
    end.

-spec group_within_window([map()], integer(), integer()) -> boolean().
group_within_window([], _Window, _Rate) ->
    true;
group_within_window([_], _Window, _Rate) ->
    true;
group_within_window(Group, BaseWindow, Rate) ->
    First = hd(Group),
    Last = lists:last(Group),
    Diff = abs(skill(First) - skill(Last)),
    EffectiveWindow = effective_window(First, BaseWindow, Rate),
    Diff =< EffectiveWindow.

-spec effective_window(map(), integer(), integer()) -> integer().
effective_window(#{submitted_at := Sub}, BaseWindow, Rate) ->
    WaitSec = (erlang:system_time(millisecond) - Sub) div 1000,
    BaseWindow + (WaitSec div 5) * Rate;
effective_window(_, BaseWindow, _Rate) ->
    BaseWindow.

-spec skill(map()) -> integer().
skill(#{properties := #{skill := S}}) when is_integer(S) -> S;
skill(#{properties := #{~"skill" := S}}) when is_integer(S) -> S;
skill(_) -> 1000.
