-module(asobi_lua_release_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% The prod release config is what gets baked into the published container
%% image. CI only ever boots the dev config, so a prod-only regression (e.g.
%% dropping kura's {backend, ...} key after the kura v2 bump) ships silently
%% and every self-host user crashes on startup with
%% {no_pool_module_configured, asobi_repo}. This pins the invariant: prod's
%% kura repo must declare a backend kura can resolve.

prod_config_declares_kura_backend_test() ->
    Kura = kura_env(consult_config("prod_sys.config.src")),
    ?assert(
        proplists:is_defined(backend, Kura) orelse
            proplists:is_defined(dialect, Kura) orelse
            proplists:is_defined(pool_module, Kura) orelse
            proplists:is_defined(repos, Kura)
    ).

dev_config_declares_kura_backend_test() ->
    Kura = kura_env(consult_config("dev_sys.config.src")),
    ?assert(
        proplists:is_defined(backend, Kura) orelse
            proplists:is_defined(dialect, Kura) orelse
            proplists:is_defined(pool_module, Kura) orelse
            proplists:is_defined(repos, Kura)
    ).

-spec kura_env([{atom(), term()}]) -> [{atom(), term()}].
kura_env(Config) ->
    case [V || {K, V} <- Config, K =:= kura, is_list(V)] of
        [Env | _] -> [{K, V} || {K, V} <- Env, is_atom(K)];
        [] -> error(no_kura_app_in_config)
    end.

-spec consult_config(string()) -> [{atom(), term()}].
consult_config(Name) ->
    {ok, Raw} = file:read_file(locate(Name)),
    Substituted = re:replace(Raw, "\\$\\{[A-Z_]+\\}", "placeholder", [global, {return, binary}]),
    Tmp = filename:join("/tmp", "asobi_lua_relcfg_" ++ Name),
    ok = file:write_file(Tmp, Substituted),
    {ok, [Config]} = file:consult(Tmp),
    ok = file:delete(Tmp),
    %% file:consult/1 answers [term()], so the term has to be narrowed to a
    %% list before it can be walked. See docs/eqwalizer-idioms.md.
    case Config of
        Terms when is_list(Terms) -> [{K, V} || {K, V} <- Terms, is_atom(K)]
    end.

-spec locate(string()) -> file:filename_all().
locate(Name) ->
    Candidates = [
        filename:join(["config", Name]),
        filename:join([filename:dirname(?FILE), "..", "config", Name])
    ],
    case [P || P <- Candidates, filelib:is_regular(P)] of
        [Path | _] -> Path;
        [] -> error({config_not_found, Name})
    end.
