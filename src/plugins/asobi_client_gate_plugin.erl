-module(asobi_client_gate_plugin).
-behaviour(nova_plugin).

-include_lib("kernel/include/logger.hrl").

-export([pre_request/4, post_request/4, plugin_info/0]).

-ifdef(TEST).
-export([decision/1]).
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

-spec decision(cowboy_req:req()) -> pass | {deny, binary()}.
decision(Req) ->
    case gate_applies(Req) andalso gate_module() of
        false -> pass;
        undefined -> pass;
        Mod -> invoke(Mod, Req)
    end.

-spec invoke(module(), cowboy_req:req()) -> pass | {deny, binary()}.
invoke(Mod, Req) ->
    try Mod:verify(Req) of
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
        Mod when is_atom(Mod), Mod =/= undefined -> Mod;
        _ -> undefined
    end.

-spec gate_applies(cowboy_req:req()) -> boolean().
gate_applies(Req) ->
    case binary:split(cowboy_req:path(Req), ~"/", [global, trim_all]) of
        [~"api", ~"v1", ~"auth", ~"register"] -> true;
        [~"api", ~"v1", ~"auth", ~"oauth"] -> true;
        [~"api", ~"v1", ~"auth", ~"guest"] -> true;
        _ -> false
    end.
