-module(asobi_auth_tokens).
-moduledoc """
Issues and revokes player auth tokens on top of `nova_auth_refresh`.

Every login path (password and OAuth) funnels through `issue/2,3` so the
client always receives the same access + refresh pair. `revoke_access/1`
kills the presented access token on logout so it can't outlive the cache TTL.
""".

-export([issue/2, issue/3, revoke_access/1]).

-doc "Issue an access + refresh pair for `Player` and build the JSON response.".
-spec issue(map(), integer()) -> {json, integer(), map(), map()}.
issue(Player, Status) ->
    issue(Player, Status, #{}).

-doc "Like `issue/2` but merges `Extra` (e.g. username) into the response body.".
-spec issue(map(), integer(), map()) -> {json, integer(), map(), map()}.
issue(Player, Status, Extra) ->
    case nova_auth_refresh:generate_pair(asobi_auth, Player) of
        {ok, #{access_token := Access, refresh_token := Refresh}} ->
            Body = maps:merge(
                #{
                    player_id => maps:get(id, Player),
                    access_token => Access,
                    refresh_token => Refresh
                },
                Extra
            ),
            {json, Status, #{}, Body};
        {error, Reason} ->
            logger:error(#{msg => ~"token_issue_failed", reason => Reason}),
            {json, 500, #{}, #{error => ~"token_issue_failed"}}
    end.

-doc "Revoke the Bearer access token on the request (logout of this device).".
-spec revoke_access(cowboy_req:req()) -> ok.
revoke_access(Req) ->
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", Access/binary>> ->
            _ = nova_auth_refresh:delete_access_token(asobi_auth, Access),
            asobi_auth_cache:invalidate(Access);
        _ ->
            ok
    end.
