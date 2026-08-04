-module(asobi_lua_dev_errors).
-moduledoc """
Dev-mode surfacing of Lua callback errors to the triggering client.

By default a failing callback is log + telemetry only, so script internals
never reach arbitrary players in production. With dev errors enabled the
player whose input triggered the failure also receives a `module.error`
event (and its deprecated `game.error` twin, until the 1.0 wire break)
carrying the callback name, script basename and Lua error message -
without it a broken `handle_input` is indistinguishable client-side from
one that never ran.

Enable via `{asobi_lua, [{dev_errors, true}]}` or `ASOBI_DEV_ERRORS=true`
(also accepts `1`). Any other value means off: unlike hot-reload's
fail-open default, this flag leaks script internals, so it fails closed.
""".

-export([enabled/0, maybe_notify/4]).

%% One notification per window per bridge process - a tick-rate input loop
%% against a broken handler must not become a per-input message stream.
-define(WINDOW_MS, 1000).

-spec enabled() -> boolean().
enabled() ->
    case asobi_lua_env:get_env(dev_errors) of
        {ok, true} -> true;
        {ok, _} -> false;
        undefined -> env_var_enabled(os:getenv("ASOBI_DEV_ERRORS"))
    end.

-doc """
Notify `PlayerId` of a failed `Callback` when dev errors are enabled.

`State` is the bridge state map (carries `script` and the rate-limit
stamp); the possibly-updated map is returned and must be kept by the
caller so the rate limit holds.
""".
-spec maybe_notify(atom(), term(), binary(), map()) -> map().
maybe_notify(Callback, Reason, PlayerId, State) ->
    case enabled() of
        false -> State;
        true -> notify(Callback, Reason, PlayerId, State)
    end.

env_var_enabled("true") -> true;
env_var_enabled("1") -> true;
env_var_enabled(_) -> false.

notify(Callback, Reason, PlayerId, State) ->
    Now = erlang:system_time(millisecond),
    case Now - maps:get(dev_error_at, State, 0) >= ?WINDOW_MS of
        false ->
            State;
        true ->
            Script = asobi_lua_game_error:script_basename(
                maps:get(script, State, ~"<unknown>")
            ),
            asobi_presence:send(
                PlayerId,
                {script_error, #{
                    ~"callback" => atom_to_binary(Callback, utf8),
                    ~"script" => Script,
                    ~"message" => asobi_lua_game_error:format_reason(Reason)
                }}
            ),
            State#{dev_error_at => Now}
    end.
