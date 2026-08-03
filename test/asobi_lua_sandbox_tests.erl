-module(asobi_lua_sandbox_tests).
-include_lib("eunit/include/eunit.hrl").

%% Negative tests for the asobi_lua sandbox. Every test in this suite
%% asserts that something a hostile script must NOT be able to do does
%% in fact fail. If any assertion here flips to a pass, somebody widened
%% the sandbox — re-read the change carefully before merging.

-spec fixture(string()) -> file:filename_all().
fixture(Name) ->
    {ok, LibDir} = safe_lib_dir(),
    filename:absname(filename:join([LibDir, "test", "fixtures", "lua", Name])).

-spec safe_lib_dir() -> {ok, string()}.
safe_lib_dir() ->
    case code:lib_dir(asobi) of
        {error, bad_name} -> error(asobi_not_loaded);
        Dir -> {ok, Dir}
    end.

%% --- OS escape hatches blocked ---

os_execute_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.execute", St)).

os_exit_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.exit", St)).

os_getenv_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.getenv", St)).

os_remove_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.remove", St)).

os_rename_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.rename", St)).

os_tmpname_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return os.tmpname", St)).

%% Calling them errors rather than silently succeeding — confirms a
%% script can't reach them via `pcall(os.execute, ...)`.
os_execute_call_errors_test() ->
    St = fresh_state(),
    ?assertEqual(false, eval_and_decode("return (pcall(os.execute, 'id'))", St)).

os_exit_call_errors_test() ->
    St = fresh_state(),
    ?assertEqual(false, eval_and_decode("return (pcall(os.exit, 0))", St)).

%% Time-related os.* helpers must remain available so games can timestamp.
os_time_still_works_test() ->
    St = fresh_state(),
    Result = eval_and_decode("return type(os.time())", St),
    ?assertEqual(~"number", Result).

os_clock_still_works_test() ->
    St = fresh_state(),
    Result = eval_and_decode("return type(os.clock())", St),
    ?assertEqual(~"number", Result).

%% --- Code-loading entry points blocked ---

dofile_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return dofile", St)).

loadfile_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return loadfile", St)).

load_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return load", St)).

loadstring_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return loadstring", St)).

%% Even if Luerl had a bytecode loader (it doesn't in 1.5.x), the
%% global is gone so the binary chunk header attack is moot.
bytecode_load_blocked_test() ->
    St = fresh_state(),
    ?assertEqual(false, eval_and_decode("return (pcall(load, '\\27Lua\\1', 'x', 'b'))", St)).

%% --- io & package blocked ---

io_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return io", St)).

package_is_nil_test() ->
    St = fresh_state(),
    ?assertEqual(nil, eval_and_decode("return package", St)).

%% --- require: validation, traversal, escape ---

require_rejects_dot_dot_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, '..foo')\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

require_rejects_absolute_path_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, '/etc/passwd')\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

require_rejects_slash_traversal_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, '../../../etc/passwd')\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

require_rejects_empty_name_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, '')\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

require_rejects_non_string_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, 42)\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

require_rejects_unknown_module_test() ->
    St = fresh_state(),
    Code =
        "local ok, err = pcall(require, 'definitely_not_a_real_module')\n"
        "return ok",
    ?assertEqual(false, eval_and_decode(Code, St)).

%% Sandboxed init (no base dir) means require always errors regardless
%% of the name — used by `asobi_lua_config` for evaluating manifests.
require_in_sandboxed_init_always_errors_test() ->
    St = asobi_lua_loader:init_sandboxed(),
    ?assertEqual(false, eval_and_decode("return (pcall(require, 'boons'))", St)).

%% --- require: legitimate use still works + caches ---

require_resolves_real_module_test() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Code =
        "local m = require('boons')\n"
        "return type(m.apply)",
    ?assertEqual(~"function", eval_and_decode(Code, St)).

%% A second require() returns the *same* table reference. We assert that
%% mutating the first reference is visible through a second require —
%% that is the only externally observable test for "is the cache hit".
require_caches_module_test() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    Code =
        "local a = require('boons')\n"
        "a.marker = 'mutated'\n"
        "local b = require('boons')\n"
        "return b.marker",
    ?assertEqual(~"mutated", eval_and_decode(Code, St)).

%% --- atom exhaustion guardrail ---

atom_count_stable_under_unknown_keys_test() ->
    %% asobi_lua_api:safe_to_atom/1 must use binary_to_existing_atom/1
    %% so a hostile script can't blow up atom_count by sending novel
    %% strings as map keys that flow into atomize_keys. We construct
    %% 200 unique runtime-built keys (Lua `..` concatenation, so the
    %% binaries never exist in the source code's literal pool) and
    %% drive them through the same code path. A regression to
    %% binary_to_atom/1 would jump atom_count by ~200; the existing
    %% guard keeps it flat.
    St = install_api(),
    Code =
        "local tag = '" ++ unique_tag() ++
            "'\n"
            "local a = { x = 0.0, y = 0.0 }\n"
            "for i = 1, 200 do a[tag .. '_' .. i] = 1.0 end\n"
            "local b = { x = 0.0, y = 0.0 }\n"
            "game.spatial.in_range(a, b, 1.0)\n"
            "return true\n",
    BeforeCount = erlang:system_info(atom_count),
    {ok, _, _} = luerl:do(Code, St),
    AfterCount = erlang:system_info(atom_count),
    %% A few atoms can come from unrelated bookkeeping during the call
    %% (logger formatters, error-info modules first-touched). The
    %% threshold catches a 200-atom regression while tolerating that.
    ?assert(AfterCount - BeforeCount < 30).

unique_tag() ->
    "sandbox_key_" ++ integer_to_list(erlang:unique_integer([positive])).

%% --- Cross-state isolation ---

two_states_do_not_share_globals_test() ->
    {ok, A} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, B} = asobi_lua_loader:new(fixture("test_match.lua")),
    {ok, _, A1} = luerl:do("ASOBI_TEST_MARK = 'a'\nreturn nil", A),
    {ok, _, _} = luerl:do("ASOBI_TEST_MARK = 'b'\nreturn nil", B),
    %% State A's marker must still be 'a' even though state B set 'b'.
    ?assertEqual(~"a", eval_and_decode("return ASOBI_TEST_MARK", A1)).

%% --- Helpers ---

fresh_state() ->
    {ok, St} = asobi_lua_loader:new(fixture("test_match.lua")),
    St.

install_api() ->
    St = fresh_state(),
    Ctx = #{match_id => ~"test", match_pid => self(), zone_pid => self()},
    asobi_lua_api:install(Ctx, St).

eval_and_decode(Code, St) ->
    case luerl:do(Code, St) of
        {ok, [Result | _], St1} -> luerl:decode(Result, St1);
        {ok, [], _} -> nil
    end.
