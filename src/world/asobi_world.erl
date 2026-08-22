-module(asobi_world).
-moduledoc """
Behaviour for large-session world game modules.

Unlike `asobi_match`, world games are spatially partitioned into zones. The game
module provides zone-level tick logic and global post-tick events. Only `init/1`,
`join/2`, `leave/2`, `spawn_position/2`, `zone_tick/2` and `post_tick/2` are
required; the rest are optional hooks (see `-optional_callbacks`).

Input handling needs **one of** `handle_input/3` or `handle_input_batch/2`.
Both are optional so a module can implement either, and a world that takes no
player input at all can implement neither - asobi acks such inputs by frame
stamp and logs once rather than failing the zone.
""".

-doc """
What happened to one input in a `handle_input_batch/2` call. One per input, in
the order they were handed over. The three constructors mirror `handle_input/3`'s
three return shapes, minus the entity map the batch returns once.
""".
-type input_outcome() ::
    ok
    | {consumed, ConsumedSeq :: non_neg_integer()}
    | {error, Reason :: term()}.

-export_type([input_outcome/0]).

-doc "Initialise global game state from the match config.".
-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-doc "A player joins the world.".
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
behind the join.
""".
-callback join(PlayerId :: binary(), Ctx :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-doc "A player leaves the world.".
-callback leave(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Where a joining player spawns.".
-callback spawn_position(PlayerId :: binary(), GameState :: term()) ->
    {ok, {X :: number(), Y :: number()}}.

-doc "Per-zone tick: advance the entities in one zone from its zone_state.".
-callback zone_tick(Entities :: map(), ZoneState :: term()) ->
    {Entities1 :: map(), ZoneState1 :: term()}.

-doc """
Apply a player input to a zone's entities.

Return `{ok, Entities1, ConsumedSeq}` to tell asobi which client sequence
this input actually advanced the simulation to. Without it the `world.ack`
carries the `seq` the client stamped on the frame, which says the frame
*arrived*, not how much of it *ran*. The two differ for any game that puts
more than one simulation step in a frame: a client predicting at 60 Hz
against a 12.5 Hz zone batches several steps per frame, and a zone that
caps how many it runs per tick parks the rest. Acking the frame stamp then
either overclaims (the client discards predicted steps the server has not
run and can never replay them) or underclaims (the client replays steps the
server already applied and overshoots).

`ConsumedSeq` is in the client's own sequence space - the same numbering the
steps inside `Input` carry - and asobi does not interpret it beyond bounding
it: a non-negative integer no larger than `?MAX_ACK_SEQ`
(`-include_lib("asobi/include/asobi_ack.hrl")`), the same bound the
client-stamped `seq` is held to, because this value is echoed to that client on
every broadcast tick and the SDKs read it into an int64. Anything else is
refused with a warning and the frame stamp is used instead.

The rules that come with it.

**Report on every input or on none.** Within a tick a report always beats a
frame stamp, whatever order they arrive in. The leak is across ticks and is
not a race: a tick in which this module reported nothing records the frame
stamp instead, and the ack keeps the highest value it has recorded, so one
unreported tick pins the ack above the watermark for good.

**Reporting acks a client that never stamped a `seq`.** Numbering the steps
inside the payload and never stamping the frame is the cleanest form of the
batching design, and a module reporting a consumed seq is asserting that its
clients reconcile. A client that does not want acks should not be playing a
game whose module reports them.

**`{error, Reason}` still advances the ack to the frame stamp** - unless a
report already landed this tick, which outranks it, because refusing one input
does not unrun the steps another already consumed. A module that parks should
model refusal as `{ok, Entities, Watermark}` rather than an error.

A module that parks steps in `handle_input/3` and drains them in
`zone_tick/2` has no channel to report the drain: the watermark rides out on
the next input this module handles. Clients re-sending unacknowledged steps
for redundancy produce one every tick, so this costs a tick of latency; a
player at rest, sending nothing, leaves their final drain unacked until they
move again.
""".
-callback handle_input(PlayerId :: binary(), Input :: map(), Entities :: map()) ->
    {ok, Entities1 :: map()}
    | {ok, Entities1 :: map(), ConsumedSeq :: non_neg_integer()}
    | {error, Reason :: term()}.

-doc """
Optional: apply a whole tick's queued inputs in one call.

