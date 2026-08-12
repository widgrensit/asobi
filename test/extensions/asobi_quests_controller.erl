-module(asobi_quests_controller).
-moduledoc """
The controller the extensions guide's `routes/0` example names, exported for
real so the guide's exact declarations pass `asobi_extensions:check/0` - the
handler-existence check makes a documented example with a fictional module a
documented build failure.
""".

-export([board/1, steam_notification/1]).

-spec board(cowboy_req:req()) -> {json, map()}.
board(#{auth_data := #{player_id := PlayerId}}) ->
    {json, #{~"player_id" => PlayerId, ~"quests" => []}}.

-spec steam_notification(cowboy_req:req()) -> {json, 200, map(), map()}.
steam_notification(_Req) ->
    {json, 200, #{}, #{~"received" => true}}.
