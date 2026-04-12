-module(asobi_zone_spawner).

%% Pure functional spawn template registry with respawn queue.
%% Stored in zone state, ticked each zone tick.

-export([new/1, new/0]).
-export([spawn_entity/3, spawn_entity/4, spawn_entity/5]).
-export([entity_removed/3, tick/2]).
-export([get_templates/1, get_spawn_count/2, info/1]).
-export([set_templates/2]).
-export([serialise/1, deserialise/1]).

-export_type([state/0, spawn_template/0, respawn_rule/0]).

-type spawn_template() :: #{
    template_id := binary(),
    type := binary(),
    base_state := map(),
    persistent => boolean(),
    respawn => respawn_rule() | undefined
}.

-type respawn_rule() :: #{
    strategy := timer,
    delay := non_neg_integer(),
    max_respawns => non_neg_integer() | infinity,
    jitter => non_neg_integer()
}.

-type spawn_request() :: #{
    template_id := binary(),
    entity_id := binary(),
    position := {number(), number()},
    overrides := map(),
    respawn_at := pos_integer()
}.

-opaque state() :: #{
    templates := #{binary() => spawn_template()},
    respawn_queue := [spawn_request()],
    spawn_counts := #{binary() => non_neg_integer()},
    entity_templates := #{binary() => binary()},
    entity_positions := #{binary() => {number(), number()}}
}.

%% -------------------------------------------------------------------
%% Constructor
%% -------------------------------------------------------------------

