-module(prop_lua_sandbox).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr property: every "forbidden expression" generated from our
%% small grammar of dangerous Lua calls fails to escalate. Either the
%% global is nil (so the call errors), or the call returns an error,
%% or the call is a no-op — but it never returns a usable function
%% reference and it never crashes the calling Erlang process.

-define(NUMTESTS, 50).

prop_sandbox_blocks_dangerous_calls_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_block_dangerous(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

prop_block_dangerous() ->
    ?FORALL(
        Expr,
        forbidden_expr(),
        check_blocked(Expr)
    ).

%% --- Generators ---

forbidden_expr() ->
    proper_types:oneof([
        os_call(),
        load_call(),
        package_access(),
        require_traversal(),
        io_access()
    ]).

os_call() ->
    proper_types:elements([
        "os.execute('id')",
        "os.exit(0)",
        "os.getenv('HOME')",
        "os.remove('/tmp/x')",
        "os.rename('a', 'b')",
        "os.tmpname()"
    ]).

load_call() ->
    proper_types:elements([
        "load('return 1')",
        "loadstring('return 1')",
        "loadfile('/etc/passwd')",
        "dofile('/etc/passwd')"
    ]).

package_access() ->
    proper_types:elements([
        "package",
        "package.loaded",
        "package.path",
        "package.searchers",
        "package.loadlib"
    ]).

require_traversal() ->
    proper_types:elements([
        "require('/etc/passwd')",
        "require('../../etc/passwd')",
        "require('..foo')",
        "require('foo/bar')",
        "require('')",
        "require(42)"
    ]).

io_access() ->
    proper_types:elements([
        "io",
        "io.open('/etc/passwd')",
        "io.read()"
    ]).

%% --- Property body ---

-spec check_blocked(string()) -> boolean().
check_blocked(Expr) ->
    St = fresh_state(),
    Code = "local ok, _ = pcall(function() return " ++ Expr ++ " end)\nreturn ok",
    case luerl:do(Code, St) of
        {ok, [Ok | _], _} ->
            %% Either pcall returns false (call errored — good) or it
            %% returns true with a result that must NOT be a usable
            %% function reference. We accept boolean true only when
            %% the expression evaluates to something safely nil.
            case Ok of
                false ->
                    true;
                true ->
                    %% Re-evaluate without the pcall wrapper to inspect
                    %% the actual value. If it's nil that's fine.
                    Bare = "return " ++ Expr,
                    case luerl:do(Bare, fresh_state()) of
                        {ok, [nil | _], _} -> true;
                        {ok, [], _} -> true;
                        _ -> false
                    end
            end;
        _ ->
            %% A non-ok return from luerl:do means the script wouldn't
            %% even compile/run, which is also "blocked".
            true
    end.

%% --- Helpers ---

fresh_state() ->
    {ok, St} = asobi_lua_loader:new(fixture_path("test_match.lua")),
    St.

fixture_path(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:join([Dir, "test", "fixtures", "lua", Name])
    end.
