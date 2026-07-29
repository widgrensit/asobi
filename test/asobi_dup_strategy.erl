-module(asobi_dup_strategy).

-export([match/2]).

%% Hostile test strategy: returns every ticket duplicated into one group, so the
%% matched group repeats a player. The matchmaker's reject seam must drop it and
%% re-queue rather than spawn a self-match. Used by asobi_matchmaker_SUITE.
match(Tickets, _Config) ->
    {[Tickets ++ Tickets], []}.
