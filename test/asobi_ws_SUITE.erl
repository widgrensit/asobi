-module(asobi_ws_SUITE).

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    ws_connect_invalid_token/1,
    ws_heartbeat/1,
    ws_unknown_type/1,
    ws_idle_auth_timeout_closes/1,
    ws_match_input_not_in_match_hint/1,
    ws_match_find_or_create_joins/1,
    ws_match_input_hint_rate_limited/1,
    ws_script_error_rendered_as_extension_error/1,
    ws_matchmaker_add_omitted_mode_rejected/1,
    ws_backfill_join_binds_the_session/1,
    ws_join_a_locked_match_is_refused/1
]).

all() ->
    [
        ws_connect_invalid_token,
        ws_heartbeat,
        ws_unknown_type,
        ws_idle_auth_timeout_closes,
        ws_match_input_not_in_match_hint,
        ws_match_find_or_create_joins,
        ws_match_input_hint_rate_limited,
        ws_script_error_rendered_as_extension_error,
        ws_matchmaker_add_omitted_mode_rejected,
        ws_backfill_join_binds_the_session,
        ws_join_a_locked_match_is_refused
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

ws_connect_invalid_token(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"session.connect",
            ~"cid" => ~"1",
            ~"payload" => #{~"token" => ~"invalid_token"}
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"error", ~"cid" := ~"1"}, Resp),
    nova_test_ws:close(Conn),
    Config.

ws_heartbeat(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"session.heartbeat",
            ~"cid" => ~"hb1"
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"session.heartbeat", ~"cid" := ~"hb1"}, Resp),
    nova_test_ws:close(Conn),
    Config.

ws_unknown_type(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    nova_test_ws:send_json(
        #{
            ~"type" => ~"nonexistent.type",
            ~"cid" => ~"u1",
            ~"payload" => #{}
        },
        Conn
    ),
    {ok, Resp} = nova_test_ws:recv_json(Conn),
    ?assertMatch(#{~"type" := ~"error", ~"payload" := #{~"reason" := ~"unknown_type"}}, Resp),
    nova_test_ws:close(Conn),
    Config.

%% #236: match.input with no joined match/zone is dropped, but the sender
%% must get a `not_in_match` hint so the drop is debuggable client-side.
ws_match_input_not_in_match_hint(Config) ->
    {_, Token} = register_player(~"nomatch", Config),
    Conn = ws_connect_authed(Token, Config),
    ok = nova_test_ws:send_json(
        #{~"type" => ~"match.input", ~"payload" => #{~"message" => ~"up"}},
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{~"payload" := #{~"reason" := ~"not_in_match", ~"type" := ~"match.input"}}, Reply
    ),
    Config.

%% #236: the hint is per-connection rate-limited - a client spamming input
%% while unjoined gets one hint per window, not a reflected stream.
ws_match_input_hint_rate_limited(Config) ->
    {_, Token} = register_player(~"nomatchrl", Config),
    Conn = ws_connect_authed(Token, Config),
    Input = #{~"type" => ~"match.input", ~"payload" => #{~"message" => ~"up"}},
    ok = nova_test_ws:send_json(Input, Conn),
    {ok, _} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    ok = nova_test_ws:send_json(Input, Conn),
    ok = nova_test_ws:send_json(Input, Conn),
    ?assertEqual({error, timeout}, nova_test_ws:recv(Conn, 300)),
    nova_test_ws:close(Conn),
    Config.

%% asobi_lua#98: a {script_error, Payload} presence message (sent by the
%% Lua runtime in dev-errors mode) must reach the client as a
%% module.error wire event carrying the payload unchanged. S6: the pre-S6
%% game.error frame rides alongside it until the 1.0 wire break, and both
%% must survive the socket as two separate frames - which is the part
%% unit tests cannot prove, because the splice happens inside nova.
ws_script_error_rendered_as_extension_error(Config) ->
    {PlayerId, Token} = register_player(~"scripterr", Config),
    Conn = ws_connect_authed(Token, Config),
    asobi_presence:send(
        PlayerId,
        {script_error, #{
            ~"callback" => ~"handle_input",
            ~"script" => ~"match.lua",
            ~"message" => ~"bad arithmetic + on nil, 1"
        }}
    ),
    {ok, Legacy} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"game.error" end, Conn
    ),
    {ok, Current} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"module.error" end, Conn
    ),
    nova_test_ws:close(Conn),
    Expected = #{
        ~"payload" => #{
            ~"module" => ~"lua",
            ~"callback" => ~"handle_input",
            ~"script" => ~"match.lua",
            ~"message" => ~"bad arithmetic + on nil, 1"
        }
    },
    ?assertEqual(Expected, maps:with([~"payload"], Legacy)),
    ?assertEqual(Expected, maps:with([~"payload"], Current)),
    Config.

