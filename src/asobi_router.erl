-module(asobi_router).
-behaviour(nova_router).

-export([routes/1]).

%% Every route accepts its real method plus OPTIONS. Nova's middleware chain
%% runs `nova_router` before `nova_cors_plugin`, so a route that doesn't
%% list `options` gets 405 from the router before the CORS plugin's OPTIONS
%% short-circuit ever runs. Listing `options` lets the plugin intercept the
%% preflight and reply 200 without the handler ever seeing it.

%% The first caller of asobi_extensions:resolve/0, and the reason it is a pure
%% memoised function rather than a process: nova is in asobi's `applications`
%% list, so nova_sup:init/1 compiles this route table before asobi_app:start/2
%% has run and before any asobi process exists. Resolving here validates the
%% installed set at the earliest possible moment. Extensions contribute no
%% routes (ADR 0003); core owns the whole table.
-spec routes(atom()) -> [map()].
routes(_Environment) ->
    _ = asobi_extensions:resolve(),
    [
        auth_routes(),
        iap_routes(),
        api_routes(),
        ops_routes(),
        console_routes(),
        ws_routes()
    ].

auth_routes() ->
    #{
        prefix => ~"/api/v1/auth",
        security => false,
        routes => [
            {~"/register", fun asobi_auth_controller:register/1, #{methods => [post, options]}},
            {~"/guest", fun asobi_guest_controller:authenticate/1, #{methods => [post, options]}},
            {~"/login", fun asobi_auth_controller:login/1, #{methods => [post, options]}},
            {~"/refresh", fun asobi_auth_controller:refresh/1, #{methods => [post, options]}},
            {~"/logout", fun asobi_auth_controller:logout/1, #{methods => [post, options]}},
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
            {~"/auth/guest/upgrade", fun asobi_guest_controller:upgrade/1, #{
                methods => [post, options]
            }},
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
            %% Declaration order matters here. routing_tree prepends on insert and
            %% lookup returns on the first sibling that matches, and a binding
            %% matches any segment - so `/matches/live` must be declared AFTER every
            %% `/matches/:id...` route or `:id` sits ahead of it and swallows "live"
            %% (asobi #326). Keep the vote route in this group for the same reason.
            {~"/matches", fun asobi_match_controller:index/1, #{methods => [get, options]}},
            {~"/matches/:id", fun asobi_match_controller:show/1, #{methods => [get, options]}},
            {~"/matches/:id/votes", fun asobi_vote_controller:index/1, #{methods => [get, options]}},
            {~"/matches/live", fun asobi_match_controller:live/1, #{methods => [get, options]}},

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

            %% Votes (`/matches/:id/votes` lives in the Matches group above)
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

%% Ops - the game-operations plane. Its own group because it is its own
%% identity: the operator capability check (ADR 0007), never the player-scoped
%% one. Every route here must carry a class in `asobi_ops_caps:classes/0`.
ops_routes() ->
    #{
        prefix => ~"/api/v1/ops",
        security => fun asobi_ops_auth:verify/1,
        routes => [
            {~"/players", fun asobi_ops_controller:players/1, #{methods => [get, options]}},
            {~"/players/:id", fun asobi_ops_controller:player/1, #{methods => [get, options]}},
            {~"/matches", fun asobi_ops_controller:matches/1, #{methods => [get, options]}},
            {~"/matches/:id", fun asobi_ops_controller:match/1, #{methods => [get, options]}},
            {~"/features", fun asobi_ops_controller:features/1, #{methods => [get, options]}},
            {~"/leaderboards", fun asobi_ops_controller:leaderboards/1, #{
                methods => [get, options]
            }},
            {~"/leaderboards/:id/entries", fun asobi_ops_controller:leaderboard_entries/1, #{
                methods => [get, options]
            }},
            {~"/matchmaker", fun asobi_ops_controller:matchmaker/1, #{methods => [get, options]}},
            {~"/economy/items", fun asobi_ops_controller:economy_items/1, #{
                methods => [get, options]
            }},
            {~"/economy/items/:id", fun asobi_ops_controller:economy_item/1, #{
                methods => [get, options]
            }},
            {~"/economy/listings", fun asobi_ops_controller:economy_listings/1, #{
                methods => [get, options]
            }},
            {~"/economy/listings/:id", fun asobi_ops_controller:economy_listing/1, #{
                methods => [get, options]
            }},
            {~"/chat/channels", fun asobi_ops_controller:chat_channels/1, #{
                methods => [get, options]
            }},
            {~"/chat/channels/:id/messages", fun asobi_ops_controller:chat_messages/1, #{
                methods => [get, options]
            }},
            {~"/tournaments", fun asobi_ops_controller:tournaments/1, #{
                methods => [get, options]
            }},
            {~"/tournaments/:id", fun asobi_ops_controller:tournament/1, #{
                methods => [get, options]
            }},
            {~"/notifications", fun asobi_ops_controller:notifications/1, #{
                methods => [get, options]
            }},

            %% The write plane. Each of these is a mutation `asobi_admin`
            %% already served against `asobi_repo` directly; here they go
            %% through core's own domain modules and every one writes an audit
            %% row. `player_data` first, then `config`.
            {~"/players/:id/ban", fun asobi_ops_write_controller:ban/1, #{
                methods => [post, options]
            }},
            {~"/players/:id/unban", fun asobi_ops_write_controller:unban/1, #{
                methods => [post, options]
            }},
            {~"/players/:id/grants", fun asobi_ops_write_controller:grant/1, #{
                methods => [post, options]
            }},
            {~"/economy/items", fun asobi_ops_write_controller:create_item/1, #{
                methods => [post, options]
            }},
            {~"/economy/listings", fun asobi_ops_write_controller:create_listing/1, #{
                methods => [post, options]
            }},
            {~"/tournaments", fun asobi_ops_write_controller:create_tournament/1, #{
                methods => [post, options]
            }}
        ]
    }.

%% Console - the operator UI bundle and the session it exchanges the operator
%% secret for. `security => false` is the whole group and it is deliberate:
%% these routes serve a document with no data in it, content-hashed static
%% files, and a login endpoint that cannot require the credential it accepts.
%% Every byte of game data the console renders comes from the ops group above.
%%
%% Absolute paths under an empty prefix, like the websocket group, and one
%% `:file` binding rather than a wildcard - `routing_tree` does no dot-segment
%% normalisation, so this table declares no route form that could carry one.
%%
%% Every route answers 404 unless `console` is enabled; see `m:asobi_console`.
console_routes() ->
    #{
        prefix => ~"",
        security => false,
        routes => [
            {~"/console", fun asobi_console_controller:index/1, #{methods => [get, options]}},
            {~"/console/assets/:file", fun asobi_console_controller:asset/1, #{
                methods => [get, options]
            }},
            {~"/console/session", fun asobi_console_controller:session/1, #{
                methods => [get, options]
            }},
            {~"/console/session", fun asobi_console_controller:login/1, #{
                methods => [post, options]
            }},
            {~"/console/session", fun asobi_console_controller:logout/1, #{
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
