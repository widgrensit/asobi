%% The `seq` on a world.input, and the seq that comes back as a world.ack.
%%
%% Bounded to a non-negative JS-safe integer at EVERY door: the value is echoed
%% back on every broadcast tick, so an unbounded bignum is a per-tick
%% json:encode amplifier, and the SDKs that read this field into an int64
%% (Dart, C#, C++) cannot parse a wider one at all. There are three doors -
%% the WebSocket handler, the datagram uplink, and a game module reporting what
%% it consumed - and a cap on two of them is a cap on none.
-define(MAX_ACK_SEQ, 16#1FFFFFFFFFFFFF).
