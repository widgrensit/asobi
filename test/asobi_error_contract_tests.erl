-module(asobi_error_contract_tests).

%% The regression guard for the shared error object (asobi#338 / plan 1b).
%%
%% Converting every controller is a one-off; keeping them converted is not. A
%% new route that answers `{status, 404}` or `#{error => ~"nope"}` is a silent
%% return to the old dialects, and no per-route test would catch it because
%% the route itself would be new. So this reads the compiled abstract code of
%% every module in the application and rejects the shapes:
%%
%%   flat_error_body   an error response whose body is a map with an `error`
%%                     key that is not an `asobi_error` object.
%%   status_only       a returned `{status, N}`, N >= 400: a status with no
%%                     body, so a client has nothing to branch on.
%%   bypasses_asobi_error
%%                     a module that writes an error response and never builds
%%                     an error object at all. Catches the body that reaches
%%                     the response through a variable.
%%   undefined_code / code_is_not_a_literal
%%                     a code outside the closed set, or one computed at run
%%                     time. The second is what enforces "a client- or
%%                     script-supplied string never becomes a code": passing a
%%                     reason where a code belongs does not get past here.
%%
%% An error response is `{json, Status, _, Body}` or `{false, Status, _, Body}`
%% (the Nova security-callback shape) or `{json, Body, Status}` in return
%% position, or any `cowboy_req:reply/4` - the plugins answer without returning
%% to Nova. Return position means the last expression of a clause or block
%% body, which is how a controller states its response; a `{status, 401}` in a
%% config map (asobi_oidc_config) is not a response and is not flagged.

-include_lib("eunit/include/eunit.hrl").

-define(ERROR_BUILDERS, [object, legacy, legacy_body]).

%% --- The contract ---

every_error_response_uses_the_shared_object_test() ->
    Violations = lists:append([violations(M, forms(M)) || M <- app_modules()]),
    ?assertEqual([], Violations).

%% A scanner that silently read nothing would pass the test above forever.
%% Pin that it really reaches the converted call sites.
the_scan_reaches_real_code_test() ->
    Modules = app_modules(),
    ?assert(length(Modules) > 50),
    Producers = [M || M <- Modules, lists:any(fun produces_error/1, expr_nodes(forms(M)))],
    ?assert(length(Producers) >= 15).

%% Every module the router can dispatch to must be one the scan covers. The
%% route table is the source of truth, so a controller that lives outside
%% `src/controllers/` - as `asobi_player_controller` and `asobi_vote_controller`
%% already do - cannot escape by sitting somewhere unexpected.
every_routed_module_is_scanned_test() ->
    Routed = routed_modules(),
    ?assert(length(Routed) >= 15),
    ?assertEqual([], Routed -- app_modules()).

%% --- The scanner itself ---

%% The deliverable is that this fails on a regression, so prove that it does.
%% Each snippet is a shape that was somewhere in the tree before this change.
scanner_rejects_the_old_dialects_test_() ->
    [
        ?_assert(
            flags(
                flat_error_body,
                ~"f(X) -> case X of a -> {json, 404, #{}, #{error => <<\"nope\">>}} end."
            )
        ),
        ?_assert(flags(flat_error_body, ~"f(R) -> {json, 403, #{}, #{error => R}}.")),
        ?_assert(flags(flat_error_body, ~"f() -> {json, #{error => <<\"nope\">>}, 400}.")),
        ?_assert(
            flags(
                flat_error_body,
                ~"f(R) -> cowboy_req:reply(429, #{}, json:encode(#{error => <<\"x\">>}), R)."
            )
        ),
        ?_assert(flags(status_only, ~"f(X) -> case X of a -> {status, 403} end.")),
        ?_assert(flags(bypasses_asobi_error, ~"f(B, R) -> cowboy_req:reply(500, #{}, B, R).")),
        ?_assert(flags(undefined_code, ~"f() -> {asobi_error, <<\"storage.not_fund\">>}.")),
        ?_assert(flags(code_is_not_a_literal, ~"f(Reason) -> {asobi_error, Reason}.")),
        ?_assert(flags(code_is_not_a_literal, ~"f(Reason) -> asobi_error:object(Reason, #{}).")),
        %% The status override form keeps the code in the third position.
        ?_assert(flags(undefined_code, ~"f() -> {asobi_error, 418, <<\"nope\">>, #{}}."))
    ].

%% ...and passes on the shapes the tree uses now, or it is just noise that the
%% next author deletes.
scanner_accepts_the_shared_object_test_() ->
    [
        ?_assertEqual([], check(~"f() -> {asobi_error, <<\"storage.not_found\">>}.")),
        ?_assertEqual(
            [], check(~"f(V) -> {asobi_error, <<\"save.version_conflict\">>, #{v => V}}.")
        ),
        ?_assertEqual([], check(~"f() -> {asobi_error, 418, <<\"internal\">>, #{}}.")),
        ?_assertEqual(
            [], check(~"f(F) -> asobi_error:legacy(<<\"validation_failed\">>, #{fields => F}).")
        ),
        ?_assertEqual(
            [],
            check(
                ~"f(R) -> B = json:encode(asobi_error:object(<<\"rate_limited\">>)), cowboy_req:reply(429, #{}, B, R)."
            )
        ),
        %% A status below 400 is not an error response.
        ?_assertEqual([], check(~"f() -> {status, 204}.")),
        %% A `{status, N}` that is not a return value is not a response at all
        %% - asobi_oidc_config's `on_failure` is a setting for a dependency.
        ?_assertEqual([], check(~"f() -> C = #{on_failure => {status, 401}}, C."))
    ].

%% --- Scanning ---

violations(Module, Forms) ->
    Nodes = expr_nodes(Forms),
    Responses = error_responses(Nodes),
    [{Module, V} || V <- body_violations(Responses) ++ code_violations(Module, Nodes)] ++
        bypass_violations(Module, Responses, Nodes).

%% `{Status, BodyExpr}` for every error response the module writes.
error_responses(Nodes) ->
    Returned = [response(E) || E <- returns(Nodes)],
    Replied = [reply(N) || N <- Nodes],
    [R || {ok, R} <- Returned ++ Replied].

response({tuple, _, [{atom, _, status}, Status]}) ->
    with_status(Status, status_only);
response({tuple, _, [{atom, _, Tag}, Status, _Headers, Body]}) when Tag =:= json; Tag =:= false ->
    with_status(Status, Body);
response({tuple, _, [{atom, _, json}, Body, Status]}) ->
    with_status(Status, Body);
response(_Other) ->
    none.

reply({call, _, {remote, _, {atom, _, cowboy_req}, {atom, _, reply}}, [Status, _H, Body, _Req]}) ->
    with_status(Status, Body);
reply(_Other) ->
    none.

with_status(Status, Body) ->
    case literal(Status) of
        {ok, N} when is_integer(N), N >= 400 -> {ok, {N, Body}};
        _ -> none
    end.

body_violations(Responses) ->
    lists:append([body_violation(R) || R <- Responses]).

body_violation({Status, status_only}) ->
    [{status_only, Status}];
body_violation({Status, Body}) ->
    case lists:filter(fun is_flat_error_map/1, expr_nodes(Body)) of
        [] -> [];
        [_ | _] -> [{flat_error_body, Status}]
    end.

%% `#{error => Something}` where Something is not an error object: the
%% pre-#338 dialect, whether the value is a literal or a runtime reason.
is_flat_error_map({map, _, Assocs}) ->
    lists:any(fun is_flat_error_assoc/1, Assocs);
is_flat_error_map(_Other) ->
    false.

is_flat_error_assoc({Assoc, _, Key, Value}) when
    Assoc =:= map_field_assoc; Assoc =:= map_field_exact
->
    (literal(Key) =:= {ok, error} orelse literal(Key) =:= {ok, ~"error"}) andalso
        not builds_error(Value);
is_flat_error_assoc(_Other) ->
    false.

%% A module that writes an error response must build the object somewhere,
%% even when the body reaches the response through a variable.
bypass_violations(Module, [], _Nodes) ->
    _ = Module,
    [];
bypass_violations(Module, [_ | _], Nodes) ->
    case lists:any(fun builds_error/1, Nodes) of
        true -> [];
        false -> [{Module, bypasses_asobi_error}]
    end.

builds_error({call, _, {remote, _, {atom, _, asobi_error}, {atom, _, F}}, _Args}) ->
    lists:member(F, ?ERROR_BUILDERS);
builds_error(_Other) ->
    false.

%% Most call sites state the failure as a `{asobi_error, Code}` result for the
%% Nova return handler rather than building the object themselves.
produces_error({tuple, _, [{atom, _, asobi_error} | _]}) -> true;
produces_error(Node) -> builds_error(Node).

%% Every code reaching the wire must be a binary literal from the closed set:
%% a computed one could carry a reason a client or a Lua script supplied.
%% `asobi_error` itself is the definition site, not a call site: it builds the
%% `{asobi_error, Code, ...}` result on its way to `handle/3` with `Code` still
%% a variable, and its own MFA tuples begin with the module's name. Its
%% behaviour is pinned by asobi_error_tests instead.
code_violations(asobi_error, _Nodes) ->
    [];
%% The other definition site. `asobi_rpc` maps an extension handler's *returned*
%% code onto an object, so it is a runtime term and the literal check cannot
%% apply. Its runtime equivalent does: it emits only a code
%% `asobi_error:defined/1` accepts - the same closed set, core's plus every
%% installed manifest's - and anything else becomes `internal`. Pinned by
%% `asobi_rpc_tests:an_undeclared_code_does_not_reach_the_client/0`.
code_violations(asobi_rpc, _Nodes) ->
    [];
code_violations(_Module, Nodes) ->
    Codes = asobi_error:codes(),
    [V || Node <- Nodes, {violation, V} <- [code_violation(Node, Codes)]].

code_violation({call, _, {remote, _, {atom, _, asobi_error}, {atom, _, F}}, [Code | _]}, Codes) ->
    case lists:member(F, ?ERROR_BUILDERS) of
        true -> known_code(Code, Codes);
        false -> ok
    end;
code_violation({tuple, _, [{atom, _, asobi_error} | Rest]}, Codes) when Rest =/= [] ->
    %% `{asobi_error, Code}`, `{asobi_error, Code, Details}` and
    %% `{asobi_error, Status, Code, Details}`: the code is the first element
    %% past the optional status override.
    case lists:dropwhile(fun is_status_override/1, Rest) of
        [Code | _] -> known_code(Code, Codes);
        [] -> {violation, {code_is_not_a_literal, 0}}
    end;
code_violation(_Node, _Codes) ->
    ok.

is_status_override(Node) ->
    case literal(Node) of
        {ok, N} -> is_integer(N);
        error -> false
    end.

known_code(Node, Codes) ->
    case literal(Node) of
        {ok, Code} when is_binary(Code) ->
            case lists:member(Code, Codes) of
                true -> ok;
                false -> {violation, {undefined_code, Code}}
            end;
        _ ->
            {violation, {code_is_not_a_literal, erl_anno:line(element(2, Node))}}
    end.

%% --- Walking ---

%% The last expression of every clause and block body: what the function, or
%% the case arm, actually answers with.
returns(Nodes) ->
    [lists:last(Body) || Node <- Nodes, Body <- body_of(Node), Body =/= []].

body_of({clause, _, _, _, Body}) -> [Body];
body_of({block, _, Body}) -> [Body];
body_of(_Other) -> [].

%% Every node except a clause's patterns. `asobi_error:handle/3` matches on
%% `{asobi_error, Code}` with `Code` unbound - consuming the shape, not minting
%% a code - and a pattern must not be read as a call site.
expr_nodes({clause, _, _Patterns, _Guards, Body} = Node) -> [Node | expr_nodes(Body)];
expr_nodes(Node) when is_tuple(Node) -> [Node | expr_nodes(tuple_to_list(Node))];
expr_nodes(List) when is_list(List) -> lists:append([expr_nodes(E) || E <- List]);
expr_nodes(_Other) -> [].

literal(Node) ->
    try
        {ok, erl_parse:normalise(Node)}
    catch
        _:_ -> error
    end.

%% --- Fixtures ---

app_modules() ->
    _ = application:load(asobi),
    {ok, Modules} = application:get_key(asobi, modules),
    Modules.

%% `code:get_object_code/1` rather than `code:which/1`: under cover the latter
%% answers `cover_compiled` and the scan would read nothing.
forms(Module) ->
    {Module, Beam, _Path} = code:get_object_code(Module),
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    Forms.

routed_modules() ->
    lists:usort([
        M
     || Group <- asobi_router:routes(test), M <- group_modules(Group), M =/= undefined
    ]).

group_modules(#{routes := Routes} = Group) ->
    [handler_module(maps:get(security, Group, false)) | [handler_module(H) || {_, H, _} <- Routes]].

handler_module(Handler) when is_function(Handler) ->
    {module, Module} = erlang:fun_info(Handler, module),
    Module;
handler_module(Handler) when is_atom(Handler), Handler =/= false -> Handler;
handler_module(_Other) ->
    undefined.

%% Parse a snippet as one function and run the same scanner over it.
check(Source) ->
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Source)),
    {ok, Form} = erl_parse:parse_form(Tokens),
    violations(snippet, [Form]).

flags(Kind, Source) ->
    lists:any(
        fun
            ({_Module, {K, _}}) -> K =:= Kind;
            ({_Module, K}) -> K =:= Kind
        end,
        check(Source)
    ).
