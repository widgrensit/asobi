-module(asobi_lua_world).
-moduledoc """
An `asobi_world` implementation that delegates all callbacks to Lua scripts
via Luerl.

The Lua script must define these functions:

```lua
function init(config)                        -- return initial game state
function join(player_id, state, ctx)         -- ctx is the client join context
function leave(player_id, state)             -- return updated state
function spawn_position(player_id, state)    -- return {x, y}
function zone_tick(entities, zone_state)     -- return entities, zone_state
function handle_input(player_id, input, entities) -- return entities[, consumed_seq]
function post_tick(tick, state)              -- return state (or state + vote/finished)
-- Optional:
function generate_world(seed, config)        -- return zone_states table
function get_state(player_id, state)         -- return state visible to player
function phases(config)                      -- return list of phase definitions
function on_phase_started(phase_name, state) -- return updated state
function on_phase_ended(phase_name, state)   -- return updated state
function spawn_templates(config)             -- return template registry table
function on_world_recovered(snapshots, state) -- return updated state
function terrain_provider(config)            -- return {module, args} or nil
function on_zone_loaded(cx, cy, state)       -- return zone_state, state
function on_zone_unloaded(cx, cy, state)     -- return state
```

`vote_resolved` is deliberately absent. `asobi_world_server` reaches it through
`erlang:function_exported/3` and this module does not export it, so a Lua world
script defining `vote_resolved` is never called. Match scripts are unaffected;
see `guides/voting.md`.

After a hot reload (`ASOBI_LUA_RELOAD`/`reload_mode`), `spawn_templates_hint/1`
tells the running zone to re-fetch `spawn_templates(config)` so an edited
script's new templates become spawnable without restarting the zone. The
`game.zone.spawn` guard reads that live set from a per-zone ETS table rather
than a value snapshotted once into Ctx, so this stays correct across any number
of hot reloads.
""".

-behaviour(asobi_world).

-include_lib("kernel/include/logger.hrl").
-include("asobi_ack.hrl").

-export([init/1, join/2, join/3, leave/2, spawn_position/2]).
-export([zone_tick/2, handle_input/3, handle_input_batch/2, handle_effects/2, post_tick/2]).
-ifdef(TEST).
-export([zone_ctx/2, make_ctx/1]).
-endif.
-export([generate_world/2, get_state/2]).
-export([phases/1, on_phase_started/2, on_phase_ended/2]).
-export([spawn_templates/1, spawn_templates_hint/1, on_world_recovered/2]).
-export([terrain_provider/1, on_zone_loaded/2, on_zone_unloaded/2]).
-export([init_zone_state/2, dump_zone_state/1]).

%% Wall-clock budgets for Lua callbacks. Init-time callbacks
%% (`init`, `generate_world`, `phases`, `spawn_templates`,
%% `terrain_provider`) get more headroom because building a world or a
%% phase table can be CPU-heavy. Per-tick callbacks share the tighter
%% TICK_TIMEOUT so a runaway script can't wedge the zone loop.
-define(INIT_TIMEOUT, 2000).
-define(GENERATE_TIMEOUT, 5000).
-define(TICK_TIMEOUT, 500).
-define(JOIN_TIMEOUT, 200).
-define(LEAVE_TIMEOUT, 200).
-define(GET_STATE_TIMEOUT, 100).
-define(SPAWN_POS_TIMEOUT, 100).
-define(PHASE_TIMEOUT, 200).
-define(ZONE_LIFECYCLE_TIMEOUT, 200).

-spec init(map()) -> {ok, map()}.
init(Config) ->
    ScriptPath =
        case maps:get(lua_script, Config, undefined) of
            P when is_binary(P); is_list(P) ->
                P;
            undefined ->
                ?LOG_ERROR(#{msg => ~"asobi_lua_world init: missing lua_script", config => Config}),
                erlang:error({missing_lua_script, Config})
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    PreInstall = fun(St) -> asobi_lua_api:install(make_ctx(Config), St) end,
    case asobi_lua_loader:new(ScriptPath, ?INIT_TIMEOUT, PreInstall) of
        {ok, LuaSt0} ->
            {EncConfig, LuaSt1} = asobi_lua_loader:encode(GameConfig, LuaSt0),
            case asobi_lua_loader:call(init, [EncConfig], LuaSt1, ?INIT_TIMEOUT) of
                {ok, [GameState | _], LuaSt2} ->
                    {ok, #{
                        lua_state => LuaSt2,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath),
                        %% Read off `Config` itself, the way make_ctx/1 does:
                        %% asobi_world_server:init/1 hands GameMod:init/1 the
                        %% game config with `match_id` injected, so there is no
                        %% nested `game_config` here to look inside.
                        lua_bridge => #{
                            kind => world,
                            world_id => maps:get(
                                match_id, Config, maps:get(world_id, Config, undefined)
                            )
                        }
                    }};
                {ok, [], _} ->
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_world init: lua init() returned no value",
                        script => ScriptPath
                    }),
                    erlang:error({lua_error, ~"init() must return a table"});
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => ~"asobi_lua_world init: lua init() failed",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    erlang:error({lua_init_failed, Reason})
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"asobi_lua_world init: lua_loader:new/1 failed",
                script => ScriptPath,
                reason => Reason
            }),
            erlang:error({lua_load_failed, ScriptPath, Reason})
    end.

