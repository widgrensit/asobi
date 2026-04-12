-module(asobi_world).

%% Behaviour for large-session world game modules.
%%
%% Unlike `asobi_match`, world games are spatially partitioned into zones.
%% The game module provides zone-level tick logic and global post-tick events.

-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-callback join(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-callback leave(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback spawn_position(PlayerId :: binary(), GameState :: term()) ->
    {ok, {X :: number(), Y :: number()}}.

-callback zone_tick(Entities :: map(), ZoneState :: term()) ->
    {Entities1 :: map(), ZoneState1 :: term()}.

-callback handle_input(PlayerId :: binary(), Input :: map(), Entities :: map()) ->
    {ok, Entities1 :: map()} | {error, Reason :: term()}.

-callback post_tick(Tick :: non_neg_integer(), GameState :: term()) ->
    {ok, GameState1 :: term()}
    | {vote, VoteConfig :: map(), GameState1 :: term()}
    | {finished, Result :: map(), GameState1 :: term()}.

-callback generate_world(Seed :: integer(), Config :: map()) ->
    {ok, ZoneStates :: #{{integer(), integer()} => term()}}.

-callback get_state(PlayerId :: binary(), GameState :: term()) ->
    StateForPlayer :: map().

-callback phases(Config :: map()) -> [asobi_phase:phase_def()].

-callback on_phase_started(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback on_phase_ended(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback on_world_recovered(Snapshots :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback spawn_templates(Config :: map()) ->
    #{binary() => asobi_zone_spawner:spawn_template()}.

-optional_callbacks([
    generate_world/2,
    get_state/2,
    phases/1,
    on_phase_started/2,
    on_phase_ended/2,
    on_world_recovered/2,
    spawn_templates/1
]).
