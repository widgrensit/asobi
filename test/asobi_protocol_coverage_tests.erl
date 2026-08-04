-module(asobi_protocol_coverage_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE_DIR, "priv/protocol/fixtures").
-define(WS_HANDLER, "src/ws/asobi_ws_handler.erl").
-define(WS_GUIDE, "guides/websocket-protocol.md").
-define(MATCH_SERVER, "src/matches/asobi_match_server.erl").
-define(WORLD_SERVER, "src/world/asobi_world_server.erl").
-define(DYNAMIC_EMIT_SOURCES, [
    ?MATCH_SERVER,
    "src/matches/asobi_matchmaker.erl",
    "src/votes/asobi_vote_server.erl",
    ?WORLD_SERVER
]).

%% Every event the asobi server emits must have a fixture file. SDKs use
%% the fixtures as ground truth for dispatch tests; a missing fixture
%% means a wire event that no SDK can dispatch-test against. This is the
%% gate that would have caught the match.matched / matchmaker.matched
%% drift before any SDK shipped.
every_emitted_event_has_a_fixture_test() ->
    Emitted = enumerate_emitted_events(),
    Fixtures = list_fixture_event_names(),
    Missing = lists:sort(Emitted -- Fixtures),
    ?assertEqual(
        [],
        Missing,
        lists:flatten(
            io_lib:format(
                "Server emits these events but priv/protocol/fixtures/<event>.json is missing: ~p",
                [Missing]
            )
        )
    ).

%% A fixture for an event the server no longer emits is a stale artifact
%% that misleads SDK authors. Catch it before it ships.
no_stale_fixtures_test() ->
    Emitted = enumerate_emitted_events(),
    Fixtures = list_fixture_event_names(),
    Stale = lists:sort(Fixtures -- Emitted),
    ?assertEqual(
        [],
        Stale,
        lists:flatten(
            io_lib:format(
                "Fixtures exist for events with no emit site in src/ — stale or renamed: ~p",
                [Stale]
            )
        )
    ).

%% Each fixture must be valid JSON and shape-conformant
%% (`{"type": "...", "payload": {...}}`). SDKs that copy a malformed
%% fixture into their test corpus would silently skip the test.
every_fixture_is_a_valid_envelope_test() ->
    Files = filelib:wildcard(?FIXTURE_DIR ++ "/*.json"),
    Bad = lists:filtermap(fun check_envelope/1, Files),
    ?assertEqual([], Bad).

%% --- helpers ---

