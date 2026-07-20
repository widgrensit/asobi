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
        {"a missing Origin (native client) always passes", fun native_passes/0}
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
