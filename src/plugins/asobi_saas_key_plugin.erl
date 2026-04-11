-module(asobi_saas_key_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

-define(HEADER, ~"x-asobi-key").
-define(CACHE_TABLE, asobi_saas_key_cache).
-define(CACHE_TTL_MS, 300_000).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, _Options, State) ->
    case application:get_env(asobi, saas_internal_url) of
        undefined ->
            {ok, Req, State};
        {ok, Url} when is_binary(Url); is_list(Url) ->
            maybe_validate(Req, to_binary(Url), State)
    end.

-spec post_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Asobi SaaS Key Plugin",
        version => ~"0.1.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Validates API keys against the Asobi SaaS control plane."
    }.

%% --- Internal ---

-spec maybe_validate(cowboy_req:req(), binary(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
maybe_validate(Req, SaasUrl, State) ->
    case is_protected(cowboy_req:path(Req)) of
        false ->
            {ok, Req, State};
        true ->
            case cowboy_req:header(?HEADER, Req) of
                undefined ->
                    reject(Req, State, 401, ~"missing_api_key");
                <<>> ->
                    reject(Req, State, 401, ~"missing_api_key");
                RawKey ->
                    validate(Req, SaasUrl, RawKey, State)
            end
    end.

-spec is_protected(binary()) -> boolean().
is_protected(Path) ->
    binary:match(Path, ~"/api/v1/") =/= nomatch.

-spec validate(cowboy_req:req(), binary(), binary(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
validate(Req, SaasUrl, RawKey, State) ->
    case lookup_cache(RawKey) of
        {ok, Ctx} ->
            apply_context(Req, Ctx, State);
        miss ->
            fetch_and_validate(Req, SaasUrl, RawKey, State)
    end.

-spec fetch_and_validate(cowboy_req:req(), binary(), binary(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
fetch_and_validate(Req, SaasUrl, RawKey, State) ->
    case call_saas(SaasUrl, RawKey) of
        {ok, #{~"environment_id" := _} = Body} ->
            case env_matches(Body) of
                true ->
                    Ctx = to_context(Body),
                    store_cache(RawKey, Ctx),
                    apply_context(Req, Ctx, State);
                false ->
                    reject(Req, State, 403, ~"environment_mismatch")
            end;
        {ok, _} ->
            reject(Req, State, 401, ~"invalid_key");
        {error, {Status, _Body}} when Status >= 400, Status < 500 ->
            reject(Req, State, 401, ~"invalid_key");
        {error, _Other} ->
            reject(Req, State, 503, ~"saas_unavailable")
    end.

-spec call_saas(binary(), binary()) ->
    {ok, map()} | {error, term()}.
call_saas(SaasUrl, RawKey) ->
    QS = iolist_to_binary(cow_qs:qs([{~"key", RawKey}])),
    Url = binary_to_list(<<SaasUrl/binary, "/internal/validate?", QS/binary>>),
    Headers = [
        {"accept", "application/json"},
        {"x-asobi-internal-token", internal_token()}
    ],
    case httpc:request(get, {Url, Headers}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
            decode_json(Body);
        {ok, {{_, Status, _}, _, _Body}} when is_integer(Status) ->
            {error, {Status, invalid}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_json(binary()) -> {ok, map()} | {error, term()}.
decode_json(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, invalid_json}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec internal_token() -> string().
internal_token() ->
    case application:get_env(asobi, saas_internal_token) of
        {ok, T} when is_binary(T) -> binary_to_list(T);
        _ -> ""
    end.

-spec env_matches(map()) -> boolean().
env_matches(Body) ->
    case application:get_env(asobi, environment_name) of
        {ok, Expected} when is_binary(Expected) ->
            maps:get(~"env_name", Body, undefined) =:= Expected;
        _ ->
            true
    end.

-spec to_context(map()) -> map().
to_context(Body) ->
    #{
        tenant_id => maps:get(~"tenant_id", Body),
        game_id => maps:get(~"game_id", Body),
        environment_id => maps:get(~"environment_id", Body),
        env_name => maps:get(~"env_name", Body, nil),
        plan => maps:get(~"plan", Body, nil),
        scopes => maps:get(~"scopes", Body, [])
    }.

-spec apply_context(cowboy_req:req(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
apply_context(Req, Ctx, State) ->
    Req1 = Req#{asobi_tenant => Ctx},
    {ok, Req1, State}.

-spec reject(cowboy_req:req(), term(), pos_integer(), binary()) ->
    {break, cowboy_req:req(), term()}.
reject(Req, State, Status, Error) ->
    Body = json:encode(#{~"error" => Error}),
    Req1 = cowboy_req:reply(
        Status,
        #{~"content-type" => ~"application/json"},
        Body,
        Req
    ),
    {break, Req1, State}.

%% --- Cache ---

-spec lookup_cache(binary()) -> {ok, map()} | miss.
lookup_cache(RawKey) ->
    ensure_table(),
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?CACHE_TABLE, RawKey) of
        [{_, Ctx, ExpiresAt}] when ExpiresAt > Now -> {ok, Ctx};
        _ -> miss
    end.

-spec store_cache(binary(), map()) -> ok.
store_cache(RawKey, Ctx) ->
    ensure_table(),
    ExpiresAt = erlang:monotonic_time(millisecond) + ?CACHE_TTL_MS,
    ets:insert(?CACHE_TABLE, {RawKey, Ctx, ExpiresAt}),
    ok.

-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?CACHE_TABLE) of
        undefined ->
            try
                _ = ets:new(?CACHE_TABLE, [
                    named_table, public, set, {read_concurrency, true}
                ]),
                ok
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end.

-spec to_binary(binary() | list()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
