-module(asobi_client_gate_plugin).
-behaviour(nova_plugin).

-include_lib("kernel/include/logger.hrl").

-export([pre_request/4, post_request/4, plugin_info/0]).

-ifdef(TEST).
-export([decision/1, context/1, token/1]).
-endif.

%% Runs immediately after the rate limiter (config/{dev,prod}_sys.config.src):
%% the limiter is a cheap in-memory token bucket, this gate may do an external
%% siteverify round-trip, so shedding floods with the cheap check first stops a
%% register flood from turning an operator's CAPTCHA vendor into a DoS
%% amplifier. Self-selects the anonymous auth-create paths the same way
%% asobi_rate_limit_plugin:select_limiter/1 does.
-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, _Options, State) ->
    case decision(Req) of
        pass ->
            {ok, Req, State};
        {deny, Reason} ->
            Body = json:encode(#{~"error" => ~"registration_gate_denied", ~"reason" => Reason}),
            Req1 = cowboy_req:reply(
                403, #{~"content-type" => ~"application/json"}, Body, Req
            ),
            {break, Req1, State}
    end.

-spec post_request(cowboy_req:req(), map(), map(), term()) -> {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Client Gate",
        version => ~"1.0.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Pluggable pre-auth traffic gate for anonymous registration (asobi#158)"
    }.

%% --- Internal ---

-define(DEFAULT_TIMEOUT, 5000).

-spec decision(cowboy_req:req()) -> pass | {deny, binary()}.
decision(Req) ->
    case gate_applies(Req) andalso gate_module() of
        false -> pass;
        undefined -> pass;
        Mod -> invoke(Mod, context(Req))
    end.

%% A gate legitimately needs the client IP, headers and a challenge token, but
%% never the plaintext password the request map still carries here. Hand it a
%% minimised context so a third-party gate cannot log or forward credentials.
-spec context(cowboy_req:req()) -> asobi_client_gate:context().
context(Req) ->
    Json = maps:get(json, Req, #{}),
    #{
        ip => asobi_peer:client_ip(Req),
        headers => maps:get(headers, Req, #{}),
        path => cowboy_req:path(Req),
        token => token(Json)
    }.

-spec token(dynamic()) -> binary().
token(Json) when is_map(Json) ->
    case maps:get(~"client_gate_token", Json, ~"") of
        T when is_binary(T) -> T;
        _ -> ~""
    end;
token(_) ->
    ~"".

%% Bound the gate call: a hanging siteverify (vendor slow, TCP blackhole, TLS
%% stall) is the dominant real-world failure and the one an attacker can induce.
%% Without a deadline it pins the request process indefinitely. Run it in a
%% monitored worker and treat a timeout like any other failure - fail closed by
%% default (on_error/0).
-spec invoke(module(), asobi_client_gate:context()) -> pass | {deny, binary()}.
invoke(Mod, Context) ->
    Timeout = gate_timeout(),
    {Pid, MRef} = spawn_monitor(fun() -> exit({gate_result, run(Mod, Context)}) end),
    receive
        {'DOWN', MRef, process, Pid, {gate_result, Result}} ->
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            %% Defensive: run/2 always exits {gate_result, _}, so this fires
            %% only on an external kill. Fail closed anyway.
            ?LOG_ERROR(#{event => client_gate_error, module => Mod, reason => Reason}),
            on_error()
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        ?LOG_ERROR(#{event => client_gate_timeout, module => Mod, timeout_ms => Timeout}),
        on_error()
    end.

-spec gate_timeout() -> non_neg_integer().
gate_timeout() ->
    case application:get_env(asobi, client_gate_timeout, ?DEFAULT_TIMEOUT) of
        T when is_integer(T), T >= 0 -> T;
        _ -> ?DEFAULT_TIMEOUT
    end.

-spec run(module(), asobi_client_gate:context()) -> pass | {deny, binary()}.
run(Mod, Context) ->
    try Mod:verify(Context) of
        skip ->
            pass;
        {deny, Reason} when is_binary(Reason) ->
            {deny, Reason};
        Other ->
            ?LOG_ERROR(#{event => client_gate_bad_return, module => Mod, value => Other}),
            on_error()
    catch
        Class:Err:St ->
            ?LOG_ERROR(#{
                event => client_gate_error,
                module => Mod,
                class => Class,
                reason => Err,
                stacktrace => St
            }),
            on_error()
    end.

%% A gate that is configured but broken (vendor down, siteverify hang, bad
%% return) fails CLOSED by default: a security control that silently fails open
%% is bypassable by knocking over the vendor. Operators can trade strictness
%% for availability with `client_gate_on_error => skip`.
-spec on_error() -> pass | {deny, binary()}.
on_error() ->
    case application:get_env(asobi, client_gate_on_error, deny) of
        skip -> pass;
        _ -> {deny, ~"client_gate_unavailable"}
    end.

-spec gate_module() -> module() | undefined.
gate_module() ->
    case application:get_env(asobi, client_gate, undefined) of
        Mod when is_atom(Mod), Mod =/= undefined, Mod =/= false ->
            case code:ensure_loaded(Mod) of
                {module, Mod} ->
                    Mod;
                _ ->
                    ?LOG_ERROR(#{event => client_gate_unloadable, module => Mod}),
                    undefined
            end;
        _ ->
            undefined
    end.

-spec gate_applies(cowboy_req:req()) -> boolean().
gate_applies(Req) ->
    case binary:split(cowboy_req:path(Req), ~"/", [global, trim_all]) of
        [~"api", ~"v1", ~"auth", ~"register"] -> true;
        [~"api", ~"v1", ~"auth", ~"oauth"] -> true;
        [~"api", ~"v1", ~"auth", ~"guest"] -> true;
        _ -> false
    end.
