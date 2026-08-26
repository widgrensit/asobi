-module(asobi_test_helpers).

-export([start/1, unique_username/1, unique_id/1, binary_join/2]).
-export([fake_session/1, fake_session/2, unique_session/1, assert_no_session/1]).
-export([with_session/2, with_session/3, with_unique_session/2, release_session/2]).
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
    %% Labelled with the CALLER's frame, read from `self()` before the spawn.
    %% `current_function` used to name the test module because the fun was
    %% written there; extracting it here made every leaker report
    %% `asobi_test_helpers`, which is the one answer `assert_no_session/1`
    %% cannot use. `initial_call` never helped - it is `{erlang,apply,2}` for a
    %% plain spawn and `{proc_lib,init_p,5}` for a real session.
    Caller = caller_frame(),
    Pid = spawn(fun Loop() ->
        proc_lib:set_label({fake_session, PlayerId, Caller}),
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

-spec caller_frame() -> {module(), atom(), arity(), term()} | unknown.
caller_frame() ->
    case erlang:process_info(self(), current_stacktrace) of
        {current_stacktrace, Stack} -> first_foreign_frame(Stack);
        _ -> unknown
    end.

-spec first_foreign_frame([term()]) -> {module(), atom(), arity(), term()} | unknown.
first_foreign_frame([{M, F, A, Loc} | _]) when
    is_atom(M), M =/= ?MODULE, is_atom(F), is_integer(A), is_list(Loc)
->
    {M, F, A, frame_line(Loc)};
first_foreign_frame([_ | Rest]) ->
    first_foreign_frame(Rest);
first_foreign_frame([]) ->
    unknown.

-spec frame_line([term()]) -> pos_integer() | undefined.
frame_line([{line, L} | _]) when is_integer(L), L > 0 -> L;
frame_line([_ | Rest]) -> frame_line(Rest);
frame_line([]) -> undefined.

-spec forward(pid() | undefined, binary(), term()) -> ok.
forward(undefined, _PlayerId, _Msg) ->
    ok;
forward(Owner, PlayerId, Msg) ->
    Owner ! {PlayerId, Msg},
    ok.

-doc """
Run `Fun` with a session registered, and release it whatever happens.

`fake_session/1,2` gives you a pid and leaves the pairing to discipline, which
is how three of them ended up bound to `_`-prefixed variables and registered
for the rest of the run. An `_` prefix says the author is discarding the pid;
the pg group is not. Prefer these where the shape allows it, so the release is
structural rather than remembered.
""".
-spec with_session(binary(), fun(() -> R)) -> R.
with_session(PlayerId, Fun) ->
    with_session(PlayerId, undefined, Fun).

-spec with_session(binary(), pid() | undefined, fun(() -> R)) -> R.
with_session(PlayerId, Owner, Fun) ->
    Pid = fake_session(PlayerId, Owner),
    try
        Fun()
    after
        release_session(PlayerId, Pid)
    end.

-doc """
Release a session: leave the group, stop the process, drain what it forwarded.

`pg:leave/3` rather than relying on the process dying, because a killed pid
lingers in the group for tens of milliseconds - long enough for an immediately
following `assert_no_session/1` to fail naming a dead pid, and long enough for
production code reading that group to get one.

The drain matters because the owner is the SAME process for every test in a
module: undrained `{PlayerId, Msg}` forwards outlive the test that caused them,
and `received_entity/2`-style selective receives would happily satisfy
themselves from a stale one if an id ever repeats.
""".
-spec release_session(binary(), pid()) -> ok.
release_session(PlayerId, Pid) ->
    _ = pg:leave(nova_scope, {player, PlayerId}, Pid),
    Pid ! stop,
    drain_forwarded(PlayerId).

-spec drain_forwarded(binary()) -> ok.
drain_forwarded(PlayerId) ->
    receive
        {PlayerId, _} -> drain_forwarded(PlayerId)
    after 0 -> ok
    end.

-doc """
As `with_session/2` under an id nothing can collide with. `Fun` receives it.
""".
-spec with_unique_session(binary(), fun((binary()) -> R)) -> R.
with_unique_session(Prefix, Fun) ->
    PlayerId = unique_id(Prefix),
    with_session(PlayerId, fun() -> Fun(PlayerId) end).

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
        Members -> error({session_already_registered, PlayerId, [who(M) || M <- Members]})
    end.

%% In a full run the module that fails this assertion is the one that did
%% nothing wrong, and a bare pid does not say who registered it - by the time
%% anyone reads the output the process may be gone. Name the leaker.
%% `proc_lib:get_label/1` is the useful half - see fake_session/2. It answers
%% `undefined` for an unlabelled or dead pid rather than raising.
%%
%% `process_info/2` RAISES on a remote pid, and pg is a distributed registry:
%% the day asobi is not single-node, an unguarded call here turns the leak
%% report into a badarg that hides the leak it was written to find.
%%
%% Deliberately not `dictionary`, `messages` or `backtrace`: asobi_lua_world
%% stores the whole zone state - Luerl VM included - in its process
%% dictionary, so a leaked zone process would dump the entire scripting VM and
%% every entity map into CI output. `current_function` is an MFA; arity, not
%% arguments.
-spec who(pid()) -> tuple().
who(Pid) when node(Pid) =/= node() ->
    {Pid, {remote, node(Pid)}};
who(Pid) ->
    {Pid, proc_lib:get_label(Pid), erlang:process_info(Pid, [current_function, registered_name])}.

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
