-module(asobi_router).
-behaviour(nova_router).

-export([routes/1, core_routes/0]).

%% Every route accepts its real method plus OPTIONS. Nova's middleware chain
%% runs `nova_router` before `nova_cors_plugin`, so a route that doesn't
%% list `options` gets 405 from the router before the CORS plugin's OPTIONS
%% short-circuit ever runs. Listing `options` lets the plugin intercept the
%% preflight and reply 200 without the handler ever seeing it.

%% The first caller of asobi_extensions:resolve/0, and the reason it is a pure
%% memoised function rather than a process: nova is in asobi's `applications`
%% list, so nova_sup:init/1 compiles this route table before asobi_app:start/2
%% has run and before any asobi process exists. Resolving here validates the
%% installed set at the earliest possible moment. Core owns the whole table:
%% an extension declares entries in its manifest's `routes/0`, and this is the
%% one place they are mounted.
-spec routes(atom()) -> [map()].
routes(_Environment) ->
    Extensions = asobi_extensions:resolve(),
    core_routes() ++ extension_routes(Extensions).

%% Core's own groups, without resolving extensions. `asobi_extension_reserved`
%% derives the reserved http claims from this - it is called from inside
%% `asobi_extensions:resolve/0`, where reading `routes/1` would re-enter the
%% resolver before its term exists.
-spec core_routes() -> [map()].
core_routes() ->
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
            %% POST, not DELETE, and it echoes a credential in the body -
            %% the same shape as the operator's `/ops/players/:id/erase` one
            %% layer up. `nova_request_plugin` skips JSON decoding entirely on
            %% GET and DELETE (RFC 9110 gives a DELETE body no semantics), so a
            %% DELETE could never carry the password confirmation this route is
            %% gated on.
            %%
            %% Declared AFTER `/players/:id`: routing_tree prepends on insert
            %% and returns on the first matching sibling, so a literal declared
            %% ahead of a binding is swallowed by it (asobi#326, the
            %% `/matches/live` trap).
            {~"/players/me/erase", fun asobi_player_controller:erase_self/1, #{
                methods => [post, options]
            }},

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
            }},

            %% Extension RPC over HTTP. The same dispatcher the socket
            %% `rpc.call` frame reaches (`asobi_rpc:dispatch/2`), in the
            %% player-scoped chain so the body cap, CORS and rate limiter apply
            %% and a tokenless caller is refused before the controller - which
            %% matches dispatch's own `unauthenticated` branch. The `/api/v1/rpc`
            %% prefix is reserved in `asobi_extension_reserved:route_prefixes/0`
            %% so no extension can claim this frozen core route.
            {~"/rpc/:method", fun asobi_rpc_controller:call/1, #{methods => [post, options]}}
        ]
    }.

%% Ops - the game-operations plane. Its own group because it is its own
%% identity: the operator capability check (ADR 0007), never the player-scoped
%% one. Every route here must carry a class in `asobi_ops_caps:classes/0`.
%%
%% The plane is a read plane plus exactly two account-lifecycle routes. Erasure
%% is a POST with a server-verified confirmation rather than a DELETE, and it
%% sits in its own `erasure` class rather than in `player_data`, because it is
%% the one action here no follow-up call can undo.
ops_routes() ->
    #{
        prefix => ~"/api/v1/ops",
        security => fun asobi_ops_auth:verify/1,
        routes => [
            {~"/players", fun asobi_ops_controller:players/1, #{methods => [get, options]}},
            %% Before `/players/:id`, the asobi#326 ordering trap the match
            %% routes carry a comment about: routing_tree prepends on insert
            %% and returns on the first matching sibling.
            {~"/players/:id/erase", fun asobi_ops_controller:erase_player/1, #{
                methods => [post, options]
            }},
            {~"/players/:id/export", fun asobi_ops_controller:export_player/1, #{
                methods => [get, options]
            }},
            {~"/players/:id", fun asobi_ops_controller:player/1, #{methods => [get, options]}},
            %% After every `:id` route, and that is the asobi#326 trap rather
            %% than a style choice. routing_tree prepends on insert and returns
            %% on the first *matching sibling* without backtracking, so the
            %% `:id` binding happily matches the literal segment `guests` and
            %% then fails to find `purge` beneath it. Declared last, the literal
            %% is prepended ahead of the binding and is tried first.
            %% `asobi_router_tests` resolves every declared route and fails if
            %% this moves back up.
            {~"/players/guests/purge", fun asobi_ops_controller:purge_guests/1, #{
                methods => [post, options]
            }},
            {~"/matches", fun asobi_ops_controller:matches/1, #{methods => [get, options]}},
            {~"/matches/:id", fun asobi_ops_controller:match/1, #{methods => [get, options]}},
            {~"/features", fun asobi_ops_controller:features/1, #{methods => [get, options]}},
            {~"/stats", fun asobi_ops_controller:stats/1, #{methods => [get, options]}},
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
            %% The one ops-plane route core owns on behalf of extensions -
            %% `routes/0` mounts player and webhook surfaces, never operator
            %% ones. This dispatches every action an installed manifest
            %% declares, exactly as one WebSocket frame type dispatches
            %% `rpc/0`. Its class is per action and comes from that manifest,
            %% so it is deliberately absent from `asobi_ops_caps:classes/0` -
            %% see `m:asobi_ops_extension`.
            {~"/ext/:extension/:action", fun asobi_ops_extension:handle/1, #{
                methods => [get, post, put, delete, options]
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

%% The declared route seam. Each manifest's `routes/0` entries mount here,
%% under core's global plugin chain: the groups declare no `plugins` key, so
%% Nova applies the chain from its own env - a group naming `plugins` would
%% replace it, which is the Nova-apps hazard this seam exists to close.
%% Ordering against core's groups is irrelevant by construction:
%% `asobi_extensions:validate/1` refused any two patterns that could match
%% one request, so the asobi#326 declaration-order trap cannot arise, and an
%% uninstalled extension's paths are simply absent - an unknown route, not a
%% reserved-looking one.
extension_routes(Extensions) ->
    lists:append([extension_groups(Routes) || #{routes := Routes} <- Extensions]).

%% The classifier is total over the validated shape, so a route that somehow
%% lost its security key crashes the compile loudly instead of vanishing
%% from the table - or worse, mounting under the wrong chain.
extension_groups(Routes) ->
    [
        Group
     || Security <- [player, webhook],
        Group <- security_group(Security, [E || E <- Routes, security(E) =:= Security])
    ].

security(#{security := Security}) -> Security.

%% `player` is the same chain `api_routes/0` carries; `webhook` mounts open,
%% like `auth_routes/0`, for a server-to-server caller that cannot hold a
%% player token - the handler authenticates its caller itself, and the rate
%% limiter puts it in the dedicated webhook bucket rather than the api one.
security_group(_Security, []) ->
    [];
security_group(player, Entries) ->
    [#{prefix => ~"", security => fun asobi_auth_plugin:verify/1, routes => mounted(Entries)}];
security_group(webhook, Entries) ->
    [#{prefix => ~"", security => false, routes => mounted(Entries)}].

mounted(Entries) ->
    [mount(Entry) || Entry <- Entries].

%% Total on purpose: a malformed entry cannot exist after validation, and if
%% one ever does, a function_clause here beats a route silently not mounted.
mount(#{path := Path, method := Method, mfa := {Module, Function, 1}}) ->
    {Path, fun Module:Function/1, #{methods => [Method, options]}}.
