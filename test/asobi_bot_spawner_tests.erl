-module(asobi_bot_spawner_tests).
-include_lib("eunit/include/eunit.hrl").
-include("asobi_lua_bots.hrl").

%% #79: fill_mode/2 must never enqueue more bots than max_players allows,
%% even when min_players is larger. Without the cap, a match_size=2 /
%% max_players=2 mode with 1 human queued would add 3 bots (filling to the
%% spawner's hardcoded min_players default of 4) — enough to form the
%% human's match PLUS a spurious bot-vs-bot match.
%%
%% #79 follow-up (HIGH severity DoS, security review): a mode declaring an
%% extreme min_players/max_players (whether from a Lua config that bypassed
%% the loader's own clamp, or a sys.config-declared mode that never goes
%% through the Lua loader at all) must never make fill_mode/2 build an
%% unbounded lists:seq/2 of bot-adds, and a matchmaker `queue_full` reply
%% must stop the fill loop immediately rather than being discarded (the old
%% bug: the same unreachable target got retried forever, once every
%% ?CHECK_INTERVAL, as a permanent matchmaking outage).

fill_mode_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"fill never exceeds max_players even when min_players is larger",
            fun fill_capped_at_max_players/0},
        {"fill still reaches min_players when it fits under max_players",
            fun fill_reaches_min_players_under_cap/0},
        {"no bots added once queue already meets max_players", fun no_bots_when_already_at_cap/0},
        {"fill target is clamped at ?MAX_BOT_FILL for an extreme min_players/max_players",
            fun fill_clamped_at_ceiling/0},
        {"fill stops incrementally as soon as the matchmaker reports queue_full",
            fun fill_stops_on_queue_full/0},
        {"fill_mode returns cleanly (no crash) when the very first add hits queue_full",
            fun fill_stops_on_queue_full_immediately/0}
    ]}.

%% Script-driven bots: a match script placing one itself rather than the
%% matchmaker topping up the queue.
add_bot_test_() ->
    {foreach, fun add_setup/0, fun add_cleanup/1, [
        {"a bare name gets the bot_ prefix and starts", fun add_bot_prefixes_and_starts/0},
        {"the mode's bot script is handed to the new bot", fun add_bot_uses_mode_script/0},
        {"a bot already in the match is not added twice", fun add_bot_skips_duplicate/0},
        {"a full match takes no bot", fun add_bot_skips_full_match/0},
        {"the bot ceiling bounds a script that keeps adding", fun add_bot_stops_at_ceiling/0},
        {"a match that ended between call and cast is not an error",
            fun add_bot_tolerates_dead_match/0},
        {"remove stops the bot process", fun remove_bot_stops_process/0},
        {"remove accepts the prefixed id from the roster", fun remove_bot_accepts_prefixed/0},
        {"removing a bot with no live process still leaves the match",
            fun remove_bot_without_process_leaves/0}
    ]}.

name_test_() ->
    [
        ?_assertEqual(ok, asobi_bot_spawner:validate_bot_name(~"Spark")),
        ?_assertEqual(ok, asobi_bot_spawner:validate_bot_name(~"a-b_9")),
        ?_assertMatch({error, _}, asobi_bot_spawner:validate_bot_name(<<>>)),
        ?_assertMatch({error, _}, asobi_bot_spawner:validate_bot_name(~"has space")),
        ?_assertMatch({error, _}, asobi_bot_spawner:validate_bot_name(~"dotted.name")),
        ?_assertMatch(
            {error, _}, asobi_bot_spawner:validate_bot_name(binary:copy(~"x", 33))
        )
    ].

add_setup() ->
    case whereis(nova_scope) of
        undefined -> pg:start_link(nova_scope);
        _ -> ok
    end,
    application:set_env(asobi, game_modes, #{}),
    meck:new(asobi_match_server, [non_strict, no_link]),
    meck:new(asobi_bot_sup, [non_strict, no_link]),
    meck:expect(asobi_bot_sup, start_bot, fun(_MatchPid, _BotId, _Script) -> {ok, self()} end),
    meck:new(asobi_presence, [non_strict, no_link]),
    meck:expect(asobi_presence, bot_pids, fun(_BotId) -> [] end),
    ok.

add_cleanup(_) ->
    meck:unload(asobi_presence),
    meck:unload(asobi_bot_sup),
    meck:unload(asobi_match_server),
    application:unset_env(asobi, game_modes).

expect_match(Players, Mode, Max) ->
    meck:expect(asobi_match_server, get_info, fun(_Pid) ->
        #{players => Players, mode => Mode, max_players => Max}
    end),
    meck:expect(asobi_match_server, leave, fun(_Pid, _PlayerId) -> ok end).

add_bot_prefixes_and_starts() ->
    expect_match([~"p1"], ~"arena", 4),
    asobi_bot_spawner:do_add_bot(self(), ~"Spark"),
    ?assert(meck:called(asobi_bot_sup, start_bot, [self(), ~"bot_Spark", '_'])).

add_bot_uses_mode_script() ->
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{bots => #{script => ~"priv/lua/bot.lua"}}
    }),
    expect_match([~"p1"], ~"arena", 4),
    asobi_bot_spawner:do_add_bot(self(), ~"Spark"),
    ?assert(
        meck:called(asobi_bot_sup, start_bot, [self(), ~"bot_Spark", ~"priv/lua/bot.lua"])
    ).

add_bot_skips_duplicate() ->
    expect_match([~"p1", ~"bot_Spark"], ~"arena", 4),
    asobi_bot_spawner:do_add_bot(self(), ~"Spark"),
    ?assertEqual(0, meck:num_calls(asobi_bot_sup, start_bot, '_')).

