-module(asobi_ops_write_SUITE).

%% The ops write plane over real HTTP against a real Postgres. What is here
%% and not in `asobi_ops_write_tests` is everything a mock would have had to
%% pretend: the audit row landing in its table, the wallet balance actually
%% moving, and the same idempotency key twice.

-include_lib("nova_test/include/nova_test.hrl").
-include_lib("kura/include/kura.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    anonymous_mutation_is_forbidden/1,
    player_token_cannot_mutate/1,
    ban_writes_the_row_and_the_audit/1,
    banned_player_loses_its_session/1,
    second_ban_keeps_the_first_timestamp/1,
    unban_restores_the_player/1,
    ban_of_an_unknown_player_is_404/1,
    grant_moves_the_balance/1,
    replayed_grant_moves_nothing/1,
    grant_without_a_key_is_422/1,
    create_item_returns_its_id_and_audits_it/1,
    create_listing_rejects_a_malformed_item_id/1,
    create_tournament_without_a_name_is_422/1
]).

-define(OPS_SECRET, ~"ops-write-suite-secret").

all() -> [{group, ops_write}].

groups() ->
    [
        {ops_write, [sequence], [
            anonymous_mutation_is_forbidden,
            player_token_cannot_mutate,
            ban_writes_the_row_and_the_audit,
            banned_player_loses_its_session,
            second_ban_keeps_the_first_timestamp,
            unban_restores_the_player,
            ban_of_an_unknown_player_is_404,
            grant_moves_the_balance,
            replayed_grant_moves_nothing,
            grant_without_a_key_is_422,
            create_item_returns_its_id_and_audits_it,
            create_listing_rejects_a_malformed_item_id,
            create_tournament_without_a_name_is_422
        ]}
    ].

init_per_suite(Config) ->
    asobi_test_helpers:start(Config).

end_per_suite(Config) ->
    Config.

init_per_group(ops_write, Config) ->
    Original = application:get_env(asobi, ops_secret),
    application:set_env(asobi, ops_secret, ?OPS_SECRET),
    {PlayerId, Token} = register(Config),
    [
        {ops_secret_was, Original},
        {run, asobi_id:rand_suffix(6)},
        {player_id, PlayerId},
        {session_token, Token}
        | Config
    ];
init_per_group(_Group, Config) ->
    Config.

end_per_group(ops_write, Config) ->
    case lists:keyfind(ops_secret_was, 1, Config) of
        {ops_secret_was, {ok, Value}} -> application:set_env(asobi, ops_secret, Value);
        _ -> application:unset_env(asobi, ops_secret)
    end,
    Config;
end_per_group(_Group, Config) ->
    Config.

%%--------------------------------------------------------------------
%% The plane is still the operator's
%%--------------------------------------------------------------------