%% asobi#243: matchmaker.add with no `mode' defaults to "default"; the WS edge
%% gates on the same known_mode/1 as REST, so an unmapped "default" must be
%% rejected here too (dev_sys.config.src ships an empty game_modes).
ws_matchmaker_add_omitted_mode_rejected(Config) ->
    {_, Token} = register_player(~"mmnomode", Config),
    Conn = ws_connect_authed(Token, Config),
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"matchmaker.add",
            ~"cid" => ~"mm1",
            ~"payload" => #{~"properties" => #{~"skill" => 1200}}
        },
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{
            ~"cid" := ~"mm1",
            ~"payload" := #{~"type" := ~"matchmaker.add", ~"reason" := ~"unknown_mode"}
        },
        Reply
    ),
    Config.

%% A WS that opens and never sends `session.connect` must be closed by
%% the server with code 1008 once the idle-auth window elapses.
ws_idle_auth_timeout_closes(Config) ->
    Old = application:get_env(asobi, ws_idle_auth_timeout_ms),
    application:set_env(asobi, ws_idle_auth_timeout_ms, 200),
    try
        {ok, Conn} = nova_test_ws:connect("/ws", Config),
        ?assertEqual({error, {closed, 1008}}, nova_test_ws:recv(Conn, 2000))
    after
        case Old of
            {ok, V} -> application:set_env(asobi, ws_idle_auth_timeout_ms, V);
            undefined -> application:unset_env(asobi, ws_idle_auth_timeout_ms)
        end
    end,
    Config.

%% --- helpers (mirrors asobi_chat_ws_SUITE) ---

%% asobi#423: the whole backfill path over a real socket. A player who finds a
%% match with match.list and joins it by id must end up bound to it - the
%% matchmaker used to be the only thing that told the session which match it
%% was in, so this join left the session with no match_pid: input came back
%% `not_in_match` and leave silently did nothing. Both are only observable
%% through the socket, which is why this is a suite case and not a unit test.
ws_backfill_join_binds_the_session(Config) ->
    {PlayerId, Token} = register_player(~"backfill", Config),
    Conn = ws_connect_authed(Token, Config),
    MatchPid = start_test_match(),
    MatchId = maps:get(match_id, asobi_match_server:get_info(MatchPid)),

    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"match.join",
            ~"cid" => ~"bf1",
            ~"payload" => #{~"match_id" => MatchId}
        },
        Conn
    ),
    {ok, Joined} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"match.joined" end, Conn
    ),
    ?assertMatch(#{~"payload" := #{~"joinable" := true}}, Joined),

    %% Input from a bound session is applied silently. The hint frame is the
    %% failure signal, so its absence is the assertion.
    ok = nova_test_ws:send_json(
        #{~"type" => ~"match.input", ~"payload" => #{~"action" => ~"move"}}, Conn
    ),
    ?assertEqual(
        {error, predicate_not_matched},
        recv_until(
            fun(M) ->
                maps:get(~"reason", maps:get(~"payload", M, #{}), undefined) =:= ~"not_in_match"
            end,
            Conn,
            5
        )
    ),

    %% `match.left` is answered unconditionally, so the reply proves nothing.
    %% What proves the leave landed is the match emptying and stopping. Asserted
    %% before the socket closes, because closing the session would empty the
    %% match on its own through the server's monitor and hide a leave that did
    %% nothing.
    Ref = monitor(process, MatchPid),
    ok = nova_test_ws:send_json(#{~"type" => ~"match.leave", ~"cid" => ~"bf2"}, Conn),
    {ok, _} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"match.left" end, Conn
    ),
    receive
        {'DOWN', Ref, process, MatchPid, {shutdown, empty}} -> ok
    after 5000 ->
        ct:fail({leave_did_not_reach_the_match, PlayerId})
    end,
    nova_test_ws:close(Conn),
    Config.

ws_join_a_locked_match_is_refused(Config) ->
    {_, Token} = register_player(~"locked", Config),
    Conn = ws_connect_authed(Token, Config),
    MatchPid = start_test_match(),
    MatchId = maps:get(match_id, asobi_match_server:get_info(MatchPid)),
    ok = asobi_match_server:set_joinable(MatchPid, false),

    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"match.join",
            ~"cid" => ~"lk1",
            ~"payload" => #{~"match_id" => MatchId}
        },
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"error" end, Conn
    ),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{
            ~"payload" := #{
                ~"reason" := ~"match_locked",
                ~"error" := #{~"code" := ~"match.locked"}
            }
        },
        Reply
    ),
    Config.