-spec new() -> state().
new() ->
    new(#{}).

-spec new(#{binary() => spawn_template()}) -> state().
new(Templates) ->
    #{
        templates => Templates,
        respawn_queue => [],
        spawn_counts => #{},
        entity_templates => #{},
        entity_positions => #{}
    }.

%% -------------------------------------------------------------------
%% Spawn an entity from a template
%% -------------------------------------------------------------------

-spec spawn_entity(binary(), {number(), number()}, state()) ->
    {ok, {binary(), map()}, state()} | {error, unknown_template}.
spawn_entity(TemplateId, Pos, State) ->
    spawn_entity(TemplateId, Pos, #{}, State).

-spec spawn_entity(binary(), {number(), number()}, map(), state()) ->
    {ok, {binary(), map()}, state()} | {error, unknown_template}.
spawn_entity(TemplateId, Pos, Overrides, State) ->
    EntityId = asobi_id:generate(),
    spawn_entity(TemplateId, EntityId, Pos, Overrides, State).

-spec spawn_entity(binary(), binary(), {number(), number()}, map(), state()) ->
    {ok, {binary(), map()}, state()} | {error, unknown_template}.
spawn_entity(TemplateId, EntityId, {X, Y} = Pos, Overrides, #{templates := Templates} = State) ->
    case maps:find(TemplateId, Templates) of
        {ok, #{type := Type, base_state := Base}} ->
            Entity = maps:merge(Base, Overrides),
            Entity1 = Entity#{x => X, y => Y, type => Type},
            #{
                spawn_counts := Counts,
                entity_templates := ET,
                entity_positions := EP
            } = State,
            Count = maps:get(TemplateId, Counts, 0),
            State1 = State#{
                spawn_counts => Counts#{TemplateId => Count + 1},
                entity_templates => ET#{EntityId => TemplateId},
                entity_positions => EP#{EntityId => Pos}
            },
            {ok, {EntityId, Entity1}, State1};
        error ->
            {error, unknown_template}
    end.

%% -------------------------------------------------------------------
%% Notify entity removed — schedules respawn if applicable
%% -------------------------------------------------------------------

-spec entity_removed(binary(), pos_integer(), state()) -> state().
entity_removed(EntityId, Now, #{entity_templates := ET} = State) ->
    case maps:find(EntityId, ET) of
        {ok, TemplateId} ->
            schedule_respawn(EntityId, TemplateId, Now, State);
        error ->
            State
    end.

schedule_respawn(EntityId, TemplateId, Now, #{templates := Templates} = State) ->
    case maps:find(TemplateId, Templates) of
        {ok, #{respawn := #{strategy := timer, delay := Delay} = Rule}} ->
            MaxRespawns = maps:get(max_respawns, Rule, infinity),
            #{spawn_counts := Counts} = State,
            Count = maps:get(TemplateId, Counts, 0),
            case MaxRespawns =:= infinity orelse Count < MaxRespawns of
                true ->
                    Jitter = maps:get(jitter, Rule, 0),
                    JitterMs =
                        case Jitter of
                            0 -> 0;
                            J -> rand:uniform(J)
                        end,
                    #{respawn_queue := Queue, entity_positions := EP} = State,
                    Pos = maps:get(EntityId, EP, {0.0, 0.0}),
                    Request = #{
                        template_id => TemplateId,
                        entity_id => EntityId,
                        position => Pos,
                        overrides => #{},
                        respawn_at => Now + Delay + JitterMs
                    },
                    State#{respawn_queue => [Request | Queue]};
                false ->
                    cleanup_entity(EntityId, State)
            end;
        _ ->
            cleanup_entity(EntityId, State)
    end.

%% -------------------------------------------------------------------
%% Tick — returns entities ready to respawn
%% -------------------------------------------------------------------

-spec tick(pos_integer(), state()) ->
    {[{binary(), map(), {number(), number()}}], state()}.
tick(Now, #{respawn_queue := Queue} = State) ->
    {Ready, Remaining} = lists:partition(
        fun(#{respawn_at := At}) -> Now >= At end,
        Queue
    ),
    process_respawns(Ready, [], State#{respawn_queue => Remaining}).

-spec process_respawns(
    [spawn_request()],
    [{binary(), map(), {number(), number()}}],
    state()
) ->
    {[{binary(), map(), {number(), number()}}], state()}.
process_respawns([], Acc, State) ->
    {Acc, State};
process_respawns(
    [#{template_id := TId, entity_id := EId, position := Pos, overrides := Ov} | Rest], Acc, State
) ->
    case spawn_entity(TId, EId, Pos, Ov, State) of
        {ok, {EId2, Entity}, State1} ->
            {X, Y} = Pos,
            process_respawns(Rest, [{EId2, Entity#{x => X, y => Y}, Pos} | Acc], State1);
        {error, _} ->
            process_respawns(Rest, Acc, State)
    end.

%% -------------------------------------------------------------------
%% Queries
%% -------------------------------------------------------------------

-spec get_templates(state()) -> #{binary() => spawn_template()}.
get_templates(#{templates := T}) -> T.

-spec set_templates(#{binary() => spawn_template()}, state()) -> state().
set_templates(Templates, State) ->
    State#{templates => Templates}.

-spec get_spawn_count(binary(), state()) -> non_neg_integer().
get_spawn_count(TemplateId, #{spawn_counts := C}) ->
    maps:get(TemplateId, C, 0).

-spec info(state()) -> map().
info(#{respawn_queue := Q, spawn_counts := C, entity_templates := ET}) ->
    #{
        pending_respawns => length(Q),
        total_spawned => maps:fold(fun(_, V, Acc) -> Acc + V end, 0, C),
        tracked_entities => map_size(ET)
    }.

%% -------------------------------------------------------------------
%% Serialisation (for zone snapshots)
%% -------------------------------------------------------------------

-spec serialise(state()) -> map().
serialise(#{
    respawn_queue := Queue,
    spawn_counts := Counts,
    entity_templates := ET,
    entity_positions := EP
}) ->
    #{
        ~"respawn_queue" => [serialise_request(R) || R <- Queue],
        ~"spawn_counts" => Counts,
        ~"entity_templates" => ET,
        ~"entity_positions" => maps:fold(
            fun(K, {X, Y}, Acc) -> Acc#{K => #{~"x" => X, ~"y" => Y}} end,
            #{},
            EP
        )
    }.

-spec deserialise(map()) -> state().
deserialise(Data) ->
    #{
        templates => #{},
        respawn_queue => [deserialise_request(R) || R <- maps:get(~"respawn_queue", Data, [])],
        spawn_counts => maps:get(~"spawn_counts", Data, #{}),
        entity_templates => maps:get(~"entity_templates", Data, #{}),
        entity_positions => maps:fold(
            fun(K, #{~"x" := X, ~"y" := Y}, Acc) -> Acc#{K => {X, Y}} end,
            #{},
            maps:get(~"entity_positions", Data, #{})
        )
    }.

%% -------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------

cleanup_entity(EntityId, #{entity_templates := ET, entity_positions := EP} = State) ->
    State#{
        entity_templates => maps:remove(EntityId, ET),
        entity_positions => maps:remove(EntityId, EP)
    }.

serialise_request(#{
    template_id := TId,
    entity_id := EId,
    position := {X, Y},
    overrides := Ov,
    respawn_at := At
}) ->
    #{
        ~"template_id" => TId,
        ~"entity_id" => EId,
        ~"position" => #{~"x" => X, ~"y" => Y},
        ~"overrides" => Ov,
        ~"respawn_at" => At
    }.

deserialise_request(#{
    ~"template_id" := TId,
    ~"entity_id" := EId,
    ~"position" := #{~"x" := X, ~"y" := Y},
    ~"overrides" := Ov,
    ~"respawn_at" := At
}) ->
    #{
        template_id => TId,
        entity_id => EId,
        position => {X, Y},
        overrides => Ov,
        respawn_at => At
    }.
