-module(asobi_world_controller).

-export([index/1, show/1, create/1]).

-spec index(map()) -> {json, map()}.
index(#{parsed_qs := QS}) ->
    Filters = build_filters(QS),
    Worlds = asobi_world_lobby:list_worlds(Filters),
    {json, #{worlds => Worlds}};
index(_Req) ->
    Worlds = asobi_world_lobby:list_worlds(),
    {json, #{worlds => Worlds}}.

-spec show(map()) -> {json, map()} | {status, 404}.
show(#{bindings := #{~"id" := WorldId}}) ->
    case asobi_world_server:whereis(WorldId) of
        {ok, Pid} ->
            Info = asobi_world_server:get_info(Pid),
            {json, Info};
        error ->
            {status, 404}
    end.

-spec create(map()) -> {json, map(), integer()} | {status, 400}.
create(#{json := #{~"mode" := Mode}}) ->
    case asobi_world_lobby:create_world(Mode) of
        {ok, _Pid, Info} ->
            {json, Info, 201};
        {error, Reason} ->
            {json, #{error => Reason}, 400}
    end;
create(_Req) ->
    {status, 400}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec build_filters(map()) -> map().
build_filters(QS) ->
    F0 = #{},
    F1 =
        case maps:get(~"mode", QS, undefined) of
            undefined -> F0;
            Mode -> F0#{mode => Mode}
        end,
    case maps:get(~"has_capacity", QS, undefined) of
        ~"true" -> F1#{has_capacity => true};
        _ -> F1
    end.
