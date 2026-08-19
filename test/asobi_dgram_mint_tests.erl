-module(asobi_dgram_mint_tests).
-include_lib("eunit/include/eunit.hrl").

%% The contract between the mint and the zone: which connections may be sent a
%% pose. It is one ETS row read on every zone's broadcast tick, so it is worth
%% pinning the shape rather than discovering a change from frozen entities.

-define(MIRROR, asobi_dgram_conns).

pose_conn_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a binary-wire connection is a pose target", fun binary_wire_is_a_target/0},
        {"a JSON-wire connection is not", fun json_wire_is_not_a_target/0},
        {"an unminted player is not", fun unminted_is_not_a_target/0}
    ]}.

setup() ->
    drop_mirror(),
    ets:new(?MIRROR, [named_table, public, {read_concurrency, true}]),
    ok.

cleanup(_) ->
    drop_mirror().

drop_mirror() ->
    case ets:whereis(?MIRROR) of
        undefined -> ok;
        _Tid -> ets:delete(?MIRROR)
    end,
    ok.

binary_wire_is_a_target() ->
    ets:insert(?MIRROR, {~"p1", 4242, true}),
    ?assertEqual({ok, 4242}, asobi_dgram_mint:pose_conn_of(~"p1")).

%% The whole point. This player HAS minted - UDP input from them is delivered -
%% but they connected on the text wire, so they were never sent an `add` record
%% and cannot resolve a slot. A pose would be dropped client-side and the entity
%% would look frozen (asobi#510).
json_wire_is_not_a_target() ->
    ets:insert(?MIRROR, {~"p1", 4242, false}),
    ?assertEqual(error, asobi_dgram_mint:pose_conn_of(~"p1")).

unminted_is_not_a_target() ->
    ?assertEqual(error, asobi_dgram_mint:pose_conn_of(~"nobody")).

%% No mirror at all is the common case: the plane is not configured on this node,
%% and a zone still calls this once per subscriber per tick.
no_mirror_is_not_a_target_test() ->
    drop_mirror(),
    ?assertEqual(error, asobi_dgram_mint:pose_conn_of(~"p1")).
