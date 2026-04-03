-module(asobi_lua_loader).
-moduledoc """
Loads Lua scripts into a Luerl state with `require()` support.

Scripts are loaded from a base directory. The `require()` function
resolves module paths relative to that directory (e.g., `require("bots.chaser")`
loads `bots/chaser.lua`).
""".

-export([new/1, call/3, call/4]).

-spec new(binary() | string()) -> {ok, term()} | {error, term()}.
new(ScriptPath) ->
    BaseDir = filename:dirname(to_string(ScriptPath)),
    FileName = filename:basename(to_string(ScriptPath)),
    St0 = luerl:init(),
    St1 = install_searcher(BaseDir, St0),
    St2 = install_helpers(St1),
    FullPath = filename:join(BaseDir, FileName),
    case file:read_file(FullPath) of
        {ok, Code} ->
            CodeStr = binary_to_list(Code),
            try luerl:do(CodeStr, St2) of
                {ok, _Results, St3} -> {ok, St3};
                {error, Errors, _St3} -> {error, {lua_error, Errors}};
                {lua_error, Reason, _St3} -> {error, {lua_error, Reason}}
            catch
                error:{lua_error, Reason, _} -> {error, {lua_error, Reason}};
                error:Reason -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {file_error, FullPath, Reason}}
    end.

-spec call(atom() | [atom() | binary()], [term()], term()) ->
    {ok, [term()], term()} | {error, term()}.
call(FuncName, Args, St) when is_atom(FuncName) ->
    call([atom_to_binary(FuncName)], Args, St);
call(FuncPath, Args, St) ->
    BinPath = [ensure_binary(P) || P <- FuncPath],
    try
        case luerl:call_function(BinPath, Args, St) of
            {ok, Result, St1} -> {ok, Result, St1}
        end
    catch
        error:{lua_error, Reason, _} ->
            {error, {lua_error, Reason}};
        error:{try_clause, {lua_error, Reason, _}} ->
            {error, {lua_error, Reason}};
        _:_ ->
            {error, {call_failed, BinPath}}
    end.

-spec call(atom() | [atom() | binary()], [term()], term(), non_neg_integer()) ->
    {ok, [term()], term()} | {error, timeout | term()}.
call(FuncPath, Args, St, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Result = call(FuncPath, Args, St),
        Self ! {Ref, Result}
    end),
    receive
        {Ref, Result} -> Result
    after TimeoutMs ->
        exit(Pid, kill),
        {error, timeout}
    end.

%% --- Internal ---

install_searcher(BaseDir, St0) ->
    BaseDirBin = ensure_binary(BaseDir),
    PathPattern = <<BaseDirBin/binary, "/?.lua;", BaseDirBin/binary, "/?/init.lua">>,
    {ok, St1} = luerl:set_table_keys([<<"package">>, <<"path">>], PathPattern, St0),
    St1.

install_helpers(St) ->
    RandFn = fun(Args, St0) ->
        case Args of
            [] -> {[rand:uniform()], St0};
            [N | _] when is_number(N), N >= 1 -> {[rand:uniform(trunc(N))], St0};
            _ -> {[rand:uniform()], St0}
        end
    end,
    SqrtFn = fun(Args, St0) ->
        case Args of
            [N | _] when is_number(N) -> {[math:sqrt(N)], St0};
            _ -> {[0.0], St0}
        end
    end,
    {EncRand, St1} = luerl:encode(RandFn, St),
    {ok, St2} = luerl:set_table_keys([<<"math">>, <<"random">>], EncRand, St1),
    {EncSqrt, St3} = luerl:encode(SqrtFn, St2),
    {ok, St4} = luerl:set_table_keys([<<"math">>, <<"sqrt">>], EncSqrt, St3),
    St4.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(A) when is_atom(A) -> atom_to_binary(A);
ensure_binary(L) when is_list(L) -> list_to_binary(L).

to_string(B) when is_binary(B) -> binary_to_list(B);
to_string(L) when is_list(L) -> L.
