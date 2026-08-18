-module(asobi_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-ifdef(TEST).
-export([ensure_oidc_providers/0]).
-endif.

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, children(role())}}.

%% Narrowed here rather than taken from application:get_env/3, which types as
%% term(). An operator typo must not silently select neither role and boot an
%% empty tree that looks healthy.
-spec role() -> engine | dgram_gw.
role() ->
    case application:get_env(asobi, role, engine) of
        dgram_gw -> dgram_gw;
        _ -> engine
    end.

%% One image, two roles. The datagram gateway binds a UDP port and parses packets
%% from anyone on the internet, so it must not share a process tree with the Lua
%% sandbox or the tenant database credentials (ADR 0012, decision 14). Running it
%% as its own role rather than its own repo keeps the codec shared and the build
%% single; the isolation that matters is at the container boundary, and this is
%% what draws it.
%%
%% `engine` is the default, so a deployment that has never heard of the gateway
%% gets exactly what it had.
-spec children(engine | dgram_gw) -> [supervisor:child_spec()].
children(dgram_gw) ->
    [dgram_gw_sup()];
children(_Engine) ->
    [
        rate_limit_spec(),
        oidc_providers_spec(),
        auth_cache_spec(),
        cluster_spec(),
        player_session_sup(),
        match_sup(),
        world_sup(),
        world_lobby_server_spec(),
        vote_sup(),
        matchmaker_spec(),
        leaderboard_sup(),
        chat_sup(),
        tournament_sup(),
        presence_spec(),
        guest_reaper_spec(),
        console_session_spec(),
        lua_game_config_spec(),
        lua_sup(),
        extension_sup()
    ].

dgram_gw_sup() ->
    #{
        id => asobi_dgram_gw_sup,
        start => {asobi_dgram_gw_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [asobi_dgram_gw_sup]
    }.

%% The asobi_lua merge: asobi_lua used to be its own OTP application, whose
%% start callback loaded the Lua game config and then started asobi_lua_sup.
%% That application started AFTER asobi, so the config load landed after every
%% asobi_sup child was already up - asobi_guest_reaper in particular reads
%% `guest_auth` in start_link/0, and read it before asobi_lua_config could set
%% it. Keeping these two entries last preserves that order exactly (core
%% children -> config load -> Lua children) rather than quietly changing what
%% the core sees at boot. Moving the load earlier is a real behaviour change
%% and belongs in its own PR.
lua_game_config_spec() ->
    #{
        id => asobi_lua_config,
        start => {erlang, apply, [fun load_lua_game_config/0, []]},
        restart => temporary
    }.

%% A broken game config aborts the boot, as it did when this raised from
%% asobi_lua_app:start/2. The failure now arrives as a supervisor
%% failed_to_start_child rather than a bare application-start error, so it also
%% takes the already-started core children down with it - still fail-closed,
%% and a node with an unloadable game config has nothing useful to serve.
load_lua_game_config() ->
    case asobi_lua_config:maybe_load_game_config() of
        ok ->
            ignore;
        {error, Reason} ->
            logger:error(#{msg => ~"game_config_failed", error => Reason}),
            error({game_config_failed, Reason})
    end.

lua_sup() ->
    #{
        id => asobi_lua_sup,
        start => {asobi_lua_sup, start_link, []},
        type => supervisor
    }.

%% Last, so an extension's processes start after every core service they might
%% call. With no extensions installed this is one idle supervisor with no
%% children.
extension_sup() ->
    #{
        id => asobi_extension_sup,
        start => {asobi_extension_sup, start_link, []},
        type => supervisor
    }.

%% Started whether or not the console is enabled. The table costs nothing
%% empty, and starting it conditionally would mean a node that has the console
%% switched on at runtime resolves every session against a table that is not
%% there - a 403 with no explanation anywhere.
console_session_spec() ->
    #{
        id => asobi_console_session,
        start => {asobi_console_session, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.

guest_reaper_spec() ->
    #{
        id => asobi_guest_reaper,
        start => {asobi_guest_reaper, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.

player_session_sup() ->
    #{
        id => asobi_player_session_sup,
        start => {asobi_player_session_sup, start_link, []},
        type => supervisor
    }.

match_sup() ->
    #{
        id => asobi_match_sup,
        start => {asobi_match_sup, start_link, []},
        type => supervisor
    }.

world_sup() ->
    #{
        id => asobi_world_sup,
        start => {asobi_world_sup, start_link, []},
        type => supervisor
    }.

world_lobby_server_spec() ->
    #{
        id => asobi_world_lobby_server,
        start => {asobi_world_lobby_server, start_link, []}
    }.

leaderboard_sup() ->
    #{
        id => asobi_leaderboard_sup,
        start => {asobi_leaderboard_sup, start_link, []},
        type => supervisor
    }.

chat_sup() ->
    #{
        id => asobi_chat_sup,
        start => {asobi_chat_sup, start_link, []},
        type => supervisor
    }.

vote_sup() ->
    #{
        id => asobi_vote_sup,
        start => {asobi_vote_sup, start_link, []},
        type => supervisor
    }.

