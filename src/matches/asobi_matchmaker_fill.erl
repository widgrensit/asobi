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
    {lists:reverse(Matched), Remaining};
group(Tickets, Size, Matched) ->
    {Group, Rest} = lists:split(Size, Tickets),
    group(Rest, Size, [Group | Matched]).
