-module(asobi_rehome_limiter).
-moduledoc """
Backstop on world zone-crossing re-homes (asobi#248): bounds how often a
single player's `world.input` can force a full interest-ring update, on top
of the hysteresis margin in asobi_zone's past_zone_margin/4 (private, which
only filters jitter - an attacker moving with amplitude past the margin
crosses every tick regardless, so this is the actual adversarial control).

Two `seki` limiters, both registered in `asobi_sup`: `asobi_rehome_limiter`
(per player_id) bounds one identity's rate, `asobi_rehome_global_limiter`
(a constant key) bounds the aggregate - every crossing's resubscribe makes a
blocking call into the single asobi_terrain_store shared by a whole world,
so N concurrent attackers each keeping their own per-player budget would
otherwise scale that blocking load linearly with attacker count. The
per-player check runs first, so an already-denied player never spends any
of the global budget.

A throttle is a cost control, not a security control, so any failure to
check either limiter - not registered, seki not started, or a bad `limit`/
`window` override reaching `seki:check/2`'s arithmetic (e.g. `limit => 0`) -
fails open rather than crashing the caller. This is checked from inside a
zone's tick handler, and an uncaught error there crash-loops the zone
(`asobi_zone_sup` is `simple_one_for_one`) and, once restarts exceed its
intensity, the whole world instance (`asobi_world_instance` is
`one_for_all`). See `asobi_script_log_limiter` for the same fail-open
precedent.
""".

-export([allow/1]).

-include_lib("kernel/include/logger.hrl").

-doc "Check whether PlayerId may re-home right now.".
-spec allow(binary()) -> boolean().
allow(PlayerId) ->
    try
        case seki:check(asobi_rehome_limiter, PlayerId) of
            {deny, _} ->
                false;
            {allow, _} ->
                case seki:check(asobi_rehome_global_limiter, ~"global") of
                    {allow, _} -> true;
                    {deny, _} -> false
                end
        end
    catch
        error:Reason:Stacktrace ->
            %% Keyed on a constant, not PlayerId: this is "a limiter itself
            %% is broken", the same failure for every caller, not a per-player
            %% event - one recurring log line covers it, not one per player.
            case asobi_script_log_limiter:allow(?MODULE) of
                {true, Dropped} ->
                    ?LOG_WARNING(#{
                        event => rehome_limiter_unavailable,
                        reason => Reason,
                        stacktrace => Stacktrace,
                        suppressed_since_last => Dropped
                    });
                false ->
                    ok
            end,
            true
    end.
