-module(asobi_lua_phases).
-moduledoc """
Shared phase-list decoding for the Lua match and world bridges.

`asobi_lua_match:phases/1` and `asobi_lua_world:phases/1` both decode the
same shape from a Lua script's `phases()` return value - a list of
`{ name = ..., duration = ..., start = ..., config = ... }` tables. This
module holds that decode logic once so neither bridge forks it.
""".

-include_lib("kernel/include/logger.hrl").

-export([decode_phases/2]).
-export([decode_phase_start/1, maybe_add/5, type_of/1, to_integer/1]).

-spec decode_phases(term(), dynamic()) -> [map()].
decode_phases(PhasesRef, LuaSt) ->
    case luerl:decode(PhasesRef, LuaSt) of
        Decoded when is_list(Decoded) ->
            lists:filtermap(
                fun
                    ({_, PhaseProps}) when is_list(PhaseProps) ->
                        Name = proplists:get_value(~"name", PhaseProps),
                        case Name of
                            undefined ->
                                false;
                            _ ->
                                Phase0 = #{name => Name},
                                Phase1 = maybe_add(
                                    Phase0, duration, PhaseProps, ~"duration", fun to_integer/1
                                ),
                                Phase2 = maybe_add(
                                    Phase1, start, PhaseProps, ~"start", fun decode_phase_start/1
                                ),
                                Phase3 = maybe_add(
                                    Phase2,
                                    config,
                                    PhaseProps,
                                    ~"config",
                                    fun asobi_lua_api:deep_decode/1
                                ),
                                {true, Phase3}
                        end;
                    (_) ->
                        false
                end,
                Decoded
            );
        Other ->
            %% Lua phases() returned a non-list — likely a script bug. Logging the
            %% type helps the developer notice it; without this, decode silently
            %% returned [], the caller treated it as "no phases", and the
            %% mismatch only surfaced as runtime weirdness much later.
            ?LOG_WARNING(#{
                msg => ~"asobi_lua_phases: phases() returned non-list, ignoring",
                got_type => type_of(Other)
            }),
            []
    end.

-spec type_of(term()) -> binary().
type_of(V) when is_list(V) -> ~"list";
type_of(V) when is_map(V) -> ~"map";
type_of(V) when is_binary(V) -> ~"binary";
type_of(V) when is_integer(V) -> ~"integer";
type_of(V) when is_float(V) -> ~"float";
type_of(V) when is_atom(V) -> ~"atom";
type_of(V) when is_tuple(V) -> ~"tuple";
type_of(_) -> ~"unknown".

-spec decode_phase_start(term()) ->
    prev_ended | all_ready | {timer, integer()} | {players, integer()}.
decode_phase_start(~"prev_ended") ->
    prev_ended;
decode_phase_start(~"all_ready") ->
    all_ready;
decode_phase_start(V) when is_number(V) -> {timer, trunc(V)};
decode_phase_start(Props) when is_list(Props) ->
    case proplists:get_value(~"players", Props) of
        N when is_number(N) -> {players, trunc(N)};
        _ ->
            case proplists:get_value(~"timer", Props) of
                N when is_number(N) -> {timer, trunc(N)};
                _ -> prev_ended
            end
    end;
decode_phase_start(_) ->
    prev_ended.

-spec maybe_add(map(), atom(), list(), binary(), fun((term()) -> term())) -> map().
maybe_add(Map, Key, Props, LuaKey, DecodeFn) ->
    case proplists:get_value(LuaKey, Props) of
        undefined -> Map;
        nil -> Map;
        Val -> Map#{Key => DecodeFn(Val)}
    end.

-spec to_integer(term()) -> integer().
to_integer(N) when is_number(N) -> trunc(N);
to_integer(_) -> 0.