anonymous_mutation_is_forbidden(Config) ->
    {ok, Resp} = nova_test:post(ban_path(Config), #{json => #{}}, Config),
    ?assertStatus(403, Resp),
    ?assertEqual(undefined, banned_at(player_id(Config))),
    Config.

%% The read plane already refuses a player token; opening the write plane must
%% not have opened a second door into it.
player_token_cannot_mutate(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    {ok, Resp} = nova_test:post(
        ban_path(Config),
        #{json => #{}, headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertStatus(403, Resp),
    ?assertEqual(undefined, banned_at(player_id(Config))),
    Config.

%%--------------------------------------------------------------------
%% Ban
%%--------------------------------------------------------------------

ban_writes_the_row_and_the_audit(Config) ->
    {ok, Resp} = post(ban_path(Config), #{}, ~"ban-op", Config),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"data" := #{~"banned" := true, ~"changed" := true}}, Resp),
    ?assertNotEqual(undefined, banned_at(player_id(Config))),
    Row = audit(~"players.ban", ~"ban-op", Config),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(1, maps:get(succeeded_count, Row)),
    ?assertEqual(player_id(Config), maps:get(target_id, Row)),
    ?assertEqual(~"player", maps:get(target_type, Row)),
    Config.

%% A ban that leaves the player's token working is not a ban. The token was
%% minted and used before the ban, so it is also in `asobi_auth_cache` -
%% making this the regression guard for the eviction step specifically.
banned_player_loses_its_session(Config) ->
    {session_token, Token} = lists:keyfind(session_token, 1, Config),
    {ok, Resp} = nova_test:get(
        "/api/v1/wallets",
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    ?assertStatus(401, Resp),
    Config.

second_ban_keeps_the_first_timestamp(Config) ->
    First = banned_at(player_id(Config)),
    {ok, Resp} = post(ban_path(Config), #{}, ~"reban-op", Config),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"data" := #{~"changed" := false}}, Resp),
    ?assertEqual(First, banned_at(player_id(Config))),
    ?assertEqual(0, maps:get(succeeded_count, audit(~"players.ban", ~"reban-op", Config))),
    Config.

unban_restores_the_player(Config) ->
    {ok, Resp} = post(unban_path(Config), #{}, ~"unban-op", Config),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"data" := #{~"banned" := false, ~"changed" := true}}, Resp),
    ?assertEqual(undefined, banned_at(player_id(Config))),
    ?assertEqual(~"ok", maps:get(outcome, audit(~"players.unban", ~"unban-op", Config))),
    Config.

ban_of_an_unknown_player_is_404(Config) ->
    Path = "/api/v1/ops/players/" ++ binary_to_list(asobi_id:generate()) ++ "/ban",
    {ok, Resp} = post(Path, #{}, ~"miss-op", Config),
    ?assertStatus(404, Resp),
    ?assertJson(#{~"error" := #{~"code" := ~"ops.not_found"}}, Resp),
    Config.

%%--------------------------------------------------------------------
%% Grants
%%--------------------------------------------------------------------

grant_moves_the_balance(Config) ->
    {ok, Resp} = post(grants_path(Config), grant_body(~"key-a"), ~"grant-op", Config),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"data" := #{~"applied" := true}}, Resp),
    ?assertEqual(250, balance(player_id(Config))),
    ?assertEqual(1, maps:get(succeeded_count, audit(~"economy.grant", ~"grant-op", Config))),
    Config.

%% The one that matters. A retried grant must leave the balance where it was,
%% write no second ledger row, and still answer 200 - a retry that reports
%% failure invites a third attempt.
replayed_grant_moves_nothing(Config) ->
    {ok, Resp} = post(grants_path(Config), grant_body(~"key-a"), ~"replay-op", Config),
    ?assertStatus(200, Resp),
    ?assertJson(#{~"data" := #{~"applied" := false}}, Resp),
    ?assertEqual(250, balance(player_id(Config))),
    Row = audit(~"economy.grant", ~"replay-op", Config),
    ?assertEqual(~"ok", maps:get(outcome, Row)),
    ?assertEqual(0, maps:get(succeeded_count, Row)),
    Config.

grant_without_a_key_is_422(Config) ->
    Body = #{~"currency" => ~"gold", ~"amount" => 250},
    {ok, Resp} = post(grants_path(Config), Body, ~"nokey-op", Config),
    ?assertStatus(422, Resp),
    ?assertJson(#{~"error" := #{~"code" := ~"ops.idempotency_key_required"}}, Resp),
    ?assertEqual(250, balance(player_id(Config))),
    Config.

%%--------------------------------------------------------------------
%% Definitions
%%--------------------------------------------------------------------

create_item_returns_its_id_and_audits_it(Config) ->
    Slug = <<"potion-", (asobi_id:rand_suffix(8))/binary>>,
    Body = #{~"slug" => Slug, ~"name" => ~"Potion", ~"category" => ~"consumable"},
    {ok, Resp} = post("/api/v1/ops/economy/items", Body, ~"item-op", Config),
    ?assertStatus(201, Resp),
    #{~"data" := #{~"id" := Id}} = nova_test:json(Resp),
    ?assertMatch({ok, #{slug := Slug}}, asobi_repo:get(asobi_item_def, Id)),
    ?assertEqual(Id, maps:get(target_id, audit(~"economy.item.create", ~"item-op", Config))),
    Config.

%% kura would take this as a uuid and Postgres would raise on it, so an
%% unchecked value is a 500 rather than the 422 it is.
create_listing_rejects_a_malformed_item_id(Config) ->
    Body = #{
        ~"item_def_id" => ~"not-a-uuid-but-still-thirty-six-byte",
        ~"currency" => ~"gold",
        ~"price" => 10
    },
    {ok, Resp} = post("/api/v1/ops/economy/listings", Body, ~"listing-op", Config),
    ?assertStatus(422, Resp),
    ?assertJson(
        #{
            ~"error" := #{
                ~"code" := ~"validation_failed",
                ~"details" := #{~"fields" := #{~"item_def_id" := _}}
            }
        },
        Resp
    ),
    Config.

create_tournament_without_a_name_is_422(Config) ->
    Body = #{
        ~"leaderboard_id" => ~"spring",
        ~"start_at" => ~"2026-09-01T00:00:00Z",
        ~"end_at" => ~"2026-09-02T00:00:00Z"
    },
    {ok, Resp} = post("/api/v1/ops/tournaments", Body, ~"tourney-op", Config),
    ?assertStatus(422, Resp),
    ?assertJson(#{~"error" := #{~"code" := ~"validation_failed"}}, Resp),
    Config.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

register(Config) ->
    Username = asobi_test_helpers:unique_username(~"opswrite"),
    {ok, Resp} = nova_test:post(
        "/api/v1/auth/register",
        #{json => #{~"username" => Username, ~"password" => ~"testpass123"}},
        Config
    ),
    #{~"player_id" := PlayerId, ~"access_token" := Token} = nova_test:json(Resp),
    %% Spend the token once so the ban path has a populated auth cache to
    %% evict rather than an empty one.
    {ok, _} = nova_test:get(
        "/api/v1/wallets",
        #{headers => [{~"authorization", <<"Bearer ", Token/binary>>}]},
        Config
    ),
    {PlayerId, Token}.

post(Path, Body, Operator, Config) ->
    nova_test:post(
        Path,
        #{
            json => Body,
            headers => [
                {~"authorization", <<"Bearer ", ?OPS_SECRET/binary>>},
                {~"x-asobi-operator", label(Operator, Config)}
            ]
        },
        Config
    ).

label(Operator, Config) ->
    {run, Run} = lists:keyfind(run, 1, Config),
    <<Operator/binary, "-", Run/binary>>.

player_id(Config) ->
    {player_id, PlayerId} = lists:keyfind(player_id, 1, Config),
    PlayerId.

ban_path(Config) ->
    "/api/v1/ops/players/" ++ binary_to_list(player_id(Config)) ++ "/ban".

unban_path(Config) ->
    "/api/v1/ops/players/" ++ binary_to_list(player_id(Config)) ++ "/unban".

grants_path(Config) ->
    "/api/v1/ops/players/" ++ binary_to_list(player_id(Config)) ++ "/grants".

grant_body(Key) ->
    #{~"currency" => ~"gold", ~"amount" => 250, ~"idempotency_key" => Key}.

%% The operator label is the display name on the audit row, so each case reads
%% back exactly the row it wrote. The per-run suffix matters as much as the
%% per-case name: this table is append-only and never pruned, so a second local
%% run against the same database would otherwise match the first run's rows too
%% (asobi#357's failure mode).
audit(Action, Operator, Config) ->
    Query = kura_query:where(
        kura_query:where(kura_query:from(asobi_ops_audit_entry), {action, Action}),
        {actor_display, label(Operator, Config)}
    ),
    {ok, [Row]} = asobi_repo:all(Query),
    Row.

banned_at(PlayerId) ->
    {ok, Player} = asobi_repo:get(asobi_player, PlayerId),
    case maps:get(banned_at, Player, undefined) of
        {{_, _, _}, {_, _, _}} = At -> At;
        _ -> undefined
    end.

balance(PlayerId) ->
    {ok, Wallets} = asobi_economy:get_wallets(PlayerId),
    case [B || #{currency := ~"gold", balance := B} <- Wallets] of
        [Balance] -> Balance;
        [] -> 0
    end.
