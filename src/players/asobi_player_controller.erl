-module(asobi_player_controller).

-export([show/1, update/1]).

-spec show(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show(#{bindings := #{~"id" := PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            {json, sanitize(Player)};
        {error, not_found} ->
            {status, 404}
    end.

-spec update(cowboy_req:req()) ->
    {json, map()} | {json, integer(), map(), map()} | {status, integer()}.
update(
    #{bindings := #{~"id" := PlayerId}, json := Params, auth_data := #{player_id := AuthId}} = _Req
) ->
    case PlayerId =:= AuthId of
        false ->
            {status, 403};
        true ->
            case asobi_repo:get(asobi_player, PlayerId) of
                {ok, Player} ->
                    CS = asobi_player:update_changeset(Player, Params),
                    case asobi_repo:update(CS) of
                        {ok, Updated} ->
                            {json, sanitize(Updated)};
                        {error, CS1} ->
                            {json, 422, #{}, #{errors => format_errors(CS1)}}
                    end;
                {error, not_found} ->
                    {status, 404}
            end
    end.

sanitize(Player) ->
    maps:without([banned_at], Player).

format_errors(CS) ->
    kura_changeset:traverse_errors(CS, fun(_Field, Msg) -> Msg end).
