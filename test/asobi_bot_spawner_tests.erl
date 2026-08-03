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
