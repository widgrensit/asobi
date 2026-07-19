-module(asobi_match).
-moduledoc """
The behaviour a game developer implements to define server-authoritative
game logic. Each game mode is a module that implements this behaviour;
Asobi runs one process per match and invokes these callbacks at the right
moments in the match lifecycle.

The Lua runtime (`asobi_lua`) implements this behaviour on your behalf, so
a Lua `match.lua` and an Erlang `asobi_match` module are the same contract
on two surfaces. Most games are written in Lua; implement this behaviour
directly when you want behaviour-level control or are embedding Asobi in an
existing OTP application.

## Example

```erlang
-module(my_card_game).
-behaviour(asobi_match).
-export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).

init(Config)            -> {ok, #{deck => shuffle(Config), players => #{}}}.
join(PlayerId, State)   -> {ok, State#{players => add(PlayerId, State)}}.
leave(_PlayerId, State) -> {ok, State}.
handle_input(_P, _I, S) -> {ok, S}.
tick(State)             -> {ok, State}.
get_state(_PlayerId, S) -> S.
```

Required: `c:init/1`, `c:join/2`, `c:leave/2`, `c:handle_input/3`, and
exactly one of `c:get_state/2` or `c:get_state/1`. Every other callback is
optional (see `optional_callbacks`).
""".

-doc """
Called once when the match is created, with the mode config it was started
with. Returns the initial game state, which is threaded through every other
callback.
""".
-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-doc """
A player is joining. Accept and attach them, returning the new state, or
reject with `{error, Reason}` (for example when the match is already full or
in progress).
""".
-callback join(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-doc """
Optional. Same as `join/2`, but also receives the join context the client
supplied — a flat map of binaries, bounded by the server, that asobi does
not interpret.

Implement this to gate entry on something the client presents: a join
code, an invite token, a party id, a password. Without it there is no
channel from a client to your game before membership exists, so `join/2`
can implement an allowlist but never a code.

Export `join/3` and it is used instead of `join/2`. asobi never reads the
context; validate it against your own `GameState` and return
`{error, Reason}` to refuse. The context is `#{}` when there is no client
— matchmaker-spawned matches join players with no request behind them.
""".
-callback join(PlayerId :: binary(), Ctx :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-doc "A player disconnected or was removed. Cannot fail. Use it to release reservations, stop timers, or forfeit.".
-callback leave(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc """
A player action arrived over the WebSocket. Validate and apply it. Inputs
are serialised onto the match process, so state can be mutated here without
races.
""".
-callback handle_input(PlayerId :: binary(), Input :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-doc """
Called on a fixed interval (default 10 Hz, configurable per mode). Advance
time, run AI, and check win conditions. Return `{finished, Result, State}`
to end the match. Optional: omit it if your game has no fixed time step.
""".
-callback tick(GameState :: term()) ->
    {ok, GameState1 :: term()}
    | {finished, Result :: map(), GameState1 :: term()}.

-doc """
Project the full match state into what this player should see. Hide opponent
hands, out-of-sight positions, and hidden rolls here.
""".
-callback get_state(PlayerId :: binary(), GameState :: term()) ->
    StateForPlayer :: map().

-doc """
Shared-payload variant of `c:get_state/2`. Avoids the per-player encode cost
when every player sees the same world. Mutually exclusive with
`c:get_state/2` - export exactly one.
""".
-callback get_state(GameState :: term()) ->
    SharedState :: map().

-doc "Optional. Return a vote configuration to open an in-match vote, or `none`.".
-callback vote_requested(GameState :: term()) ->
    {ok, VoteConfig :: map()} | none.

-doc "Optional. React to a resolved vote; `Result` carries the winning option.".
-callback vote_resolved(Template :: binary(), Result :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Optional. Declare named, timed phases (lobby, active, results). Supported for Erlang match games and Lua world games.".
-callback phases(Config :: map()) -> [asobi_phase:phase_def()].

-doc "Optional. Hook invoked when a declared phase begins.".
-callback on_phase_started(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Optional. Hook invoked when a declared phase ends.".
-callback on_phase_ended(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-optional_callbacks([
    join/3,
    tick/1,
    get_state/1,
    get_state/2,
    vote_requested/1,
    vote_resolved/3,
    phases/1,
    on_phase_started/2,
    on_phase_ended/2
]).
