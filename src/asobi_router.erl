-module(asobi_router).
-behaviour(nova_router).

-export([routes/1]).

%% Every route accepts its real method plus OPTIONS. Nova's middleware chain
%% runs `nova_router` before `nova_cors_plugin`, so a route that doesn't
%% list `options` gets 405 from the router before the CORS plugin's OPTIONS
%% short-circuit ever runs. Listing `options` lets the plugin intercept the
%% preflight and reply 200 without the handler ever seeing it.

-spec routes(atom()) -> [map()].
routes(_Environment) ->
    [
        auth_routes(),
        iap_routes(),
        api_routes(),
        ws_routes()
    ].

auth_routes() ->
    #{
        prefix => ~"/api/v1/auth",
        security => false,
        routes => [
            {~"/register", fun asobi_auth_controller:register/1, #{methods => [post, options]}},
            {~"/login", fun asobi_auth_controller:login/1, #{methods => [post, options]}},
            {~"/refresh", fun asobi_auth_controller:refresh/1, #{methods => [post, options]}},
            {~"/oauth", fun asobi_oauth_controller:authenticate/1, #{methods => [post, options]}}
        ]
    }.

iap_routes() ->
    #{
        prefix => ~"/api/v1/iap",
        security => fun asobi_auth_plugin:verify/1,
        routes => [
            {~"/apple", fun asobi_iap_controller:verify_apple/1, #{methods => [post, options]}},
            {~"/google", fun asobi_iap_controller:verify_google/1, #{methods => [post, options]}}
        ]
    }.

api_routes() ->
    #{
        prefix => ~"/api/v1",
        security => fun asobi_auth_plugin:verify/1,
        routes => [
            %% Auth - Provider linking
            {~"/auth/link", fun asobi_oauth_controller:link/1, #{methods => [post, options]}},
            {~"/auth/unlink", fun asobi_oauth_controller:unlink/1, #{methods => [delete, options]}},

            %% Players
            {~"/players/:id", fun asobi_player_controller:show/1, #{methods => [get, options]}},
            {~"/players/:id", fun asobi_player_controller:update/1, #{methods => [put, options]}},

            %% Worlds
            {~"/worlds", fun asobi_world_controller:index/1, #{methods => [get, options]}},
            {~"/worlds/:id", fun asobi_world_controller:show/1, #{methods => [get, options]}},
            {~"/worlds", fun asobi_world_controller:create/1, #{methods => [post, options]}},

            %% Matches
            {~"/matches", fun asobi_match_controller:index/1, #{methods => [get, options]}},
            {~"/matches/:id", fun asobi_match_controller:show/1, #{methods => [get, options]}},

            %% Matchmaker
            {~"/matchmaker", fun asobi_matchmaker_controller:add/1, #{methods => [post, options]}},
            {~"/matchmaker/:ticket_id", fun asobi_matchmaker_controller:status/1, #{
                methods => [get, options]
            }},
            {~"/matchmaker/:ticket_id", fun asobi_matchmaker_controller:remove/1, #{
                methods => [delete, options]
            }},

            %% Leaderboards
            {~"/leaderboards/:id", fun asobi_leaderboard_controller:top/1, #{
                methods => [get, options]
            }},
            {~"/leaderboards/:id", fun asobi_leaderboard_controller:submit/1, #{
                methods => [post, options]
            }},
            {~"/leaderboards/:id/around/:player_id", fun asobi_leaderboard_controller:around/1, #{
                methods => [get, options]
            }},

            %% Economy
            {~"/wallets", fun asobi_economy_controller:wallets/1, #{methods => [get, options]}},
            {~"/wallets/:currency/history", fun asobi_economy_controller:history/1, #{
                methods => [get, options]
            }},
            {~"/store", fun asobi_economy_controller:store/1, #{methods => [get, options]}},
            {~"/store/purchase", fun asobi_economy_controller:purchase/1, #{
                methods => [post, options]
            }},

            %% Inventory
            {~"/inventory", fun asobi_inventory_controller:index/1, #{methods => [get, options]}},
            {~"/inventory/consume", fun asobi_inventory_controller:consume/1, #{
                methods => [post, options]
            }},

            %% Social - Friends
            {~"/friends", fun asobi_social_controller:friends/1, #{methods => [get, options]}},
            {~"/friends", fun asobi_social_controller:add_friend/1, #{methods => [post, options]}},
            {~"/friends/:friend_id", fun asobi_social_controller:update_friend/1, #{
                methods => [put, options]
            }},
            {~"/friends/:friend_id", fun asobi_social_controller:remove_friend/1, #{
                methods => [delete, options]
            }},

            %% Social - Groups
            {~"/groups", fun asobi_social_controller:create_group/1, #{methods => [post, options]}},
            {~"/groups/:id", fun asobi_social_controller:show_group/1, #{methods => [get, options]}},
            {~"/groups/:id", fun asobi_social_controller:update_group/1, #{
                methods => [put, options]
            }},
            {~"/groups/:id/join", fun asobi_social_controller:join_group/1, #{
                methods => [post, options]
            }},
            {~"/groups/:id/leave", fun asobi_social_controller:leave_group/1, #{
                methods => [post, options]
            }},
            {~"/groups/:id/members", fun asobi_social_controller:list_members/1, #{
                methods => [get, options]
            }},
            {
                ~"/groups/:id/members/:player_id/role",
                fun asobi_social_controller:update_member_role/1,
                #{methods => [put, options]}
            },
            {~"/groups/:id/members/:player_id", fun asobi_social_controller:kick_member/1, #{
                methods => [delete, options]
            }},

            %% Chat
            {~"/chat/:channel_id/history", fun asobi_chat_controller:history/1, #{
                methods => [get, options]
            }},

            %% Direct Messages
            {~"/dm", fun asobi_dm_controller:send/1, #{methods => [post, options]}},
            {~"/dm/:player_id/history", fun asobi_dm_controller:history/1, #{
                methods => [get, options]
            }},

            %% Votes
            {~"/matches/:id/votes", fun asobi_vote_controller:index/1, #{methods => [get, options]}},
            {~"/votes/:id", fun asobi_vote_controller:show/1, #{methods => [get, options]}},

            %% Tournaments
            {~"/tournaments", fun asobi_tournament_controller:index/1, #{methods => [get, options]}},
            {~"/tournaments/:id", fun asobi_tournament_controller:show/1, #{
                methods => [get, options]
            }},
            {~"/tournaments/:id/join", fun asobi_tournament_controller:join/1, #{
                methods => [post, options]
            }},

            %% Notifications
            {~"/notifications", fun asobi_notification_controller:index/1, #{
                methods => [get, options]
            }},
            {~"/notifications/:id/read", fun asobi_notification_controller:mark_read/1, #{
                methods => [put, options]
            }},
            {~"/notifications/:id", fun asobi_notification_controller:delete/1, #{
                methods => [delete, options]
            }},

            %% Storage - Cloud Saves
            {~"/saves", fun asobi_storage_controller:list_saves/1, #{methods => [get, options]}},
            {~"/saves/:slot", fun asobi_storage_controller:get_save/1, #{methods => [get, options]}},
            {~"/saves/:slot", fun asobi_storage_controller:put_save/1, #{methods => [put, options]}},

            %% Storage - Generic
            {~"/storage/:collection", fun asobi_storage_controller:list_storage/1, #{
                methods => [get, options]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:get_storage/1, #{
                methods => [get, options]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:put_storage/1, #{
                methods => [put, options]
            }},
            {~"/storage/:collection/:key", fun asobi_storage_controller:delete_storage/1, #{
                methods => [delete, options]
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
