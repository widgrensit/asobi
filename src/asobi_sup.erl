-module(asobi_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

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
    Children = [
        rate_limit_spec(),
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
        season_manager_spec(),
        guest_reaper_spec()
    ],
    {ok, {SupFlags, Children}}.

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
        iap => #{algorithm => sliding_window, limit => 10, window => 1000},
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
        rehome_global => #{algorithm => sliding_window, limit => 200, window => 1000}
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
limiter_name(api) -> asobi_api_limiter;
limiter_name(ws_connect) -> asobi_ws_connect_limiter;
limiter_name(join) -> asobi_join_limiter;
limiter_name(guest_global) -> asobi_guest_global_limiter;
limiter_name(script_log) -> asobi_script_log_limiter;
limiter_name(rehome) -> asobi_rehome_limiter;
limiter_name(rehome_global) -> asobi_rehome_global_limiter.

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

season_manager_spec() ->
    #{
        id => asobi_season_manager,
        start => {asobi_season_manager, start_link, []}
    }.
