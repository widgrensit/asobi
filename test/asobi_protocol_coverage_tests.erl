-module(asobi_protocol_coverage_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE_DIR, "priv/protocol/fixtures").
-define(WS_HANDLER, "src/ws/asobi_ws_handler.erl").
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
    Static = scan_encode_reply_types(read_file(?WS_HANDLER)),
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
