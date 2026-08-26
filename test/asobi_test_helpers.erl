-module(asobi_test_helpers).

-export([start/1, unique_username/1, unique_id/1, binary_join/2]).
-export([fake_session/1, fake_session/2, unique_session/1, assert_no_session/1]).
-export([http_routes/1, routes_missing_options/1, preflight_targets/1, sample_path/1]).

-spec start(list()) -> list().
start(Config) ->
    nova_test:start(asobi) ++ Config.

-spec unique_username(binary()) -> binary().
unique_username(_Prefix) ->
    %% Use first 32 chars of a hex-encoded random value
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    binary:part(Hex, 0, 32).

-doc """
A value no other run will produce, for any column under a unique index.

The local database persists between runs while CI gets a fresh one, so a
suite that writes a uniquely-constrained fixture and does not delete it only
ever breaks local developers - and looks like a regression in unrelated work
when it does (asobi#357).

`erlang:unique_integer/1` is not a substitute: it is unique within one
runtime instance, and each `rebar3 ct` run is a new one, so two runs hand out
the same low integers. Random bytes are unique across runs and let a suite
run concurrently with itself.
""".
-spec unique_id(binary()) -> binary().
unique_id(Prefix) ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<Prefix/binary, "_", Hex/binary>>.

%% --- Player sessions ---

-doc """
A live, pg-registered session for a player.

`asobi_world_server` and `asobi_match_server` both resolve a player's session
through `pg:get_members(nova_scope, {player, PlayerId})`. With no member the
pid is `undefined` and the caller degrades: no interest subscriptions, no
monitor. A test that asserts on subscriptions therefore needs a real member,
or it asserts on the degraded path without saying so.

Hand-copied into five test modules before this lived here, in two variants
that differed only in whether they forwarded messages.

**`nova_scope` is shared by the whole run and `{player, Id}` is not
namespaced**, so a module that leaves one of these alive lends it to every
later test that happens to use the same id. That has now been found three
times, most recently as a test that passed only in a full run because it
borrowed another module's session and subscribed it to four zones. Prefer
`unique_session/1`; if you must name the player, kill the session in an
`after`.
""".
-spec fake_session(binary()) -> pid().
fake_session(PlayerId) ->
    fake_session(PlayerId, undefined).

-doc """
As `fake_session/1`, forwarding every message to `Owner` as `{PlayerId, Msg}`
so a test can assert on actual delivery rather than on subscriber-map
bookkeeping.
""".
-spec fake_session(binary(), pid() | undefined) -> pid().
fake_session(PlayerId, Owner) ->
    Pid = spawn(fun Loop() ->
        receive
            stop ->
                ok;
            Msg ->
                forward(Owner, PlayerId, Msg),
                Loop()
        end
    end),
    ok = pg:join(nova_scope, {player, PlayerId}, Pid),
    Pid.

-spec forward(pid() | undefined, binary(), term()) -> ok.
forward(undefined, _PlayerId, _Msg) ->
    ok;
forward(Owner, PlayerId, Msg) ->
    Owner ! {PlayerId, Msg},
    ok.

-doc """
A session under an id no other run or module can collide with.

`unique_id/1` rather than a hand-picked name: a distinctive id works only
until someone else picks it, which is the same guarantee `p1` had.
""".
-spec unique_session(binary()) -> {binary(), pid()}.
unique_session(Prefix) ->
    PlayerId = unique_id(Prefix),
    {PlayerId, fake_session(PlayerId)}.

-doc """
Assert that nobody is registered as this player before the test relies on it.

For the tests that want the SESSION-LESS path. Without this, a leftover
session from another module silently turns that test into a different one -
which is exactly how the bug this helper documents stayed hidden.
""".
-spec assert_no_session(binary()) -> ok.
assert_no_session(PlayerId) ->
    case pg:get_members(nova_scope, {player, PlayerId}) of
        [] -> ok;
        Members -> error({session_already_registered, PlayerId, Members})
    end.

%% --- Router enumeration ---
%%
%% Tests that assert a property of "every route group" derive the groups from
%% `asobi_router:routes/1` through these, so a group added later is covered
%% without editing the test. Pure over the group list, so a suite can feed a
%% synthetic group and check the property actually fails on a bad one.

-spec http_routes([map()]) -> [{binary(), binary(), fun(), [atom()]}].
http_routes(Groups) ->
    [
        {Prefix, Path, Handler, maps:get(methods, Opts)}
     || #{prefix := Prefix, routes := Routes} <- Groups,
        {Path, Handler, Opts} <- Routes,
        is_map_key(methods, Opts)
    ].

-spec routes_missing_options([map()]) -> [{binary(), binary()}].
routes_missing_options(Groups) ->
    [
        {Prefix, Path}
     || {Prefix, Path, _Handler, Methods} <- http_routes(Groups),
        not lists:member(options, Methods)
    ].

%% One concrete request path per group that serves HTTP. Groups that only
%% carry a protocol handler (the WebSocket group) have no preflight to make.
-spec preflight_targets([map()]) -> [{binary(), binary()}].
preflight_targets(Groups) ->
    [Target || Group <- Groups, Target <- first_http_route(Group)].

-doc "Join binaries with a separator. lists:join/2 widens to [term()], which then defeats iolist_to_binary/1 - see docs/eqwalizer-idioms.md.".
-spec binary_join(binary(), [binary()]) -> binary().
binary_join(_Sep, []) -> ~"";
binary_join(_Sep, [B]) -> B;
binary_join(Sep, [B | Rest]) -> <<B/binary, Sep/binary, (binary_join(Sep, Rest))/binary>>.

-spec first_http_route(map()) -> [{binary(), binary()}].
first_http_route(#{prefix := Prefix} = Group) ->
    case http_routes([Group]) of
        [{_, Path, _, _} | _] -> [{Prefix, <<Prefix/binary, (sample_path(Path))/binary>>}];
        [] -> []
    end.

%% Concrete path for a declared route: every `:binding` segment becomes a
%% value no literal sibling route uses.
-spec sample_path(binary()) -> binary().
sample_path(Path) ->
    Segments = [
        case Segment of
            <<":", _/binary>> -> ~"g-1";
            Literal -> Literal
        end
     || Segment <- binary:split(Path, ~"/", [global])
    ],
    binary_join(~"/", Segments).
