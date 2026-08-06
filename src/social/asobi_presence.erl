-module(asobi_presence).
-moduledoc """
Who is reachable, and who counts as online.

Those are two different facts and this module keeps them apart:

- *addressable* - the process is a delivery target for `send/2`, keyed by
  player id. Player sessions and bots are both addressable.
- *online* - a connected human player. Only `track/2` records that, and
  `online_count/0` counts exactly those.

Bots (`asobi_bot`) are addressable but never online. `track_bot/2` joins the
delivery group and nothing else: a bot does not count toward
`online_count/0` and does not emit `player_online` / `player_offline`
presence broadcasts. `online_count/0` is the operator-facing concurrency
number, and bot fill is itself driven by how few humans are queued, so
counting server-spawned bots would both inflate the figure and feed it back
into its own input.

## Message contract

Everything `send/2` delivers arrives at the target process as
`{asobi_message, message()}`. `message/0` is the contract between the core
servers that produce those terms (`asobi_match_server`, `asobi_world_server`,
`asobi_zone`, `asobi_matchmaker`, the Lua runtime) and the processes that
pattern-match them (`asobi_ws_handler`, `asobi_player_session`, `asobi_bot`).

Shared match state is the one shape whose form depends on the recipient:
`send_match_state/3` hands a session the pre-encoded frame and a bot the
same payload as a term. Both are `message/0` shapes; see that function.

It is a public type on purpose. `send/2` is spec'd with it, so a producer
that invents a shape fails dialyzer instead of quietly emitting a term no
consumer handles, and a consumer (`asobi_bot` does this) can spec its own
clauses against the same named type rather than an ad-hoc guess.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([track/2, track_bot/2, untrack/1, untrack_bot/2, update/2, get_status/1, send/2]).
-export([send_match_state/3]).
-export([online_count/0]).
-export([disconnect/2, revoke_session/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PRESENCE_GROUP, asobi_online).
-define(PG_SCOPE, nova_scope).
-define(BOT_GROUP(Id), {bot, Id}).

-type event_name() :: atom() | binary().
-type message() ::
    {match_joined, pid()}
    | {match_state, map()}
    | {match_state_raw, binary()}
    | {match_event, event_name(), map()}
    | {world_joined, pid(), pid() | undefined}
    | {world_zone_changed, pid()}
    | {world_event, event_name(), map()}
    | {zone_delta, non_neg_integer(), [map()]}
    | {zone_delta_raw, binary()}
    | {terrain_chunk, {integer(), integer()}, binary()}
    | {dm_message, map()}
    | {notification, map()}
    | {game_message, term()}
    | {script_error, map()}.

-export_type([event_name/0, message/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Track a connected player session: addressable by `send/2` and counted by
`online_count/0`.
""".
-spec track(binary(), pid()) -> ok.
track(PlayerId, Pid) ->
    nova_pubsub:join(?PRESENCE_GROUP, Pid),
    join_delivery_group(PlayerId, Pid),
    nova_pubsub:broadcast(presence, ~"player_online", #{player_id => PlayerId}),
    ok.

-doc """
Track a bot process: addressable by `send/2`, deliberately not online.

A bot never counts toward `online_count/0` and never emits a presence
broadcast. See the module docs for why.
""".
-spec track_bot(binary(), pid()) -> ok.
track_bot(BotId, Pid) ->
    join_delivery_group(BotId, Pid),
    pg:join(?PG_SCOPE, ?BOT_GROUP(BotId), Pid),
    ok.

-spec untrack(binary()) -> ok.
untrack(PlayerId) ->
    nova_pubsub:broadcast(presence, ~"player_offline", #{player_id => PlayerId}),
    ok.

-spec untrack_bot(binary(), pid()) -> ok.
untrack_bot(BotId, Pid) ->
    pg:leave(?PG_SCOPE, {player, BotId}, Pid),
    pg:leave(?PG_SCOPE, ?BOT_GROUP(BotId), Pid),
    ok.

-spec join_delivery_group(binary(), pid()) -> ok.
join_delivery_group(Id, Pid) ->
    pg:join(?PG_SCOPE, {player, Id}, Pid).

-spec update(binary(), map()) -> ok.
update(PlayerId, Status) ->
    nova_pubsub:broadcast(presence, ~"player_status", #{player_id => PlayerId, status => Status}),
    ok.

-spec get_status(binary()) -> online | offline.
get_status(PlayerId) ->
    case pg:get_members(?PG_SCOPE, {player, PlayerId}) of
        [] -> offline;
        _ -> online
    end.

-spec send(binary(), message()) -> ok.
send(PlayerId, Message) ->
    Members = pg:get_members(?PG_SCOPE, {player, PlayerId}),
    lists:foreach(fun(Pid) when is_pid(Pid) -> Pid ! {asobi_message, Message} end, Members),
    ok.

-doc """
Deliver one tick of shared match state to a roster entry.

Sessions get `PreEncoded`, the wire frame the caller encoded once for the
whole match (ADR 0001). Bots get `SharedState`, the same payload as a term,
because a bot reads the state in Erlang and has no use for a JSON binary:
routing it here keeps the one encode per tick and costs a bot no decode.
""".
-spec send_match_state(binary(), map(), binary()) -> ok.
send_match_state(PlayerId, SharedState, PreEncoded) ->
    Bots = pg:get_members(?PG_SCOPE, ?BOT_GROUP(PlayerId)),
    lists:foreach(
        fun(Pid) when is_pid(Pid) ->
            Message =
                case lists:member(Pid, Bots) of
                    true -> {match_state, SharedState};
                    false -> {match_state_raw, PreEncoded}
                end,
            Pid ! {asobi_message, Message}
        end,
        pg:get_members(?PG_SCOPE, {player, PlayerId})
    ),
    ok.

-spec revoke_session(binary(), binary()) -> ok.
revoke_session(PlayerId, Reason) ->
    _ = asobi_broadcast_worker:enqueue(~"session_revoked", #{
        player_id => PlayerId,
        reason => Reason
    }),
    ok.

-spec disconnect(binary(), binary()) -> ok.
disconnect(PlayerId, Reason) ->
    Members = pg:get_members(?PG_SCOPE, {player, PlayerId}),
    lists:foreach(fun(Pid) when is_pid(Pid) -> Pid ! {session_revoked, Reason} end, Members),
    ok.

-spec online_count() -> non_neg_integer().
online_count() ->
    length(nova_pubsub:get_members(?PRESENCE_GROUP)).

-spec init([]) -> {ok, #{}}.
init([]) ->
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.
