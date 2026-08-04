-module(asobi_player_controller).

-export([show/1, update/1]).

-spec show(cowboy_req:req()) -> {json, map()} | {asobi_error, asobi_error:code()}.
show(#{bindings := #{~"id" := PlayerId}} = _Req) ->
    case asobi_repo:get(asobi_player, PlayerId) of
        {ok, Player} ->
            {json, sanitize(Player)};
        {error, not_found} ->
            {asobi_error, ~"player.not_found"}
    end.

-spec update(cowboy_req:req()) ->
    {json, map()} | {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
update(
    #{bindings := #{~"id" := PlayerId}, json := Params, auth_data := #{player_id := AuthId}} = _Req
) when is_map(Params) ->
    case PlayerId =:= AuthId of
        false ->
            {asobi_error, ~"forbidden"};
        true ->
            case asobi_repo:get(asobi_player, PlayerId) of
                {ok, Player} ->
                    CS = asobi_player:update_changeset(Player, Params),
                    case asobi_repo:update(CS) of
                        {ok, Updated} ->
                            {json, sanitize(Updated)};
                        {error, CS1} ->
                            %% `errors` keeps its top-level place for form UIs
                            %% and doubles as the object's `details`.
                            asobi_error:legacy(~"validation_failed", #{
                                errors => format_errors(CS1)
                            })
                    end;
                {error, not_found} ->
                    {asobi_error, ~"player.not_found"}
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
