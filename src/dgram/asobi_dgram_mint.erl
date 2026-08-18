-module(asobi_dgram_mint).
-moduledoc """
Issues datagram credentials, and remembers who holds them.

The engine's half of ADR 0012's decision 5. A credential is a **registered
binding**, not a token: the engine generates it, hands it to the gateway, waits
for the acknowledgement, and only then tells the player. Registration is what
buys instant revocation when a session dies, which a signed token structurally
cannot do however short its expiry.

## Why the engine keeps its own record

The binding table lives in the gateway, which is the untrusted end. When a
verified input comes back the engine has to answer "which player is this?"
without asking the gateway, or the gateway could name anyone. So the mint is
recorded here too, keyed by `conn_id`, and `player_of/1` reads only this.

## `KUp` leaves exactly once

It travels inside TLS, in the `rpc.ok` the player receives, and never touches the
datagram plane. Every uplink datagram including the first `hello` is
authenticated under it, which is why the datagram protocol contains no key
exchange at all.

`conn_id` is NOT a secret and never should be described as one: it is cleartext
in every datagram, visible to any on-path observer, and it will end up in logs and
metric labels.
""".

-behaviour(gen_server).

-export([start_link/0, open/2, close/1, player_of/1, conn_of/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% How long a mint is good for if the client never opens the plane. Long enough
%% for a slow client to finish probing, short enough that a client that mints and
%% walks away does not hold a gateway table slot all session.
-define(TTL_MS, 60_000).

%% A read-only mirror of player_id -> conn_id, for the one caller that cannot
%% afford a gen_server call: a zone resolving its subscribers on every broadcast
%% tick. This is the escape hatch asobi_dgram_table's own doc names - a mirror of
%% a lookup, written only by the owner, never a move of the state machine into
%% ETS.
-define(MIRROR, asobi_dgram_conns).

-type mint() :: #{
    conn_id := non_neg_integer(),
    player_id := binary(),
    session_pid := pid(),
    epoch := 0..65535,
    expires_at := integer()
}.

-type request() ::
    {open, binary(), pid()}
    | {player_of, non_neg_integer()}.

-type state() :: #{by_conn := #{non_neg_integer() => mint()}, epoch := 0..65535}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Mints a credential for one session, registering it with the gateway first.

Returns `{error, no_gateway}` when the plane is unavailable, which the caller
turns into "no datagram plane for this session" rather than into a failure: the
WebSocket carries everything regardless, so an absent gateway is a degraded plane
and not a broken session.
""".
-spec open(binary(), pid()) -> {ok, map()} | {error, term()}.
open(PlayerId, SessionPid) ->
    case gen_server:call(?MODULE, {open, PlayerId, SessionPid}, 5000) of
        {ok, Credential} when is_map(Credential) -> {ok, Credential};
        {error, Reason} -> {error, Reason}
    end.

-doc "Revokes a credential. Called when a session ends.".
-spec close(non_neg_integer()) -> ok.
close(ConnId) -> gen_server:cast(?MODULE, {close, ConnId}).

-doc """
This player's `conn_id`, or `error`.

Reads the mirror directly, with no message to this process at all: a zone calls
it once per subscriber per broadcast tick, and a gen_server call there would put
one process in the path of every zone's tick.
""".
-spec conn_of(binary()) -> {ok, non_neg_integer()} | error.
conn_of(PlayerId) ->
    try ets:lookup(?MIRROR, PlayerId) of
        [{_, ConnId}] when is_integer(ConnId) -> {ok, ConnId};
        _ -> error
    catch
        %% No mirror: the plane is not configured on this node.
        error:badarg -> error
    end.

-doc "Who holds this `conn_id`, for the uplink. Reads the engine's own record.".
-spec player_of(non_neg_integer()) -> {ok, mint()} | error.
player_of(ConnId) ->
    case gen_server:call(?MODULE, {player_of, ConnId}, 1000) of
        {ok, #{
            conn_id := C,
            player_id := P,
            session_pid := S,
            epoch := E,
            expires_at := X
        }} when
            is_integer(C), is_binary(P), is_pid(S), is_integer(E), is_integer(X)
        ->
            {ok, #{
                conn_id => C, player_id => P, session_pid => S, epoch => E, expires_at => X
            }};
        _ ->
            error
    end.

%% --- gen_server ---

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?MIRROR, [named_table, protected, {read_concurrency, true}]),
    _ = erlang:send_after(?TTL_MS, self(), sweep),
    %% The epoch changes every time this process starts, so a client holding a
    %% credential from before a restart is told to re-mint rather than being
    %% quietly served against a table that no longer knows it.
    {ok, #{by_conn => #{}, epoch => rand_epoch()}}.

-spec handle_call(request(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({open, PlayerId, SessionPid}, _From, #{by_conn := ByConn, epoch := Epoch} = State) ->
    ConnId = binary:decode_unsigned(crypto:strong_rand_bytes(4)),
    KUp = crypto:strong_rand_bytes(32),
    ExpiresAt = erlang:system_time(millisecond) + ?TTL_MS,
    Binding = #{
        conn_id => ConnId,
        kup => KUp,
        player_id => PlayerId,
        epoch => Epoch,
        expires_at => ExpiresAt
    },
    %% The gateway gets it BEFORE the player does. A client told it may open the
    %% plane before the gateway would recognise it spends its whole probing
    %% budget being ignored, and then reports a broken plane that works.
    case asobi_dgram_link_client:register(Binding) of
        ok ->
            Mint = #{
                conn_id => ConnId,
                player_id => PlayerId,
                session_pid => SessionPid,
                epoch => Epoch,
                expires_at => ExpiresAt
            },
            Reply = maps:merge(
                #{
                    conn_id => ConnId,
                    kup => base64:encode(KUp),
                    epoch => Epoch,
                    endpoint => endpoint(),
                    expires_in => ?TTL_MS div 1000
                },
                pose_manifest()
            ),
            true = ets:insert(?MIRROR, {PlayerId, ConnId}),
            {reply, {ok, Reply}, State#{by_conn => ByConn#{ConnId => Mint}}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({player_of, ConnId}, _From, #{by_conn := ByConn} = State) ->
    Reply =
        case ByConn of
            #{
                ConnId := #{
                    conn_id := C, player_id := P, session_pid := S, epoch := E, expires_at := X
                }
            } ->
                {ok, #{
                    conn_id => C, player_id => P, session_pid => S, epoch => E, expires_at => X
                }};
            _ ->
                error
        end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast({close, non_neg_integer()}, state()) -> {noreply, state()}.
handle_cast({close, ConnId}, #{by_conn := ByConn} = State) when is_integer(ConnId) ->
    ok = asobi_dgram_link_client:unregister(ConnId),
    _ = forget(ConnId, ByConn),
    {noreply, State#{by_conn => maps:remove(ConnId, ByConn)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(sweep, #{by_conn := ByConn} = State) ->
    _ = erlang:send_after(?TTL_MS, self(), sweep),
    Now = erlang:system_time(millisecond),
    Live = #{C => M || C := #{expires_at := E} = M <- ByConn, E > Now},
    %% The mirror is swept with the map it mirrors, in the same pass, so it can
    %% never outlive the record it was derived from.
    _ = [forget(C, ByConn) || C := _ <- maps:without(maps:keys(Live), ByConn)],
    {noreply, State#{by_conn => Live}};
handle_info(_Info, State) ->
    {noreply, State}.

%% --- Internal ---

%% The transform field list and its scales, delivered once here rather than on
%% every datagram. That is what lets a pose record be a fixed layout with no field
%% names in it at all, and it is why the decoder on the client is a byte loop
%% rather than a parser.
pose_manifest() ->
    case asobi_dgram_pose:manifest() of
        disabled ->
            #{fields => [], period_ticks => 0};
        {ok, #{fields := Fields, period_ticks := Period}} ->
            #{
                fields => [#{name => N, scale => S} || #{name := N, scale := S} <- Fields],
                period_ticks => Period
            }
    end.

%% What the client is told to send to. In the mint response rather than resolved
%% by the client, which is what makes the plane independent of DNS and of SNI and
%% why a non-standard port costs the client nothing.
endpoint() ->
    case application:get_env(asobi, dgram_endpoint) of
        {ok, E} when is_binary(E) -> E;
        _ -> ~""
    end.

%% Deletes by player rather than by conn_id, and only when the mirror still points
%% at THIS conn_id: a player who re-minted already overwrote the entry, and
%% deleting it then would blank a live credential.
forget(ConnId, ByConn) ->
    case ByConn of
        #{ConnId := #{player_id := PlayerId}} ->
            case ets:lookup(?MIRROR, PlayerId) of
                [{_, ConnId}] -> ets:delete(?MIRROR, PlayerId);
                _ -> true
            end;
        _ ->
            true
    end.

rand_epoch() -> binary:decode_unsigned(crypto:strong_rand_bytes(2)).
