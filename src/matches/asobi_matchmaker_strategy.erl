-module(asobi_matchmaker_strategy).

-doc """
Behaviour for matchmaking strategies.

Implement `match/2` to define how tickets are grouped into matches.
Return `{Matched, Unmatched}` where Matched is a list of groups
(each group is a list of tickets that form a match) and Unmatched
is the remaining tickets that couldn't be matched.
""".

-callback match(Tickets :: [map()], Config :: map()) ->
    {Matched :: [[map()]], Unmatched :: [map()]}.
