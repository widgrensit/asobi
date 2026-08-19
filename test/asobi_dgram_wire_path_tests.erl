-module(asobi_dgram_wire_path_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#527: the negotiated wire has to survive every hop between the socket and
%% the mint, and each hop rebuilds the map it hands on. Both earlier datagram gaps
%% were the same shape - a value correct at one end and absent at the other, with
%% the transport itself reporting healthy - so this walks the whole path a client
%% walks: a `rpc.call` frame on a session that negotiated the binary wire, through
%% the dispatcher, into the mint, and then asks the mirror the question the zone
%% asks on every tick.

-define(MIRROR, asobi_dgram_conns).

wire_path_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"a binary-wire session mints a pose target", fun binary_wire_is_minted_as_a_target/0},
        {"a json-wire session mints, but is not one", fun json_wire_is_minted_but_not/0}
    ]}.

setup() ->
    asobi_readiness:mark_ready(),
    %% The gateway half of the mint. It has to answer before the credential is
    %% handed out, so the plane is "configured" here without a gateway to talk to.
    meck:new(asobi_dgram_link_client, [passthrough, non_strict]),
    meck:expect(asobi_dgram_link_client, enabled, 0, true),
    meck:expect(asobi_dgram_link_client, register, 1, ok),
    meck:expect(asobi_dgram_link_client, unregister, 1, ok),
    {ok, Mint} = asobi_dgram_mint:start_link(),
    Mint.

cleanup(Mint) ->
    gen_server:stop(Mint),
    meck:unload(asobi_dgram_link_client),
    asobi_readiness:reset(),
    ok.

%% The defect: the frame arrived on a binary-wire session, the mint recorded JSON,
%% `pose_conn_of/1` answered `error` for every player, and the zone emitted no pose
%% at all - which the SDK reads as a dead plane and shuts down, while the UDP
%% handshake below it completes cleanly and reports nothing wrong.
binary_wire_is_minted_as_a_target() ->
    PlayerId = open_the_plane(~"binary"),
    ?assertMatch({ok, ConnId} when is_integer(ConnId), asobi_dgram_mint:pose_conn_of(PlayerId)).

%% The other half of the same contract, and the reason the wire travels at all: a
%% JSON-wire client is still minted - `world.input` upstream needs no slots - but
%% never receives an `add` on `world.tick`, so a pose would name a slot it cannot
%% resolve.
json_wire_is_minted_but_not() ->
    PlayerId = open_the_plane(~"json"),
    ?assertEqual(error, asobi_dgram_mint:pose_conn_of(PlayerId)),
    ?assert(ets:member(?MIRROR, PlayerId)).

%% --- Helpers ---

%% One `asobi.datagram.open` the way a client sends it: a text frame into the
%% socket handler, on a state carrying the wire `session.connect` negotiated.
open_the_plane(Wire) ->
    PlayerId = ~"p-527",
    Frame = json:encode(#{
        ~"type" => ~"rpc.call",
        ~"cid" => ~"c-1",
        ~"payload" => #{
            ~"protocol" => asobi_rpc:protocol(),
            ~"method" => ~"asobi.datagram.open",
            ~"params" => #{}
        }
    }),
    {reply, {text, Reply}, _State} = asobi_ws_handler:websocket_handle(
        {text, iolist_to_binary(Frame)}, state(PlayerId, Wire)
    ),
    ?assertMatch(#{~"type" := ~"rpc.ok"}, json:decode(iolist_to_binary(Reply))),
    PlayerId.

state(PlayerId, Wire) ->
    #{
        player_id => PlayerId,
        session => self(),
        wire => Wire,
        ws_msg_count => 0,
        ws_msg_window_start => erlang:system_time(millisecond)
    }.