check_envelope(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{~"type" := T, ~"payload" := P} when is_binary(T), is_map(P) ->
                    Stem = filename:basename(Path, ".json"),
                    case unicode:characters_to_binary(Stem) of
                        T -> false;
                        _ -> {true, {Path, type_filename_mismatch, T}}
                    end;
                _ ->
                    {true, {Path, missing_type_or_payload}}
            catch
                _:E -> {true, {Path, {invalid_json, E}}}
            end;
        {error, R} ->
            {true, {Path, {read_error, R}}}
    end.

list_fixture_event_names() ->
    Files = filelib:wildcard(?FIXTURE_DIR ++ "/*.json"),
    [unicode:characters_to_binary(filename:basename(F, ".json")) || F <- Files].

enumerate_emitted_events() ->
    WsHandler = read_file(?WS_HANDLER),
    Static = scan_encode_reply_types(WsHandler) ++ scan_extension_frame_types(WsHandler),
    MatchAtoms = collect_match_emit_atoms(),
    WorldAtoms = collect_world_emit_atoms(),
    lists:usort(
        Static ++
            [<<"match.", A/binary>> || A <- MatchAtoms] ++
            [<<"world.", A/binary>> || A <- WorldAtoms]
    ).

collect_match_emit_atoms() ->
    Direct = lists:flatmap(
        fun(Src) -> scan_tuple_atoms(read_file(Src), "match_event") end,
        ?DYNAMIC_EMIT_SOURCES
    ),
    %% asobi_match_server:broadcast_event(_, AtomEvent, _) is the public
    %% extension point used by the vote server.
    Broadcast = lists:flatmap(
        fun(Src) -> scan_broadcast_event_atoms(read_file(Src)) end,
        ?DYNAMIC_EMIT_SOURCES
    ),
    %% Inside asobi_match_server.erl, notify_players(AtomEvent, _) is a
    %% private helper that ultimately fans out as match.<atom>.
    Notify = scan_notify_players(read_file(?MATCH_SERVER)),
    Direct ++ Broadcast ++ Notify.

collect_world_emit_atoms() ->
    Direct = lists:flatmap(
        fun(Src) -> scan_tuple_atoms(read_file(Src), "world_event") end,
        ?DYNAMIC_EMIT_SOURCES
    ),
    %% Same private-helper pattern in world_server.
    Notify = scan_notify_players(read_file(?WORLD_SERVER)),
    Direct ++ Notify.

read_file(Rel) ->
    case file:read_file(Rel) of
        {ok, Bin} -> Bin;
        {error, _} -> <<>>
    end.

%% Pulls every literal type from `encode_reply(_, ~"X", _)` calls in the
%% WS handler. Captures both namespaced events ("match.state") and the
%% unnamespaced "error" envelope. Skips reason strings inside error
%% payloads — those are not events.
scan_encode_reply_types(Bin) ->
    Re = "encode_reply\\([^,]+,\\s*~\"([a-z][a-z._]*)\"",
    case re:run(Bin, Re, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [B || [B] <- Matches];
        nomatch -> []
    end.

%% S6: extension-produced frames go out through extension_frames/3, which
%% names two wire types - the current one and the deprecated pre-rename
%% one it is emitted alongside. Both reach clients, so both need a
%% fixture, and neither is visible to scan_encode_reply_types/1 because
%% the encode inside the helper takes a variable type.
scan_extension_frame_types(Bin) ->
    Re = "extension_frames\\(\\s*~\"([a-z][a-z._]*)\",\\s*~\"([a-z][a-z._]*)\"",
    case re:run(Bin, Re, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> lists:append(Matches);
        nomatch -> []
    end.

%% Pulls the atom out of `{match_event, foo, _}` / `{world_event, foo, _}`
%% literals. Atoms in Erlang start with [a-z]; this keeps us from
%% capturing variable names like `Event`.
scan_tuple_atoms(Bin, EventTag) ->
    Re = "\\{" ++ EventTag ++ ",\\s*([a-z][a-z_]*)\\b",
    extract_captures(Bin, Re).

%% Pulls the atom out of `asobi_match_server:broadcast_event(_, foo, _)`.
scan_broadcast_event_atoms(Bin) ->
    Re = "asobi_match_server:broadcast_event\\([^,]+,\\s*([a-z][a-z_]*)\\b",
    extract_captures(Bin, Re).

%% Pulls the atom out of `notify_players(foo, _)` calls. The function-head
%% `notify_players(Event, ...)` is skipped because variables start uppercase.
scan_notify_players(Bin) ->
    Re = "notify_players\\(([a-z][a-z_]*)\\b",
    extract_captures(Bin, Re).

extract_captures(Bin, Re) ->
    case re:run(Bin, Re, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [B || [B] <- Matches];
        nomatch -> []
    end.

%% The existence and envelope checks above cannot catch a fixture whose
%% payload has the wrong KEYS. world.list.json shipped for a long time with
%% `id`/`capacity`/`size` while the server emits
%% `world_id`/`max_players`/`player_count`. SDKs treat these fixtures as
%% ground truth for dispatch tests, so a wrong-shaped fixture teaches every
%% client the wrong contract and nothing fails.
%%
%% The two listing events have a pure projection function to compare
%% against, so pin them exactly.
listing_fixtures_match_the_projection_test() ->
    WorldKeys = projection_keys(fun asobi_world_server:listing_info/1, #{
        world_id => ~"w",
        status => running,
        player_count => 1,
        max_players => 2,
        mode => ~"m",
        grid_size => 1,
        started_at => 0,
        players => [~"p"]
    }),
    ?assertEqual(
        WorldKeys,
        fixture_entry_keys("world.list", ~"worlds"),
        "world.list fixture must match asobi_world_server:listing_info/1"
    ),

    MatchKeys = projection_keys(fun asobi_match_server:listing_info/1, #{
        match_id => ~"m",
        status => waiting,
        player_count => 1,
        max_players => 2,
        mode => ~"m",
        players => [~"p"],
        listed => true
    }),
    ?assertEqual(
        MatchKeys,
        fixture_entry_keys("match.list", ~"matches"),
        "match.list fixture must match asobi_match_server:listing_info/1"
    ).

%% #303: game.broadcast's binary event-name path (asobi_ws_handler's
%% ?RESERVED_EVENT_NAMES) closes the match./world. wire namespace to
%% scripts by rejecting any name asobi itself would otherwise emit — a
%% script-supplied "tick" must never produce a frame indistinguishable
%% from a genuine `world.tick` broadcast. This asserts that guarantee
%% stays honest: every match./world. event this module discovers is
%% emitted must have its bare suffix reserved, so a future library event
%% that's added can't silently reopen the forgery hole.
every_emitted_match_or_world_event_is_reserved_test() ->
    Emitted = enumerate_emitted_events(),
    Suffixes = lists:usort(lists:filtermap(fun match_or_world_suffix/1, Emitted)),
    Reserved = asobi_ws_handler:reserved_event_names(),
    Missing = Suffixes -- Reserved,
    ?assertEqual(
        [],
        Missing,
        lists:flatten(
            io_lib:format(
                "match./world. event suffixes not in asobi_ws_handler:?RESERVED_EVENT_NAMES: ~p",
                [Missing]
            )
        )
    ).

%% #302: the reserved set is a contract game authors design event names
%% against, so the guide spells it out rather than sending them to the
%% source. A library event added later moves ?RESERVED_EVENT_NAMES (the
%% test above sees to that) and would leave the guide quietly wrong.
guide_documents_the_reserved_event_names_test() ->
    Documented = lists:usort(scan_documented_reserved_names(read_file(?WS_GUIDE))),
    Reserved = lists:usort(asobi_ws_handler:reserved_event_names()),
    ?assertEqual(
        Reserved,
        Documented,
        "reserved-event-names block in guides/websocket-protocol.md is out of sync "
        "with asobi_ws_handler:reserved_event_names/0"
    ).

scan_documented_reserved_names(Bin) ->
    Re = "BEGIN reserved-event-names.*?```\\s*(.*?)```",
    case re:run(Bin, Re, [dotall, {capture, all_but_first, binary}]) of
        {match, [Block]} -> binary:split(Block, [~" ", ~"\n"], [global, trim_all]);
        nomatch -> []
    end.

match_or_world_suffix(<<"match.", Suffix/binary>>) -> {true, Suffix};
match_or_world_suffix(<<"world.", Suffix/binary>>) -> {true, Suffix};
match_or_world_suffix(_) -> false.

projection_keys(Fun, Sample) ->
    lists:sort([atom_to_binary(K) || K <- maps:keys(Fun(Sample))]).

fixture_entry_keys(Event, ListKey) ->
    {ok, Bin} = file:read_file(?FIXTURE_DIR ++ "/" ++ Event ++ ".json"),
    #{~"payload" := #{ListKey := [Entry | _]}} = json:decode(Bin),
    entry_keys(Entry).

%% Guard narrows json:decode_value() to a map for eqwalizer.
entry_keys(Entry) when is_map(Entry) ->
    lists:sort(maps:keys(Entry)).
