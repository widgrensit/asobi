-module(asobi_fixture_quests_controller).
-moduledoc """
Nova controllers behind the quests fixture's declared routes: arity 1, `Req`
in, ordinary Nova return out - exactly what an extracted core controller is.
""".

-export([board/1, webhook/1]).

-spec board(cowboy_req:req()) -> {json, map()}.
board(#{auth_data := #{player_id := PlayerId}}) ->
    {json, #{~"player_id" => PlayerId, ~"quests" => []}}.

%% Explicit 200: nova's default for a bare `{json, _}` on POST is 201, and a
%% webhook sender retries on anything it does not recognise as acknowledged.
-spec webhook(cowboy_req:req()) -> {json, 200, map(), map()}.
webhook(#{json := Body}) when is_map(Body) ->
    {json, 200, #{}, #{~"received" => Body}};
webhook(_Req) ->
    {json, 200, #{}, #{~"received" => #{}}}.
