-module(asobi_rpc_SUITE).
-moduledoc """
The extension RPC wire, over a real socket.

Unit tests prove the dispatcher maps a declared method onto a module. This
proves a client can reach it: `rpc.call` in over cowboy, `rpc.ok` or
`rpc.error` out, with the extension installed as a loaded OTP application the
way a dependency is. The distinction is the whole point of the change - the
declaration was already validated before any of this existed.
""".

-include_lib("nova_test/include/nova_test.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    rpc_call_reaches_the_extension/1,
    rpc_error_carries_the_extensions_own_code/1,
    rpc_unknown_method/1,
    rpc_requires_an_authenticated_socket/1,
    rpc_rejects_an_unvalidated_cid/1,
    rpc_rejects_a_foreign_protocol_version/1
]).

-define(QUESTS, asobi_fixture_quests).

all() ->
    [
        rpc_call_reaches_the_extension,
        rpc_error_carries_the_extensions_own_code,
        rpc_unknown_method,
        rpc_requires_an_authenticated_socket,
        rpc_rejects_an_unvalidated_cid,
        rpc_rejects_a_foreign_protocol_version
    ].

%% The registry is memoised at Nova's boot, before this suite runs, so the
%% fixture is installed and the memo cleared rather than the node restarted.
%% `resolve/0` re-reads the loaded application set, which is exactly what a
%% real release does once at boot.
init_per_suite(Config) ->
    Config1 = asobi_test_helpers:start(Config),
    ok = asobi_fixture_app:install(?QUESTS, asobi_fixture_quests_extension, []),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config1.

end_per_suite(Config) ->
    asobi_fixture_app:uninstall(?QUESTS),
    asobi_extensions:reset(),
    _ = asobi_extensions:resolve(),
    Config.

rpc_call_reaches_the_extension(Config) ->
    {PlayerId, Token} = register_player(~"rpcok", Config),
    Conn = ws_connect_authed(Token, Config),
    Reply = rpc_call(Conn, ~"r-1", ~"quests.list", #{~"echo" => ~"pong"}),
    nova_test_ws:close(Conn),
    ?assertMatch(#{~"type" := ~"rpc.ok", ~"cid" := ~"r-1"}, Reply),
    #{~"payload" := #{~"result" := Result}} = Reply,
    ?assertEqual(
        #{~"player_id" => PlayerId, ~"method" => ~"quests.list", ~"echo" => ~"pong"},
        Result
    ),
    Config.

%% #364 gave an extension its own code domain. A failure from an extension's
%% handler must surface as that code, not as `internal`.
rpc_error_carries_the_extensions_own_code(Config) ->
    {_, Token} = register_player(~"rpcerr", Config),
    Conn = ws_connect_authed(Token, Config),
    Reply = rpc_call(Conn, ~"r-2", ~"quests.claim", #{~"behaviour" => ~"declared_code"}),
    nova_test_ws:close(Conn),
    ?assertMatch(#{~"type" := ~"rpc.error", ~"cid" := ~"r-2"}, Reply),
    ?assertMatch(
        #{
            ~"payload" := #{
                ~"error" := #{
                    ~"code" := ~"quests.already_claimed",
                    ~"message" := ~"This quest was already claimed.",
                    ~"details" := #{}
                }
            }
        },
        Reply
    ),
    Config.

rpc_unknown_method(Config) ->
    {_, Token} = register_player(~"rpc404", Config),
    Conn = ws_connect_authed(Token, Config),
    Reply = rpc_call(Conn, ~"r-3", ~"quests.nothing_here", #{}),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{
            ~"type" := ~"rpc.error",
            ~"payload" := #{~"error" := #{~"code" := ~"rpc.unknown_method"}}
        },
        Reply
    ),
    Config.

%% A socket that never sent session.connect has no player, so a declared
%% method must not run for it. `unauthenticated`, not `unknown_type`: the
%% method exists and the caller does not.
rpc_requires_an_authenticated_socket(Config) ->
    {ok, Conn} = nova_test_ws:connect("/ws", Config),
    Reply = rpc_call(Conn, ~"r-4", ~"quests.claim", #{}),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{~"type" := ~"rpc.error", ~"payload" := #{~"error" := #{~"code" := ~"unauthenticated"}}},
        Reply
    ),
    Config.

%% An invalid cid is not echoed back, so the reply frame carries none at all.
rpc_rejects_an_unvalidated_cid(Config) ->
    {_, Token} = register_player(~"rpccid", Config),
    Conn = ws_connect_authed(Token, Config),
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"rpc.call",
            ~"cid" => 17,
            ~"payload" => #{
                ~"protocol" => 1, ~"method" => ~"quests.claim", ~"params" => #{}
            }
        },
        Conn
    ),
    {ok, Reply} = recv_until(fun(M) -> maps:get(~"type", M, undefined) =:= ~"rpc.error" end, Conn),
    nova_test_ws:close(Conn),
    ?assertEqual(error, maps:find(~"cid", Reply)),
    ?assertMatch(
        #{~"payload" := #{~"error" := #{~"code" := ~"rpc.invalid_cid"}}},
        Reply
    ),
    Config.

rpc_rejects_a_foreign_protocol_version(Config) ->
    {_, Token} = register_player(~"rpcproto", Config),
    Conn = ws_connect_authed(Token, Config),
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"rpc.call",
            ~"cid" => ~"r-5",
            ~"payload" => #{
                ~"protocol" => 99, ~"method" => ~"quests.claim", ~"params" => #{}
            }
        },
        Conn
    ),
    {ok, Reply} = recv_until(fun(M) -> maps:get(~"type", M, undefined) =:= ~"rpc.error" end, Conn),
    nova_test_ws:close(Conn),
    ?assertMatch(
        #{
            ~"cid" := ~"r-5",
            ~"payload" := #{
                ~"error" := #{
                    ~"code" := ~"rpc.unsupported_protocol",
                    ~"details" := #{~"supported" := [1]}
                }
            }
        },
        Reply
    ),
    Config.

%% --- helpers (mirrors asobi_ws_SUITE) ---

rpc_call(Conn, Cid, Method, Params) ->
    ok = nova_test_ws:send_json(
        #{
            ~"type" => ~"rpc.call",
            ~"cid" => Cid,
            ~"payload" => #{
                ~"protocol" => 1, ~"method" => Method, ~"params" => Params
            }
        },
        Conn
    ),
    {ok, Reply} = recv_until(
        fun(M) -> lists:member(maps:get(~"type", M, undefined), [~"rpc.ok", ~"rpc.error"]) end,
        Conn
    ),
    Reply.

%% asobi#357: `erlang:unique_integer/1` is unique per runtime instance, not
%% across runs, while `players` persists - so a later run re-mints a username an
%% earlier one registered and hits the unique index. The name must stay inside
%% the 32-character username limit, hence a short tag plus 8 hex.
register_player(Suffix, Config) ->
    Username = <<"rpc_", Suffix/binary, "_", (asobi_id:rand_suffix(4))/binary>>,
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    {PlayerId, Token}.

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
