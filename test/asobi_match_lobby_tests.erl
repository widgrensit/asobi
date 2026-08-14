-module(asobi_match_lobby_tests).
-include_lib("eunit/include/eunit.hrl").

-define(GAME, asobi_test_game).
-define(BASE_CONFIG, #{game_module => ?GAME, min_players => 2, max_players => 4, tick_rate => 50}).

setup() ->
    case ets:whereis(asobi_match_state) of
        undefined -> ets:new(asobi_match_state, [named_table, public, set]);
        _ -> ok
    end,
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    %% asobi#482: find_or_create spawns through asobi_match_sup and serializes
    %% through asobi_world_lobby_server, neither of which this module needed
    %% before - it hand-starts match servers. Both are stopped again in cleanup:
    %% the lobby server OWNS the asobi_world_lobby_cache ETS table, and leaving
    %% it running makes asobi_world_lobby_cache_tests unable to create or delete
    %% that table in its own setup.
    Started = [
        Name
     || {Name, Start} <- [
            {asobi_match_sup, fun asobi_match_sup:start_link/0},
            {asobi_world_lobby_server, fun asobi_world_lobby_server:start_link/0}
        ],
        whereis(Name) =:= undefined andalso started(Start)
    ],
    meck:new(asobi_repo, [no_link]),
    meck:expect(asobi_repo, insert, fun(_CS) -> {ok, #{}} end),
    meck:expect(asobi_repo, insert, fun(_CS, _Opts) -> {ok, #{}} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, send, fun(_PlayerId, _Msg) -> ok end),
    Started.

cleanup(Started) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_repo),
    lists:foreach(fun stop_named/1, lists:reverse(Started)),
    ok.

started(Start) ->
    {ok, Pid} = Start(),
    unlink(Pid),
    true.

stop_named(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 2000 -> ok
            end
    end.

%% Unlinked: see the note in asobi_match_server_tests (asobi#376).
start_match(Overrides) ->
    {ok, Pid} = asobi_match_server:start_link(maps:merge(?BASE_CONFIG, Overrides)),
    unlink(Pid),
    Pid.

stop_match(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    wait_gone(Pid, 50).

wait_gone(_Pid, 0) ->
    ok;
wait_gone(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_gone(Pid, N - 1)
    end.

match_lobby_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"find_or_create spawns when the mode has no live match (#482)",
            fun foc_spawns_when_none/0},
        {"find_or_create reuses a listed, joinable match with room (#482)",
            fun foc_reuses_existing/0},
        {"find_or_create REFUSES a non-quick_play mode, so ranked stays matchmaker-only (#482)",
            fun foc_refuses_non_quick_play/0},
        {"quick_play and listed stay independent axes (#482)",
            fun foc_quick_play_is_independent_of_listed/0},
        {"a mode that declares no quick_play is refused, so upgrades are safe (#482)",
            fun foc_defaults_closed/0},
        {"find_or_create picks the FULLEST eligible match, consolidating (#482)",
            fun foc_picks_fullest/0},
        {"find_or_create ignores a match closed with set_joinable(false) (#482)",
            fun foc_ignores_closed/0},
        {"find_or_create refuses a world mode (#482)", fun foc_refuses_world_mode/0},
        {"find_or_create refuses an unconfigured mode (#482)", fun foc_refuses_unknown_mode/0},
        {"find_or_create refuses past the global match cap (#482)", fun foc_respects_cap/0},
        {"concurrent find_or_create callers land in ONE match (#482)", fun foc_is_serialized/0},
        {"matches are unlisted by default", fun unlisted_by_default/0},
        {"listed => true opts a match into discovery", fun listed_opts_in/0},
        {"listing drops the roster and the flag", fun listing_drops_roster/0},
        {"filters by mode", fun filters_by_mode/0},
        {"has_capacity excludes a full match", fun filters_by_capacity/0},
        {"a listing says whether the match will take a player", fun listing_carries_joinable/0},
        {"joinable => true excludes a closed match", fun filters_by_joinable/0},
        {"joinable => false finds only the closed ones", fun filters_by_not_joinable/0},
        {"a closed match with room is still excluded by joinable",
            fun capacity_and_joinable_are_separate/0}
    ]}.

listing_carries_joinable() ->
    Pid = start_match(#{mode => ~"joinable_mode", listed => true}),
    [M] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"joinable_mode"}),
    ?assert(maps:get(joinable, M)),
    stop_match(Pid).

filters_by_joinable() ->
    Open = start_match(#{mode => ~"jf_open", listed => true}),
    Closed = start_match(#{mode => ~"jf_closed", listed => true}),
    ok = asobi_match_server:set_joinable(Closed, false),
    timer:sleep(50),
    Modes = [maps:get(mode, M) || M <- asobi_match_lobby:list_matches(#{joinable => true})],
    ?assert(lists:member(~"jf_open", Modes)),
    ?assertNot(lists:member(~"jf_closed", Modes)),
    stop_match(Open),
    stop_match(Closed).

filters_by_not_joinable() ->
    Open = start_match(#{mode => ~"jn_open", listed => true}),
    Closed = start_match(#{mode => ~"jn_closed", listed => true}),
    ok = asobi_match_server:set_joinable(Closed, false),
    timer:sleep(50),
    Modes = [maps:get(mode, M) || M <- asobi_match_lobby:list_matches(#{joinable => false})],
    ?assert(lists:member(~"jn_closed", Modes)),
    ?assertNot(lists:member(~"jn_open", Modes)),
    stop_match(Open),
    stop_match(Closed).

%% Room and willingness are different questions: a match with three free
%% slots that has closed itself must not come back as somewhere to join.
capacity_and_joinable_are_separate() ->
    Pid = start_match(#{mode => ~"cj_mode", listed => true, max_players => 4}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ok = asobi_match_server:set_joinable(Pid, false),
    timer:sleep(50),
    ?assertEqual(
        1,
        length(asobi_match_lobby:list_matches(#{mode => ~"cj_mode", has_capacity => true}))
    ),
    ?assertEqual(
        [],
        asobi_match_lobby:list_matches(#{
            mode => ~"cj_mode", has_capacity => true, joinable => true
        })
    ),
    stop_match(Pid).

unlisted_by_default() ->
    Pid = start_match(#{mode => ~"unlisted_mode"}),
    ?assertEqual(
        [],
        asobi_match_lobby:list_matches(#{listed => true, mode => ~"unlisted_mode"}),
        "a matchmaker-spawned match must not appear in a browser by default"
    ),
    ?assertEqual(1, length(asobi_match_lobby:list_matches(#{mode => ~"unlisted_mode"}))),
    stop_match(Pid).

listed_opts_in() ->
    Pid = start_match(#{mode => ~"listed_mode", listed => true}),
    [M] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"listed_mode"}),
    ?assertEqual(~"listed_mode", maps:get(mode, M)),
    ?assertEqual(waiting, maps:get(status, M)),
    stop_match(Pid).

listing_drops_roster() ->
    Pid = start_match(#{mode => ~"roster_mode", listed => true}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    [M] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"roster_mode"}),
    ?assertEqual(
        lists:sort([match_id, status, player_count, max_players, mode, joinable]),
        lists:sort(maps:keys(M)),
        "listing key set is a security contract - widen it deliberately"
    ),
    ?assertEqual(1, maps:get(player_count, M)),
    ?assert(maps:is_key(players, asobi_match_server:get_info(Pid))),
    stop_match(Pid).

filters_by_mode() ->
    A = start_match(#{mode => ~"mode_a", listed => true}),
    B = start_match(#{mode => ~"mode_b", listed => true}),
    [MA] = asobi_match_lobby:list_matches(#{listed => true, mode => ~"mode_a"}),
    ?assertEqual(~"mode_a", maps:get(mode, MA)),
    stop_match(A),
    stop_match(B).

filters_by_capacity() ->
    Pid = start_match(#{mode => ~"cap_mode", listed => true, min_players => 1, max_players => 1}),
    ok = asobi_match_server:join(Pid, ~"p1"),
    ?assertEqual(
        [],
        asobi_match_lobby:list_matches(#{
            listed => true, mode => ~"cap_mode", has_capacity => true
        })
    ),
    ?assertEqual(
        1, length(asobi_match_lobby:list_matches(#{listed => true, mode => ~"cap_mode"}))
    ),
    stop_match(Pid).

%% asobi#482: find_or_create is the match twin of world.find_or_create. These
%% drive find_or_create_unsafe/2 directly - the serialization is the server's
%% job and is covered separately; what matters here is the find-or-spawn
%% decision and every case it must refuse.

foc_mode(Mode, Extra) ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        Mode => maps:merge(
            #{
                module => ?GAME,
                match_size => 2,
                max_players => 4,
                listed => true,
                quick_play => true
            },
            Extra
        )
    }),
    Prev.

%% A mode exactly as an operator would have written it before this verb existed:
%% no quick_play key at all.
foc_mode_bare(Mode) ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        Mode => #{module => ?GAME, match_size => 2, max_players => 4, listed => true}
    }),
    Prev.

foc_mode2(Mode, Extra) ->
    Prev = application:get_env(asobi, game_modes),
    Existing =
        case Prev of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end,
    application:set_env(asobi, game_modes, Existing#{
        Mode => maps:merge(
            #{
                module => ?GAME,
                match_size => 2,
                max_players => 4,
                listed => true,
                quick_play => true
            },
            Extra
        )
    }),
    Prev.

restore_modes({ok, P}) -> application:set_env(asobi, game_modes, P);
restore_modes(undefined) -> application:unset_env(asobi, game_modes).

foc_spawns_when_none() ->
    Prev = foc_mode(~"foc_a", #{}),
    try
        {ok, Pid, Info} = asobi_match_lobby:find_or_create_unsafe(~"foc_a", ~"p1"),
        ?assert(is_pid(Pid)),
        ?assertEqual(~"foc_a", maps:get(mode, Info)),
        stop_match(Pid)
    after
        restore_modes(Prev)
    end.

foc_reuses_existing() ->
    Prev = foc_mode(~"foc_b", #{}),
    try
        {ok, Pid1, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_b", ~"p1"),
        {ok, Pid2, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_b", ~"p2"),
        ?assertEqual(
            Pid1,
            Pid2,
            "a second caller must land in the first caller's match, not a fresh one"
        ),
        stop_match(Pid1)
    after
        restore_modes(Prev)
    end.

foc_refuses_non_quick_play() ->
    %% The policy gate. quick_play defaults FALSE for match modes, so a
    %% matchmaker-only mode is not merely un-found - it must be REFUSED. Before
    %% this the filter simply missed the unlisted match and spawned another, so
    %% every call minted a fresh ranked match and joined the caller to it,
    %% routing around matchmaking entirely and bounded only by the join limiter.
    Prev = foc_mode(~"foc_c", #{quick_play => false}),
    try
        ?assertEqual(
            {error, quick_play_disabled},
            asobi_match_lobby:find_or_create_unsafe(~"foc_c", ~"p1")
        ),
        ?assertEqual(
            [],
            asobi_match_lobby:list_matches(#{mode => ~"foc_c"}),
            "a refused call must not have spawned anything"
        )
    after
        restore_modes(Prev)
    end.

foc_picks_fullest() ->
    %% Ordering is not incidental. list_matches/1 order comes from
    %% pg:which_groups/1, i.e. ETS iteration order, which reshuffles as groups
    %% churn - so without an explicit rule, concurrent callers can flip between
    %% matches mid-fill and leave two half-filled waiting matches that each die
    %% at ?WAITING_TIMEOUT without reaching min_players. Fullest-first
    %% consolidates: the match at 2/4 is the one worth completing.
    Prev = foc_mode(~"foc_j", #{}),
    try
        Empty = start_match(#{mode => ~"foc_j", listed => true, max_players => 4}),
        Fuller = start_match(#{mode => ~"foc_j", listed => true, max_players => 4}),
        ok = asobi_match_server:join(Fuller, ~"a"),
        ok = asobi_match_server:join(Fuller, ~"b"),
        {ok, Picked, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_j", ~"p1"),
        ?assertEqual(Fuller, Picked, "the fuller match must win, not whichever pg listed first"),
        ?assertNotEqual(Empty, Picked),
        stop_match(Empty),
        stop_match(Fuller)
    after
        restore_modes(Prev)
    end.

foc_defaults_closed() ->
    %% The upgrade-safety case, and the one that matters most: every match mode
    %% that exists today predates this verb and declares no quick_play. If the
    %% default were open, merging this would silently expose every operator's
    %% ranked mode to a client that can spawn and join one without ever being
    %% rated or queued. Declaring quick_play => false is NOT what protects them
    %% - declaring nothing is the common case.
    Prev = foc_mode_bare(~"foc_i"),
    try
        ?assertEqual(
            {error, quick_play_disabled},
            asobi_match_lobby:find_or_create_unsafe(~"foc_i", ~"p1")
        ),
        ?assertEqual([], asobi_match_lobby:list_matches(#{mode => ~"foc_i"}))
    after
        restore_modes(Prev)
    end.

foc_quick_play_is_independent_of_listed() ->
    %% The two axes stay separate: hidden from the browser but still auto-filled
    %% is a legitimate cell, and collapsing them onto `listed` would remove it.
    Prev = foc_mode(~"foc_h", #{listed => false, quick_play => true}),
    try
        {ok, Pid1, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_h", ~"p1"),
        {ok, Pid2, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_h", ~"p2"),
        ?assertEqual(Pid1, Pid2),
        ?assertEqual([], asobi_match_lobby:list_matches(#{mode => ~"foc_h", listed => true})),
        stop_match(Pid1)
    after
        restore_modes(Prev)
    end.

foc_ignores_closed() ->
    Prev = foc_mode(~"foc_d", #{}),
    try
        {ok, Pid1, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_d", ~"p1"),
        ok = asobi_match_server:set_joinable(Pid1, false),
        {ok, Pid2, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_d", ~"p2"),
        ?assertNotEqual(Pid1, Pid2, "set_joinable(false) must keep new players out"),
        stop_match(Pid1),
        stop_match(Pid2)
    after
        restore_modes(Prev)
    end.

foc_refuses_world_mode() ->
    %% Symmetric to the world.create guard: a world mode resolved here would
    %% build a match around asobi_lua_world.
    Prev = foc_mode(~"foc_w", #{type => world}),
    try
        ?assertEqual(
            {error, wrong_mode_type}, asobi_match_lobby:find_or_create_unsafe(~"foc_w", ~"p1")
        )
    after
        restore_modes(Prev)
    end.

foc_refuses_unknown_mode() ->
    Prev = foc_mode(~"foc_e", #{}),
    try
        ?assertEqual(
            {error, not_found}, asobi_match_lobby:find_or_create_unsafe(~"nope", ~"p1")
        )
    after
        restore_modes(Prev)
    end.

foc_respects_cap() ->
    %% The matchmaker bounded match creation implicitly - it took match_size
    %% queued tickets to make one. A client-facing create removes that bound, so
    %% the cap is required machinery, not hardening.
    %%
    %% Discriminating on purpose: the earlier version set match_max to
    %% live_match_count() and asserted 0 >= 0, which passed even with the count
    %% hardcoded to zero - which is what a bare-atom pg lookup effectively was.
    Prev = foc_mode(~"foc_f", #{}),
    Prev2 = foc_mode2(~"foc_g", #{}),
    PrevMax = application:get_env(asobi, match_max),
    try
        {ok, P1, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_f", ~"p1"),
        Base = asobi_match_lobby:live_match_count(),
        ?assert(Base >= 1, "a live match must be counted, or the cap can never fire"),
        application:set_env(asobi, match_max, Base),
        ?assertEqual(
            {error, match_capacity_reached},
            asobi_match_lobby:find_or_create_unsafe(~"foc_g", ~"p2")
        ),
        application:set_env(asobi, match_max, Base + 1),
        {ok, P2, _} = asobi_match_lobby:find_or_create_unsafe(~"foc_g", ~"p3"),
        stop_match(P1),
        stop_match(P2)
    after
        case PrevMax of
            {ok, M} -> application:set_env(asobi, match_max, M);
            undefined -> application:unset_env(asobi, match_max)
        end,
        restore_modes(Prev2),
        restore_modes(Prev)
    end.

%% The reason find_or_create goes through a gen_server at all. Unserialized,
%% N callers arriving together all see an empty listing and all spawn - the
%% TOCTOU asobi_world_lobby_server was built to close, and worse on the match
%% path because the split leaves several half-empty matches that may each fail
%% to reach min_players. Drives the public (serialized) entry point, so removing
%% the serialization fails this.
foc_is_serialized() ->
    Prev = foc_mode(~"foc_race", #{max_players => 64}),
    Parent = self(),
    try
        %% Barrier: without it the eight spawns run sequentially and caller 1
        %% can finish before caller 8 starts, so they would all find match 1
        %% even unserialized and the test would prove nothing.
        Pids = [
            spawn(fun() ->
                receive
                    go -> ok
                end,
                Parent ! {foc, N, asobi_match_lobby:find_or_create(~"foc_race", ~"racer")}
            end)
         || N <- lists:seq(1, 8)
        ],
        [P ! go || P <- Pids],
        Got = [
            receive
                {foc, _, {ok, P, _}} -> P;
                {foc, _, Other} -> Other
            after 5000 -> timeout
            end
         || _ <- lists:seq(1, 8)
        ],
        Unique = lists:usort(Got),
        ?assertMatch([_], Unique, "every concurrent caller must land in the same match"),
        [One] = Unique,
        ?assert(is_pid(One)),
        stop_match(One)
    after
        restore_modes(Prev)
    end.
