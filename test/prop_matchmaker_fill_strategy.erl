-module(prop_matchmaker_fill_strategy).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr: random ticket queue + match_size, the fill strategy:
%%
%%   - returns groups of exactly match_size
%%   - leftover queue has < match_size tickets
%%   - groups + leftover preserves the input list (no drops, no dupes)
%%   - within each group, ticket order matches input order (FCFS)

-define(NUMTESTS, 100).

matchmaker_fill_strategy_test_() ->
    {timeout, 30,
        ?_assert(
            proper:quickcheck(prop_fill_strategy(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

%% --- Property ---

prop_fill_strategy() ->
    ?FORALL(
        {Tickets, Size},
        {ticket_queue(), match_size()},
        run_iteration(narrow_tickets(Tickets), narrow_int(Size))
    ).

ticket_queue() ->
    proper_types:list(ticket()).

ticket() ->
    ?LET(Id, proper_types:integer(1, 1_000_000), make_ticket(Id)).

-spec make_ticket(term()) -> #{id => binary(), submitted_at => integer()}.
make_ticket(Id) when is_integer(Id) ->
    #{id => integer_to_binary(Id), submitted_at => Id}.

match_size() ->
    proper_types:integer(1, 8).

%% --- Runner ---

-spec run_iteration([map()], pos_integer()) -> boolean().
run_iteration(Tickets, Size) ->
    {Groups, Remaining} = asobi_matchmaker_fill:match(Tickets, #{match_size => Size}),
    Checks = [
        {all_groups_correct_size, all_groups_size(Groups, Size)},
        {remaining_below_size, length(Remaining) < Size},
        {preserves_count, total_count(Groups) + length(Remaining) =:= length(Tickets)},
        {preserves_order, preserves_order(Tickets, Groups, Remaining)}
    ],
    case all_passed(Checks) of
        true ->
            true;
        false ->
            io:format(
                user,
                "~ninvariants violated: ~p~n  tickets=~p size=~p~n  groups=~p remaining=~p~n",
                [
                    [K || {K, V} <- Checks, V =/= true],
                    Tickets,
                    Size,
                    Groups,
                    Remaining
                ]
            ),
            false
    end.

-spec all_groups_size([[term()]], pos_integer()) -> boolean().
all_groups_size([], _Size) ->
    true;
all_groups_size([G | Rest], Size) when is_list(G) ->
    case length(G) =:= Size of
        true -> all_groups_size(Rest, Size);
        false -> false
    end.

-spec total_count([[term()]]) -> non_neg_integer().
total_count([]) -> 0;
total_count([G | Rest]) when is_list(G) -> length(G) + total_count(Rest).

-spec all_passed([{atom(), boolean()}]) -> boolean().
all_passed([]) -> true;
all_passed([{_, true} | Rest]) -> all_passed(Rest);
all_passed([{_, false} | _]) -> false.

preserves_order(Tickets, Groups, Remaining) ->
    Flattened = lists:append(Groups) ++ Remaining,
    Flattened =:= Tickets.

-spec narrow_tickets(term()) -> [map()].
narrow_tickets(L) when is_list(L) -> [T || T <- L, is_map(T)].

-spec narrow_int(term()) -> pos_integer().
narrow_int(N) when is_integer(N), N > 0 -> N.
