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
