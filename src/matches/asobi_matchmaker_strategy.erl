-module(asobi_matchmaker_strategy).
-moduledoc """
Behaviour for matchmaking strategies.

Implement `match/2` to define how tickets are grouped into matches. Asobi ships
`fill` and `skill_based`; provide your own by implementing this behaviour and
pointing the matchmaker at your module.
""".

-doc """
Group pending tickets into matches.

Return `{Matched, Unmatched}` where `Matched` is a list of groups (each group a
list of tickets that form one match) and `Unmatched` is the tickets that could
not be matched this pass.
""".
-callback match(Tickets :: [map()], Config :: map()) ->
    {Matched :: [[map()]], Unmatched :: [map()]}.
