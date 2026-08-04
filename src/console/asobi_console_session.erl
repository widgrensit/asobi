-module(asobi_console_session).
-behaviour(gen_server).
-moduledoc """
Browser sessions for the operator console: an opaque cookie, and a CSRF token
derived from it.

The console does not hold the operator secret, and it does not hold a bearer
token either. It exchanges the secret once for a session, and every later
request carries an `HttpOnly` cookie the page cannot read plus an
`x-csrf-token` header the page holds in memory. The trade this makes is the
one the console design settles on:

| Model | What XSS yields | Persistence |
|---|---|---|
| `HttpOnly` cookie + derived CSRF | acting from the page while it is open | none - the cookie is unreadable |
| bearer in JS memory | the token, exfiltrated anywhere | until it expires |
| bearer in `localStorage` | the same, and it survives reload | worse |

The CSRF token is `HMAC(node_secret, "csrf:" ++ cookie)`, so it is **derived,
not stored**, and it exists only for a cookie that resolves to a live session.
That is what separates it from a plain double-submit token: an attacker who
can set a cookie in the victim's browser still cannot produce a value that
verifies, because producing one needs the node secret.

It travels in a second, script-readable cookie so the page can send it back as
a header after a reload. Holding it only in memory would end the session every
time the operator refreshed, and a cross-origin page cannot read either cookie
anyway - both are `SameSite=Strict`.

The node secret is per boot. Sessions live in an ETS table this process owns,
so a restart takes both the table and the secret with it and every session in
flight ends - which is the correct coupling, not a gap.

Expiry is absolute and `resolve/2` does not extend it. A sliding window would
mean a write from every reading process, and an ops session that never ends
while a tab sits open is the wrong default for a surface that bans players.
""".

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, create/1, resolve/2, delete/1, csrf/1, ttl_seconds/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-ifdef(TEST).
-export([expire/1, sweep/0]).
-endif.

-define(TABLE, ?MODULE).
-define(SECRET_KEY, {?MODULE, secret}).
-define(ID_BYTES, 32).
-define(SECRET_BYTES, 32).
-define(DEFAULT_TTL, 43200).
-define(MIN_TTL, 60).
-define(MAX_TTL, 86400).
-define(SWEEP_MS, 60000).
-define(MAX_LABEL_BYTES, 64).

-type session() :: #{id := binary(), csrf := binary(), label := binary(), expires_at := integer()}.
-type reason() :: unknown | expired | bad_csrf.