A module that exports this is handed the tick's inputs together and returns one
entity map plus one outcome per input, in the same order. asobi still owns the
ack policy - an outcome only says what happened to that input, and the mapping
from outcome to `world.ack` is unchanged from `handle_input/3`:

- `ok` acks the frame stamp, exactly as `{ok, Entities1}` does
- `{consumed, Seq}` reports a watermark, exactly as `{ok, Entities1, Seq}` does
- `{error, Reason}` logs and still advances the stamp, exactly as
  `{error, Reason}` does

It exists for bridges whose per-input cost is dominated by marshalling the
entity map across a language boundary rather than by the input itself.
`asobi_lua_world` encodes the map into Luerl once per tick here instead of once
per input, which is the difference between O(inputs x entities) and O(entities)
work per tick. The measurements are in
[Performance tuning](performance-tuning.md#players-in-one-zone).

Breaking the contract - a wrong-length outcome list, or a return that is not
`{ok, Entities1, Outcomes}` at all - logs and acks **nothing** for that tick. A
frame stamp would be worse than silence: the session's ack gate is monotonic, so
stamping over a watermark the module did report buries it permanently, while a
missing ack is undone by the next clean tick. A wrong-length list still keeps
the entities the module handed back (it may already have applied them); an
unusable return keeps the ones the zone held. Neither is re-run through
`handle_input/3`, for the same reason.

A module that does not export this gets `handle_input/3` per input, unchanged.

Exporting it **shadows `handle_input/3` entirely** for that module: asobi never
calls the per-input path when the batch exists. A module that exports both is
carrying two implementations of one semantic and has to keep them in lockstep.

An empty or invalid return means the same thing on both paths for the entities:
leave them alone. That is not free here - the module is handed the map itself
rather than a copy - so asobi reverts the Luerl state the call produced, which
reverts the heap the mutation lived in. Without it, a handler written as "apply
the move, then `return` to reject it" would keep the move, and one that looks
its target up from a client-controlled field would be a write primitive on any
entity in the zone. The revert is of the whole Luerl state, so a global the
handler wrote on its reject path, or randomness it consumed, is discarded with
it - `handle_input/3` kept those. Keep anything that must survive a rejection in
`game_state` or on an entity.

`asobi_lua_world` deliberately exports both. The batch is what production runs;
`handle_input/3` is kept as the reference semantic the batch is checked against,
and `asobi_lua_input_batch_tests:batch_agrees_with_per_input/0` drives the
hostile-return corpus through both, comparing entities and outcomes. Delete it
and the only cross-check on `batch_result/3` goes with it.
""".
-callback handle_input_batch(
    Inputs :: [{PlayerId :: binary(), Input :: map()}],
    Entities :: map()
) ->
    {ok, Entities1 :: map(), Outcomes :: [input_outcome()]}.

-doc """
Optional: apply this tick's cross-zone effects.

An effect arrives from a *neighbouring* zone that could see one of this zone's
entities in the border mirror and asked for something to happen to it -
`game.zone.apply` in Lua, `asobi_zone:apply_effect/3` in Erlang. The neighbour
never writes the entity; this zone does, in its own tick, which is what keeps a
single writer per entity while still letting a shot fired in one zone land in
the next (widgrensit/asobi#544).

Delivered after the tick's inputs, batched, and already filtered to effects
naming an entity this zone still owns - a target that died or crossed away
between the read and the tick is dropped rather than handed over as a nil
lookup. Returning something that is not a map drops the tick's effects.

A world that never calls `game.zone.apply` never needs this callback. One that
does and has not defined it gets a rate-limited error rather than silence: a
dropped effect is indistinguishable from a delivery bug from the game's side.
""".
-callback handle_effects(
    Effects :: [{EntityId :: binary(), Event :: map()}],
    Entities :: map()
) ->
    {ok, Entities1 :: map()} | Entities1 :: map().

-doc """
Optional: does this zone still have work asobi cannot see?

A zone with no entities, no queued input, no live entity timer and no pending
respawn is demoted and ticks once every `cold_tick_divisor` ticks
(widgrensit/asobi#543). That test reads asobi's own bookkeeping, which is blind
to work a script keeps in its zone state - a wave spawner counting down between
waves, weather, a zone-level phase timer. Such a zone holds nothing, so it is
demoted, and the countdown then runs at a tenth of the rate it was written for.

Export this to veto that. It is consulted **only when asobi already believes the
zone is idle**, so a zone with entities never pays for it, and a zone answering
`true` is doing work in `zone_tick` and paying for that anyway.

Fail-safe is "keep the zone hot": a raising or non-boolean answer is treated as
`true` and logged. Demoting a zone that has work is the harmful direction.
""".
-callback zone_busy(ZoneState :: term()) -> boolean().

-doc "Global post-tick hook: continue, trigger a vote, or finish the world.".
-callback post_tick(Tick :: non_neg_integer(), GameState :: term()) ->
    {ok, GameState1 :: term()}
    | {vote, VoteConfig :: map(), GameState1 :: term()}
    | {finished, Result :: map(), GameState1 :: term()}.

-doc "Optional: seed the initial zone states from a world seed.".
-callback generate_world(Seed :: integer(), Config :: map()) ->
    {ok, ZoneStates :: #{{integer(), integer()} => term()}}.

-doc "Optional: project the world to the state one player should see.".
-callback get_state(PlayerId :: binary(), GameState :: term()) ->
    StateForPlayer :: map().

-doc "Optional: declare the world's phases.".
-callback phases(Config :: map()) -> [asobi_phase:phase_def()].

-doc "Optional: a phase started.".
-callback on_phase_started(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Optional: a phase ended.".
-callback on_phase_ended(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Optional: the world was recovered from snapshots after a crash.".
-callback on_world_recovered(Snapshots :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc "Optional: named entity spawn templates for zone spawners.".
-callback spawn_templates(Config :: map()) ->
    #{binary() => asobi_zone_spawner:spawn_template()}.

-doc """
Optional (asobi#253): a per-tick, cheap hint that spawn templates may have
changed since zone creation - e.g. a script hot-reload adding/renaming a
template. `spawn_templates/1` is only ever called once, at zone creation;
without this, a long-running zone never learns about a template added
later and every spawn attempt against it surfaces as `unknown_spawn_template`
indefinitely, not just until the next reload.

Called every tick if exported, so implementations MUST be cheap in the
common case - return `unchanged` immediately unless something already
indicates a real change happened this tick (e.g. a hot-reload just ran).
Do not unconditionally rebuild/re-read a template source here.

`{changed, NewTemplates}` REPLACES the zone's entire template set, the same
as `spawn_templates/1`'s result does at creation - it is not a delta. An
implementation built from a partial reload that reconstructs only the
templates it knows changed will silently drop every other template; make
sure `NewTemplates` includes every template that should still be spawnable,
not only the ones that changed.
""".
-callback spawn_templates_hint(ZoneState :: term()) ->
    unchanged | {changed, #{binary() => asobi_zone_spawner:spawn_template()}}.

-doc "Optional: the terrain provider module + args, or `none`.".
-callback terrain_provider(Config :: map()) ->
    {Module :: module(), ProviderArgs :: map()} | none.

-doc "Optional: a zone was lazily loaded.".
-callback on_zone_loaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, ZoneState :: map(), GameState1 :: term()}.

-doc "Optional: a zone was unloaded.".
-callback on_zone_unloaded(Coords :: {integer(), integer()}, GameState :: term()) ->
    {ok, GameState1 :: term()}.

-doc """
Build this zone's zone_state in the zone process, from the zone Config and any
plain gameplay state restored from a snapshot. This is where a game module that
holds a per-zone runtime (e.g. a Lua VM) constructs it, bound to the zone
process. Runs once, after init, via handle_continue.
""".
-callback init_zone_state(Config :: map(), ZoneState :: map()) -> map().

-doc """
Reduce zone_state to a JSON-safe map for snapshotting: drop any live runtime
(e.g. a VM that cannot be serialised) and decode engine-held gameplay state to
plain terms. The inverse of `init_zone_state`'s restore path.
""".
-callback dump_zone_state(ZoneState :: map()) -> map().

-optional_callbacks([
    join/3,
    generate_world/2,
    get_state/2,
    phases/1,
    on_phase_started/2,
    on_phase_ended/2,
    on_world_recovered/2,
    spawn_templates/1,
    spawn_templates_hint/1,
    terrain_provider/1,
    on_zone_loaded/2,
    on_zone_unloaded/2,
    init_zone_state/2,
    dump_zone_state/1,
    handle_input/3,
    handle_input_batch/2,
    handle_effects/2,
    zone_busy/1
]).
