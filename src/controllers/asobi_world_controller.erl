-module(asobi_world_controller).

-export([index/1, show/1, create/1]).

-spec index(map()) -> {json, map()}.
index(#{parsed_qs := QS}) ->
    Filters = build_filters(QS),
    %% H3 (2026-05-19): use cached enumeration; freshness is 500ms which is
    %% well below the granularity a polling client perceives.
    Worlds = asobi_world_lobby:list_worlds_cached(Filters),
    {json, #{worlds => Worlds}};
index(_Req) ->
    Worlds = asobi_world_lobby:list_worlds_cached(),
    {json, #{worlds => Worlds}}.

-spec show(map()) -> {json, map()} | {asobi_error, asobi_error:code()}.
show(#{bindings := #{~"id" := WorldId}}) ->
    case asobi_world_server:whereis(WorldId) of
        {ok, Pid} ->
            Info = asobi_world_server:get_info(Pid),
            {json, asobi_world_server:listing_info(Info)};
        error ->
            {asobi_error, ~"world.not_found"}
    end.

-spec create(map()) ->
    {json, map(), integer()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.
create(#{json := #{~"mode" := Mode}, auth_data := #{player_id := PlayerId}}) when
    is_binary(PlayerId)
->
    case asobi_world_lobby:create_world(Mode, PlayerId) of
        {ok, _Pid, Info} ->
            {json, Info, 201};
        {error, player_world_limit_reached} ->
            {asobi_error, ~"world.player_limit_reached"};
        {error, world_capacity_reached} ->
            {asobi_error, ~"world.capacity_reached"};
        {error, Reason} ->
            %% Anything else - including a refusal the loaded game's own mode
            %% config produced - is reported under one code with the raw reason
            %% in `details`. A script must not be able to mint a code.
            {asobi_error, ~"world.create_failed", #{reason => reason(Reason)}}
    end;
create(_Req) ->
    {asobi_error, ~"invalid_payload"}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec reason(term()) -> binary().
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format(~"~p", [Reason])).

-spec build_filters(map()) -> map().
build_filters(QS) ->
    F0 = #{},
    %% Bound `mode` to the same 64-byte cap the WS path enforces
    %% (asobi_ws_handler:build_world_filters/1); a longer value matches no
    %% registered mode, so drop the filter rather than scan with it.
    F1 =
        case maps:get(~"mode", QS, undefined) of
            Mode when is_binary(Mode), byte_size(Mode) =< 64 -> F0#{mode => Mode};
            _ -> F0
        end,
    case maps:get(~"has_capacity", QS, undefined) of
        ~"true" -> F1#{has_capacity => true};
        _ -> F1
    end.
