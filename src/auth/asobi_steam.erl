-module(asobi_steam).

-export([validate_ticket/1]).

-define(STEAM_API_URL, ~"https://api.steampowered.com/ISteamUserAuth/AuthenticateUserTicket/v1/").
-define(STEAM_PLAYER_URL, ~"https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/").

%% Validate a Steam session ticket via the Steam Web API.
%% The game client obtains a ticket via ISteamUser::GetAuthSessionTicket
%% and sends the hex-encoded ticket to this endpoint.
-spec validate_ticket(binary()) -> {ok, map()} | {error, binary()}.
validate_ticket(Ticket) when is_binary(Ticket) ->
    case is_hex_ticket(Ticket) of
        false ->
            {error, ~"invalid_ticket_format"};
        true ->
            case steam_api_key() of
                undefined ->
                    {error, ~"steam_not_configured"};
                ApiKey ->
                    AppId = steam_app_id(),
                    do_validate_ticket(ApiKey, AppId, Ticket)
            end
    end;
validate_ticket(_) ->
    {error, ~"invalid_ticket_format"}.

%% --- Internal ---

%% F-18: tickets are documented as hex-encoded by Valve. Reject anything
%% else early so the ticket cannot be used to inject query parameters
%% even if downstream URL-encoding regresses.
-spec is_hex_ticket(binary()) -> boolean().
is_hex_ticket(<<>>) ->
    false;
is_hex_ticket(Bin) when byte_size(Bin) > 4096 ->
    false;
is_hex_ticket(Bin) ->
    is_hex_chars(Bin).

is_hex_chars(<<>>) ->
    true;
is_hex_chars(<<C, Rest/binary>>) when
    (C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F)
->
    is_hex_chars(Rest);
is_hex_chars(_) ->
    false.

-spec do_validate_ticket(binary(), binary(), binary()) -> {ok, map()} | {error, binary()}.
do_validate_ticket(ApiKey, AppId, Ticket) ->
    %% F-18: defense in depth — even though we already validated the
    %% ticket character class above, URL-encode every dynamic component
    %% so an accidental rule loosening can't be exploited to inject
    %% additional query parameters into the Steam request.
    Url = iolist_to_binary([
        ?STEAM_API_URL,
        ~"?key=",
        url_encode(ApiKey),
        ~"&appid=",
        url_encode(AppId),
        ~"&ticket=",
        url_encode(Ticket)
    ]),
    case
        httpc:request(get, {binary_to_list(Url), []}, [{timeout, 10000}], [{body_format, binary}])
    of
        {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
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
        #{~"response" := #{~"params" := #{~"result" := ~"OK", ~"steamid" := SteamId}}} when
            is_binary(SteamId)
        ->
            maybe_fetch_profile(SteamId);
        #{~"response" := #{~"error" := #{~"errordesc" := Desc}}} when is_binary(Desc) ->
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
                url_encode(ApiKey),
                ~"&steamids=",
                url_encode(SteamId)
            ]),
            case
                httpc:request(
                    get, {binary_to_list(Url), []}, [{timeout, 10000}], [{body_format, binary}]
                )
            of
                {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
                    case json:decode(Body) of
                        #{~"response" := #{~"players" := [Player | _]}} when is_map(Player) ->
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
    case application:get_env(asobi, steam_api_key, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

-spec steam_app_id() -> binary().
steam_app_id() ->
    case application:get_env(asobi, steam_app_id, ~"0") of
        V when is_binary(V) -> V;
        _ -> ~"0"
    end.

-spec url_encode(binary()) -> binary().
url_encode(Bin) when is_binary(Bin) ->
    iolist_to_binary(uri_string:quote(Bin)).
