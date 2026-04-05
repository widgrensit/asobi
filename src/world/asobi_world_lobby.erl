-module(asobi_world_lobby).

-export([list_worlds/0, list_worlds/1, find_or_create/1, create_world/1]).

-define(PG_SCOPE, nova_scope).

-doc "List all running worlds.".
-spec list_worlds() -> [map()].
list_worlds() ->
    list_worlds(#{}).

-doc "List running worlds with optional filters: mode, has_capacity.".
-spec list_worlds(map()) -> [map()].
list_worlds(Filters) ->
    Groups = pg:which_groups(?PG_SCOPE),
    WorldGroups = [
        {WorldId, Pid}
     || {asobi_world_server, WorldId} = Group <- Groups,
        Pid <- take_first(pg:get_members(?PG_SCOPE, Group))
    ],
    Worlds = lists:filtermap(
        fun({_WorldId, Pid}) ->
            try asobi_world_server:get_info(Pid) of
                Info when is_map(Info) ->
                    case matches_filters(Info, Filters) of
                        true -> {true, Info};
                        false -> false
                    end
            catch
                _:_ -> false
            end
        end,
        WorldGroups
    ),
    Worlds.

-doc "Find a running world with capacity for the given mode, or create one.".
-spec find_or_create(binary()) -> {ok, pid(), map()} | {error, term()}.
find_or_create(Mode) ->
    Worlds = list_worlds(#{mode => Mode, has_capacity => true}),
    case Worlds of
        [#{world_id := WorldId} | _] ->
            case asobi_world_server:whereis(WorldId) of
                {ok, Pid} -> {ok, Pid, hd(Worlds)};
                error -> create_world(Mode)
            end;
        [] ->
            create_world(Mode)
    end.

-doc "Create a new world for the given mode.".
-spec create_world(binary()) -> {ok, pid(), map()} | {error, term()}.
create_world(Mode) ->
    case asobi_game_modes:world_config(Mode) of
        {ok, Config} ->
            case asobi_world_instance_sup:start_world(Config) of
                {ok, InstancePid} ->
                    WorldPid = wait_for_world_server(InstancePid, 10),
                    case WorldPid of
                        undefined ->
                            {error, world_server_not_started};
                        _ ->
                            Info = asobi_world_server:get_info(WorldPid),
                            {ok, WorldPid, Info}
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec matches_filters(map(), map()) -> boolean().
matches_filters(Info, Filters) ->
    ModeOk =
        case maps:find(mode, Filters) of
            {ok, Mode} -> maps:get(mode, Info, undefined) =:= Mode;
            error -> true
        end,
    CapOk =
        case maps:get(has_capacity, Filters, false) of
            true ->
                maps:get(player_count, Info, 0) < maps:get(max_players, Info, 500);
            false ->
                true
        end,
    StatusOk = maps:get(status, Info, undefined) =:= running,
    ModeOk andalso CapOk andalso StatusOk.

-spec take_first([pid()]) -> [pid()].
take_first([Pid | _]) -> [Pid];
take_first([]) -> [].

-spec wait_for_world_server(pid(), non_neg_integer()) -> pid() | undefined.
wait_for_world_server(_InstancePid, 0) ->
    undefined;
wait_for_world_server(InstancePid, Retries) ->
    case asobi_world_instance:get_child(InstancePid, asobi_world_server) of
        undefined ->
            timer:sleep(50),
            wait_for_world_server(InstancePid, Retries - 1);
        Pid ->
            Pid
    end.
