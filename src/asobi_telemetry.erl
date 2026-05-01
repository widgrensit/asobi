-module(asobi_telemetry).
-include_lib("kernel/include/logger.hrl").

-export([setup/0]).
-export([match_started/2, match_finished/3, match_player_joined/2, match_player_left/2]).
-export([world_started/2, world_finished/3, world_player_joined/2, world_player_left/2]).
-export([world_phase_changed/3]).
-export([matchmaker_queued/2, matchmaker_removed/2, matchmaker_formed/3]).
-export([session_connected/1, session_disconnected/2]).
-export([ws_connected/0, ws_disconnected/0, ws_message_in/1, ws_message_out/1]).
-export([anticheat_violation/3]).
-export([economy_transaction/4, store_purchase/3]).
-export([chat_message_sent/2]).
-export([vote_started/2, vote_cast/2, vote_resolved/3]).
-export([handle_event/4]).

-spec setup() -> ok.
setup() ->
    ok = telemetry:attach_many(
        <<"asobi-metrics-logger">>,
        [
            [asobi, match, started],
            [asobi, match, finished],
            [asobi, match, player_joined],
            [asobi, match, player_left],
            [asobi, world, started],
            [asobi, world, finished],
            [asobi, world, player_joined],
            [asobi, world, player_left],
            [asobi, world, phase_changed],
            [asobi, matchmaker, queued],
            [asobi, matchmaker, removed],
            [asobi, matchmaker, formed],
            [asobi, session, connected],
            [asobi, session, disconnected],
            [asobi, ws, connected],
            [asobi, ws, disconnected],
            [asobi, ws, message_in],
            [asobi, ws, message_out],
            [asobi, economy, transaction],
            [asobi, store, purchase],
            [asobi, chat, message_sent],
            [asobi, vote, started],
            [asobi, vote, cast],
            [asobi, vote, resolved]
        ],
        fun ?MODULE:handle_event/4,
        #{}
    ),
    ok.

%% --- Match Events ---

-spec match_started(binary(), binary() | undefined) -> ok.
match_started(MatchId, Mode) ->
    telemetry:execute([asobi, match, started], #{count => 1}, #{
        match_id => MatchId, mode => Mode
    }).

-spec match_finished(binary(), pos_integer(), map()) -> ok.
match_finished(MatchId, DurationMs, Result) ->
    telemetry:execute([asobi, match, finished], #{duration_ms => DurationMs, count => 1}, #{
        match_id => MatchId, result => Result
    }).

-spec match_player_joined(binary(), binary()) -> ok.
match_player_joined(MatchId, PlayerId) ->
    telemetry:execute([asobi, match, player_joined], #{count => 1}, #{
        match_id => MatchId, player_id => PlayerId
    }).

-spec match_player_left(binary(), binary()) -> ok.
match_player_left(MatchId, PlayerId) ->
    telemetry:execute([asobi, match, player_left], #{count => 1}, #{
        match_id => MatchId, player_id => PlayerId
    }).

%% --- World Events ---

-spec world_started(binary(), binary() | undefined) -> ok.
world_started(WorldId, Mode) ->
    telemetry:execute([asobi, world, started], #{count => 1}, #{
        world_id => WorldId, mode => Mode
    }).

-spec world_finished(binary(), pos_integer(), map()) -> ok.
world_finished(WorldId, DurationMs, Result) ->
    telemetry:execute([asobi, world, finished], #{duration_ms => DurationMs, count => 1}, #{
        world_id => WorldId, result => Result
    }).

-spec world_player_joined(binary(), binary()) -> ok.
world_player_joined(WorldId, PlayerId) ->
    telemetry:execute([asobi, world, player_joined], #{count => 1}, #{
        world_id => WorldId, player_id => PlayerId
    }).

-spec world_player_left(binary(), binary()) -> ok.
world_player_left(WorldId, PlayerId) ->
    telemetry:execute([asobi, world, player_left], #{count => 1}, #{
        world_id => WorldId, player_id => PlayerId
    }).

-spec world_phase_changed(binary(), binary(), binary()) -> ok.
world_phase_changed(WorldId, FromPhase, ToPhase) ->
    telemetry:execute([asobi, world, phase_changed], #{count => 1}, #{
        world_id => WorldId, from_phase => FromPhase, to_phase => ToPhase
    }).

%% --- Matchmaker Events ---

