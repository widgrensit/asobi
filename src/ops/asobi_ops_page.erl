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
""".

-include_lib("kura/include/kura.hrl").

-export([list/3]).

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
