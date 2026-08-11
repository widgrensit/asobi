-module(asobi_ops_params_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Limit / offset clamping
%%--------------------------------------------------------------------

page_defaults_test() ->
    ?assertEqual(#{limit => 50, offset => 0}, asobi_ops_params:page(#{})).

limit_is_honoured_test() ->
    ?assertMatch(#{limit := 25}, asobi_ops_params:page(#{~"limit" => ~"25"})).

limit_clamped_to_max_test() ->
    ?assertMatch(#{limit := 200}, asobi_ops_params:page(#{~"limit" => ~"10000000"})).

limit_clamped_to_min_test() ->
    ?assertMatch(#{limit := 1}, asobi_ops_params:page(#{~"limit" => ~"0"})),
    ?assertMatch(#{limit := 1}, asobi_ops_params:page(#{~"limit" => ~"-5"})).

%% The regression this whole module exists for: raw binary_to_integer/1 on
%% `abc` raises badarg, which cowboy turns into a 500.
limit_garbage_falls_back_to_default_test() ->
    ?assertMatch(#{limit := 50}, asobi_ops_params:page(#{~"limit" => ~"abc"})),
    ?assertMatch(#{limit := 50}, asobi_ops_params:page(#{~"limit" => ~"12x"})),
    ?assertMatch(#{limit := 50}, asobi_ops_params:page(#{~"limit" => ~""})).

%% `?limit` with no value parses to the atom `true`, not a binary.
limit_valueless_falls_back_to_default_test() ->
    ?assertMatch(#{limit := 50}, asobi_ops_params:page(#{~"limit" => true})).

offset_is_honoured_test() ->
    ?assertEqual(
        #{limit => 10, offset => 30},
        asobi_ops_params:page(#{~"limit" => ~"10", ~"offset" => ~"30"})
    ).

offset_garbage_falls_back_to_zero_test() ->
    ?assertMatch(#{offset := 0}, asobi_ops_params:page(#{~"offset" => ~"; DROP TABLE"})).

offset_never_negative_test() ->
    ?assertMatch(#{offset := 0}, asobi_ops_params:page(#{~"offset" => ~"-100"})).

offset_clamped_to_max_test() ->
    ?assertMatch(
        #{offset := 100000}, asobi_ops_params:page(#{~"limit" => ~"100", ~"offset" => ~"9999999"})
    ).

%% Snapped down to a page boundary so the echoed offset is the one the query
%% actually used.
offset_snaps_to_page_boundary_test() ->
    ?assertEqual(
        #{limit => 50, offset => 50},
        asobi_ops_params:page(#{~"limit" => ~"50", ~"offset" => ~"75"})
    ).

page_number_converts_to_offset_test() ->
    ?assertEqual(
        #{limit => 20, offset => 40},
        asobi_ops_params:page(#{~"limit" => ~"20", ~"page" => ~"3"})
    ).

page_number_wins_over_offset_test() ->
    ?assertEqual(
        #{limit => 20, offset => 0},
        asobi_ops_params:page(#{~"limit" => ~"20", ~"page" => ~"1", ~"offset" => ~"999"})
    ).

page_number_clamped_test() ->
    ?assertMatch(
        #{offset := 100000}, asobi_ops_params:page(#{~"limit" => ~"200", ~"page" => ~"99999"})
    ),
    ?assertMatch(#{offset := 0}, asobi_ops_params:page(#{~"page" => ~"0"})).

%%--------------------------------------------------------------------
%% Sort allowlist
%%--------------------------------------------------------------------

allowlist() ->
    [{~"username", username}, {~"inserted_at", inserted_at}].

sort_defaults_when_absent_test() ->
    ?assertEqual(
        {ok, [{inserted_at, desc}, {id, desc}]},
        asobi_ops_params:sort(#{}, allowlist(), [{inserted_at, desc}])
    ).

sort_maps_allowed_field_to_atom_test() ->
    ?assertEqual(
        {ok, [{username, asc}, {id, desc}]},
        asobi_ops_params:sort(#{~"sort" => ~"username"}, allowlist(), [{inserted_at, desc}])
    ).

sort_honours_order_test() ->
    ?assertEqual(
        {ok, [{username, desc}, {id, desc}]},
        asobi_ops_params:sort(
            #{~"sort" => ~"username", ~"order" => ~"desc"}, allowlist(), [{inserted_at, desc}]
        )
    ),
    ?assertEqual(
        {ok, [{username, desc}, {id, desc}]},
        asobi_ops_params:sort(
            #{~"sort" => ~"username", ~"order" => ~"DESC"}, allowlist(), [{inserted_at, desc}]
        )
    ).

%% The injection guard: a field that is not on the allowlist is rejected, and
%% never reaches order_by as a string.
sort_rejects_unknown_field_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"hashed_password"}},
        asobi_ops_params:sort(#{~"sort" => ~"hashed_password"}, allowlist(), [{inserted_at, desc}])
    ).

sort_rejects_injection_payload_test() ->
    Payload = ~"id; DROP TABLE players--",
    ?assertEqual(
        {error, {unknown_sort, Payload}},
        asobi_ops_params:sort(#{~"sort" => Payload}, allowlist(), [{inserted_at, desc}])
    ).

sort_rejects_unknown_order_test() ->
    ?assertEqual(
        {error, {unknown_order, ~"sideways"}},
        asobi_ops_params:sort(
            #{~"sort" => ~"username", ~"order" => ~"sideways"}, allowlist(), [{inserted_at, desc}]
        )
    ).

sort_valueless_falls_back_to_default_test() ->
    ?assertEqual(
        {ok, [{inserted_at, desc}, {id, desc}]},
        asobi_ops_params:sort(#{~"sort" => true}, allowlist(), [{inserted_at, desc}])
    ).

%% Offset pagination over a non-unique key is non-deterministic without a
%% unique tie-breaker.
sort_always_ends_on_unique_column_test() ->
    {ok, Orders} = asobi_ops_params:sort(
        #{~"sort" => ~"username"}, allowlist(), [{inserted_at, desc}]
    ),
    ?assertEqual({id, desc}, lists:last(Orders)).

sort_does_not_duplicate_id_test() ->
    ?assertEqual(
        {ok, [{id, asc}]},
        asobi_ops_params:sort(#{~"sort" => ~"id"}, [{~"id", id}], [{inserted_at, desc}])
    ).

%%--------------------------------------------------------------------
%% Sort with an explicit tie-breaker
%%--------------------------------------------------------------------

%% A row set that is not keyed on `id` - a queue keyed on `mode`, a board's
%% entries keyed on `player_id` - must end on *its* unique column. Appending
%% `id` there orders by a field the rows do not have, which is the
%% repeat-a-row bug the tie-breaker exists to prevent.
sort_ends_on_the_given_tie_break_test() ->
    ?assertEqual(
        {ok, [{waiting, desc}, {mode, asc}]},
        asobi_ops_params:sort(
            #{~"sort" => ~"waiting", ~"order" => ~"desc"},
            [{~"waiting", waiting}],
            [{waiting, desc}],
            {mode, asc}
        )
    ).

sort_default_also_ends_on_the_tie_break_test() ->
    ?assertEqual(
        {ok, [{entries, desc}, {board_id, asc}]},
        asobi_ops_params:sort(#{}, [{~"entries", entries}], [{entries, desc}], {board_id, asc})
    ).

sort_does_not_duplicate_the_tie_break_test() ->
    ?assertEqual(
        {ok, [{score, desc}, {player_id, asc}]},
        asobi_ops_params:sort(
            #{},
            [{~"score", score}],
            [{score, desc}, {player_id, asc}],
            {player_id, asc}
        )
    ).

sort_with_tie_break_still_rejects_unknown_field_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"properties"}},
        asobi_ops_params:sort(
            #{~"sort" => ~"properties"}, [{~"mode", mode}], [{mode, asc}], {mode, asc}
        )
    ).

%%--------------------------------------------------------------------
%% Search terms
%%--------------------------------------------------------------------

search_absent_test() ->
    ?assertEqual(none, asobi_ops_params:search(#{}, ~"q")).

search_valueless_test() ->
    ?assertEqual(none, asobi_ops_params:search(#{~"q" => true}, ~"q")).

search_too_long_test() ->
    ?assertEqual(none, asobi_ops_params:search(#{~"q" => binary:copy(~"a", 65)}, ~"q")).

%% The in-memory search and the `ilike` search take the same input, so the
%% length rule is checked once for both.
search_returns_the_raw_term_test() ->
    ?assertEqual({ok, ~"kai%to"}, asobi_ops_params:search(#{~"q" => ~"kai%to"}, ~"q")),
    ?assertEqual({ok, ~"%kai\\%to%"}, asobi_ops_params:like_pattern(#{~"q" => ~"kai%to"}, ~"q")).

%%--------------------------------------------------------------------
%% Search patterns
%%--------------------------------------------------------------------

like_pattern_absent_test() ->
    ?assertEqual(none, asobi_ops_params:like_pattern(#{}, ~"q")).

like_pattern_empty_test() ->
    ?assertEqual(none, asobi_ops_params:like_pattern(#{~"q" => ~""}, ~"q")).

like_pattern_too_long_test() ->
    Long = binary:copy(~"a", 65),
    ?assertEqual(none, asobi_ops_params:like_pattern(#{~"q" => Long}, ~"q")).

like_pattern_wraps_term_test() ->
    ?assertEqual({ok, ~"%kaito%"}, asobi_ops_params:like_pattern(#{~"q" => ~"kaito"}, ~"q")).

%% A bare `%` would otherwise match every row.
like_pattern_escapes_wildcards_test() ->
    ?assertEqual({ok, ~"%\\%%"}, asobi_ops_params:like_pattern(#{~"q" => ~"%"}, ~"q")),
    ?assertEqual({ok, ~"%a\\_b%"}, asobi_ops_params:like_pattern(#{~"q" => ~"a_b"}, ~"q")).

%% `\%` escapes to `\\` + `\%`: the backslash goes first, or the escape added
%% for `%` would itself be escaped and the `%` would stay a wildcard.
like_pattern_escapes_backslash_first_test() ->
    ?assertEqual({ok, ~"%\\\\\\%%"}, asobi_ops_params:like_pattern(#{~"q" => ~"\\%"}, ~"q")).

%% A backslash with no wildcard after it still doubles. Pins the two literals
%% that had to move off the `~""` sigil to keep ELP's lexer able to read this
%% module - see escape_like/1.
%% Every sigil here deliberately ends in something other than a backslash;
%% one that ends in a backslash is unreadable to ELP and would put this module
%% back on the lint job's error list.
like_pattern_escapes_lone_backslash_test() ->
    ?assertEqual({ok, ~"%a\\\\b%"}, asobi_ops_params:like_pattern(#{~"q" => ~"a\\b"}, ~"q")),
    ?assertEqual(
        {ok, ~"%a\\\\\\\\b%"}, asobi_ops_params:like_pattern(#{~"q" => ~"a\\\\b"}, ~"q")
    ).

%%--------------------------------------------------------------------
%% Cursors
%%--------------------------------------------------------------------

cursor_absent_test() ->
    ?assertEqual(none, asobi_ops_params:cursor(#{})).

cursor_round_trips_test() ->
    Id = ~"0197f3d0-1c2b-7000-8000-000000000001",
    Token = asobi_ops_params:encode_cursor(Id),
    ?assertEqual({ok, Id}, asobi_ops_params:cursor(#{~"cursor" => Token})).

cursor_is_url_safe_test() ->
    Token = asobi_ops_params:encode_cursor(<<255, 254, 253, 252>>),
    ?assertEqual(nomatch, binary:match(Token, [~"+", ~"/", ~"="])).

cursor_rejects_garbage_test() ->
    ?assertEqual({error, invalid_cursor}, asobi_ops_params:cursor(#{~"cursor" => ~"not*base64"})).

cursor_rejects_oversized_token_test() ->
    Token = asobi_ops_params:encode_cursor(binary:copy(~"a", 200)),
    ?assertEqual({error, invalid_cursor}, asobi_ops_params:cursor(#{~"cursor" => Token})).

cursor_rejects_valueless_param_test() ->
    ?assertEqual({error, invalid_cursor}, asobi_ops_params:cursor(#{~"cursor" => true})).

%%--------------------------------------------------------------------
%% Exact-match and boolean filters
%%--------------------------------------------------------------------

filter_reads_a_value_test() ->
    ?assertEqual({ok, ~"gold"}, asobi_ops_params:filter(#{~"currency" => ~"gold"}, ~"currency")).

filter_absent_is_none_test() ->
    ?assertEqual(none, asobi_ops_params:filter(#{}, ~"currency")).

filter_empty_is_none_test() ->
    ?assertEqual(none, asobi_ops_params:filter(#{~"currency" => ~""}, ~"currency")).

filter_valueless_param_is_none_test() ->
    ?assertEqual(none, asobi_ops_params:filter(#{~"currency" => true}, ~"currency")).

filter_oversized_is_none_test() ->
    Long = binary:copy(~"c", 65),
    ?assertEqual(none, asobi_ops_params:filter(#{~"currency" => Long}, ~"currency")).

filter_at_the_limit_is_kept_test() ->
    Limit = binary:copy(~"c", 64),
    ?assertEqual({ok, Limit}, asobi_ops_params:filter(#{~"currency" => Limit}, ~"currency")).

boolean_reads_true_and_false_test() ->
    ?assertEqual({ok, true}, asobi_ops_params:boolean(#{~"active" => ~"true"}, ~"active")),
    ?assertEqual({ok, false}, asobi_ops_params:boolean(#{~"active" => ~"false"}, ~"active")).

%% `?active=1` reading as `false` would answer with the opposite of what was
%% asked for, so anything that is not the two words does not filter at all.
boolean_rejects_anything_else_test() ->
    [
        ?assertEqual(none, asobi_ops_params:boolean(#{~"active" => Value}, ~"active"))
     || Value <- [~"1", ~"0", ~"TRUE", ~"yes", ~"", true]
    ].

boolean_absent_is_none_test() ->
    ?assertEqual(none, asobi_ops_params:boolean(#{}, ~"active")).

%%--------------------------------------------------------------------
%% Uuid shape
%%--------------------------------------------------------------------

uuid_accepts_a_generated_id_test() ->
    ?assert(asobi_ops_params:uuid(asobi_id:generate())).

uuid_rejects_a_malformed_id_test() ->
    [
        ?assertNot(asobi_ops_params:uuid(Id))
     || Id <- [
            ~"",
            ~"not-a-uuid",
            ~"0197f3d0-1c2b-7000-8000-00000000000",
            ~"0197f3d0-1c2b-7000-8000-0000000000012",
            ~"0197f3d01c2b70008000000000000001",
            ~"0197F3D0-1C2B-7000-8000-000000000001",
            ~"0197f3d0-1c2b-7000-8000-00000000000g",
            ~"0197f3d0'-1c2b-7000-8000-00000000001"
        ]
    ].

%% A non-binary binding must not crash the shape check.
uuid_rejects_a_non_binary_test() ->
    ?assertNot(asobi_ops_params:uuid(undefined)),
    ?assertNot(asobi_ops_params:uuid(42)).