matchmaker_spec() ->
    #{
        id => asobi_matchmaker,
        start => {asobi_matchmaker, start_link, []}
    }.

tournament_sup() ->
    #{
        id => asobi_tournament_sup,
        start => {asobi_tournament_sup, start_link, []},
        type => supervisor
    }.

presence_spec() ->
    #{
        id => asobi_presence,
        start => {asobi_presence, start_link, []}
    }.

oidc_providers_spec() ->
    #{
        id => asobi_oidc_providers,
        start => {erlang, apply, [fun ensure_oidc_providers/0, []]},
        restart => temporary
    }.

%% asobi#220: nova_auth_oidc_sup (the provider-configuration-worker
%% supervisor) never starts any workers on its own - ensure_providers/1 is
%% what does that, and nothing called it before this. asobi_oauth_controller
%% has always called nova_auth_oidc_jwt:validate_token/3 to check an OIDC
%% ID token, but that needs a running provider worker to fetch the JWKS,
%% and none was ever started - OIDC social login has never actually worked.
%%
%% Only run this when at least one OIDC provider is configured - not to
%% avoid a blocking network fetch at boot (oidcc_provider_configuration_worker
%% loads its discovery document via handle_continue, so ensure_providers/1
%% itself never blocks on the network either way), but so a deployment that
%% doesn't use OIDC never spawns a permanent worker, and its retry traffic,
%% for nothing.
%%
%% Reads asobi_oidc_config:config/0's already-narrowed-and-validated
%% `providers` map, not the raw oidc_providers env var directly, so this
%% gate and what ensure_providers/1 actually consumes can never disagree.
%% config/0 raises a clear asobi#220 error on a provider entry that's
%% present but missing (or non-https) issuer, rather than letting
%% ensure_providers/1 crash on a bare #{issuer := _} pattern match deep
%% inside a dependency.
ensure_oidc_providers() ->
    case maps:get(providers, asobi_oidc_config:config(), #{}) of
        Providers when map_size(Providers) > 0 ->
            ok = nova_auth_oidc:ensure_providers(asobi_oidc_config);
        _ ->
            ok
    end,
    ignore.

rate_limit_spec() ->
    #{
        id => asobi_rate_limits,
        start => {erlang, apply, [fun register_limiters/0, []]},
        restart => temporary
    }.