add_bot_skips_full_match() ->
    expect_match([~"p1", ~"p2"], ~"arena", 2),
    asobi_bot_spawner:do_add_bot(self(), ~"Spark"),
    ?assertEqual(0, meck:num_calls(asobi_bot_sup, start_bot, '_')).

add_bot_stops_at_ceiling() ->
    Bots = [<<"bot_", (integer_to_binary(N))/binary>> || N <- lists:seq(1, ?MAX_BOT_FILL)],
    expect_match(Bots, ~"arena", 1000),
    asobi_bot_spawner:do_add_bot(self(), ~"OneTooMany"),
    ?assertEqual(0, meck:num_calls(asobi_bot_sup, start_bot, '_')).

add_bot_tolerates_dead_match() ->
    meck:expect(asobi_match_server, get_info, fun(_Pid) -> exit({noproc, get_info}) end),
    ?assertEqual(ok, asobi_bot_spawner:do_add_bot(self(), ~"Spark")),
    ?assertEqual(0, meck:num_calls(asobi_bot_sup, start_bot, '_')).

remove_bot_stops_process() ->
    Bot = spawn_bot(),
    meck:expect(asobi_presence, bot_pids, fun(~"bot_Spark") -> [Bot] end),
    expect_match([~"bot_Spark"], ~"arena", 4),
    asobi_bot_spawner:do_remove_bot(self(), ~"Spark"),
    ?assertNot(is_process_alive(Bot)).

remove_bot_accepts_prefixed() ->
    Bot = spawn_bot(),
    meck:expect(asobi_presence, bot_pids, fun(~"bot_Spark") -> [Bot] end),
    expect_match([~"bot_Spark"], ~"arena", 4),
    asobi_bot_spawner:do_remove_bot(self(), ~"bot_Spark"),
    ?assertNot(is_process_alive(Bot)).

remove_bot_without_process_leaves() ->
    expect_match([~"bot_Ghost"], ~"arena", 4),
    asobi_bot_spawner:do_remove_bot(self(), ~"Ghost"),
    ?assert(meck:called(asobi_match_server, leave, [self(), ~"bot_Ghost"])).

%% A stand-in for asobi_bot: gen_server:stop/3 is how removal works, so the
%% double has to be a real gen_server.
spawn_bot() ->
    {ok, Pid} = gen_server:start(asobi_bot_spawner_tests_stub, [], []),
    Pid.

setup() ->
    application:set_env(asobi, game_modes, #{}),
    meck:new(asobi_matchmaker, [non_strict, no_link]),
    meck:expect(asobi_matchmaker, add, fun(_BotId, _Opts) -> ok end),
    ok.

cleanup(_) ->
    meck:unload(asobi_matchmaker),
    application:unset_env(asobi, game_modes).

fill_capped_at_max_players() ->
    %% match_size = max_players = 2; bots.min_players left at the
    %% spawner's default (4). 1 human already queued.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 2,
            max_players => 2,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 1),
    ?assertEqual(1, meck:num_calls(asobi_matchmaker, add, '_')).

fill_reaches_min_players_under_cap() ->
    %% max_players is generous (10); min_players = 4 is fully reachable.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 4,
            max_players => 10,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 1),
    ?assertEqual(3, meck:num_calls(asobi_matchmaker, add, '_')).

no_bots_when_already_at_cap() ->
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 2,
            max_players => 2,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 2),
    ?assertEqual(0, meck:num_calls(asobi_matchmaker, add, '_')).

fill_clamped_at_ceiling() ->
    %% A sys.config-declared mode bypasses asobi_lua_config's own clamp
    %% entirely, so fill_mode/2 must enforce the ceiling itself. Without it,
    %% 1 human queued against min_players=max_players=5,000,000 would try
    %% to build a 5-million-element lists:seq/2 and issue that many
    %% gen_server:call/2s to the matchmaker.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 2,
            max_players => 5000000,
            bots => #{enabled => true, min_players => 5000000}
        }
    }),
    asobi_bot_spawner:fill_mode(~"arena", 1),
    ?assertEqual(?MAX_BOT_FILL - 1, meck:num_calls(asobi_matchmaker, add, '_')).

fill_stops_on_queue_full() ->
    %% 1 human queued against min_players=max_players=10 needs 9 bots, but
    %% the matchmaker reports queue_full on the 3rd add. The loop must stop
    %% right there — 3 calls total, not 9 — proving both that adds happen
    %% one at a time (not via a pre-built list whose per-element result is
    %% discarded) and that queue_full is honoured.
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 10,
            max_players => 10,
            bots => #{enabled => true, min_players => 10}
        }
    }),
    Counter = counters:new(1, []),
    meck:expect(asobi_matchmaker, add, fun(_BotId, _Opts) ->
        counters:add(Counter, 1, 1),
        case counters:get(Counter, 1) of
            N when N >= 3 -> {error, queue_full};
            _ -> ok
        end
    end),
    ?assertEqual(ok, asobi_bot_spawner:fill_mode(~"arena", 1)),
    ?assertEqual(3, meck:num_calls(asobi_matchmaker, add, '_')).

fill_stops_on_queue_full_immediately() ->
    application:set_env(asobi, game_modes, #{
        ~"arena" => #{
            match_size => 4,
            max_players => 4,
            bots => #{enabled => true, min_players => 4}
        }
    }),
    meck:expect(asobi_matchmaker, add, fun(_BotId, _Opts) -> {error, queue_full} end),
    ?assertEqual(ok, asobi_bot_spawner:fill_mode(~"arena", 1)),
    ?assertEqual(1, meck:num_calls(asobi_matchmaker, add, '_')).
