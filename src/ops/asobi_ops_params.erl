-module(asobi_ops_params).
-moduledoc """
Request-input parsing for the ops read plane: query string, and the id in a
bound path segment.

Three rules, each of them load-bearing:

* Numbers are parsed safely and clamped. `?limit=abc` must never reach
  `binary_to_integer/1` (a `badarg` is a 500 and a free log-flood), and
  `?limit=10000000` must never reach the database. Parsing goes through
  `asobi_qs:integer/5`, which already fails soft to a default.
* `order_by` is built from a per-endpoint allowlist of atoms and nothing else.
  A user-supplied string reaching `order_by` is SQL injection, so an unknown
  sort field is *rejected* rather than ignored - silently falling back to a
  default would hide the mistake from the caller.
* Every sort ends on a unique column. Offset pagination over a non-unique key
  can return one row twice and skip another between pages, so `sort/3` appends
  the primary key as a tie-breaker, and `sort/4` takes the unique column for
  a row set that is not keyed on `id`.

`?page=N` and `?offset=N` both select a window. `page` wins when both are
given. The offset returned is the one the query actually used - see `page/1`.
""".

-export([page/1, sort/3, sort/4, search/2, like_pattern/2, cursor/1, encode_cursor/1]).
-export([filter/2, boolean/2, uuid/1]).

-export_type([params/0, page_spec/0, sort_spec/0, sort_allowlist/0, tie_break/0]).

-type params() :: #{binary() => binary() | true}.
-type page_spec() :: #{limit := pos_integer(), offset := non_neg_integer()}.
-type sort_spec() :: [{atom(), asc | desc}].
-type sort_allowlist() :: [{binary(), atom()}].
-type tie_break() :: {atom(), asc | desc}.

-define(DEFAULT_LIMIT, 50).
-define(MIN_LIMIT, 1).
-define(MAX_LIMIT, 200).
-define(MAX_OFFSET, 100000).
-define(MAX_PAGE, 10000).
-define(MAX_SEARCH_BYTES, 64).
-define(MAX_FILTER_BYTES, 64).
-define(MAX_CURSOR_BYTES, 128).

-doc """
Window for a list endpoint: a clamped limit and a clamped offset.

`limit` defaults to 50 and is clamped to `[1, 200]`. `offset` is clamped to
`[0, 100000]` - a deeper offset is a sequential scan, not a page.

The offset is then snapped down to a whole multiple of the limit, because
`kura_paginator:paginate/3` is page-based and can only express offsets that
land on a page boundary. Snapping keeps the offset reported in the envelope
equal to the offset the query ran with, rather than echoing one the caller
asked for and did not get.
""".
-spec page(params()) -> page_spec().
page(Params) ->
    Props = maps:to_list(Params),
    Limit = asobi_qs:integer(~"limit", Props, ?DEFAULT_LIMIT, ?MIN_LIMIT, ?MAX_LIMIT),
    #{limit => Limit, offset => offset(Params, Props, Limit)}.

-spec offset(params(), [{binary(), binary() | true}], pos_integer()) -> non_neg_integer().
offset(Params, Props, Limit) ->
    Requested =
        case maps:is_key(~"page", Params) of
            true -> (asobi_qs:integer(~"page", Props, 1, 1, ?MAX_PAGE) - 1) * Limit;
            false -> asobi_qs:integer(~"offset", Props, 0, 0, ?MAX_OFFSET)
        end,
    min(Requested, ?MAX_OFFSET) div Limit * Limit.

-doc """
Resolve `?sort=` and `?order=` against a per-endpoint allowlist.

`Allowed` maps the wire name to the column atom; only atoms already in that
list can reach the query. An unknown field or direction is an error, so the
caller answers 400 instead of quietly returning differently-ordered rows.

`Default` is used when no sort is requested. Either way the result is
completed with `{id, desc}` so the ordering is total.
""".
-spec sort(params(), sort_allowlist(), sort_spec()) ->
    {ok, sort_spec()} | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
sort(Params, Allowed, Default) ->
    sort(Params, Allowed, Default, {id, desc}).

-doc """
`sort/3` for a row set whose unique key is not `id`.

A board's entries are unique on `player_id` within the board, a queue has one
row per `mode`: those are the columns the order has to end on there. Passing
the wrong one is not a syntax error, it is a page that can repeat a row, so
the tie-breaker is named by the endpoint rather than assumed.
""".
-spec sort(params(), sort_allowlist(), sort_spec(), tie_break()) ->
    {ok, sort_spec()} | {error, {unknown_sort, binary()} | {unknown_order, binary()}}.
sort(Params, Allowed, Default, TieBreak) ->
    case maps:get(~"sort", Params, undefined) of
        Field when is_binary(Field), Field =/= ~"" ->
            case lists:keyfind(Field, 1, Allowed) of
                {_, Column} -> sorted_by(Column, Params, TieBreak);
                false -> {error, {unknown_sort, Field}}
            end;
        _ ->
            {ok, deterministic(Default, TieBreak)}
    end.

-spec sorted_by(atom(), params(), tie_break()) ->
    {ok, sort_spec()} | {error, {unknown_order, binary()}}.
sorted_by(Column, Params, TieBreak) ->
    case order(Params) of
        {ok, Direction} -> {ok, deterministic([{Column, Direction}], TieBreak)};
        {error, _} = Error -> Error
    end.

