-module(asobi_dgram_limits).
-moduledoc """
The datagram plane's rate-limit tiers (ADR 0012, decision 9).

**No tier is keyed on an observed source address, and that is not an oversight.**
Bare-IP keying starves every player behind a carrier-grade NAT, where thousands
of real users share one address. `(IP, port)` keying is worse behind a
masquerade: the address collapses to a single value while the port is
attacker-chosen, so an attacker mints tens of thousands of free keys by varying
a field they control. Every tier below is keyed in a server-issued namespace - a
constant, or `conn_id`.

If a deployment is ever *verified* to preserve the real client address, an
address tier may be added as defence in depth. It may never become load-bearing:
a limiter whose correctness depends on a network topology fails silently when
the topology moves, and nothing about that failure is visible from inside.

## The ordering is the guarantee

    parse guard   no limiter, pure arithmetic on the first bytes
    ingress_global   a constant   total datagrams looked at
    unknown_conn     a constant   conn_id missed the table
    ingress          conn_id      pre-MAC work for a live connection
    input            conn_id      post-MAC input rate
    rebind           conn_id      enforced in asobi_dgram_binding, not here

MAC verification is the only expensive step and is reachable only by a datagram
that passed the guard, fitted the global budget, carried a live `conn_id` and
fitted that connection's own pre-MAC budget. This mirrors `asobi_sup`'s own
doctrine for the HTTP and WebSocket tiers.

`ingress_global` is the primary volumetric defence precisely because a constant
is the one key an attacker cannot rotate.

## Every number here is provisional

ADR 0012 says so of every constant in the design, and these were chosen by
argument rather than measurement: they are anchored to the WebSocket's own 60
frames per second per connection, which is the only comparable figure that has
seen real traffic. An operator running this at scale should measure and override.
""".

-export([register/0, allow_ingress/1, allow_input/1, allow_unknown/0]).
-export([defaults/0, limiter_name/1]).

-doc """
Registers every tier with seki. Called from the gateway supervisor only.

Reads the same `asobi.rate_limits` key the engine's tiers use, so an operator
tunes both planes in one place.
""".
-spec register() -> ignore.
register() ->
    Configured =
        case application:get_env(asobi, rate_limits, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    maps:foreach(
        fun(Group, DefaultOpts) ->
            Overrides =
                case maps:get(Group, Configured, #{}) of
                    O when is_map(O) -> O;
                    _ -> #{}
                end,
            seki:new_limiter(limiter_name(Group), merged(DefaultOpts, Overrides))
        end,
        defaults()
    ),
    ignore.

%% Narrowed key by key rather than handed straight from maps:merge/2, which types
%% as term() over an operator-supplied map. Only the three tuning knobs are
%% overridable; `backend` and friends are seki's own and an operator reaching for
%% them on this plane is more likely a typo than an intent.
-spec merged(map(), map()) -> seki:limiter_opts().
merged(Default, Overrides) ->
    Merged = maps:merge(Default, Overrides),
    #{
        algorithm => algorithm(Merged),
        limit => positive(limit, Merged, 60),
        window => positive(window, Merged, 1000)
    }.

algorithm(#{algorithm := A}) when is_atom(A) -> A;
algorithm(_) -> sliding_window.

positive(Key, Map, Fallback) ->
    case Map of
        #{Key := V} when is_integer(V), V > 0 -> V;
        _ -> Fallback
    end.

-doc "The tier defaults, exported so a test can assert the shape of the table.".
-spec defaults() -> #{atom() => seki:limiter_opts()}.
defaults() ->
    #{
        %% Anchored to the WebSocket's 60 frames per second per connection: at
        %% 500 players that is 30k/s of honest traffic, so 50k leaves headroom
        %% without letting a flood through. The one key an attacker cannot
        %% rotate, which is why it carries the volumetric defence.
        dgram_ingress_global => #{algorithm => sliding_window, limit => 50_000, window => 1000},
        %% Bounds log and telemetry volume rather than CPU: a datagram whose
        %% conn_id misses the table has already been dropped by the time this is
        %% consulted. Without it a spoofed flood turns the log into the outage.
        dgram_unknown_conn => #{algorithm => sliding_window, limit => 100, window => 1000},
        %% Pre-MAC work for one live connection. Double the input cap so pings
        %% and a rebind's hellos fit alongside a client sending input flat out.
        dgram_ingress => #{algorithm => sliding_window, limit => 120, window => 1000},
        %% Post-MAC input rate, matching the WebSocket's own per-connection cap.
        %% A client that can send more input over UDP than over TCP would be a
        %% way to bypass a limit rather than a feature.
        dgram_input => #{algorithm => sliding_window, limit => 60, window => 1000}
    }.

-doc "Pre-MAC budget for one connection. Consulted after the conn_id is known.".
-spec allow_ingress(non_neg_integer()) -> boolean().
allow_ingress(ConnId) -> allow(asobi_dgram_ingress_limiter, key(ConnId)).

-doc "Post-MAC input budget for one connection.".
-spec allow_input(non_neg_integer()) -> boolean().
allow_input(ConnId) -> allow(asobi_dgram_input_limiter, key(ConnId)).

-doc "Budget for datagrams naming a `conn_id` that is not in the table.".
-spec allow_unknown() -> boolean().
allow_unknown() -> allow(asobi_dgram_unknown_conn_limiter, ~"global").

-doc "Maps a tier to its registered limiter name.".
-spec limiter_name(atom()) -> atom().
limiter_name(dgram_ingress_global) -> asobi_dgram_ingress_global_limiter;
limiter_name(dgram_unknown_conn) -> asobi_dgram_unknown_conn_limiter;
limiter_name(dgram_ingress) -> asobi_dgram_ingress_limiter;
limiter_name(dgram_input) -> asobi_dgram_input_limiter.

%% --- Internal ---

%% Fails OPEN when the limiter is not registered, which happens only in the
%% engine role where no datagram can arrive anyway. Failing closed there would
%% turn a misconfiguration into a silent total outage of a plane nobody is using.
allow(Name, Key) ->
    try seki:check(Name, Key) of
        {allow, _} -> true;
        {deny, _} -> false
    catch
        _:_ -> true
    end.

key(ConnId) -> integer_to_binary(ConnId).
