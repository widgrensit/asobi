-module(asobi_lua_config_path_tests).
-include_lib("eunit/include/eunit.hrl").

%% H1 (2026-05-19): Lua-supplied script paths in config.lua and match.lua
%% (`bots.script`) flow through to file:read_file + Lua eval. Without
%% anchoring inside the game directory, a stray "../" could load any
%% readable file as Lua. These tests pin the safe_join contract.

-define(BASE, "/app/game").

valid_relative_path_test() ->
    {ok, Abs} = asobi_lua_config:safe_join(?BASE, ~"arena/match.lua"),
    ?assertEqual("/app/game/arena/match.lua", Abs).

valid_nested_path_test() ->
    {ok, Abs} = asobi_lua_config:safe_join(?BASE, ~"deep/nested/path/script.lua"),
    ?assertEqual("/app/game/deep/nested/path/script.lua", Abs).

dotdot_segment_rejected_test() ->
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"../escape.lua")
    ).

nested_dotdot_rejected_test() ->
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"arena/../../../etc/passwd")
    ).

absolute_path_rejected_test() ->
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"/etc/passwd")
    ).

empty_path_rejected_test() ->
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"")
    ).

dot_segment_rejected_test() ->
    %% `./foo.lua` should be rejected: the intent is to enforce explicit,
    %% minimal relative paths. If a script wants the current dir it can
    %% just write `foo.lua`.
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"./match.lua")
    ).

double_slash_rejected_test() ->
    %% `foo//bar.lua` has an empty path segment between the slashes; the
    %% safe-relative check rejects empty segments to keep normalisation
    %% deterministic.
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"arena//match.lua")
    ).

newline_in_segment_rejected_test() ->
    %% A newline in a filename is legal on Linux and survives a tar, and the
    %% resolved path is logged as a charlist, which OTP's default formatter
    %% prints with ~ts rather than escaping. Without this a bundle names a file
    %% "a\nlevel=emergency msg=...\n.lua" and forges whole operator log lines.
    ?assertMatch(
        {error, _},
        asobi_lua_config:safe_join(?BASE, ~"a\nlevel=emergency msg=forged\n.lua")
    ).

control_char_in_segment_rejected_test() ->
    %% The whole C0 range plus DEL, not just newline: CR splits a line just as
    %% well, and ESC drives a terminal reading the log.
    ?assertMatch({error, _}, asobi_lua_config:safe_join(?BASE, ~"arena/ma\rtch.lua")),
    ?assertMatch({error, _}, asobi_lua_config:safe_join(?BASE, ~"arena/ma\x{1b}[2Jtch.lua")),
    ?assertMatch({error, _}, asobi_lua_config:safe_join(?BASE, ~"arena/ma\x{7f}tch.lua")),
    ?assertMatch({error, _}, asobi_lua_config:safe_join(?BASE, ~"arena/ma\x{00}tch.lua")).

ordinary_path_still_accepted_test() ->
    %% The control-char guard must not reject anything that was legal before:
    %% spaces, dots, dashes and non-ASCII names are all fine.
    ?assertMatch({ok, _}, asobi_lua_config:safe_join(?BASE, ~"my modes/arena-2.lua")),
    ?assertMatch({ok, _}, asobi_lua_config:safe_join(?BASE, ~"モード/match.lua")).

base_with_trailing_slash_handled_test() ->
    %% Operator-supplied GameDir may or may not have a trailing slash.
    %% Both forms must yield the same normalised result and pass the
    %% prefix check.
    {ok, A} = asobi_lua_config:safe_join("/app/game", ~"arena/match.lua"),
    {ok, B} = asobi_lua_config:safe_join("/app/game/", ~"arena/match.lua"),
    ?assertEqual(A, B).
