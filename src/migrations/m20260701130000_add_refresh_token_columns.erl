-module(m20260701130000_add_refresh_token_columns).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [
        %% Rotating refresh tokens: `family_id` groups an access+refresh
        %% lineage so reuse detection can burn the whole family; `used_at`
        %% marks a refresh token as already rotated.
        {alter_table, <<"player_tokens">>, [
            {add_column, #kura_column{name = family_id, type = string}},
            {add_column, #kura_column{name = used_at, type = utc_datetime}}
        ]},
        {create_index, <<"player_tokens">>, [family_id], #{}}
    ].

-spec down() -> [kura_migration:operation()].
down() ->
    [
        {drop_index, <<"player_tokens_family_id_index">>},
        {alter_table, <<"player_tokens">>, [
            {drop_column, family_id},
            {drop_column, used_at}
        ]}
    ].
