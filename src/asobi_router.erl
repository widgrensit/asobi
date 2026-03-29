-module(asobi_router).
-behaviour(nova_router).

-export([routes/1]).

-spec routes(atom()) -> [map()].
routes(_Environment) ->
    [
        auth_routes(),
        api_routes(),
        ws_routes()
    ].

auth_routes() ->
    #{
        prefix => ~"/api/v1/auth",
        security => false,
        plugins => [
            {pre_request, nova_request_plugin, #{
                decode_json_body => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => ~"*"}},
            {pre_request, nova_correlation_plugin, #{}}
        ],
        routes => [
            {~"/register", fun asobi_auth_controller:register/1, #{methods => [post]}},
            {~"/login", fun asobi_auth_controller:login/1, #{methods => [post]}},
            {~"/refresh", fun asobi_auth_controller:refresh/1, #{methods => [post]}}
        ]
    }.

api_routes() ->
    #{
        prefix => ~"/api/v1",
        security => fun asobi_auth_plugin:verify/1,
        plugins => [
            {pre_request, nova_request_plugin, #{
                decode_json_body => true,
                parse_qs => true
            }},
            {pre_request, nova_cors_plugin, #{allow_origins => ~"*"}},
            {pre_request, nova_correlation_plugin, #{}}
        ],
        routes => [
            %% Players
            {~"/players/:id", fun asobi_player_controller:show/1, #{methods => [get]}},
            {~"/players/:id", fun asobi_player_controller:update/1, #{methods => [put]}},

            %% Matches
            {~"/matches", fun asobi_match_controller:index/1, #{methods => [get]}},
            {~"/matches/:id", fun asobi_match_controller:show/1, #{methods => [get]}},

            %% Matchmaker
            {~"/matchmaker", fun asobi_matchmaker_controller:add/1, #{methods => [post]}},
            {~"/matchmaker/:ticket_id", fun asobi_matchmaker_controller:status/1, #{
                methods => [get]
            }},
            {~"/matchmaker/:ticket_id", fun asobi_matchmaker_controller:remove/1, #{
                methods => [delete]
            }},

            %% Leaderboards
            {~"/leaderboards/:id", fun asobi_leaderboard_controller:top/1, #{methods => [get]}},
            {~"/leaderboards/:id", fun asobi_leaderboard_controller:submit/1, #{methods => [post]}},
            {~"/leaderboards/:id/around/:player_id", fun asobi_leaderboard_controller:around/1, #{
                methods => [get]
            }},

            %% Economy
            {~"/wallets", fun asobi_economy_controller:wallets/1, #{methods => [get]}},
            {~"/wallets/:currency/history", fun asobi_economy_controller:history/1, #{
                methods => [get]
            }},
            {~"/store", fun asobi_economy_controller:store/1, #{methods => [get]}},
            {~"/store/purchase", fun asobi_economy_controller:purchase/1, #{methods => [post]}},

            %% Inventory
            {~"/inventory", fun asobi_inventory_controller:index/1, #{methods => [get]}},
            {~"/inventory/consume", fun asobi_inventory_controller:consume/1, #{methods => [post]}},

            %% Social - Friends
            {~"/friends", fun asobi_social_controller:friends/1, #{methods => [get]}},
            {~"/friends", fun asobi_social_controller:add_friend/1, #{methods => [post]}},
            {~"/friends/:friend_id", fun asobi_social_controller:update_friend/1, #{
                methods => [put]
            }},
            {~"/friends/:friend_id", fun asobi_social_controller:remove_friend/1, #{
                methods => [delete]
            }},

            %% Social - Groups
            {~"/groups", fun asobi_social_controller:create_group/1, #{methods => [post]}},
            {~"/groups/:id", fun asobi_social_controller:show_group/1, #{methods => [get]}},
            {~"/groups/:id/join", fun asobi_social_controller:join_group/1, #{methods => [post]}},
            {~"/groups/:id/leave", fun asobi_social_controller:leave_group/1, #{methods => [post]}},

            %% Chat
            {~"/chat/:channel_id/history", fun asobi_chat_controller:history/1, #{methods => [get]}},

            %% Tournaments
            {~"/tournaments", fun asobi_tournament_controller:index/1, #{methods => [get]}},
            {~"/tournaments/:id", fun asobi_tournament_controller:show/1, #{methods => [get]}},
            {~"/tournaments/:id/join", fun asobi_tournament_controller:join/1, #{methods => [post]}},

            %% Notifications
            {~"/notifications", fun asobi_notification_controller:index/1, #{methods => [get]}},
            {~"/notifications/:id/read", fun asobi_notification_controller:mark_read/1, #{
                methods => [put]
            }},
            {~"/notifications/:id", fun asobi_notification_controller:delete/1, #{
                methods => [delete]
            }},

            %% Storage - Cloud Saves
            {~"/saves", fun asobi_storage_controller:list_saves/1, #{methods => [get]}},
            {~"/saves/:slot", fun asobi_storage_controller:get_save/1, #{methods => [get]}},
            {~"/saves/:slot", fun asobi_storage_controller:put_save/1, #{methods => [put]}},

            %% Storage - Generic
            {~"/storage/:collection", fun asobi_storage_controller:list_storage/1, #{
                methods => [get]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:get_storage/1, #{
                methods => [get]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:put_storage/1, #{
                methods => [put]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:delete_storage/1, #{
                methods => [delete]
            }}
        ]
    }.

ws_routes() ->
    #{
        prefix => ~"",
        security => false,
        routes => [
            {~"/ws", asobi_ws_handler, #{protocol => ws}}
        ]
    }.
