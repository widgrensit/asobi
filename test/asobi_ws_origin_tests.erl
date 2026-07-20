-module(asobi_ws_origin_tests).
-include_lib("eunit/include/eunit.hrl").

%% #160: opt-in Origin allowlist for the /ws upgrade (CSWSH defence-in-depth).
%% Default-open per ADR 0002; a configured allowlist gates browser Origins;
%% native clients (no Origin header) always pass.

setup() ->
    application:unset_env(asobi, ws_allowed_origins),
    ok.

cleanup(_) ->
    application:unset_env(asobi, ws_allowed_origins),
    ok.

origin_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"no allowlist configured: every origin passes (default-open)", fun default_open/0},
        {"empty allowlist is treated as unset (default-open)", fun empty_is_open/0},
        {"a configured allowlist admits a listed origin", fun listed_passes/0},
        {"a configured allowlist rejects an unlisted origin", fun unlisted_rejected/0},
        {"a missing Origin (native client) always passes", fun native_passes/0},
        {"a malformed allowlist (bare binary, not a list) fails closed",
            fun malformed_fails_closed/0},
        {"a non-list term fails closed", fun non_list_fails_closed/0}
    ]}.

default_open() ->
    application:unset_env(asobi, ws_allowed_origins),
    ?assert(asobi_ws_handler:origin_allowed(~"https://evil.example")).

empty_is_open() ->
    application:set_env(asobi, ws_allowed_origins, []),
    ?assert(asobi_ws_handler:origin_allowed(~"https://anything.example")).

listed_passes() ->
    application:set_env(asobi, ws_allowed_origins, [~"https://game.studio", ~"https://itch.io"]),
    ?assert(asobi_ws_handler:origin_allowed(~"https://itch.io")).

unlisted_rejected() ->
    application:set_env(asobi, ws_allowed_origins, [~"https://game.studio"]),
    ?assertNot(asobi_ws_handler:origin_allowed(~"https://evil.example")).

native_passes() ->
    %% Even with a strict allowlist, a client that sends no Origin header is
    %% a non-browser client and cannot be a CSWSH vector.
    application:set_env(asobi, ws_allowed_origins, [~"https://game.studio"]),
    ?assert(asobi_ws_handler:origin_allowed(undefined)).

malformed_fails_closed() ->
    %% The dropped-bracket typo: a bare binary instead of a list. The old code
    %% fell through to allow-all, silently disabling the control. It must now
    %% reject rather than quietly open the socket to every origin.
    application:set_env(asobi, ws_allowed_origins, ~"https://game.studio"),
    ?assertNot(asobi_ws_handler:origin_allowed(~"https://game.studio")),
    ?assertNot(asobi_ws_handler:origin_allowed(~"https://evil.example")).

non_list_fails_closed() ->
    application:set_env(asobi, ws_allowed_origins, all),
    ?assertNot(asobi_ws_handler:origin_allowed(~"https://anything.example")).
