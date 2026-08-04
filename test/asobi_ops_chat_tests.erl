-module(asobi_ops_chat_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kura/include/kura.hrl").

%%--------------------------------------------------------------------
%% Messages
%%--------------------------------------------------------------------

messages_default_order_is_deterministic_test() ->
    {ok, #kura_query{order_bys = Orders}} = asobi_ops_chat:messages_query(~"lobby", #{}),
    ?assertEqual([{sent_at, desc}, {id, desc}], Orders).

every_message_sort_ends_on_the_unique_key_test() ->
    [
        begin
            {ok, #kura_query{order_bys = Orders}} = asobi_ops_chat:messages_query(
                ~"lobby", #{~"sort" => Wire}
            ),
            ?assertMatch({id, _Direction}, lists:last(Orders))
        end
     || {Wire, _Column} <- asobi_ops_chat:messages_sortable()
    ].

%% The channel binding scopes the read and is not the caller's to sort on or
%% override, so it is the first clause and is always present.
messages_are_always_scoped_to_the_channel_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_chat:messages_query(~"lobby", #{
        ~"q" => ~"hello"
    }),
    ?assertEqual({channel_id, ~"lobby"}, hd(Wheres)).

messages_search_is_ilike_on_content_test() ->
    {ok, #kura_query{wheres = Wheres}} = asobi_ops_chat:messages_query(~"lobby", #{
        ~"q" => ~"slur"
    }),
    ?assertEqual([{channel_id, ~"lobby"}, {content, ilike, ~"%slur%"}], Wheres).

messages_sender_filter_must_be_a_uuid_test() ->
    ?assertEqual(
        {error, {invalid_filter, ~"sender_id"}},
        asobi_ops_chat:messages_query(~"lobby", #{~"sender_id" => ~"kaito"})
    ).

messages_reject_unknown_sort_test() ->
    ?assertEqual(
        {error, {unknown_sort, ~"content"}},
        asobi_ops_chat:messages_query(~"lobby", #{~"sort" => ~"content"})
    ).

messages_projection_drops_game_authored_metadata_test() ->
    Projected = asobi_ops_chat:project_message(sample_message()),
    ?assertNot(maps:is_key(metadata, Projected)),
    ?assertEqual(~"hello", maps:get(content, Projected)).

messages_sortable_fields_are_all_projected_test() ->
    Projected = maps:keys(asobi_ops_chat:project_message(sample_message())),
    [
        ?assert(lists:member(Column, Projected))
     || {_Wire, Column} <- asobi_ops_chat:messages_sortable()
    ].

sample_message() ->
    #{
        id => ~"0197f3d0-1c2b-7000-8000-0000000000b1",
        channel_type => ~"room",
        channel_id => ~"lobby",
        sender_id => ~"0197f3d0-1c2b-7000-8000-0000000000b2",
        content => ~"hello",
        metadata => #{~"client" => ~"godot"},
        sent_at => {{2026, 8, 3}, {12, 0, 0}}
    }.

%%--------------------------------------------------------------------
%% Live channels
%%--------------------------------------------------------------------

channels_test_() ->
    {setup, fun setup_channels/0, fun cleanup_channels/1, [
        fun channels_are_busiest_first/0,
        fun channels_order_ends_on_the_channel_id/0,
        fun channels_search_matches_the_id_case_insensitively/0,
        fun channels_reject_unknown_sort/0
    ]}.

setup_channels() ->
    meck:new(asobi_chat_channel, [passthrough]),
    meck:expect(asobi_chat_channel, channels, fun() ->
        [
            #{channel_id => ~"Lobby", members => 2},
            #{channel_id => ~"arena", members => 9},
            #{channel_id => ~"coop", members => 2}
        ]
    end),
    ok.

cleanup_channels(_) ->
    catch meck:unload(asobi_chat_channel),
    ok.

channels_are_busiest_first() ->
    {ok, {_Rows, Orders}} = asobi_ops_chat:channels(#{}),
    ?assertEqual([{members, desc}, {channel_id, asc}], Orders).

channels_order_ends_on_the_channel_id() ->
    [
        begin
            {ok, {_Rows, Orders}} = asobi_ops_chat:channels(#{~"sort" => Wire}),
            ?assertEqual({channel_id, asc}, lists:last(Orders))
        end
     || {Wire, _Column} <- asobi_ops_chat:channels_sortable()
    ].

channels_search_matches_the_id_case_insensitively() ->
    {ok, {Rows, _Orders}} = asobi_ops_chat:channels(#{~"q" => ~"LOB"}),
    ?assertEqual([~"Lobby"], [Id || #{channel_id := Id} <- Rows]).

channels_reject_unknown_sort() ->
    ?assertEqual(
        {error, {unknown_sort, ~"pid"}},
        asobi_ops_chat:channels(#{~"sort" => ~"pid"})
    ).

channels_projection_is_an_allowlist_test() ->
    ?assertEqual(
        #{channel_id => ~"lobby", members => 3},
        asobi_ops_chat:project_channel(#{
            channel_id => ~"lobby", members => 3, pid => self(), buffer => [~"secret"]
        })
    ).

%%--------------------------------------------------------------------
%% The registry read behind the channel list
%%--------------------------------------------------------------------

%% The console this replaces read `pg:which_groups/1`, which forgets a
%% channel the moment its last member leaves. This reads the registry, so a
%% running channel nobody is joined to still appears - with zero members.
registry_lists_a_running_channel_with_no_members_test() ->
    Table = ets:new(asobi_chat_registry, [named_table, public, set]),
    try
        ets:insert(Table, {~"lobby", self()}),
        ?assertEqual(
            [#{channel_id => ~"lobby", members => 0}],
            asobi_chat_channel:channels()
        )
    after
        ets:delete(Table)
    end.

registry_drops_a_dead_channel_test() ->
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive
        {'DOWN', Ref, process, Dead, _} -> ok
    after 1000 -> ?assert(false)
    end,
    Table = ets:new(asobi_chat_registry, [named_table, public, set]),
    try
        ets:insert(Table, {~"gone", Dead}),
        ?assertEqual([], asobi_chat_channel:channels())
    after
        ets:delete(Table)
    end.

no_registry_is_an_empty_list_not_a_crash_test() ->
    ?assertEqual(undefined, ets:whereis(asobi_chat_registry)),
    ?assertEqual([], asobi_chat_channel:channels()).