%% min_players => 1 so the match is `running` from the first join, which is
%% the state a backfill joiner actually meets.
start_test_match() ->
    {ok, Pid} = asobi_match_sup:start_match(#{
        game_module => asobi_test_game,
        min_players => 1,
        max_players => 4,
        tick_rate => 50
    }),
    Pid.

register_player(Suffix, Config) ->
    Username = unique_name(Suffix),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    {PlayerId, Token}.

%% asobi#357: `erlang:unique_integer/1` is unique per runtime instance, not
%% across runs, while `players` persists - so a later run re-mints a username an
%% earlier one registered and hits the unique index. The name must stay inside
%% the 32-character username limit, hence a short tag plus 8 hex.
unique_name(Suffix) ->
    <<"ws_", Suffix/binary, "_", (asobi_id:rand_suffix(4))/binary>>.

ws_connect_authed(Token, Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"session.connect",
            ~"cid" => ~"sess",
            ~"payload" => #{~"token" => Token}
        },
        Conn
    ),
    {ok, _} = recv_until(
        fun(M) -> maps:get(~"type", M, undefined) =:= ~"session.connected" end,
        Conn
    ),
    Conn.

recv_until(Pred, Conn) ->
    recv_until(Pred, Conn, 50).

recv_until(_Pred, _Conn, 0) ->
    {error, predicate_not_matched};
recv_until(Pred, Conn, N) ->
    case nova_test_ws:recv_json(Conn) of
        {ok, Msg} ->
            case Pred(Msg) of
                true -> {ok, Msg};
                false -> recv_until(Pred, Conn, N - 1)
            end;
        {error, _} = Err ->
            Err
    end.

%% asobi#482: match.find_or_create is the match twin of world.find_or_create.
%% Two things this pins that a unit test cannot: the frame is dispatched at all
%% (it is an additive inbound type under the 1.0 freeze), and the reply is
%% match.joined rather than a new match.created leaf - minting an outbound
%% match. leaf would have to enter ?RESERVED_EVENT_NAMES and would retroactively
%% ban that name for any shipped game broadcasting it via game.broadcast.
ws_match_find_or_create_joins(Config) ->
    Prev = application:get_env(asobi, game_modes),
    application:set_env(asobi, game_modes, #{
        ~"foc_ws" => #{
            module => asobi_test_game,
            match_size => 2,
            min_players => 2,
            max_players => 8,
            listed => true
        }
    }),
    try
        {_, Tok1} = register_player(~"focws1", Config),
        Conn1 = ws_connect_authed(Tok1, Config),
        ok = nova_test_ws:send_json(
            #{
                ~"type" => ~"match.find_or_create",
                ~"cid" => ~"f1",
                ~"payload" => #{~"mode" => ~"foc_ws"}
            },
            Conn1
        ),
        {ok, R1} = recv_until(fun(M) -> maps:get(~"cid", M, undefined) =:= ~"f1" end, Conn1),
        ?assertEqual(~"match.joined", maps:get(~"type", R1, undefined)),
        MatchId = maps:get(~"match_id", maps:get(~"payload", R1, #{}), undefined),
        ?assert(is_binary(MatchId)),

        %% A second player asking for the same mode must land in that match,
        %% not a fresh one - the whole point of the verb.
        {_, Tok2} = register_player(~"focws2", Config),
        Conn2 = ws_connect_authed(Tok2, Config),
        ok = nova_test_ws:send_json(
            #{
                ~"type" => ~"match.find_or_create",
                ~"cid" => ~"f2",
                ~"payload" => #{~"mode" => ~"foc_ws"}
            },
            Conn2
        ),
        {ok, R2} = recv_until(fun(M) -> maps:get(~"cid", M, undefined) =:= ~"f2" end, Conn2),
        nova_test_ws:close(Conn1),
        nova_test_ws:close(Conn2),
        ?assertEqual(~"match.joined", maps:get(~"type", R2, undefined)),
        ?assertEqual(
            MatchId,
            maps:get(~"match_id", maps:get(~"payload", R2, #{}), undefined),
            "the second caller must find the first caller's match"
        )
    after
        case Prev of
            {ok, P} -> application:set_env(asobi, game_modes, P);
            undefined -> application:unset_env(asobi, game_modes)
        end
    end,
    Config.
