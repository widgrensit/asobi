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
    Sorted = sort_by_skill(Tickets),
    match_groups(Sorted, Size, Window, ExpandRate, [], []).

-spec sort_by_skill([map()]) -> [map()].
sort_by_skill(Tickets) ->
    Tagged = tag_skill(Tickets),
    Sorted = lists:keysort(1, Tagged),
    untag_skill(Sorted).

-spec tag_skill([map()]) -> [{integer(), map()}].
tag_skill([]) -> [];
tag_skill([T | Rest]) -> [{skill(T), T} | tag_skill(Rest)].

-spec untag_skill([{integer(), map()}]) -> [map()].
untag_skill([]) -> [];
untag_skill([{_, T} | Rest]) -> [T | untag_skill(Rest)].

-spec match_groups([map()], pos_integer(), integer(), integer(), [[map()]], [map()]) ->
    {[[map()]], [map()]}.
match_groups([], _Size, _Window, _Rate, Matched, Unmatched) ->
    {rev(Matched, []), Unmatched};
match_groups(Tickets, Size, _Window, _Rate, Matched, Unmatched) when length(Tickets) < Size ->
    {rev(Matched, []), Tickets ++ Unmatched};
match_groups([First | _] = Tickets, Size, Window, Rate, Matched, Unmatched) ->
    {Candidate, Rest} = split_at(Size, Tickets, []),
    case group_within_window(Candidate, Window, Rate) of
        true ->
            match_groups(Rest, Size, Window, Rate, [Candidate | Matched], Unmatched);
        false ->
            [_ | Remaining] = Tickets,
            match_groups(Remaining, Size, Window, Rate, Matched, [First | Unmatched])
    end.

-spec split_at(non_neg_integer(), [T], [T]) -> {[T], [T]}.
split_at(0, Rest, Acc) ->
    {rev(Acc, []), Rest};
split_at(_, [], Acc) ->
    {rev(Acc, []), []};
split_at(N, [H | T], Acc) ->
    split_at(N - 1, T, [H | Acc]).

-spec rev([T], [T]) -> [T].
rev([], Acc) -> Acc;
rev([H | T], Acc) -> rev(T, [H | Acc]).

-spec group_within_window([map()], integer(), integer()) -> boolean().
group_within_window([], _Window, _Rate) ->
    true;
group_within_window([_], _Window, _Rate) ->
    true;
group_within_window([First | _] = Group, BaseWindow, Rate) ->
    Last = last_elem(Group),
    Diff = abs(skill(First) - skill(Last)),
    EffectiveWindow = effective_window(First, BaseWindow, Rate),
    Diff =< EffectiveWindow.

-spec last_elem([T, ...]) -> T.
last_elem([X]) -> X;
last_elem([_ | Rest]) -> last_elem(Rest).

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