-spec order(params()) -> {ok, asc | desc} | {error, {unknown_order, binary()}}.
order(Params) ->
    case maps:get(~"order", Params, undefined) of
        Raw when is_binary(Raw), Raw =/= ~"" ->
            case string:lowercase(Raw) of
                ~"asc" -> {ok, asc};
                ~"desc" -> {ok, desc};
                _ -> {error, {unknown_order, Raw}}
            end;
        _ ->
            {ok, asc}
    end.

-spec deterministic(sort_spec(), tie_break()) -> sort_spec().
deterministic(Orders, {Column, _Direction} = TieBreak) ->
    case lists:keymember(Column, 1, Orders) of
        true -> Orders;
        false -> Orders ++ [TieBreak]
    end.

-doc """
Read a free-text search parameter.

Returns `none` when the parameter is absent, empty, valueless, or longer than
64 bytes. The one place the length rule lives, so a search that reaches the
database and a search matched in memory accept the same input.
""".
-spec search(params(), binary()) -> {ok, binary()} | none.
search(Params, Key) ->
    case maps:get(Key, Params, undefined) of
        Term when is_binary(Term), Term =/= ~"", byte_size(Term) =< ?MAX_SEARCH_BYTES -> {ok, Term};
        _ -> none
    end.

-doc "Build an `ILIKE` pattern from the search parameter `search/2` accepts.".
-spec like_pattern(params(), binary()) -> {ok, binary()} | none.
like_pattern(Params, Key) ->
    case search(Params, Key) of
        {ok, Term} -> {ok, iolist_to_binary([~"%", escape_like(Term), ~"%"])};
        none -> none
    end.

%% `%` and `_` are ILIKE wildcards and `\` is its escape character, so an
%% unescaped search term changes what the query means - a lone `%` matches
%% every row. Escape the backslash first, or the escapes added below get
%% escaped in turn.
%% The two backslash literals are `<<>>` rather than the `~""` sigil this
%% codebase uses everywhere else, and have to stay that way: ELP's lexer does
%% not terminate a `~"..."` whose content ends in an escaped backslash. It
%% treats the closing quote as escaped, runs on into the following tokens and
%% reports a syntax error several lines later. These three lines were the only
%% ELP lint errors in the tree and the reason the lint job could not be turned
%% on. Erlang itself parses either form; `~"%"` and `~"\\%"` are unaffected
%% because they do not end in a backslash.
-spec escape_like(binary()) -> binary().
escape_like(Term) ->
    Backslashes = binary:replace(Term, <<"\\">>, <<"\\\\">>, [global]),
    Percents = binary:replace(Backslashes, ~"%", ~"\\%", [global]),
    binary:replace(Percents, ~"_", ~"\\_", [global]).

-doc """
Read an exact-match filter parameter.

`none` when the parameter is absent, empty, valueless, or longer than 64
bytes - the same soft drop `search/2` applies, and for the same reason: a
value no column of this size can hold is not worth a query.
""".
-spec filter(params(), binary()) -> {ok, binary()} | none.
filter(Params, Key) ->
    case maps:get(Key, Params, undefined) of
        Value when is_binary(Value), Value =/= ~"", byte_size(Value) =< ?MAX_FILTER_BYTES ->
            {ok, Value};
        _ ->
            none
    end.

-doc """
Read a boolean filter parameter.

Only `true` and `false` are values. `?active=1` is a typo, and reading it as
`false` would answer with the exact opposite of what was asked for, so
anything else is `none` and the filter does not apply.
""".
-spec boolean(params(), binary()) -> {ok, boolean()} | none.
boolean(Params, Key) ->
    case maps:get(Key, Params, undefined) of
        ~"true" -> {ok, true};
        ~"false" -> {ok, false};
        _ -> none
    end.

-doc """
Whether `Id` is a canonical lowercase hyphenated uuid.

Every primary key in this plane is a `uuid` column. Postgres *raises* on a
value that is not one, so an id checked only by the database turns a
malformed request into a 500 and a log line. Checking the shape first makes
it the 400 it is, and costs no query.
""".
-spec uuid(term()) -> boolean().
uuid(<<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-, E:12/binary>>) ->
    lists:all(fun is_hex/1, binary_to_list(<<A/binary, B/binary, C/binary, D/binary, E/binary>>));
uuid(_Id) ->
    false.

-spec is_hex(term()) -> boolean().
is_hex(Char) when Char >= $0, Char =< $9 -> true;
is_hex(Char) when Char >= $a, Char =< $f -> true;
is_hex(_Char) -> false.

-doc """
Decode an opaque `?cursor=` token back to its keyset value.

Cursors are base64url without padding so they survive a query string intact
and carry no meaning a caller can hand-craft. Anything that is not a valid
token is an error, never a silent fall back to the first page.
""".
-spec cursor(params()) -> {ok, binary()} | none | {error, invalid_cursor}.
cursor(Params) ->
    case maps:get(~"cursor", Params, undefined) of
        Token when is_binary(Token), Token =/= ~"", byte_size(Token) =< ?MAX_CURSOR_BYTES ->
            decode_cursor(Token);
        undefined ->
            none;
        _ ->
            {error, invalid_cursor}
    end.

-spec decode_cursor(binary()) -> {ok, binary()} | {error, invalid_cursor}.
decode_cursor(Token) ->
    try base64:decode(Token, #{mode => urlsafe, padding => false}) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_cursor}
    end.

-doc "Encode a keyset value as the opaque cursor token `cursor/1` accepts.".
-spec encode_cursor(binary()) -> binary().
encode_cursor(Value) when is_binary(Value) ->
    base64:encode(Value, #{mode => urlsafe, padding => false}).
