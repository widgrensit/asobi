-module(asobi_reconnect).

%% Reconnection policy for match and world servers.
%%
%% Tracks disconnected players with grace period timers.
%% Pure functional — the owning server calls `tick/2` each tick and
%% `disconnect/3` / `reconnect/2` on player state changes.

-export([new/1]).
-export([disconnect/3, reconnect/2, tick/2]).
-export([is_disconnected/2, disconnected_players/1, info/1]).

-export_type([state/0, reconnect_event/0, policy/0]).

-type policy() :: #{
    grace_period := pos_integer(),
    during_grace := idle | ai_controlled | invulnerable | removed | frozen,
    on_reconnect := resume | respawn | spectate,
    on_expire := remove | forfeit | ai_takeover | kick,
    pause_match := boolean(),
    max_offline_total := pos_integer() | infinity
}.

-type reconnect_event() ::
    {grace_started, binary()}
    | {grace_expired, binary(), atom()}
    | {player_reconnected, binary(), atom()}.

-opaque state() :: #{
    policy := policy(),
    disconnected := #{binary() => disconnect_entry()},
    offline_totals := #{binary() => pos_integer()}
}.

-type disconnect_entry() :: #{
    player_id := binary(),
    disconnected_at := pos_integer(),
    grace_remaining := pos_integer(),
    total_offline := pos_integer()
}.

%% -------------------------------------------------------------------
%% Constructor
%% -------------------------------------------------------------------

-spec new(policy()) -> state().
new(Policy) ->
    #{policy => Policy, disconnected => #{}, offline_totals => #{}}.

%% -------------------------------------------------------------------
%% Player disconnected
%% -------------------------------------------------------------------

-spec disconnect(binary(), pos_integer(), state()) -> {[reconnect_event()], state()}.
disconnect(
    PlayerId,
    Now,
    #{
        policy := Policy,
        disconnected := Disc,
        offline_totals := Totals
    } = State
) ->
    GracePeriod = maps:get(grace_period, Policy),
    PrevTotal = maps:get(PlayerId, Totals, 0),
    Entry = #{
        player_id => PlayerId,
        disconnected_at => Now,
        grace_remaining => GracePeriod,
        total_offline => PrevTotal
    },
    {[{grace_started, PlayerId}], State#{disconnected => Disc#{PlayerId => Entry}}}.

%% -------------------------------------------------------------------
%% Player reconnected
%% -------------------------------------------------------------------

-spec reconnect(binary(), state()) -> {[reconnect_event()], state()}.
reconnect(
    PlayerId,
    #{
        policy := Policy,
        disconnected := Disc,
        offline_totals := Totals
    } = State
) ->
    case maps:get(PlayerId, Disc, undefined) of
        undefined ->
            {[], State};
        #{total_offline := Total} ->
            Action = maps:get(on_reconnect, Policy),
            {[{player_reconnected, PlayerId, Action}], State#{
                disconnected => maps:remove(PlayerId, Disc),
                offline_totals => Totals#{PlayerId => Total}
            }}
    end.

%% -------------------------------------------------------------------
%% Tick — check grace periods
%% -------------------------------------------------------------------

-spec tick(pos_integer(), state()) -> {[reconnect_event()], state()}.
tick(DeltaMs, #{policy := Policy, disconnected := Disc} = State) ->
    OnExpire = maps:get(on_expire, Policy),
    MaxTotal = maps:get(max_offline_total, Policy, infinity),
    {Events, Disc1} = maps:fold(
        fun(PlayerId, #{grace_remaining := Rem, total_offline := Total} = Entry, {Evts, Acc}) ->
            Rem1 = Rem - DeltaMs,
            Total1 = Total + DeltaMs,
            BudgetExceeded = MaxTotal =/= infinity andalso Total1 >= MaxTotal,
            case Rem1 =< 0 orelse BudgetExceeded of
                true ->
                    {[{grace_expired, PlayerId, OnExpire} | Evts], Acc};
                false ->
                    Entry1 = Entry#{grace_remaining => Rem1, total_offline => Total1},
                    {Evts, Acc#{PlayerId => Entry1}}
            end
        end,
        {[], #{}},
        Disc
    ),
    {Events, State#{disconnected => Disc1}}.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec is_disconnected(binary(), state()) -> boolean().
is_disconnected(PlayerId, #{disconnected := Disc}) ->
    maps:is_key(PlayerId, Disc).

-spec disconnected_players(state()) -> [binary()].
disconnected_players(#{disconnected := Disc}) ->
    maps:keys(Disc).

-spec info(state()) -> map().
info(#{policy := Policy, disconnected := Disc}) ->
    #{
        policy => Policy,
        disconnected_count => map_size(Disc),
        disconnected => maps:map(
            fun(_Id, #{grace_remaining := Rem, total_offline := Total}) ->
                #{grace_remaining_ms => max(0, Rem), total_offline_ms => Total}
            end,
            Disc
        )
    }.