-spec join(binary(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, State) ->
    join(PlayerId, #{}, State).

-doc """
Join carrying the client-supplied join context (asobi's optional `join/3`).

Passed to the Lua `join` as a third argument: `function join(player_id,
state)` keeps working (Lua discards extra arguments) and
`function join(player_id, state, ctx)` receives it.
""".
-spec join(binary(), map(), map()) -> {ok, map()} | {error, term()}.
join(PlayerId, Ctx, #{lua_state := LuaSt, game_state := GS} = State) when is_map(Ctx) ->
    %% Erlang maps must be encoded before they cross into Luerl - GS is
    %% already a Lua value, but Ctx arrives raw from the client.
    {EncCtx, LuaSt0} = asobi_lua_loader:encode(Ctx, LuaSt),
    case asobi_lua_loader:call(join, [PlayerId, GS, EncCtx], LuaSt0, ?JOIN_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec leave(binary(), map()) -> {ok, map()}.
leave(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(leave, [PlayerId, GS], LuaSt, ?LEAVE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, Reason} ->
            log_lua_error(leave, Reason, State),
            {ok, State}
    end.

-spec spawn_position(binary(), map()) -> {ok, {number(), number()}}.
spawn_position(PlayerId, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(spawn_position, [PlayerId, GS], LuaSt, ?SPAWN_POS_TIMEOUT) of
        {ok, [PosTable | _], LuaSt1} ->
            Pos = decode_position(PosTable, LuaSt1),
            {ok, Pos};
        {error, Reason} ->
            log_lua_error(spawn_position, Reason, State),
            {ok, {0.0, 0.0}}
    end.

%% asobi_zone calls apply_inputs (handle_input/3) *before* zone_tick/2 each
%% tick, and the only state it carries is the entities map — no lua_state
%% threaded through. We bridge that by stashing the current ZoneState in the
%% zone process's dictionary from zone_tick, and reading it back in
%% handle_input. Both run inside the same zone gen_server process so the
%% proc dict is safe and per-zone-isolated.
-define(PD_KEY, {?MODULE, zone_state}).

%% asobi_lua#110 + asobi#253: the zone's declared spawn-template set, read
%% live by asobi_lua_api:known_template/2 on every game.zone.spawn call
%% instead of being snapshotted once into Ctx. A Ctx-cached map (the
%% original #110 fix) goes stale forever after the first hot reload: the
%% zone's own game_module callback re-runs (via spawn_templates_hint/1
%% below, wired from asobi_zone's maybe_apply_spawn_templates_hint/5 on
%% every reload tick) and updates asobi_zone_spawner's live set, but
%% asobi_lua_reload:reload_script/2 re-executes the edited script's body
%% into the EXISTING Luerl state and never re-runs asobi_lua_api:install/2
%% - so a Ctx-captured closure keeps whatever map it saw at zone init for
%% the zone's whole lifetime.
%%
%% A process dictionary keyed by `self()` (as used for ?PD_KEY above) does
%% NOT fix this: every Lua callback invoked with a wall-clock budget
%% (asobi_lua_loader:call/4, which is everything except handle_input/3 -
%% see the trust model, guides/security-trust-model.md) runs the actual
%% Lua call inside a short-lived worker
%% process spawned by asobi_lua_loader:bounded_eval/2, not the zone
%% process itself. `game.zone.spawn` is called from `zone_tick`, so its
%% closure's `self()` at call time is that ephemeral worker, not the zone
%% - a pd read there is always empty. Instead, `init_zone_state/2` gives
%% each zone its own small `protected` ETS table (owned by the zone
%% process, so it dies with it - no leak) and stores its reference in both
%% Ctx (`templates_tab`, for the closure to read) and ZoneState
%% (`templates_tab`, for spawn_templates_hint/1 to update). Only the owning
%% (zone) process ever writes to it; any process can read it, which is
%% exactly the write/read split here.
-define(TEMPLATES_KEY, known).

-spec zone_tick(map(), term()) ->
    {map(), term()} | {map(), term(), boolean()} | {map(), term(), boolean(), map()}.
zone_tick(Entities, ZoneState0) when is_map(ZoneState0) ->
    %% Pick up any lua_state updates that handle_input stashed earlier this
    %% tick. The dev-error rate-limit stamp must ride along too: asobi_zone's
    %% canonical ZoneState0 never carries it, so dropping it here would reset
    %% the limit every tick and turn a broken handler into a per-tick stream.
    ZoneState1 =
        case erlang:get(?PD_KEY) of
            #{lua_state := LuaFromDict} = Stashed ->
                maps:merge(
                    ZoneState0#{lua_state => LuaFromDict},
                    maps:with([dev_error_at], Stashed)
                );
            _ ->
                ZoneState0
        end,
    %% Hot-reload the script if it changed on disk since the last tick.
    %% Mirrors asobi_lua_match's per-tick reload — keeps live worlds in sync
    %% with on-disk edits without restarting the zone process.
    %% #536: collect before the callback, not after it. The expensive moment
    %% is asobi_lua_loader:call/4's copy of the whole state into its eval
    %% worker, and this is the last point before it - collecting after meant
    %% the tick paid the copy at the peak of the sawtooth every time, and a
    %% tick that failed on heap or timeout never reached the collection at
    %% all, so it failed identically on every following tick.
    ZoneState = asobi_lua_loader:collect_state(asobi_lua_reload:maybe_hot_reload(ZoneState1)),
    %% asobi#253: refresh the live known-template set (?TEMPLATES_KEY) the
    %% instant a reload lands, before this tick's own zone_tick Lua body
    %% runs - not just from asobi_zone's separate, later
    %% spawn_templates_hint/1 call (maybe_apply_spawn_templates_hint/5 runs
    %% AFTER GameMod:zone_tick/2 returns). Without this, a script that
    %% spawns its own newly-declared template on the very tick it gets
    %% hot-reloaded would still see the stale set for that one tick.
    %% spawn_templates_hint/1 is cheap when nothing changed and idempotent
    %% when asobi_zone calls it again right after for the spawner update.
    _ = spawn_templates_hint(ZoneState),
    %% Entities returned here (and from handle_input/3 below) feed straight
    %% into asobi_zone's shared, game-module-agnostic tick path - crossing
    %% detection, snapshotting, grid maintenance - all of which pattern-match
    %% atom keys (#{type := ..., x := ..., y := ...}). decode_to_map/2 builds
    %% straight off Luerl's binary-keyed proplist output, so without
    %% atomize_entities/1 here every one of those clauses silently no-ops for
    %% a Lua world instead of matching. atomize_entities/1 only rewrites map
    %% keys, never values, and luerl:encode/2 turns an atom key back into the
    %% identical binary Lua sees either way (atom_to_binary/2) - so this is
    %% invisible to the Lua script on the next tick. See widgrensit/asobi#270.
    Result =
        case maps:get(lua_state, ZoneState, undefined) of
            undefined ->
                {Entities, ZoneState};
            LuaSt ->
                {EncEntities, LuaSt1} = asobi_lua_loader:encode(Entities, LuaSt),
                GS = maps:get(game_state, ZoneState, nil),
                case
                    asobi_lua_loader:call(
                        zone_tick, [EncEntities, GS], LuaSt1, ?TICK_TIMEOUT
                    )
                of
                    {ok, [Ents1, ZS1, Busy, Dirty | _], LuaSt2} ->
                        ZS = ZoneState#{lua_state => LuaSt2, game_state => ZS1},
                        case decode_dirty(Dirty, LuaSt2) of
                            undefined ->
                                Ents2 = asobi_lua_api:atomize_entities(
                                    decode_to_map(Ents1, LuaSt2)
                                ),
                                {Ents2, ZS, truthy(Busy)};
                            DirtySet ->
                                %% `Entities` - what asobi handed IN - rather
                                %% than a decode of what came back. That is the
                                %% point: see decode_dirty/2.
                                {Entities, ZS, truthy(Busy), DirtySet}
                        end;
                    {ok, [Ents1, ZS1, Busy | _], LuaSt2} ->
                        Ents2 = asobi_lua_api:atomize_entities(decode_to_map(Ents1, LuaSt2)),
                        {Ents2, ZoneState#{lua_state => LuaSt2, game_state => ZS1}, truthy(Busy)};
                    {ok, [Ents1, ZS1 | _], LuaSt2} ->
                        Ents2 = asobi_lua_api:atomize_entities(decode_to_map(Ents1, LuaSt2)),
                        {Ents2, ZoneState#{lua_state => LuaSt2, game_state => ZS1}};
                    {ok, [Ents1 | _], LuaSt2} ->
                        Ents2 = asobi_lua_api:atomize_entities(decode_to_map(Ents1, LuaSt2)),
                        {Ents2, ZoneState#{lua_state => LuaSt2}};
                    {error, Reason} ->
                        log_lua_error(zone_tick, Reason, ZoneState),
                        {Entities, ZoneState}
                end
        end,
    erlang:put(?PD_KEY, result_zone_state(Result)),
    Result;
zone_tick(Entities, ZoneState) ->
    {Entities, ZoneState}.

result_zone_state({_Entities, ZoneState}) -> ZoneState;
result_zone_state({_Entities, ZoneState, _Busy}) -> ZoneState;
result_zone_state({_Entities, ZoneState, _Busy, _Dirty}) -> ZoneState.

%% Reads `zone_tick`'s optional fourth return value: what actually changed.
%%
%% ```lua
%% function zone_tick(entities, zone_state)
%%   local changed, removed = {}, {}
%%   for id, e in pairs(entities) do
%%     if wants_to_move(e) then step(e); changed[id] = e end
%%     if e.hp and e.hp <= 0 then removed[#removed + 1] = id end
%%   end
%%   return entities, zone_state, false, { changed = changed, removed = removed }
%% end
%% ```
%%
%% Declaring it is what lets this bridge stop decoding the whole entities table.
%% Without it a populated zone round-trips every entity across the boundary in
%% both directions on every tick regardless of how many actually changed - a zone
%% with 500 NPCs of which 3 move pays for 500, twenty times a second, and pays
%% again downstream because the decode rebuilds every entity map and destroys the
%% structural sharing `compute_deltas/2` and `sync_spatial_grid/3` rely on
%% (widgrensit/asobi#557). Measured on a 2,000-entity zone with an inert script
%% under `owned`, the round trip was ~9.3ms per tick and 200k reductions on the
%% zone process; declaring takes it to ~4.6ms and 1.2k.
%%
%% **The declaration is the truth.** An entity the script mutated and did not put
%% in `changed` is not changed as far as asobi is concerned, and the next tick
%% re-encodes asobi's map over the top of it - so the mutation is not merely
%% invisible, it is undone. That is inherent to any dirty contract and it is why
%% this is opt-in per script rather than a mode.
%%
%% Anything that is not a table declaring at least one of `changed` and `removed`
%% means "no declaration" and today's semantics, which is also what a three-value
%% return gives. That fallback is the safe direction in both places it is reached
%% from: it costs a full decode and nothing else. Malformed HALVES are narrowed
%% and reported in `asobi_zone:apply_dirty/3` rather than here, so an Erlang game
%% module declaring the same thing meets the same bar.
-spec decode_dirty(term(), dynamic()) -> map() | undefined.
%% Only a TABLE reference is a declaration, and `is_tuple/1` does not say that.
%% Luerl represents every non-scalar as a record - `#tref{}`, `#funref{}`,
%% `#erl_func{}`, `#erl_mfa{}`, `#usdref{}` - so `is_tuple/1` admitted all of
%% them, and each one raises out of decode_to_map/2. `asobi_zone:do_tick/2`
%% calls `zone_tick/2` with no try/catch, so `return entities, zone_state,
%% false, print` killed the zone and everyone in it (widgrensit/asobi#557
%% review). The record tag is the check; the try/catch is for a `#tref{}` that
%% is recursive or stale, which decode_to_map/2 also raises on.
decode_dirty(Ref, LuaSt) when is_tuple(Ref), element(1, Ref) =:= tref ->
    try decode_to_map(Ref, LuaSt) of
        Decoded -> narrow_dirty(Decoded)
    catch
        _:_ -> undefined
    end;
decode_dirty(_Other, _LuaSt) ->
    undefined.

%% A table has to actually declare something. `decode_to_map/2` coerces an
%% array-shaped decode to `#{}`, so without this test `{"a","b"}` - or any
%% table that is simply not a dirty set - became a well-formed EMPTY
%% declaration, and an empty declaration means "nothing changed", every tick,
%% forever. Falling back to the full decode is the only reading that cannot
%% silently freeze a zone.
-spec narrow_dirty(map()) -> map() | undefined.
narrow_dirty(Decoded) when
    is_map_key(~"changed", Decoded); is_map_key(~"removed", Decoded)
->
    #{
        changed => asobi_lua_api:atomize_entities(
            as_entity_map(maps:get(~"changed", Decoded, #{}))
        ),
        removed => as_id_list(maps:get(~"removed", Decoded, []))
    };
narrow_dirty(_NotADeclaration) ->
    undefined.

%% An empty Lua table decodes to `[]`, not `#{}` - there is nothing in it to
%% tell a record from an array - so `changed = {}` is the ordinary "I moved
%% nothing this tick" case and passes through silently. A NON-empty list is a
%% script that built `changed` as an array (`changed[#changed + 1] = e`), which
%% is one line away from the idiom in the guide; asobi cannot use it, and
%% saying nothing would revert every mutation the tick made.
-spec as_entity_map(term()) -> map().
as_entity_map(M) when is_map(M) ->
    M;
as_entity_map([]) ->
    #{};
as_entity_map(Other) ->
    report_bad_half(~"changed", Other),
    #{}.

-spec as_id_list(term()) -> [binary()].
as_id_list(L) when is_list(L) ->
    [Id || Id <- L, is_binary(Id)];
as_id_list(#{} = Empty) when map_size(Empty) =:= 0 ->
    [];
as_id_list(Other) ->
    report_bad_half(~"removed", Other),
    [].

%% Reported here rather than left to asobi_zone: by the time the bridge has
%% normalised a malformed half away, core sees something well-formed and has
%% nothing to complain about. That gap is what made this whole class silent.
-spec report_bad_half(binary(), term()) -> ok.
report_bad_half(Half, Other) ->
    asobi_telemetry:game_error(bad_zone_dirty, #{callback => zone_tick}),
    ?LOG_ERROR(#{
        msg => ~"zone_tick's dirty declaration has a malformed half; ignoring it",
        half => Half,
        shape => dirty_half_shape(Other)
    }),
    ok.

%% Shape, never the value: the value is the script's and so is its size.
-spec dirty_half_shape(term()) -> tuple() | binary().
dirty_half_shape(T) when is_list(T) -> {list, length(T)};
dirty_half_shape(T) when is_map(T) -> {map, map_size(T)};
dirty_half_shape(T) when is_binary(T) -> {binary, byte_size(T)};
dirty_half_shape(T) -> iolist_to_binary(io_lib:format("~P", [T, 4])).

%% Lua truthiness, not Erlang's: `nil` and `false` are the only falsey values, so
%% `return entities, zone_state, wave_countdown > 0` works and so does returning
%% a number. Reading a bare returned value can run no metamethod, which is the
%% whole reason this is a return value and not a field - see asobi_zone's
%% zone_tick_result/2.
truthy(nil) -> false;
truthy(false) -> false;
truthy(_) -> true.

-doc """
Delegates to the script's `handle_input`.

A second Lua return value is the client sequence the script has consumed, and
it becomes the `world.ack` for that player instead of the seq the client
stamped on the frame - see the `asobi_world` callback for why a game that
batches several simulation steps into one frame needs to say what it *ran*
rather than what *arrived*:

```lua
function handle_input(player_id, input, entities)
  local watermark = apply_steps(input.steps, entities)
  return entities, watermark
end
```

A non-numeric or negative second value is refused with a warning and the frame
stamp is used, so a script cannot ack something the client will not accept.
""".
-spec handle_input(binary(), map(), map()) ->
    {ok, map()} | {ok, map(), non_neg_integer()} | {error, term()}.
handle_input(PlayerId, Input, Entities) ->
    case stashed_zone_state() of
        #{lua_state := LuaSt} = ZoneState ->
            {EncInput, LuaSt1} = asobi_lua_loader:encode(Input, LuaSt),
            {EncEntities, LuaSt2} = asobi_lua_loader:encode(Entities, LuaSt1),
            %% No bounded_eval: handle_input is not a sandbox boundary, see
            %% guides/security-trust-model.md.
            case
                asobi_lua_loader:call(
                    handle_input, [PlayerId, EncInput, EncEntities], LuaSt2
                )
            of
                {ok, Rets, LuaSt3} ->
                    ZoneState1 = ZoneState#{lua_state => LuaSt3},
                    erlang:put(?PD_KEY, ZoneState1),
                    input_result(Rets, LuaSt3, Entities, ZoneState1);
                {error, Reason} ->
                    log_lua_error(handle_input, Reason, ZoneState),
                    ZoneState1 = asobi_lua_dev_errors:maybe_notify(
                        handle_input, Reason, PlayerId, ZoneState
                    ),
                    erlang:put(?PD_KEY, ZoneState1),
                    {ok, Entities}
            end;
        _ ->
            {ok, Entities}
    end.

-doc """
Delegates a tick's cross-zone effects to the script's `handle_effects`.

```lua
function handle_effects(effects, entities)
  for _, e in ipairs(effects) do
    local target = entities[e.entity_id]
    target.hp = target.hp - (e.event.damage or 0)
  end
  return entities
end
```

Batched, and inline on the zone process for the same reason
`handle_input_batch/2` is: the entity map is encoded once for the whole tick's
effects, and the copy a bounded call would make is the cost
`widgrensit/asobi#543` is about. asobi has already filtered the list to effects
naming an entity this zone still owns, so `entities[e.entity_id]` is never nil.

A script with no `handle_effects` gets an error logged once per limiter window
and its effects dropped - silently ignoring them would make a missing handler
look like a delivery bug.
""".
-spec handle_effects([{binary(), map()}], map()) -> {ok, map()}.
handle_effects(Effects, Entities) ->
    case stashed_zone_state() of
        #{lua_state := LuaSt} = ZoneState ->
            %% asobi_zone cannot make this call for us: the bridge module always
            %% exports handle_effects/2, so `function_exported` there says
            %% nothing about whether the *script* defines one. Luerl cannot tell
            %% an undefined global apart from a raising one either (see
            %% asobi_lua_loader:is_defined/2), so the check has to be explicit or
            %% a missing handler is reported as a script crash.
            case asobi_lua_loader:is_defined(handle_effects, LuaSt) of
                false ->
                    log_lua_error(handle_effects, no_handler, ZoneState),
                    {ok, Entities};
                true ->
                    call_handle_effects(Effects, Entities, LuaSt, ZoneState)
            end;
        _ ->
            {ok, Entities}
    end.

call_handle_effects(Effects, Entities, LuaSt, ZoneState) ->
    {EncEffects, LuaSt1} = asobi_lua_loader:encode(encode_effects(Effects), LuaSt),
    {EncEntities, LuaSt2} = asobi_lua_loader:encode(Entities, LuaSt1),
    case asobi_lua_loader:call(handle_effects, [EncEffects, EncEntities], LuaSt2) of
        {ok, [Ents1 | _], LuaSt3} ->
            erlang:put(?PD_KEY, ZoneState#{lua_state => LuaSt3}),
            {ok, asobi_lua_api:atomize_entities(decode_to_map(Ents1, LuaSt3))};
        {ok, [], LuaSt3} ->
            erlang:put(?PD_KEY, ZoneState#{lua_state => LuaSt3}),
            {ok, Entities};
        {error, Reason} ->
            log_lua_error(handle_effects, Reason, ZoneState),
            {ok, Entities}
    end.

encode_effects(Effects) ->
    [#{~"entity_id" => Id, ~"event" => Event} || {Id, Event} <- Effects].

-doc """
Apply a tick's whole input queue with one encode of the entity map.

`handle_input/3` encodes the entity map into Luerl on every call, so a zone with
P players applied it P times per tick and decoded it P times back. That is the
same map every time, and it dominated both the allocation and the tick: measured
at 200 entities, `handle_input` allocated `208 x P` Lua tables per tick against
`zone_tick`'s constant 177.6, and 64 players in one zone ran a tick well past
any budget the world could be given. See
`guides/performance-tuning.md`.

Here the map is encoded once, the resulting Luerl reference is threaded through
every input, and it is decoded once at the end. Each input still pays for its
own (small) input frame.

The reference is **anchored** for the batch (`asobi_lua_loader:anchor_ref/2`).
Luerl's root set is `_G`, the stack and the live call frames, so a table Erlang
carries between calls is reachable only while some frame happens to name it, and
a script that ignores the argument (`function handle_input(p, i)` when three were
passed) drops the map from its frame. A collection at that moment frees it, its
slot returns to luerl's free list, the next input's `luerl:encode/2` recycles it,
and the reference then aliases that input's frame: the zone's whole entity map
silently becomes one player's input, which `asobi_zone` accepts and the
snapshotter persists.

Two things stop that, and they close different doors. `collectgarbage` is
stripped from the sandbox, so a script cannot force a collection mid-batch. The
anchor makes the reference survive one regardless, which is what keeps this
correct if a collection is ever introduced on this path. `_G` is script-writable,
so the anchor is re-checked after every call: a script that clears it loses that
tick's inputs rather than corrupting the zone.

An empty or invalid return means what it means under `handle_input/3`: leave the
entities alone. The script holds the table itself here, so that is not free -
see `batch_result/2`.
""".
-spec handle_input_batch([{binary(), map()}], map()) ->
    {ok, map(), [asobi_world:input_outcome()]}.
handle_input_batch([], Entities) ->
    {ok, Entities, []};
handle_input_batch(Inputs, Entities) ->
    case stashed_zone_state() of
        #{lua_state := LuaSt} = ZoneState ->
            {EncEntities, LuaSt1} = asobi_lua_loader:encode(Entities, LuaSt),
            {EncEntities1, Outcomes, LuaSt2, ZoneState1} = run_input_batch(
                Inputs, EncEntities, LuaSt1, ZoneState, []
            ),
            %% Decode BEFORE unanchoring: the reference is only rooted until the
            %% slot is cleared, and nothing should read an unrooted one.
            Result =
                case EncEntities1 of
                    anchor_lost ->
                        {ok, Entities, Outcomes};
                    _ ->
                        Decoded = asobi_lua_api:atomize_entities(
                            decode_to_map(EncEntities1, LuaSt2)
                        ),
                        {ok, Decoded, Outcomes}
                end,
            LuaSt3 = asobi_lua_loader:unanchor_ref(LuaSt2),
            erlang:put(?PD_KEY, ZoneState1#{lua_state => LuaSt3}),
            Result;
        _ ->
            {ok, Entities, [ok || _ <- Inputs]}
    end.

%% `erlang:get/1` is typed `term()`, so matching a zone state straight out of the
%% process dictionary loses the map shape and every luerl call on what comes out
%% of it reads as untyped. Narrowing it once here keeps the callers honest
%% without an eqwalizer suppression.
-spec stashed_zone_state() -> map() | undefined.
stashed_zone_state() ->
    case erlang:get(?PD_KEY) of
        ZoneState when is_map(ZoneState) -> ZoneState;
        _ -> undefined
    end.

run_input_batch([], Enc, LuaSt, ZoneState, Acc) ->
    {Enc, lists:reverse(Acc), LuaSt, ZoneState};
run_input_batch([{PlayerId, Input} | Rest], Enc, LuaSt, ZoneState, Acc) ->
    %% Anchor BEFORE the input encode, not after: `Enc` has to be rooted across
    %% every allocation, not merely across the call. Re-anchored each iteration
    %% because `Enc` changes - whatever the last script returned is what the
    %% next one is handed.
    LuaSt0 = asobi_lua_loader:anchor_ref(Enc, LuaSt),
    {EncInput, LuaSt1} = asobi_lua_loader:encode(Input, LuaSt0),
    case asobi_lua_loader:call(handle_input, [PlayerId, EncInput, Enc], LuaSt1) of
        {ok, Rets, LuaSt2} ->
            %% `_G` is script-writable, so a script can clear asobi's root with
            %% `__asobi_ref_anchor = nil`. Nothing Erlang is holding is safe to
            %% decode after that, so abandon the batch and hand back the map the
            %% zone gave us rather than one that may alias a recycled slot.
            case asobi_lua_loader:ref_anchored(Enc, LuaSt2) of
                true ->
                    case batch_result(Rets, ZoneState) of
                        {keep, Enc1, Outcome} ->
                            run_input_batch(Rest, Enc1, LuaSt2, ZoneState, [Outcome | Acc]);
                        {revert, Outcome} ->
                            %% Carrying LuaSt0 onward is the revert under
                            %% `copy`; under `owned` the mutation already
                            %% happened in the VM, so it has to be undone
                            %% explicitly. Same intent, said twice because the
                            %% two modes disagree about who holds the state.
                            run_input_batch(
                                Rest,
                                Enc,
                                asobi_lua_loader:revert(LuaSt0),
                                ZoneState,
                                [Outcome | Acc]
                            )
                    end;
                false ->
                    log_anchor_cleared(ZoneState),
                    %% Carry the outcomes already produced this tick rather than
                    %% flattening them to stamps. A {consumed, Seq} replaced by
                    %% a frame stamp is buried for good - the session ack gate
                    %% is monotonic - and the input that cleared the anchor is
                    %% not the input that reported. The current input and the
                    %% un-run remainder ack by stamp, which is all asobi knows.
                    Unrun = [ok || _ <- [dropped | Rest]],
                    {anchor_lost, lists:reverse(Acc, Unrun), LuaSt2, ZoneState}
            end;
        {error, Reason} ->
            log_lua_error(handle_input, Reason, ZoneState),
            ZoneState1 = asobi_lua_dev_errors:maybe_notify(
                handle_input, Reason, PlayerId, ZoneState
            ),
            %% `ok`, not `{error, Reason}`. A Lua exception is a bridge failure,
            %% not a module rejection: handle_input/3 maps one to
            %% `{ok, Entities}` after a rate-limited, shape-classified
            %% log_lua_error/3, and reporting it as a rejection instead would
            %% classify every throwing handler as the game refusing the input.
            run_input_batch(Rest, Enc, LuaSt0, ZoneState1, [ok | Acc])
    end.

-doc """
What a script's `handle_input` return means for the table the batch is carrying.

`{keep, Enc1, Outcome}` takes what the script returned. `{revert, Outcome}`
means it returned nothing usable, and `run_input_batch/5` then drops the Luerl
state the call produced.

Dropping the state is what makes an empty return mean the same thing here as it
does under `handle_input/3` **for the entities**. It is wider than that in one
respect worth knowing: the Luerl state is the whole VM, so anything else the
call did - a global it wrote, randomness it consumed - goes with the revert,
where `handle_input/3` kept it. A handler that counts strikes in a global on its
reject path has to keep that count in `game_state` or in an entity instead. There, the module gets a fresh copy of the entity
map per input, so a mutation it made and did not return is discarded because
Erlang still holds the original. Here the script is handed the table itself, and
there is no Erlang-side copy to fall back on - but the Luerl state is
functional, so reverting to the state from before the call reverts the heap the
mutation lives in. It costs nothing and it is the difference between "returning
nothing rejects the input" and "returning nothing keeps whatever you touched,
including another player's entity". Under ADR 0015's `owned` mode the state is
not the caller's to drop, so the same revert is asked of the VM explicitly -
see `asobi_lua_loader:revert/1`.

The same revert runs on a Lua exception, which is why a raising handler leaves
no input frame behind either.
""".
batch_result([], _ZoneState) ->
    {revert, ok};
%% A Luerl table reference is a tuple, so anything else is a script returning a
%% scalar where entities belong. Stated as what is ACCEPTED rather than as a
%% list of rejects: the accepted value is threaded onward as `Enc` and written
%% into `_G` by anchor_ref/2, so it has to be a reference and nothing else.
batch_result([Ents | _Rest], ZoneState) when not is_tuple(Ents) ->
    log_invalid_input_return(ZoneState),
    {revert, ok};
batch_result([Ents | Rest], ZoneState) ->
    case Rest of
        [] ->
            {keep, Ents, ok};
        [Consumed | _] ->
            case consumed_seq(Consumed) of
                {ok, Seq} ->
                    {keep, Ents, {consumed, Seq}};
                none ->
                    {keep, Ents, ok};
                invalid ->
                    log_invalid_input_return(ZoneState),
                    {keep, Ents, ok}
            end
    end.

-spec post_tick(non_neg_integer(), map()) ->
    {ok, map()} | {vote, map(), map()} | {finished, map(), map()}.
post_tick(TickN, State0) ->
    %% Hot-reload the world-level script (separate from per-zone reload in
    %% zone_tick). Reloading at world level keeps phases, post_tick, and
    %% on_phase_* callbacks in sync with on-disk edits.
    %% #536: collect ahead of the callback - see zone_tick/2.
    #{lua_state := LuaSt, game_state := GS} =
        State = asobi_lua_loader:collect_state(asobi_lua_reload:maybe_hot_reload(State0)),
    case asobi_lua_loader:call(post_tick, [TickN, GS], LuaSt, ?TICK_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            Outcome = check_post_tick_result(GS1, LuaSt1),
            State1 = State#{lua_state => LuaSt1, game_state => GS1},
            case Outcome of
                ok ->
                    {ok, State1};
                {vote, VoteConfig} ->
                    {vote, VoteConfig, State1};
                {finished, Result} ->
                    {finished, Result, State1}
            end;
        {error, Reason} ->
            log_lua_error(post_tick, Reason, State),
            {ok, State}
    end.

-spec generate_world(integer(), map()) -> {ok, map()}.
generate_world(Seed, #{lua_state := LuaSt} = State) ->
    %% generate_world is optional (see moduledoc) - asobi_lua_loader:call/4
    %% cannot tell "never defined" apart from "defined and raised", both
    %% surface as {error, {lua_error, _}} - so probe first. Only a script
    %% that DOES define it and then fails gets logged.
    case asobi_lua_loader:is_defined(generate_world, LuaSt) of
        false ->
            {ok, #{}};
        true ->
            case asobi_lua_loader:call(generate_world, [Seed, #{}], LuaSt, ?GENERATE_TIMEOUT) of
                {ok, [ZoneStates | _], LuaSt1} ->
                    {ok, decode_zone_states(ZoneStates, LuaSt1)};
                {error, Reason} ->
                    log_lua_error(generate_world, Reason, State),
                    {ok, #{}}
            end
    end;
generate_world(Seed, Config) when is_map(Config) ->
    %% Called by asobi_world_server before init/1 has run, so no lua_state is
    %% threaded through. Build a fresh luerl state to ask the script for zone
    %% coords, then give each returned zone its own luerl state so subsequent
    %% zone_tick/handle_input calls can invoke Lua callbacks. Only used to ask
    %% the script for zone coords + initial per-zone state - each zone builds
    %% its own VM later, in its own process, via init_zone_state/2.
    %%
    %% match_pid in the ctx is the caller of generate_world/2 - typically
    %% asobi_world_server, not a match process. game.broadcast emitted from a
    %% script's generate_world callback therefore reaches the world server,
    %% mirroring how broadcast already routed pre-fix.
    case boot_throwaway_lua_state(Config, generate_world) of
        {ok, DelegateState} -> generate_world(Seed, DelegateState);
        {error, _} -> {ok, #{}}
    end.

-spec get_state(binary(), map()) -> map().
get_state(PlayerId, #{lua_state := LuaSt, game_state := GS}) ->
    case asobi_lua_loader:call(get_state, [PlayerId, GS], LuaSt, ?GET_STATE_TIMEOUT) of
        {ok, [PlayerState | _], LuaSt1} ->
            decode_to_map(PlayerState, LuaSt1);
        {error, _} ->
            #{}
    end.

%% --- Phase callbacks ---

-spec phases(map()) -> [map()].
phases(#{lua_state := LuaSt} = State) ->
    %% Optional callback - see generate_world/2's is_defined comment above.
    case asobi_lua_loader:is_defined(phases, LuaSt) of
        false ->
            [];
        true ->
            case asobi_lua_loader:call(phases, [#{}], LuaSt, ?INIT_TIMEOUT) of
                {ok, [PhasesRef | _], LuaSt1} ->
                    decode_phases(PhasesRef, LuaSt1);
                {error, Reason} ->
                    log_lua_error(phases, Reason, State),
                    []
            end
    end;
phases(Config) when is_map(Config) ->
    %% Called by asobi_world_server:init/1 with GameConfig directly - the same
    %% map GameMod:init/1 itself receives - so lua_script lives at this map's
    %% top level (no game_config unwrap needed, unlike spawn_templates/1 and
    %% terrain_provider/1 below). boot_throwaway_lua_state/2 resolves both
    %% shapes via make_ctx/1.
    case boot_throwaway_lua_state(Config, phases) of
        {ok, DelegateState} -> phases(DelegateState);
        {error, _} -> []
    end;
phases(_) ->
    [].

-spec on_phase_started(binary(), map()) -> {ok, map()}.
on_phase_started(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_started, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

-spec on_phase_ended(binary(), map()) -> {ok, map()}.
on_phase_ended(PhaseName, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_phase_ended, [PhaseName, GS], LuaSt, ?PHASE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Spawn templates ---

-spec spawn_templates(map()) -> #{binary() => asobi_zone_spawner:spawn_template()}.
spawn_templates(#{lua_state := LuaSt} = State) ->
    %% Optional callback - see generate_world/2's is_defined comment above.
    case asobi_lua_loader:is_defined(spawn_templates, LuaSt) of
        false ->
            #{};
        true ->
            case asobi_lua_loader:call(spawn_templates, [#{}], LuaSt, ?INIT_TIMEOUT) of
                {ok, [TemplatesRef | _], LuaSt1} ->
                    decode_spawn_templates(TemplatesRef, LuaSt1);
                {error, Reason} ->
                    log_lua_error(spawn_templates, Reason, State),
                    #{}
            end
    end;
spawn_templates(Config) when is_map(Config) ->
    %% Called by asobi_world_server:configure_zone_manager/1 with the raw
    %% world config (game_config nested inside) - no lua_state threaded
    %% through, since GameMod:init/1 already ran but its result was never
    %% passed here. Same gap as generate_world/2's raw-config clause.
    case boot_throwaway_lua_state(Config, spawn_templates) of
        {ok, DelegateState} -> spawn_templates(DelegateState);
        {error, _} -> #{}
    end;
spawn_templates(_) ->
    #{}.

%% asobi#253: maybe_hot_reload/1 stamps `just_reloaded => true` on the zone
%% state for exactly the tick it swaps in a freshly-reloaded lua_state.
%%
%% This deliberately does NOT delegate to spawn_templates/1: that function
%% collapses "not defined" and "the Lua call raised/timed out" to the same
%% #{} result, which is correct at zone creation (an empty template set is
%% the right starting point either way) but wrong here - spawn_templates_hint
%% REPLACES the zone's whole live template set (asobi_zone_spawner:set_templates/2),
%% so a broken hot-edit would silently wipe every spawnable template out of an
%% already-running zone. Only a genuine successful decode is reported as
%% {changed, _}; "not defined" and "call failed" both leave the zone's
%% existing templates alone. Requires lua_state directly (rather than falling
%% through to spawn_templates/1's raw-config clause) so a state that somehow
%% lost its lua_state can't trigger an expensive throwaway-VM boot every tick.
-spec spawn_templates_hint(map()) ->
    unchanged | {changed, #{binary() => asobi_zone_spawner:spawn_template()}}.
spawn_templates_hint(#{just_reloaded := true, lua_state := LuaSt} = State) ->
    case asobi_lua_loader:is_defined(spawn_templates, LuaSt) of
        false ->
            unchanged;
        true ->
            case asobi_lua_loader:call(spawn_templates, [#{}], LuaSt, ?INIT_TIMEOUT) of
                {ok, [TemplatesRef | _], LuaSt1} ->
                    New = decode_spawn_templates(TemplatesRef, LuaSt1),
                    %% Refresh the live set the zone's own Luerl closures read
                    %% at call time - see ?TEMPLATES_KEY above. Without this,
                    %% asobi_zone_spawner learns about the reloaded template
                    %% (via the {changed, New} return below) but
                    %% game.zone.spawn keeps rejecting it forever.
                    put_known_templates(State, New),
                    {changed, New};
                {error, Reason} ->
                    log_lua_error(spawn_templates_hint, Reason, State),
                    unchanged
            end
    end;
spawn_templates_hint(_State) ->
    unchanged.

put_known_templates(#{templates_tab := Tab}, Templates) when is_map(Templates) ->
    ets:insert(Tab, {?TEMPLATES_KEY, Templates});
put_known_templates(_State, _Templates) ->
    ok.

%% --- World recovery ---

-spec on_world_recovered(map(), map()) -> {ok, map()}.
on_world_recovered(Snapshots, #{lua_state := LuaSt, game_state := GS} = State) ->
    {EncSnap, LuaSt1} = asobi_lua_loader:encode(Snapshots, LuaSt),
    case asobi_lua_loader:call(on_world_recovered, [EncSnap, GS], LuaSt1, ?INIT_TIMEOUT) of
        {ok, [GS1 | _], LuaSt2} ->
            {ok, State#{lua_state => LuaSt2, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Terrain & zone lifecycle ---

-spec terrain_provider(map()) -> {module(), map()} | none.
terrain_provider(#{lua_state := LuaSt} = State) ->
    %% Optional callback - see generate_world/2's is_defined comment above.
    case asobi_lua_loader:is_defined(terrain_provider, LuaSt) of
        false ->
            none;
        true ->
            case asobi_lua_loader:call(terrain_provider, [#{}], LuaSt, ?INIT_TIMEOUT) of
                {ok, [Result | _], LuaSt1} ->
                    decode_terrain_provider(Result, LuaSt1);
                {error, Reason} ->
                    log_lua_error(terrain_provider, Reason, State),
                    none
            end
    end;
terrain_provider(Config) when is_map(Config) ->
    %% Same raw-config gap as spawn_templates/1 above.
    case boot_throwaway_lua_state(Config, terrain_provider) of
        {ok, DelegateState} -> terrain_provider(DelegateState);
        {error, _} -> none
    end;
terrain_provider(_) ->
    none.

-spec on_zone_loaded({integer(), integer()}, map()) -> {ok, map(), map()}.
on_zone_loaded({CX, CY}, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_zone_loaded, [CX, CY, GS], LuaSt, ?ZONE_LIFECYCLE_TIMEOUT) of
        {ok, [ZS, GS1 | _], LuaSt1} ->
            ZoneState = decode_to_map(ZS, LuaSt1),
            {ok, ZoneState, State#{lua_state => LuaSt1, game_state => GS1}};
        {ok, [ZS | _], LuaSt1} ->
            ZoneState = decode_to_map(ZS, LuaSt1),
            {ok, ZoneState, State#{lua_state => LuaSt1}};
        {error, _} ->
            {ok, #{}, State}
    end.

-spec on_zone_unloaded({integer(), integer()}, map()) -> {ok, map()}.
on_zone_unloaded({CX, CY}, #{lua_state := LuaSt, game_state := GS} = State) ->
    case asobi_lua_loader:call(on_zone_unloaded, [CX, CY, GS], LuaSt, ?ZONE_LIFECYCLE_TIMEOUT) of
        {ok, [GS1 | _], LuaSt1} ->
            {ok, State#{lua_state => LuaSt1, game_state => GS1}};
        {error, _} ->
            {ok, State}
    end.

%% --- Internal ---

%% H-2: a Lua script can return any binary as `module`. Without an
%% allowlist, the bridge would `binary_to_existing_atom` and call
%% `Mod:init/1`, `Mod:load_chunk/2`, `Mod:generate_chunk/3` on whichever
%% loaded module the script names — including unrelated OTP modules
%% (`gen_server`, `rpc`, `application`, etc.). Treat the set of valid
%% terrain providers as a small explicit list, configurable via env so
%% operators shipping new providers can extend it without code changes.
-define(DEFAULT_TERRAIN_PROVIDERS, [
    asobi_terrain_flat,
    asobi_terrain_perlin
]).

decode_terrain_provider(Result, LuaSt) ->
    Decoded = asobi_lua_loader:decode(Result, LuaSt),
    case Decoded of
        nil ->
            none;
        false ->
            none;
        Props when is_list(Props) ->
            Module = proplists:get_value(~"module", Props),
            Args = proplists:get_value(~"args", Props, []),
            case Module of
                undefined ->
                    none;
                ModBin when is_binary(ModBin) ->
                    case lookup_allowed_provider(ModBin) of
                        {ok, Mod} ->
                            DecodedArgs = deep_decode(Args),
                            ProvArgs =
                                case is_map(DecodedArgs) of
                                    true -> DecodedArgs;
                                    false -> #{}
                                end,
                            {Mod, ProvArgs};
                        not_allowed ->
                            ?LOG_WARNING(#{
                                msg => ~"terrain_provider_not_allowed",
                                requested => ModBin
                            }),
                            none
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end.

-spec lookup_allowed_provider(binary()) -> {ok, atom()} | not_allowed.
lookup_allowed_provider(ModBin) ->
    Allowed = allowed_terrain_providers(),
    AllowedBins = [atom_to_binary(M, utf8) || M <- Allowed],
    case lists:member(ModBin, AllowedBins) of
        true ->
            try
                {ok, binary_to_existing_atom(ModBin, utf8)}
            catch
                _:_ -> not_allowed
            end;
        false ->
            not_allowed
    end.

-spec allowed_terrain_providers() -> [atom()].
allowed_terrain_providers() ->
    case asobi_lua_env:get_env(terrain_providers, ?DEFAULT_TERRAIN_PROVIDERS) of
        L when is_list(L) -> [M || M <- L, is_atom(M)];
        _ -> ?DEFAULT_TERRAIN_PROVIDERS
    end.

%% Logs Lua callback failures uniformly. Pre-fix, leave/spawn_position/
%% zone_tick/handle_input swallowed errors silently and only post_tick logged
%% — so a broken Lua script could degrade gameplay invisibly. State is either
%% the world State (carries `script`) or a per-zone ZoneState (may not).
%%
%% asobi#252: zone_tick/1 and handle_input/3 run per-tick - a script that
%% fails on every tick would otherwise log once per tick forever. The log
%% line is rate-limited per {Script, Callback} via asobi_script_log_limiter
%% (shared with asobi's own log_spawn_failed/3); the telemetry emit below
%% stays unconditional so dashboards/alerts see the true failure rate.
log_lua_error(Callback, Reason, StateOrZoneState) ->
    Script = maps:get(script, StateOrZoneState, ~"<unknown>"),
    Severity =
        case Reason of
            timeout -> ~"timeout";
            _ -> ~"error"
        end,
    %% The raw reason can embed player input via Lua error()/assert() and is
    %% unbounded - log a classified, capped rendering so a failing callback
    %% under input load cannot amplify into the logs.
    case asobi_script_log_limiter:allow({Script, Callback}) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"lua callback failed",
                callback => Callback,
                severity => Severity,
                script => Script,
                reason_class => asobi_lua_game_error:reason_class(Reason),
                detail => asobi_lua_game_error:format_reason(Reason),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end,
    asobi_lua_game_error:emit(Callback, Reason, Script).

decode_position(PosTable, LuaSt) ->
    case asobi_lua_loader:decode(PosTable, LuaSt) of
        Decoded when is_list(Decoded) ->
            X = proplists:get_value(~"x", Decoded, 0.0),
            Y = proplists:get_value(~"y", Decoded, 0.0),
            {to_number(X), to_number(Y)};
        _ ->
            {0.0, 0.0}
    end.

check_post_tick_result(GS, LuaSt) ->
    try
        case asobi_lua_loader:get_table_key(GS, ~"_finished", LuaSt) of
            {ok, true, LuaSt1} ->
                case asobi_lua_loader:get_table_key(GS, ~"_result", LuaSt1) of
                    {ok, ResRef, LuaSt2} -> {finished, decode_to_map(ResRef, LuaSt2)};
                    _ -> {finished, #{}}
                end;
            _ ->
                case asobi_lua_loader:get_table_key(GS, ~"_vote", LuaSt) of
                    {ok, VoteRef, LuaSt1} when VoteRef =/= nil, VoteRef =/= false ->
                        {vote, decode_to_map(VoteRef, LuaSt1)};
                    _ ->
                        ok
                end
        end
    catch
        _:_ -> ok
    end.

decode_zone_states(ZoneStatesRef, LuaSt) ->
    case asobi_lua_loader:decode(ZoneStatesRef, LuaSt) of
        Decoded when is_list(Decoded) -> decode_zone_states_acc(Decoded, #{});
        _ -> #{}
    end.

-spec decode_zone_states_acc(list(), map()) -> map().
decode_zone_states_acc([], Acc) ->
    Acc;
decode_zone_states_acc([{Key, Val} | Rest], Acc) when is_binary(Key) ->
    case parse_coords(Key) of
        {ok, Coords} -> decode_zone_states_acc(Rest, Acc#{Coords => deep_decode(Val)});
        error -> decode_zone_states_acc(Rest, Acc)
    end;
decode_zone_states_acc([_ | Rest], Acc) ->
    decode_zone_states_acc(Rest, Acc).

decode_phases(PhasesRef, LuaSt) ->
    asobi_lua_phases:decode_phases(PhasesRef, LuaSt).

parse_coords(Bin) ->
    case binary:split(Bin, ~",") of
        [XBin, YBin] ->
            try
                X = binary_to_integer(XBin),
                Y = binary_to_integer(YBin),
                {ok, {X, Y}}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

%% `handle_input` returns entities, and optionally the client seq the script has
%% consumed. The seq becomes that player's world.ack instead of the seq stamped
%% on the frame, so a script that batches several simulation steps into one
%% frame acks what it RAN rather than what ARRIVED (see the `asobi_world`
%% callback). An empty return list is a script whose handle_input returns
%% nothing: leave the entities alone rather than crashing the shared zone.
input_result([], _LuaSt, Entities, _ZoneState) ->
    {ok, Entities};
input_result([Ents | _Rest], _LuaSt, Entities, ZoneState) when
    not is_tuple(Ents), not is_map(Ents), not is_list(Ents)
->
    %% `return nil, 5` or `return "ok"`. decode_to_map/2 case_clauses on a
    %% scalar, one line from the guard above, and this runs in the zone process
    %% - so the same author mistake that used to kill every player in the zone
    %% would just kill them a different way.
    log_invalid_input_return(ZoneState),
    {ok, Entities};
input_result([Ents | Rest], LuaSt, _Entities, ZoneState) ->
    Decoded = asobi_lua_api:atomize_entities(decode_to_map(Ents, LuaSt)),
    case Rest of
        [] ->
            {ok, Decoded};
        [Consumed | _] ->
            case consumed_seq(Consumed) of
                {ok, Seq} ->
                    {ok, Decoded, Seq};
                none ->
                    {ok, Decoded};
                invalid ->
                    log_invalid_input_return(ZoneState),
                    {ok, Decoded}
            end
    end.

%% Its own limiter bucket, for the same reason log_invalid_input_return/1 below
%% has one: keying on {Script, Callback} the way log_lua_error/3 does would let
%% script-driven noise exhaust the budget real Lua exceptions are logged from.
log_anchor_cleared(ZoneState) ->
    Script = maps:get(script, ZoneState, ~"<unknown>"),
    case asobi_script_log_limiter:allow({Script, anchor_cleared}) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg =>
                    ~"lua script cleared asobi's reference anchor; this tick's inputs were dropped",
                script => asobi_lua_game_error:script_basename(Script),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

log_invalid_input_return(ZoneState) ->
    Script = maps:get(script, ZoneState, ~"<unknown>"),
    case asobi_script_log_limiter:allow({Script, invalid_input_return}) of
        {true, SuppressedSinceLast} ->
            ?LOG_WARNING(#{
                msg => ~"lua handle_input returned something that is not entities and a seq",
                script => asobi_lua_game_error:script_basename(Script),
                suppressed_since_last => SuppressedSinceLast
            });
        false ->
            ok
    end.

%% Deliberately NOT asobi_lua_phases:to_integer/1, which turns anything
%% non-numeric into 0 - acking seq 0 would tell the client the server had
%% consumed nothing, which is a worse answer than falling back to the frame
%% stamp. An explicit `nil` is the ordinary "no ack for this input" case a
%% script writes when it has nothing new to report, so it is not an error.
%%
%% Shape-guarded rather than decoded. luerl carries a Lua number as a plain
%% Erlang number, so there is nothing to decode - and luerl:decode/2 raises
%% `recursive_table` on a self-referential table, which here would be an
%% uncaught exit in the zone process (this runs after asobi_lua_loader:call/3
%% has returned, so nothing is guarding it any more). ?MAX_ACK_SEQ is enforced
%% before trunc/1, which happily mints a 309-digit integer out of 1e308.
consumed_seq(nil) ->
    none;
consumed_seq(N) when is_number(N), N >= 0, N =< ?MAX_ACK_SEQ ->
    {ok, trunc(N)};
consumed_seq(_) ->
    invalid.

decode_to_map(Term, LuaSt) ->
    asobi_lua_api:decode_to_map(Term, LuaSt).

deep_decode(Term) ->
    asobi_lua_api:deep_decode(Term).

to_number(N) when is_number(N) -> N;
to_number(_) -> 0.0.

to_integer(N) ->
    asobi_lua_phases:to_integer(N).

decode_spawn_templates(TemplatesRef, LuaSt) ->
    case asobi_lua_loader:decode(TemplatesRef, LuaSt) of
        Decoded when is_list(Decoded) -> decode_spawn_templates_acc(Decoded, #{});
        _ -> #{}
    end.

-spec decode_spawn_templates_acc(list(), map()) -> map().
decode_spawn_templates_acc([], Acc) ->
    Acc;
decode_spawn_templates_acc([{TemplateId, Props} | Rest], Acc) when
    is_binary(TemplateId), is_list(Props)
->
    Type = proplists:get_value(~"type", Props, ~"npc"),
    BaseState = deep_decode(proplists:get_value(~"base_state", Props, [])),
    %% asobi_zone_spawner merges base_state straight into the new entity, and
    %% every atom-keyed consumer in asobi_zone (snapshot_entities' `persistent`
    %% read, the crossing clauses, asobi_spatial) then reads it. Without this
    %% the entity is binary-keyed until the next zone_tick round-trip happens
    %% to atomize it - the same gap asobi#270 closed for tick results.
    Base =
        case is_map(BaseState) of
            true -> asobi_lua_api:atomize_keys(BaseState);
            false -> #{}
        end,
    Template = #{
        template_id => TemplateId,
        type => Type,
        base_state => Base,
        persistent => proplists:get_value(~"persistent", Props, true),
        respawn => decode_respawn_rule(proplists:get_value(~"respawn", Props, nil))
    },
    decode_spawn_templates_acc(Rest, Acc#{TemplateId => Template});
decode_spawn_templates_acc([_ | Rest], Acc) ->
    decode_spawn_templates_acc(Rest, Acc).

decode_respawn_rule(nil) ->
    undefined;
decode_respawn_rule(false) ->
    undefined;
decode_respawn_rule(Props) when is_list(Props) ->
    #{
        strategy => timer,
        delay => to_integer(proplists:get_value(~"delay", Props, 0)),
        max_respawns => decode_max_respawns(
            proplists:get_value(~"max_respawns", Props, nil)
        ),
        jitter => to_integer(proplists:get_value(~"jitter", Props, 0))
    };
decode_respawn_rule(_) ->
    undefined.

decode_max_respawns(nil) -> infinity;
decode_max_respawns(N) when is_number(N) -> trunc(N);
decode_max_respawns(_) -> infinity.

%% Build this zone's Luerl VM in the zone process, so it binds to the zone pid
%% (self()) and game.zone.spawn / zone-based game.spatial / game.terrain resolve.
%% Called once via asobi_zone's handle_continue, for every zone-creation path
%% (pre-spawned, lazy, recovered). Re-encodes gameplay state from a prior
%% snapshot if present; the VM itself is never persisted, only rebuilt here.
-spec init_zone_state(map(), term()) -> map().
init_zone_state(Config, ZoneState00) ->
    %% An empty Lua zone table decodes to [], not #{}; coerce before merging.
    ZoneState0 =
        case ZoneState00 of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    GameConfig = maps:get(game_config, Config, #{}),
    case maps:get(lua_script, GameConfig, undefined) of
        undefined ->
            ZoneState0;
        ScriptPath ->
            %% asobi_lua#110: ask the script for its declared template set up
            %% front (a throwaway VM, same mechanism as spawn_templates/1's
            %% raw-config clause) and stash it in a fresh, per-zone ETS table
            %% before the per-zone VM's game.zone.spawn is ever callable.
            %% game.zone.spawn checks membership against that live table
            %% synchronously, instead of round-tripping the self-cast to
            %% asobi_zone (which would deadlock - the zone's Luerl VM runs
            %% inside the zone process itself). Unlike a Ctx-cached snapshot,
            %% this stays current: a later hot reload overwrites the same
            %% table's row from spawn_templates_hint/1 above. `protected`
            %% (the default) is deliberate: only this (owning, zone) process
            %% ever writes; asobi_lua_api:known_template/2 reads it from
            %% whichever process is actually running the Lua closure at the
            %% time (see ?TEMPLATES_KEY's comment - not necessarily this
            %% one). The table dies with the zone process, so it never leaks.
            Templates = spawn_templates(Config),
            TemplatesTab = ets:new(asobi_lua_zone_templates, [set, protected]),
            ets:insert(TemplatesTab, {?TEMPLATES_KEY, Templates}),
            PreInstall = fun(St) -> asobi_lua_api:install(zone_ctx(Config, TemplatesTab), St) end,
            case asobi_lua_loader:new(ScriptPath, ?GENERATE_TIMEOUT, PreInstall) of
                {ok, LuaSt0} ->
                    {GameState, LuaSt1} = restore_game_state(ZoneState0, LuaSt0),
                    ZoneState0#{
                        lua_state => LuaSt1,
                        game_state => GameState,
                        script => ScriptPath,
                        script_mtime => filelib:last_modified(ScriptPath),
                        templates_tab => TemplatesTab,
                        %% #536: identity for `[asobi, lua, state]`. Every zone
                        %% in a world runs the same script, so without these
                        %% they all report under one label set. Not persisted -
                        %% dump_zone_state/1 carries game_state only.
                        lua_bridge => #{
                            kind => zone,
                            world_id => maps:get(world_id, Config, undefined),
                            coords => maps:get(coords, Config, undefined)
                        }
                    };
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg =>
                            ~"asobi_lua_world init_zone_state: lua_loader:new failed; zone Lua inert",
                        script => ScriptPath,
                        reason => Reason
                    }),
                    ZoneState0
            end
    end.

%% Inverse of init_zone_state's restore path: drop the non-serialisable VM and
%% decode the script's gameplay state to a plain, JSON-safe map for jsonb.
%% game_state is the sole canonical persisted field; other per-zone keys are
%% rebuilt from config on init, so they are intentionally not carried here.
%% A never-seeded zone (game_state nil) round-trips as null, not #{}, so the
%% script's `game_state == nil` initialisation guard still fires after recovery.
-spec dump_zone_state(map()) -> map().
dump_zone_state(#{lua_state := LuaSt} = ZoneState) ->
    GameState =
        case maps:get(game_state, ZoneState, nil) of
            nil -> null;
            GS -> decode_to_map(GS, LuaSt)
        end,
    #{~"game_state" => GameState};
dump_zone_state(ZoneState) ->
    maps:remove(lua_state, ZoneState).

-spec restore_game_state(map(), dynamic()) -> {dynamic(), dynamic()}.
restore_game_state(ZoneState0, LuaSt) ->
    case maps:get(~"game_state", ZoneState0, undefined) of
        Map when is_map(Map) -> asobi_lua_loader:encode(Map, LuaSt);
        _ -> {nil, LuaSt}
    end.

-spec zone_ctx(map(), ets:table()) -> map().
zone_ctx(Config, TemplatesTab) ->
    GameConfig = maps:get(game_config, Config, #{}),
    #{
        vm => zone,
        zone_pid => self(),
        match_pid => maps:get(world_server_pid, Config, self()),
        match_id => maps:get(match_id, GameConfig, maps:get(world_id, Config, undefined)),
        %% The zone's own identity in the grid, for the neighbour-facing calls.
        %% Fixed for the zone's life, so a Ctx snapshot is correct here in a way
        %% it is not for the template set above.
        world_id => maps:get(world_id, Config, undefined),
        coords => maps:get(coords, Config, undefined),
        zone_size => maps:get(zone_size, Config, undefined),
        grid_size => maps:get(grid_size, Config, undefined),
        border_tab => maps:get(border_tab, Config, undefined),
        script => maps:get(lua_script, GameConfig, undefined),
        %% asobi_lua#110 + asobi#253: NOT a known_templates snapshot here -
        %% a table reference, not the map value. asobi_lua_api:known_template/2
        %% reads the live row from this table at call time, so it survives
        %% any number of hot reloads. See ?TEMPLATES_KEY's comment above.
        templates_tab => TemplatesTab
    }.

%% Config is either the game_config directly (init/1, phases/1 - lua_script
%% at the top level) or the full outer world config with game_config nested
%% (generate_world/2, spawn_templates/1, terrain_provider/1's raw-config
%% clauses). Resolving both shapes here - rather than assuming one - is what
%% zone_ctx/1 already does for the per-zone ctx; this mirrors it so
%% game.log/game.error from these callbacks carry a real script/match_id
%% instead of <unknown>/undefined.
-spec make_ctx(map()) -> map().
make_ctx(Config) ->
    GameConfig = maps:get(game_config, Config, Config),
    #{
        vm => world,
        match_id => maps:get(match_id, GameConfig, maps:get(world_id, Config, undefined)),
        match_pid => self(),
        script => maps:get(lua_script, GameConfig, undefined)
    }.

%% Init-time callbacks (spawn_templates/1, terrain_provider/1, phases/1,
%% generate_world/2) are invoked by asobi_world_server with the raw world
%% config - no lua_state threaded through, since GameMod:init/1 hasn't run yet
%% (mirrors generate_world/2's raw-config clause). Boot a throwaway luerl
%% state just to ask the script the one question, then let it get GC'd.
%% Boots the VM at ?GENERATE_TIMEOUT (not ?INIT_TIMEOUT) - init_zone_state/2
%% and generate_world/2 already load this same file at that budget, and a
%% script large enough to matter shouldn't load fine for one caller and time
%% out for another. Returns a ready-to-delegate state map (script alongside
%% lua_state) so the caller's #{lua_state := _} clause can log a real script
%% path instead of <unknown> if the subsequent Lua call itself fails.
%%
%% Installs with a `probe => true` Ctx (kept separate from the plain `Ctx`
%% used for logging/make_ctx, which init/1's real VM boot also builds via
%% make_ctx/1) so asobi_lua_api:install/2 stubs out every effectful game.*
%% function - booting this VM re-runs the script's whole top-level body, and
%% without the marker a top-level side-effecting call would fire a second
%% time per throwaway boot (see security review on widgrensit/asobi_lua#109
%% / #117).
-spec boot_throwaway_lua_state(map(), atom()) -> {ok, map()} | {error, term()}.
boot_throwaway_lua_state(Config, Caller) ->
    Ctx = make_ctx(Config),
    case maps:get(script, Ctx, undefined) of
        ScriptPath when is_binary(ScriptPath); is_list(ScriptPath) ->
            ProbeCtx = Ctx#{probe => true},
            PreInstall = fun(St) -> asobi_lua_api:install(ProbeCtx, St) end,
            % Copied, never owned: this state answers one question and is
            % dropped, so an ADR 0015 VM here would be a process nothing stops.
            case asobi_lua_loader:new_copied(ScriptPath, ?GENERATE_TIMEOUT, PreInstall) of
                {ok, LuaSt} ->
                    {ok, #{lua_state => LuaSt, script => ScriptPath}};
                {error, Reason} ->
                    log_lua_error(Caller, Reason, Ctx),
                    {error, Reason}
            end;
        _ ->
            {error, missing_lua_script}
    end.
