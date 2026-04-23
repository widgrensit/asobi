-module(asobi_matchmaker_fill).
-behaviour(asobi_matchmaker_strategy).

-doc """
Fill strategy — groups players in order until match_size is reached.
No skill matching. First-come-first-served.
""".

-export([match/2]).

-spec match([map()], map()) -> {[[map()]], [map()]}.
match(Tickets, Config) ->
    Size = maps:get(match_size, Config, 2),
    group(Tickets, Size, []).

-spec group([map()], pos_integer(), [[map()]]) -> {[[map()]], [map()]}.
group(Remaining, Size, Matched) when length(Remaining) < Size ->
    {rev(Matched, []), Remaining};
group(Tickets, Size, Matched) ->
    {Group, Rest} = split_at(Size, Tickets),
    group(Rest, Size, [Group | Matched]).

-spec split_at(non_neg_integer(), [T]) -> {[T], [T]}.
split_at(0, Rest) ->
    {[], Rest};
split_at(_, []) ->
    {[], []};
split_at(N, [H | T]) ->
    {Taken, Rest} = split_at(N - 1, T),
    {[H | Taken], Rest}.

-spec rev([T], [T]) -> [T].
rev([], Acc) -> Acc;
rev([H | T], Acc) -> rev(T, [H | Acc]).
