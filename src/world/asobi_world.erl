-module(asobi_world).
-moduledoc """
Behaviour for large-session world game modules.

Unlike `asobi_match`, world games are spatially partitioned into zones. The game
module provides zone-level tick logic and global post-tick events. Only `init/1`,
`join/2`, `leave/2`, `spawn_position/2`, `zone_tick/2`, `handle_input/3`,
`post_tick/2`, `init_zone_state/2`, and `dump_zone_state/1` are required; the rest
are optional hooks (see `-optional_callbacks`).
""".

-doc "Initialise global game state from the match config.".
-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-doc "A player joins the world.".
-callback join(PlayerId :: binary(), GameState :: term()) ->
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

-doc "Apply a player input to a zone's entities.".
-callback handle_input(PlayerId :: binary(), Input :: map(), Entities :: map()) ->
    {ok, Entities1 :: map()} | {error, Reason :: term()}.

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
    generate_world/2,
    get_state/2,
    phases/1,
    on_phase_started/2,
    on_phase_ended/2,
    on_world_recovered/2,
    spawn_templates/1,
    terrain_provider/1,
    on_zone_loaded/2,
    on_zone_unloaded/2,
    init_zone_state/2,
    dump_zone_state/1
]).