-export_type([session/0, reason/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Open a session for an operator who has already proved the secret.

`Label` is the display name the audit trail carries. It is self-asserted -
the credential is a shared secret, so nothing here attests who typed it - and
it is held to the same shape `asobi_ops_auth:display/1` holds the
`x-asobi-operator` header to.
""".
-spec create(binary()) -> {ok, session()}.
create(Label) ->
    gen_server:call(?MODULE, {create, label(Label)}).

-doc """
Resolve a cookie and its CSRF token to a live session.

Both halves are required. A cookie alone is not a credential here: that is
the whole point of the second layer, and it is why a cross-origin form post
carrying the browser's cookie gets 403 rather than a ban.
""".
-spec resolve(binary(), binary()) -> {ok, session()} | {error, reason()}.
resolve(Id, Csrf) when is_binary(Id), is_binary(Csrf) ->
    case lookup(Id) of
        {ok, Session} -> checked(Session, Csrf);
        {error, _} = Error -> Error
    end;
resolve(_Id, _Csrf) ->
    {error, unknown}.

-doc "End a session. Unknown ids are `ok` - logging out twice is not an error.".
-spec delete(binary()) -> ok.
delete(Id) when is_binary(Id) ->
    gen_server:call(?MODULE, {delete, Id});
delete(_Id) ->
    ok.

-doc "The CSRF token for `Id`. Derived, so it is the same on every call.".
-spec csrf(binary()) -> binary().
csrf(Id) ->
    Mac = crypto:mac(hmac, sha256, secret(), <<"csrf:", Id/binary>>),
    base64:encode(Mac, #{mode => urlsafe, padding => false}).

-doc "Session lifetime in seconds. `console_session_ttl`, clamped to 1 minute - 1 day.".
-spec ttl_seconds() -> pos_integer().
ttl_seconds() ->
    case application:get_env(asobi, console_session_ttl) of
        {ok, Ttl} when is_integer(Ttl) -> min(max(Ttl, ?MIN_TTL), ?MAX_TTL);
        _ -> ?DEFAULT_TTL
    end.

-spec init([]) -> {ok, #{}}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    persistent_term:put(?SECRET_KEY, crypto:strong_rand_bytes(?SECRET_BYTES)),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), #{}) -> {reply, term(), #{}}.
handle_call({create, Label}, _From, State) ->
    Id = base64:encode(crypto:strong_rand_bytes(?ID_BYTES), #{mode => urlsafe, padding => false}),
    ExpiresAt = erlang:system_time(second) + ttl_seconds(),
    true = ets:insert(?TABLE, {Id, ExpiresAt, Label}),
    {reply, {ok, #{id => Id, csrf => csrf(Id), label => Label, expires_at => ExpiresAt}}, State};
handle_call({delete, Id}, _From, State) ->
    true = ets:delete(?TABLE, Id),
    {reply, ok, State};
handle_call({expire, Id}, _From, State) ->
    %% Test-only, and it goes through the owner because the table is
    %% `protected`. Ageing a row is the only way to exercise expiry and the
    %% sweeper without waiting out a real TTL.
    Aged = [{Id, erlang:system_time(second) - 1, Label} || {_, _, Label} <- ets:lookup(?TABLE, Id)],
    true = Aged =:= [] orelse ets:insert(?TABLE, Aged),
    {reply, ok, State};
handle_call(sweep, _From, State) ->
    sweep_expired(),
    {reply, ok, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), #{}) -> {noreply, #{}}.
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(term(), #{}) -> {noreply, #{}}.
handle_info(sweep, State) ->
    sweep_expired(),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

%% `resolve/2` already refuses an expired row, so the sweep is about the
%% table's size rather than about correctness. It is separate from the timer
%% so that running it cannot also schedule another one.
-spec sweep_expired() -> ok.
sweep_expired() ->
    Removed = ets:select_delete(?TABLE, [
        {{'_', '$1', '_'}, [{'<', '$1', erlang:system_time(second)}], [true]}
    ]),
    log_sweep(Removed).

-spec lookup(binary()) -> {ok, session()} | {error, reason()}.
lookup(Id) ->
    try ets:lookup(?TABLE, Id) of
        [{Id, ExpiresAt, Label}] -> live(Id, ExpiresAt, Label);
        [] -> {error, unknown}
    catch
        %% The table is gone only while the owner is restarting. That is a
        %% logged-out console, not a crashed request.
        error:badarg -> {error, unknown}
    end.

-spec live(binary(), integer(), binary()) -> {ok, session()} | {error, reason()}.
live(Id, ExpiresAt, Label) ->
    case ExpiresAt > erlang:system_time(second) of
        true -> {ok, #{id => Id, csrf => csrf(Id), label => Label, expires_at => ExpiresAt}};
        false -> {error, expired}
    end.

-spec checked(session(), binary()) -> {ok, session()} | {error, reason()}.
checked(#{csrf := Expected} = Session, Presented) ->
    case constant_equal(Expected, Presented) of
        true -> {ok, Session};
        false -> {error, bad_csrf}
    end.

%% Hash first: crypto:hash_equals/2 raises on operands of different size, so
%% comparing the raw values would both crash and leak a length.
-spec constant_equal(binary(), binary()) -> boolean().
constant_equal(Expected, Presented) ->
    crypto:hash_equals(crypto:hash(sha256, Expected), crypto:hash(sha256, Presented)).

-spec secret() -> binary().
secret() ->
    persistent_term:get(?SECRET_KEY, <<>>).

-spec label(term()) -> binary().
label(Label) when is_binary(Label), Label =/= ~"", byte_size(Label) =< ?MAX_LABEL_BYTES ->
    case printable(Label) of
        true -> Label;
        false -> ~"operator"
    end;
label(_Label) ->
    ~"operator".

-spec printable(binary()) -> boolean().
printable(Label) ->
    lists:all(fun(Char) -> Char >= 32 andalso Char =< 126 end, binary_to_list(Label)).

-spec log_sweep(non_neg_integer()) -> ok.
log_sweep(0) -> ok;
log_sweep(Removed) -> ?LOG_INFO(#{msg => ~"console sessions expired", removed => Removed}).

-ifdef(TEST).
-spec expire(binary()) -> ok.
expire(Id) -> gen_server:call(?MODULE, {expire, Id}).

-spec sweep() -> ok.
sweep() -> gen_server:call(?MODULE, sweep).
-endif.
