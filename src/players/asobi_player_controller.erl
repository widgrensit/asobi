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
) when is_map(Params) ->
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

%% Positive whitelist: only fields safe for any authenticated viewer.
%% Never expose `hashed_password` (or any future credential fields).
sanitize(Player) ->
    maps:with(
        [id, username, display_name, avatar_url, metadata, inserted_at, updated_at],
        Player
    ).

format_errors(CS) ->
    kura_changeset:traverse_errors(CS, fun(_Field, Msg) -> Msg end).
