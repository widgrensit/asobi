-module(asobi_steam).

-export([validate_ticket/1]).

-define(STEAM_API_URL, ~"https://api.steampowered.com/ISteamUserAuth/AuthenticateUserTicket/v1/").
-define(STEAM_PLAYER_URL, ~"https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/").

%% Validate a Steam session ticket via the Steam Web API.
%% The game client obtains a ticket via ISteamUser::GetAuthSessionTicket
%% and sends the hex-encoded ticket to this endpoint.
-spec validate_ticket(binary()) -> {ok, map()} | {error, binary()}.
validate_ticket(Ticket) ->
    case steam_api_key() of
        undefined ->
            {error, ~"steam_not_configured"};
        ApiKey ->
            AppId = steam_app_id(),
            do_validate_ticket(ApiKey, AppId, Ticket)
    end.

%% --- Internal ---

-spec do_validate_ticket(binary(), binary(), binary()) -> {ok, map()} | {error, binary()}.
do_validate_ticket(ApiKey, AppId, Ticket) ->
    Url = iolist_to_binary([
        ?STEAM_API_URL,
        ~"?key=",
        ApiKey,
        ~"&appid=",
        AppId,
        ~"&ticket=",
        Ticket
    ]),
    case
        httpc:request(get, {binary_to_list(Url), []}, [{timeout, 10000}], [{body_format, binary}])
    of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_auth_response(Body);
        {ok, {{_, Status, _}, _, _}} ->
            logger:warning(#{msg => ~"steam_api_error", status => Status}),
            {error, ~"steam_api_error"};
        {error, Reason} ->
            logger:warning(#{msg => ~"steam_api_request_failed", reason => Reason}),
            {error, ~"steam_api_unavailable"}
    end.

-spec parse_auth_response(binary()) -> {ok, map()} | {error, binary()}.
parse_auth_response(Body) ->
    case json:decode(Body) of
        #{~"response" := #{~"params" := #{~"result" := ~"OK", ~"steamid" := SteamId}}} ->
            maybe_fetch_profile(SteamId);
        #{~"response" := #{~"error" := #{~"errordesc" := Desc}}} ->
            {error, Desc};
        _ ->
            {error, ~"invalid_steam_response"}
    end.

-spec maybe_fetch_profile(binary()) -> {ok, map()}.
maybe_fetch_profile(SteamId) ->
    Claims = #{
        provider_uid => SteamId,
        provider_email => undefined,
        provider_display_name => undefined
    },
    case fetch_player_summary(SteamId) of
        {ok, Summary} ->
            {ok, Claims#{
                provider_display_name => maps:get(~"personaname", Summary, undefined)
            }};
        {error, _} ->
            {ok, Claims}
    end.

-spec fetch_player_summary(binary()) -> {ok, map()} | {error, term()}.
fetch_player_summary(SteamId) ->
    case steam_api_key() of
        undefined ->
            {error, not_configured};
        ApiKey ->
            Url = iolist_to_binary([
                ?STEAM_PLAYER_URL,
                ~"?key=",
                ApiKey,
                ~"&steamids=",
                SteamId
            ]),
            case
                httpc:request(
                    get, {binary_to_list(Url), []}, [{timeout, 10000}], [{body_format, binary}]
                )
            of
                {ok, {{_, 200, _}, _, Body}} ->
                    case json:decode(Body) of
                        #{~"response" := #{~"players" := [Player | _]}} ->
                            {ok, Player};
                        _ ->
                            {error, no_players}
                    end;
                _ ->
                    {error, request_failed}
            end
    end.

-spec steam_api_key() -> binary() | undefined.
steam_api_key() ->
    application:get_env(asobi, steam_api_key, undefined).

-spec steam_app_id() -> binary().
steam_app_id() ->
    application:get_env(asobi, steam_app_id, ~"0").
