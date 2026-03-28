-module(asobi_auth).
-behaviour(nova_auth).

-export([config/0]).

-spec config() -> map().
config() ->
    #{
        repo => asobi_repo,
        user_schema => asobi_player,
        token_schema => asobi_player_token,
        user_identity_field => username,
        user_password_field => hashed_password,
        session_validity_days => 30,
        hash_algorithm => pbkdf2_sha256,
        token_bytes => 32
    }.
