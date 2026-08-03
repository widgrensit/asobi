-module(asobi_lua_game_log_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

game_log_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"logs a string message with script context", fun logs_string/0},
        {"warn maps to warning level", fun warn_maps_to_warning/0},
        {"invalid level returns error envelope", fun invalid_level/0},
        {"wrong args return error envelope", fun wrong_args/0},
        {"table message renders as json", fun table_message/0},
        {"long message is bounded", fun long_message_bounded/0},
        {"meta table is forwarded", fun meta_forwarded/0},
        {"oversized meta is truncated", fun meta_truncated/0},
        {"per-key deny returns false and skips global", fun per_key_denied/0},
        {"global deny returns false", fun global_denied/0},
        {"missing limiters fail closed", fun no_limiter_fails_closed/0},
        {"zone context keys on zone pid", fun zone_keyed_on_pid/0},
        {"non-utf8 message bytes are scrubbed, not a crash", fun non_utf8_message/0},
        {"long non-utf8 message is scrubbed and bounded", fun long_non_utf8_message/0},
        {"control chars are stripped from messages", fun control_chars_stripped/0},
        {"zone_ctx carries the script from game_config", fun zone_ctx_carries_script/0},
        {"make_ctx carries the script from config", fun make_ctx_carries_script/0},
        {"match bridge threads script into game.log", fun match_bridge_script_in_log/0}
    ]}.

setup() ->
    OldPrimary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => undefined, level => all}),
    meck:new(seki, [no_link, passthrough]),
    meck:expect(seki, check, fun(_, _) -> {allow, 1} end),
    OldPrimary.

%% eunit runs each foreach test in its own process, so the receiving pid
%% must be attached per-test, not captured in setup.
attach() ->
    ok = logger:set_handler_config(?MODULE, config, self()).

cleanup(OldPrimary) ->
    _ = logger:remove_handler(?MODULE),
    ok = logger:set_primary_config(OldPrimary),
    meck:unload(seki).

log(#{level := Level, msg := {report, Report}}, #{config := Pid}) ->
    Pid ! {game_log, Level, Report};
log(_, _) ->
    ok.

install_api() ->
    install_api(#{match_id => ~"m1", match_pid => self(), script => ~"priv/lua/game.lua"}).

install_api(Ctx) ->
    {ok, St0} = asobi_lua_loader:new(fixture("test_match.lua")),
    asobi_lua_api:install(Ctx, St0).

fixture(Name) ->
    Dir =
        case code:lib_dir(asobi) of
            {error, bad_name} -> error(asobi_not_loaded);
            D -> D
        end,
    filename:join([Dir, "test", "fixtures", "lua", Name]).

eval(Code, St) ->
    luerl:do(Code, St).

recv_report() ->
    receive
        {game_log, Level, Report} -> {Level, Report}
    after 1000 -> error(no_log_received)
    end.

logs_string() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', 'hello world')", St),
    {info, Report} = recv_report(),
    ?assertEqual(~"game.log", maps:get(msg, Report)),
    ?assertEqual(~"game.lua", maps:get(script, Report)),
    ?assertEqual(~"m1", maps:get(match_id, Report)),
    ?assertEqual(match, maps:get(context, Report)),
    ?assertEqual(~"hello world", maps:get(message, Report)),
    ?assertNot(maps:is_key(meta, Report)).

warn_maps_to_warning() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('warn', 'careful')", St),
    {warning, _} = recv_report().

invalid_level() ->
    attach(),
    St = install_api(),
    {ok, [Res | _], _} = eval("local r = game.log('shout', 'x') return r.error ~= nil", St),
    ?assertEqual(true, Res),
    receive
        {game_log, _, _} -> error(unexpected_log)
    after 50 -> ok
    end.

wrong_args() ->
    St = install_api(),
    {ok, [Res | _], _} = eval("local r = game.log(42) return r.error ~= nil", St),
    ?assertEqual(true, Res).

table_message() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', { hp = 10, name = 'goblin' })", St),
    {info, Report} = recv_report(),
    Msg = maps:get(message, Report),
    ?assertMatch({_, _}, binary:match(Msg, ~"goblin")),
    ?assertMatch({_, _}, binary:match(Msg, ~"10")).

long_message_bounded() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', string.rep('x', 5000))", St),
    {info, Report} = recv_report(),
    ?assert(string:length(maps:get(message, Report)) =< 500).

meta_forwarded() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', 'spawn', { id = 'e1', hp = 5 })", St),
    {info, Report} = recv_report(),
    ?assertEqual(#{~"id" => ~"e1", ~"hp" => 5}, maps:get(meta, Report)).

meta_truncated() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval(
        "return game.log('info', 'big', { blob = string.rep('x', 4000) })", St
    ),
    {info, Report} = recv_report(),
    ?assertEqual(#{~"_truncated" => true}, maps:get(meta, Report)).

per_key_denied() ->
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, _) -> {deny, 0};
        (asobi_lua_log_global_limiter, _) -> error(should_not_be_spent)
    end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'dropped')", St),
    ?assertEqual(1, meck:num_calls(seki, check, [asobi_lua_log_limiter, '_'])).

global_denied() ->
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, _) -> {allow, 1};
        (asobi_lua_log_global_limiter, _) -> {deny, 0}
    end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'dropped')", St).