register_limiters() ->
    %% F-19: auth and iap routes get tighter per-IP / per-token limits.
    %% Brute-force resistance: 5 auth requests/sec was the historical
    %% setting and is reasonable for honest UX; iap is per-purchase so
    %% 10/sec is plenty. The general-purpose api limiter stays at 300.
    %% ws_connect protects the WebSocket upgrade path: 60/sec/IP is
    %% high enough for legitimate mobile reconnect storms (carrier-NAT
    %% means many real users share one IP) but low enough to bound a
    %% single-IP flood of fresh connections.
    %%
    %% register gets its OWN bucket (asobi#157): /auth/register runs the
    %% password KDF (pbkdf2_sha256, 100k iters) as its only cost gate, so
    %% sharing login's bucket let a signup flood both starve honest logins
    %% and amplify CPU. A dedicated, tighter limit (registration is a
    %% one-time event, rarer than login) caps single-IP KDF cost and
    %% isolates it from login. Per-IP only bounds single-IP cost;
    %% distributed abuse needs the pre-auth gate tracked in asobi#158.
    Defaults = #{
        auth => #{algorithm => sliding_window, limit => 5, window => 1000},
        register => #{algorithm => sliding_window, limit => 3, window => 1000},
        %% Account erasure runs the same KDF as register, on the wrong-password
        %% path an attacker controls, and it is the only irreversible thing a
        %% player can do to themselves. Deleting your account is a once-ever
        %% action, so the honest rate is far below register's: this bounds
        %% single-IP KDF cost on a route where a legitimate client has no reason
        %% to retry quickly. Same argument as register (asobi#157), lower
        %% number because the honest frequency is lower.
        erase => #{algorithm => sliding_window, limit => 3, window => 60000},
        iap => #{algorithm => sliding_window, limit => 10, window => 1000},
        %% Extension routes mounted with `security => webhook` (see
        %% asobi_extension:routes/0). A webhook handler authenticates its
        %% caller itself - signature crypto on every request - so letting
        %% tokenless traffic ride the 300/s api bucket makes each request a
        %% CPU amplifier. Same shape and size as iap, which is the known
        %% webhook case the seam exists for.
        webhook => #{algorithm => sliding_window, limit => 10, window => 1000},
        api => #{algorithm => sliding_window, limit => 300, window => 1000},
        ws_connect => #{algorithm => sliding_window, limit => 60, window => 1000},
        %% Per-player bound on world/match joins (asobi#193). Joining is how a
        %% client reaches a roster, and leaving is free, so an unbounded join
        %% rate lets one account sweep every live world by joining, reading
        %% `world.joined`, and leaving. Keyed on player_id, not IP: the cost we
        %% are bounding is per-identity, and identities are what an attacker
        %% would rotate. Generous for real play - a player browsing worlds joins
        %% a handful of times a minute, not ten times a second.
        join => #{algorithm => sliding_window, limit => 10, window => 60000},
        %% Global (not per-IP) bound on guest-create throughput. Guest rows are
        %% minted unauthenticated and cheaply, so a per-IP limit alone lets a
        %% botnet spam rows; this caps the total rate. Keyed on a constant.
        guest_global => #{algorithm => sliding_window, limit => 100, window => 1000},
        %% asobi#252: bounds LOG LINES (not the telemetry counter, which stays
        %% unconditional - see asobi_script_log_limiter's moduledoc) from a
        %% script that fails on every tick. Keyed per call site's own choice
        %% of "same recurring failure" (typically per zone or per callback),
        %% so one broken zone/script doesn't starve another's visibility.
        %% Generous: this is about volume, not adversarial abuse.
        script_log => #{algorithm => sliding_window, limit => 3, window => 10_000},
        %% Backstop on world zone-crossing re-homes (asobi#248). Each crossing
        %% resubscribes part of a player's interest ring, and each new
        %% subscription makes a blocking asobi_terrain_store call and resends
        %% a full zone snapshot. asobi_zone's past_zone_margin/4 hysteresis
        %% only filters jitter (oscillating within the margin); an attacker
        %% moving with amplitude past it crosses every tick regardless, so
        %% this limiter is the actual adversarial control, not a backstop
        %% under it. Keyed on player_id: the cost is per-session. 5/sec is
        %% generous for real movement (crossing more than a few zones a
        %% second sustained isn't a realistic player speed) but denies a
        %% client thrashing a boundary from forcing this every tick.
        rehome => #{algorithm => sliding_window, limit => 5, window => 1000},
        %% Per-player alone doesn't bound the aggregate: every subscribe a
        %% crossing triggers calls into the single asobi_terrain_store shared
        %% by the whole world, so N concurrent attackers each keeping their
        %% own 5/sec budget scales that blocking load linearly with attacker
        %% count. Same reasoning as guest_global. Size from your real
        %% concurrent-player target; this default is a placeholder.
        rehome_global => #{algorithm => sliding_window, limit => 200, window => 1000},
        %% world.resync is the one inbound frame whose response is orders of
        %% magnitude larger than the request: a ~120-byte ask produces a full
        %% zone keyframe, measured at ~50 KB of JSON for a 400-entity zone, so
        %% roughly 400x. Two limiters because one cannot cover both shapes of
        %% abuse. Per player bounds a single client looping the request; the
        %% global bucket bounds the aggregate, because per-player alone lets N
        %% players cost N times the egress and the node's uplink does not care
        %% whose request it was.
        %%
        %% Keyed on player_id rather than IP on purpose. The frame is only
        %% reachable on an authenticated session, and IP keying would starve
        %% every player behind one carrier-grade NAT - the same reasoning
        %% asobi_sup already applies to the rehome pair.
        %%
        %% An honest client needs this once per detected gap, and a gap on a TCP
        %% wire should be impossible, so 2 per 10 s is generous. A client hitting
        %% the limit is already broken and backing it off is the correct answer.
        resync => #{algorithm => sliding_window, limit => 2, window => 10000},
        resync_global => #{algorithm => sliding_window, limit => 20, window => 1000}
    },
    Configured =
        case application:get_env(asobi, rate_limits, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    maps:foreach(
        fun(Group, DefaultOpts) ->
            Overrides =
                case maps:get(Group, Configured, #{}) of
                    O when is_map(O) -> O;
                    _ -> #{}
                end,
            Opts = maps:merge(DefaultOpts, Overrides),
            Name = limiter_name(Group),
            seki:new_limiter(Name, Opts)
        end,
        Defaults
    ),
    asobi_script_log_limiter:init_table(),
    ignore.

limiter_name(auth) -> asobi_auth_limiter;
limiter_name(register) -> asobi_register_limiter;
limiter_name(iap) -> asobi_iap_limiter;
limiter_name(webhook) -> asobi_webhook_limiter;
limiter_name(api) -> asobi_api_limiter;
limiter_name(ws_connect) -> asobi_ws_connect_limiter;
limiter_name(join) -> asobi_join_limiter;
limiter_name(erase) -> asobi_erase_limiter;
limiter_name(guest_global) -> asobi_guest_global_limiter;
limiter_name(script_log) -> asobi_script_log_limiter;
limiter_name(rehome) -> asobi_rehome_limiter;
limiter_name(rehome_global) -> asobi_rehome_global_limiter;
limiter_name(resync) -> asobi_world_resync_limiter;
limiter_name(resync_global) -> asobi_world_resync_global_limiter.

cluster_spec() ->
    #{
        id => asobi_cluster,
        start => {asobi_cluster, start_link, []}
    }.

auth_cache_spec() ->
    #{
        id => asobi_auth_cache,
        start => {asobi_auth_cache, start_link, []}
    }.