-spec matchmaker_queued(binary(), binary() | undefined) -> ok.
matchmaker_queued(PlayerId, Mode) ->
    telemetry:execute([asobi, matchmaker, queued], #{count => 1}, #{
        player_id => PlayerId, mode => Mode
    }).

-spec matchmaker_removed(binary(), atom()) -> ok.
matchmaker_removed(PlayerId, Reason) ->
    telemetry:execute([asobi, matchmaker, removed], #{count => 1}, #{
        player_id => PlayerId, reason => Reason
    }).

-spec matchmaker_formed(binary(), pos_integer(), pos_integer()) -> ok.
matchmaker_formed(Mode, PlayerCount, WaitMs) ->
    telemetry:execute(
        [asobi, matchmaker, formed],
        #{
            player_count => PlayerCount, wait_ms => WaitMs, count => 1
        },
        #{mode => Mode}
    ).

%% --- Session Events ---

-spec session_connected(binary()) -> ok.
session_connected(PlayerId) ->
    telemetry:execute([asobi, session, connected], #{count => 1}, #{
        player_id => PlayerId
    }).

-spec session_disconnected(binary(), pos_integer()) -> ok.
session_disconnected(PlayerId, DurationMs) ->
    telemetry:execute(
        [asobi, session, disconnected],
        #{
            duration_ms => DurationMs, count => 1
        },
        #{player_id => PlayerId}
    ).

%% --- WebSocket Events ---

-spec ws_connected() -> ok.
ws_connected() ->
    telemetry:execute([asobi, ws, connected], #{count => 1}, #{}).

-spec ws_disconnected() -> ok.
ws_disconnected() ->
    telemetry:execute([asobi, ws, disconnected], #{count => 1}, #{}).

-spec anticheat_violation(binary(), atom(), map()) -> ok.
anticheat_violation(PlayerId, Type, Details) ->
    telemetry:execute(
        [asobi, anticheat, violation],
        #{count => 1},
        #{player_id => PlayerId, type => Type, details => Details}
    ).

-spec ws_message_in(binary()) -> ok.
ws_message_in(Type) ->
    telemetry:execute([asobi, ws, message_in], #{count => 1}, #{type => Type}).

-spec ws_message_out(binary()) -> ok.
ws_message_out(Type) ->
    telemetry:execute([asobi, ws, message_out], #{count => 1}, #{type => Type}).

%% --- Economy Events ---

-spec economy_transaction(binary(), binary(), integer(), binary()) -> ok.
economy_transaction(PlayerId, Currency, Amount, Reason) ->
    telemetry:execute([asobi, economy, transaction], #{amount => Amount, count => 1}, #{
        player_id => PlayerId, currency => Currency, reason => Reason
    }).

-spec store_purchase(binary(), binary(), integer()) -> ok.
store_purchase(PlayerId, ItemId, Cost) ->
    telemetry:execute([asobi, store, purchase], #{cost => Cost, count => 1}, #{
        player_id => PlayerId, item_id => ItemId
    }).

%% --- Chat Events ---

-spec chat_message_sent(binary(), binary()) -> ok.
chat_message_sent(ChannelId, SenderId) ->
    telemetry:execute([asobi, chat, message_sent], #{count => 1}, #{
        channel_id => ChannelId, sender_id => SenderId
    }).

%% --- Vote Events ---

-spec vote_started(binary(), binary()) -> ok.
vote_started(VoteId, Method) ->
    telemetry:execute([asobi, vote, started], #{count => 1}, #{
        vote_id => VoteId, method => Method
    }).

-spec vote_cast(binary(), binary()) -> ok.
vote_cast(VoteId, PlayerId) ->
    telemetry:execute([asobi, vote, cast], #{count => 1}, #{
        vote_id => VoteId, player_id => PlayerId
    }).

-spec vote_resolved(binary(), pos_integer(), map()) -> ok.
vote_resolved(VoteId, DurationMs, Result) ->
    telemetry:execute([asobi, vote, resolved], #{duration_ms => DurationMs, count => 1}, #{
        vote_id => VoteId, result => Result
    }).

%% --- Internal ---

-spec handle_event(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> ok.
handle_event(EventName, Measurements, Metadata, _Config) ->
    ?LOG_DEBUG(#{
        msg => ~"telemetry_event",
        event => EventName,
        measurements => Measurements,
        metadata => Metadata
    }),
    ok.
