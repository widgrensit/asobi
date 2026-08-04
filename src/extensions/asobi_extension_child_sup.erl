-module(asobi_extension_child_sup).
-moduledoc """
One extension's processes, with their own restart budget.

The budget is the point. `asobi_sup` is `one_for_one` with intensity 10 in 60
over eighteen children including the matchmaker, presence and every match and
world supervisor. Without a per-extension boundary one crash-looping
extension exhausts that shared budget and takes all of it down with no
attribution.

`sup/0` is read here, at `init/1`, rather than cached at resolve time, so a
code upgrade that changes an extension's children takes effect on the next
restart.
""".

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([start_link/2]).
-export([init/1]).

-define(DEFAULT_INTENSITY, 5).
-define(DEFAULT_PERIOD, 60).

-spec start_link(asobi_extension:name(), module()) -> supervisor:startlink_ret().
start_link(Name, Module) ->
    supervisor:start_link(?MODULE, [Name, Module]).

-spec init([asobi_extension:name() | module()]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([Name, Module]) ->
    Specs = asobi_extensions:sup_specs(Module),
    ?LOG_INFO(#{msg => ~"extension_started", extension => Name, children => length(Specs)}),
    {ok, {sup_flags(), Specs}}.

sup_flags() ->
    Configured =
        case application:get_env(asobi, extension_restart, #{}) of
            Map when is_map(Map) -> Map;
            _ -> #{}
        end,
    #{
        strategy => one_for_one,
        intensity => maps:get(intensity, Configured, ?DEFAULT_INTENSITY),
        period => maps:get(period, Configured, ?DEFAULT_PERIOD)
    }.