no_limiter_fails_closed() ->
    meck:expect(seki, check, fun(_, _) -> error(limiter_not_registered) end),
    St = install_api(),
    {ok, [false | _], _} = eval("return game.log('info', 'nowhere to go')", St).

zone_keyed_on_pid() ->
    attach(),
    Self = self(),
    meck:expect(seki, check, fun
        (asobi_lua_log_limiter, Key) when Key =:= Self -> {allow, 1};
        (asobi_lua_log_global_limiter, _) -> {allow, 1};
        (asobi_lua_log_limiter, Other) -> error({wrong_key, Other})
    end),
    St = install_api(#{
        match_id => ~"world-1",
        match_pid => self(),
        zone_pid => self(),
        script => ~"world.lua"
    }),
    {ok, [true | _], _} = eval("return game.log('info', 'from zone')", St),
    {info, Report} = recv_report(),
    ?assertEqual(zone, maps:get(context, Report)).

non_utf8_message() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', string.char(255, 254))", St),
    {info, Report} = recv_report(),
    Msg = maps:get(message, Report),
    ?assert(is_binary(Msg)),
    ?assertNotEqual(nomatch, binary:match(Msg, <<16#EF, 16#BF, 16#BD>>)).

long_non_utf8_message() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval(
        "return game.log('info', string.rep(string.char(255), 700))", St
    ),
    {info, Report} = recv_report(),
    Msg = maps:get(message, Report),
    ?assert(is_binary(Msg)),
    ?assert(string:length(Msg) =< 500).

control_chars_stripped() ->
    attach(),
    St = install_api(),
    {ok, [true | _], _} = eval("return game.log('info', 'a\\nfake log line\\rb\\tc')", St),
    {info, Report} = recv_report(),
    ?assertEqual(~"afake log lineb\tc", maps:get(message, Report)).

zone_ctx_carries_script() ->
    Tab = ets:new(test_templates, [set, protected]),
    ets:insert(Tab, {known, #{~"goblin" => #{type => ~"npc", base_state => #{}}}}),
    Ctx = asobi_lua_world:zone_ctx(
        #{
            world_server_pid => self(),
            game_config => #{match_id => ~"w1", lua_script => ~"priv/lua/world.lua"}
        },
        Tab
    ),
    ?assertEqual(~"priv/lua/world.lua", maps:get(script, Ctx)),
    ?assertEqual(self(), maps:get(zone_pid, Ctx)),
    ?assertEqual(~"w1", maps:get(match_id, Ctx)),
    %% asobi_lua#110 + asobi#253: zone_ctx/2 carries a table REFERENCE, not
    %% a known_templates map snapshot - known_template/2 reads the live row
    %% from this table at call time, so it survives any number of hot
    %% reloads.
    ?assertEqual(Tab, maps:get(templates_tab, Ctx)),
    ?assertNot(maps:is_key(known_templates, Ctx)).

make_ctx_carries_script() ->
    Ctx = asobi_lua_world:make_ctx(#{
        match_id => ~"w2", lua_script => ~"priv/lua/world.lua"
    }),
    ?assertEqual(~"priv/lua/world.lua", maps:get(script, Ctx)),
    ?assertEqual(~"w2", maps:get(match_id, Ctx)).

match_bridge_script_in_log() ->
    attach(),
    Name = "game_log_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".lua",
    Path = filename:join([filename:basedir(user_cache, "asobi_lua_tests"), Name]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(
        Path,
        ~"""
        match_size = 1
        function init(_) return {} end
        function join(id, s) return s end
        function leave(id, s) return s end
        function handle_input(pid, input, s)
            game.log("info", "input seen")
            return s
        end
        function tick(s) return s end
        function get_state(_, s) return s end
        """
    ),
    {ok, State} = asobi_lua_match:init(#{lua_script => Path, match_id => ~"m-log"}),
    {ok, _} = asobi_lua_match:handle_input(~"p1", #{~"a" => 1}, State),
    {info, Report} = recv_report(),
    ?assertEqual(unicode:characters_to_binary(filename:basename(Name)), maps:get(script, Report)),
    ?assertEqual(~"m-log", maps:get(match_id, Report)),
    ?assertEqual(~"input seen", maps:get(message, Report)).
