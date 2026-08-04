-module(asobi_ops_page).
-moduledoc """
The one list envelope every ops read endpoint returns.

```erlang
#{data => [...], page => #{limit => 50, offset => 0, total => 137}}
```

`total` is the point of the envelope: a console that cannot say how many rows
exist cannot render a pager, and every list endpoint that predates this module
made the caller guess. `kura_paginator:paginate/3` runs the count and the page
as one unit, so the two can never describe different filters.

`Project` is applied to every row on the way out. It is the endpoint's field
allowlist, not a formatter - see the projections in `asobi_ops_players` and
`asobi_ops_matches`.

`list/3` pages a database query; `slice/4` pages rows already in hand, for
the reads the database cannot page - a queue held in a process, and a board
list whose one grouped aggregate has to run whole either way. Both produce
the identical envelope, so a console cannot tell them apart.
""".

-include_lib("kura/include/kura.hrl").

-export([list/3, slice/4]).

-doc """
Run `Query` as one page and wrap it in the envelope.

`Query` must already carry a deterministic order; `asobi_ops_params:sort/3`
guarantees one. Without it the offset window is not stable between requests.
""".
-spec list(#kura_query{}, asobi_ops_params:page_spec(), fun((map()) -> map())) ->
    {ok, map()} | {error, term()}.
list(Query, #{limit := Limit, offset := Offset}, Project) when
    is_integer(Limit), Limit > 0, is_integer(Offset), Offset >= 0
->
    PageNumber = Offset div Limit + 1,
    case kura_paginator:paginate(asobi_repo, Query, #{page => PageNumber, page_size => Limit}) of
        {ok, #{entries := Entries, total_entries := Total}} ->
            {ok, #{
                data => [Project(Entry) || Entry <- Entries],
                page => #{limit => Limit, offset => Offset, total => Total}
            }};
        {error, _} = Error ->
            Error
    end.

-doc """
Wrap an in-memory row list in the same envelope, sorting it first.

`Orders` comes from `asobi_ops_params:sort/4` exactly as it would for a
query, so it ends on a unique key and the window is stable between requests.
Rows sort by Erlang term order rather than a database collation - these row
sets are counts, timestamps and identifiers, never prose - and a missing key
sorts as `undefined`, so a row is never dropped for lacking one.

This never fails: the data is already read. Both sources it serves are
bounded (a queue by `max_queue`, a board set by its enumeration cap), so
sorting the whole list to return one page of it is not the cost that matters.
""".
-spec slice(
    [map()], asobi_ops_params:sort_spec(), asobi_ops_params:page_spec(), fun((map()) -> map())
) -> map().
slice(Rows, Orders, #{limit := Limit, offset := Offset}, Project) when
    is_integer(Limit), Limit > 0, is_integer(Offset), Offset >= 0
->
    Total = length(Rows),
    Sorted = lists:sort(fun(A, B) -> precedes(Orders, A, B) end, Rows),
    Window = lists:sublist(lists:nthtail(min(Offset, Total), Sorted), Limit),
    #{
        data => [Project(Row) || Row <- Window],
        page => #{limit => Limit, offset => Offset, total => Total}
    }.

-spec precedes(asobi_ops_params:sort_spec(), map(), map()) -> boolean().
precedes([], _A, _B) ->
    true;
precedes([{Key, Direction} | Rest], A, B) ->
    Left = maps:get(Key, A, undefined),
    Right = maps:get(Key, B, undefined),
    if
        %% `==`, not `=:=`: an integer and a float score that compare equal
        %% must fall through to the tie-breaker, not to an arbitrary order.
        Left == Right -> precedes(Rest, A, B);
        Direction =:= asc -> Left < Right;
        true -> Left > Right
    end.
