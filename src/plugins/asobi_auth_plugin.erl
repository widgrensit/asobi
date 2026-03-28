-module(asobi_auth_plugin).

-export([verify/1]).

-spec verify(cowboy_req:req()) -> true | false | {true, map()}.
verify(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        undefined ->
            false;
        <<"Bearer ", Token/binary>> ->
            case nova_auth_session:get_user_by_session_token(asobi_auth, Token) of
                {ok, Player} ->
                    {true, #{player_id => maps:get(id, Player)}};
                {error, _} ->
                    false
            end;
        _ ->
            false
    end.
