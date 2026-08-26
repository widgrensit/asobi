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

-export([start_link/0, create/1, create/3, resolve/2, delete/1, csrf/1, ttl_seconds/0]).
-export([consume_token/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-ifdef(TEST).
-export([expire/1, sweep/0]).
-endif.

-define(TABLE, ?MODULE).
%% Minted tokens already spent on a session. Keyed by the token's MAC, valued
%% by its own expiry, so a row costs nothing to reason about: it is needed for
%% exactly as long as the token it refuses could still be presented.
-define(SEEN_TABLE, asobi_console_session_seen).
-define(SECRET_KEY, {?MODULE, secret}).
-define(ID_BYTES, 32).
-define(SECRET_BYTES, 32).
-define(DEFAULT_TTL, 43200).
-define(MIN_TTL, 60).
-define(MAX_TTL, 86400).
-define(SWEEP_MS, 60000).
-define(MAX_LABEL_BYTES, 64).

-type session() :: #{
    id := binary(),
    csrf := binary(),
    label := binary(),
    caps := [asobi_ops_caps:class()],
    expires_at := integer()
}.
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

**Every capability class but `erasure`.** The secret proves all of them, so
this is not about what was proved; it is about the medium the credential
arrived on. A bearer secret in a config file is a script an operator wrote. A
session cookie is a browser, which can be XSS'd or clickjacked into posting
somewhere the operator never meant to - and an erasure is the one ops action
no follow-up call can undo. Same secret, different blast radius, different
default. Set `console_erasure` to `true` to erase from the console anyway.
""".
%% term(), because label/1 normalises every shape a caller can hand it. The
%% controller used to re-implement that check; one normaliser is enough.
-spec create(term()) -> {ok, session()}.
create(Label) ->
    create(Label, console_caps(), erlang:system_time(second) + ttl_seconds()).

-spec console_caps() -> [asobi_ops_caps:class()].
console_caps() ->
    case application:get_env(asobi, console_erasure, false) of
        true -> asobi_ops_caps:class_names();
        _ -> asobi_ops_caps:class_names() -- [erasure]
    end.

-doc """
Open a session carrying `Caps` and expiring no later than `NotAfter`.

A **minted** token proves only the classes it carries and expires in minutes,
so exchanging one for a session must not widen either: the session inherits
the token's capabilities, and its expiry is clamped to the token's. Otherwise
a fifteen-minute credential with two classes would buy a twelve-hour session
with three, which is the whole point of the token undone by the exchange.

Nothing is subtracted here, unlike `create/1`: a minted token carries exactly
the classes the control plane decided to mint, and second-guessing that would
put the decision in two places.
""".
-spec create(term(), [asobi_ops_caps:class()], integer()) -> {ok, session()}.
create(Label, Caps, NotAfter) ->
    %% gen_server:call/2 answers term(). See docs/eqwalizer-idioms.md.
    case gen_server:call(?MODULE, {create, label(Label), Caps, NotAfter}) of
        {ok, #{id := I, csrf := C, label := L, caps := Cs, expires_at := E}} when
            is_binary(I), is_binary(C), is_binary(L), is_list(Cs), is_integer(E)
        ->
            {ok, #{id => I, csrf => C, label => L, caps => caps(Cs), expires_at => E}}
    end.

-doc """
Spend a minted token, so it can open exactly one session.

`verify/1` proving a token authentic says nothing about whether it has already
been used, and until this existed nothing did: exchanging a token at
`/console/session` left it valid for the rest of its fifteen minutes, usable
again there or directly as a bearer header on the ops plane. Anyone who read
it in transit, out of a log, or off a shared machine had a live credential for
as long as the person it was minted for did.

It also closes the login-CSRF half of the same hole. `SameSite` governs which
requests carry a cookie, not which may set one, so any origin could post a
token it held to a victim's browser and land them in a session the attacker
chose. There is no privilege gain - the token is env-scoped and role-derived -
but every audit row the victim then wrote would name the attacker's `sub`, on
the one plane whose rows are the only surviving evidence of an erasure.

`{error, replayed}` is deliberately not distinguishable from a bad token by
the caller's response: both answer 403 the same way, so presenting a spent
token teaches nothing about whether it was ever real.
""".
-spec consume_token(binary(), integer()) -> ok | {error, replayed}.
consume_token(TokenId, NotAfter) ->
    %% Not a pass-through: `gen_server:call/2` is typed `term()`, and this is
    %% the one call in this module whose answer decides whether a credential is
    %% honoured. Narrowing it here means an unexpected reply crashes at the
    %% boundary rather than being read as something it is not.
    case gen_server:call(?MODULE, {consume_token, TokenId, NotAfter}) of
        ok -> ok;
        {error, replayed} -> {error, replayed}
    end.

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
    ok = gen_server:call(?MODULE, {delete, Id});
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
        {ok, Ttl} when is_integer(Ttl) -> clamp(Ttl, ?MIN_TTL, ?MAX_TTL);
        _ -> ?DEFAULT_TTL
    end.

%% erlang:min/2 and max/2 are specced term() -> term() whatever they are handed.
%% See docs/eqwalizer-idioms.md.
-spec clamp(integer(), pos_integer(), pos_integer()) -> pos_integer().
clamp(V, Lo, _Hi) when V < Lo -> Lo;
clamp(V, _Lo, Hi) when V > Hi -> Hi;
clamp(V, _Lo, _Hi) -> V.

-spec init([]) -> {ok, #{}}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    _ = ets:new(?SEEN_TABLE, [named_table, protected, set, {read_concurrency, true}]),
    persistent_term:put(?SECRET_KEY, crypto:strong_rand_bytes(?SECRET_BYTES)),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), #{}) -> {reply, term(), #{}}.
handle_call({create, Label, Caps, NotAfter}, _From, State) ->
    Id = base64:encode(crypto:strong_rand_bytes(?ID_BYTES), #{mode => urlsafe, padding => false}),
    ExpiresAt = min(erlang:system_time(second) + ttl_seconds(), NotAfter),
    true = ets:insert(?TABLE, {Id, ExpiresAt, Label, Caps}),
    {reply,
        {ok, #{
            id => Id,
            csrf => csrf(Id),
            label => Label,
            caps => Caps,
            expires_at => ExpiresAt
        }},
        State};
handle_call({consume_token, TokenId, NotAfter}, _From, State) ->
    %% `insert_new` is the whole mechanism: the first exchange wins and every
    %% later one loses, atomically, without a read-then-write the second
    %% request could interleave with.
    case ets:insert_new(?SEEN_TABLE, {TokenId, NotAfter}) of
        true -> {reply, ok, State};
        false -> {reply, {error, replayed}, State}
    end;
handle_call({delete, Id}, _From, State) ->
    true = ets:delete(?TABLE, Id),
    {reply, ok, State};
handle_call({expire, Id}, _From, State) ->
    %% Test-only, and it goes through the owner because the table is
    %% `protected`. Ageing a row is the only way to exercise expiry and the
    %% sweeper without waiting out a real TTL.
    Aged = [
        {Id, erlang:system_time(second) - 1, Label, Caps}
     || {_, _, Label, Caps} <- ets:lookup(?TABLE, Id)
    ],
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
    Now = erlang:system_time(second),
    Removed = ets:select_delete(?TABLE, [
        {{'_', '$1', '_', '_'}, [{'<', '$1', Now}], [true]}
    ]),
    %% A spent token past its own expiry can no longer be presented, so
    %% remembering it buys nothing. Not logged: this is bookkeeping about
    %% credentials that already died of old age, and a count of it would only
    %% dilute the session sweep line that operators actually read.
    _ = ets:select_delete(?SEEN_TABLE, [{{'_', '$1'}, [{'<', '$1', Now}], [true]}]),
    log_sweep(Removed).

-spec lookup(binary()) -> {ok, session()} | {error, reason()}.
lookup(Id) ->
    try ets:lookup(?TABLE, Id) of
        [{Id, ExpiresAt, Label, Caps}] when
            is_integer(ExpiresAt), is_binary(Label), is_list(Caps)
        ->
            live(Id, ExpiresAt, Label, caps(Caps));
        [] ->
            {error, unknown}
    catch
        %% The table is gone only while the owner is restarting. That is a
        %% logged-out console, not a crashed request.
        error:badarg -> {error, unknown}
    end.

-spec live(binary(), integer(), binary(), [asobi_ops_caps:class()]) ->
    {ok, session()} | {error, reason()}.
live(Id, ExpiresAt, Label, Caps) ->
    case ExpiresAt > erlang:system_time(second) of
        true ->
            {ok, #{
                id => Id,
                csrf => csrf(Id),
                label => Label,
                caps => Caps,
                expires_at => ExpiresAt
            }};
        false ->
            {error, expired}
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

%% ETS content is this module's own, but the read is still a boundary the
%% checker cannot see through. See docs/eqwalizer-idioms.md.
-spec caps([term()]) -> [asobi_ops_caps:class()].
caps(Caps) ->
    [Class || Cap <- Caps, {ok, Class} <- [asobi_ops_caps:class_of(Cap)]].

-spec secret() -> binary().
secret() ->
    %% No default. A session cannot exist without the secret that derives its
    %% CSRF token, and an empty key makes that token publicly computable from
    %% the session id - which is exactly what this module's second layer is
    %% supposed to prevent.
    case persistent_term:get(?SECRET_KEY) of
        Secret when is_binary(Secret) -> Secret
    end.

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
log_sweep(0) ->
    ok;
log_sweep(Removed) ->
    ?LOG_INFO(#{msg => ~"console sessions expired", removed => Removed}),
    ok.

-ifdef(TEST).
-spec expire(binary()) -> ok.
expire(Id) -> ok = gen_server:call(?MODULE, {expire, Id}).

-spec sweep() -> ok.
sweep() -> ok = gen_server:call(?MODULE, sweep).
-endif.
