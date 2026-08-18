-module(asobi_dgram_env_tests).
-include_lib("eunit/include/eunit.hrl").

%% Folding environment variables into the application env.
%%
%% This is the only path by which a self-hoster running the published image can
%% reach the datagram plane at all, so "it parses" is the whole feature.

-define(VARS, [
    "ASOBI_ROLE",
    "ASOBI_DGRAM_PORT",
    "ASOBI_DGRAM_LINK_PORT",
    "ASOBI_DGRAM_SHARDS",
    "ASOBI_DGRAM_LINK_SECRET",
    "ASOBI_DGRAM_LINK_SECRET_FILE",
    "ASOBI_DGRAM_GATEWAY",
    "ASOBI_DGRAM_ENDPOINT",
    "ASOBI_DGRAM_POSE_FIELDS",
    "ASOBI_DGRAM_POSE_PERIOD",
    "ASOBI_BINARY_WIRE"
]).

-define(KEYS, [
    role, dgram, dgram_link_secret, dgram_gateway, dgram_endpoint, dgram_pose, binary_wire
]).

env_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        {"nothing set changes nothing", fun empty_is_a_noop/0},
        {"the gateway role is opt-in and a typo is not it", fun role_typo_is_the_engine/0},
        {"ports and shards fold in", fun ports_fold_in/0},
        {"a configured sys.config always wins", fun app_env_wins/0},
        {"the gateway address parses as host:port", fun gateway_parses/0},
        {"a malformed gateway is refused, not half-applied", fun gateway_malformed/0},
        {"the pose manifest parses in canonical order", fun pose_parses/0},
        {"a malformed pose manifest is refused", fun pose_malformed/0},
        {"a secret file beats a secret variable", fun secret_file_wins/0},
        {"an unreadable secret file leaves no secret", fun secret_file_unreadable/0},
        {"the binary wire folds in, which is what carries the plane", fun binary_wire_folds_in/0},
        {"a pose manifest without the binary wire is reported, not accepted",
            fun pose_without_binary_wire_is_reported/0}
    ]}.

setup() ->
    Saved = [{K, application:get_env(asobi, K)} || K <- ?KEYS],
    [application:unset_env(asobi, K) || K <- ?KEYS],
    [os:unsetenv(V) || V <- ?VARS],
    Saved.

cleanup(Saved) ->
    [os:unsetenv(V) || V <- ?VARS],
    [application:unset_env(asobi, K) || K <- ?KEYS],
    [
        case V of
            undefined -> ok;
            {ok, Val} -> application:set_env(asobi, K, Val)
        end
     || {K, V} <- Saved
    ],
    ok.

%% --- Tests ---

empty_is_a_noop() ->
    ok = asobi_dgram_env:apply(),
    [?assertEqual(undefined, application:get_env(asobi, K)) || K <- ?KEYS].

%% Defaulting a misspelling to the engine keeps a deployment serving its game.
%% Defaulting it to the gateway would silently take the game down, which is a
%% much worse answer to the same typo.
role_typo_is_the_engine() ->
    os:putenv("ASOBI_ROLE", "dgram-gw"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, role)),

    os:putenv("ASOBI_ROLE", "dgram_gw"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual({ok, dgram_gw}, application:get_env(asobi, role)).

ports_fold_in() ->
    os:putenv("ASOBI_DGRAM_PORT", "9000"),
    os:putenv("ASOBI_DGRAM_LINK_PORT", "9001"),
    os:putenv("ASOBI_DGRAM_SHARDS", "2"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual(
        {ok, #{port => 9000, link_port => 9001, shards => 2}},
        application:get_env(asobi, dgram)
    ).

%% Nothing may have two sources of truth at once. A deployment that configures
%% asobi in Erlang keeps doing so, whatever the container image sets.
app_env_wins() ->
    application:set_env(asobi, dgram, #{port => 1234}),
    application:set_env(asobi, role, engine),
    os:putenv("ASOBI_DGRAM_PORT", "9000"),
    os:putenv("ASOBI_ROLE", "dgram_gw"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual({ok, #{port => 1234}}, application:get_env(asobi, dgram)),
    ?assertEqual({ok, engine}, application:get_env(asobi, role)).

gateway_parses() ->
    os:putenv("ASOBI_DGRAM_GATEWAY", "gateway:7778"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual(
        {ok, #{host => "gateway", port => 7778}}, application:get_env(asobi, dgram_gateway)
    ).

%% Refused rather than half-applied. Configuring this is the engine's opt-in, so
%% a half-parsed value would be an engine that dials somewhere unintended.
gateway_malformed() ->
    [
        begin
            os:putenv("ASOBI_DGRAM_GATEWAY", Bad),
            application:unset_env(asobi, dgram_gateway),
            ok = asobi_dgram_env:apply(),
            ?assertEqual(undefined, application:get_env(asobi, dgram_gateway), Bad)
        end
     || Bad <- ["gateway", "gateway:", ":7778", "gateway:notaport", "gateway:99999"]
    ].

%% The order is load-bearing: the wire is a fixed layout with no field names in
%% it, so reordering this changes what every field on the wire means.
pose_parses() ->
    os:putenv("ASOBI_DGRAM_POSE_FIELDS", "x:100,y:100,vx:50"),
    os:putenv("ASOBI_DGRAM_POSE_PERIOD", "30"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual(
        {ok, #{
            fields => [
                #{name => ~"x", scale => 100},
                #{name => ~"y", scale => 100},
                #{name => ~"vx", scale => 50}
            ],
            period_ticks => 30
        }},
        application:get_env(asobi, dgram_pose)
    ),
    %% ...and it is the shape the manifest reader accepts, not merely a map.
    ?assertMatch({ok, #{fields := [_, _, _]}}, asobi_dgram_pose:manifest()).

pose_malformed() ->
    [
        begin
            os:putenv("ASOBI_DGRAM_POSE_FIELDS", Bad),
            application:unset_env(asobi, dgram_pose),
            ok = asobi_dgram_env:apply(),
            ?assertEqual(undefined, application:get_env(asobi, dgram_pose), Bad)
        end
     || Bad <- ["x", "x:", ":100", "x:0", "x:-1", "x:100,y", "x:abc"]
    ].

%% A file stays out of `docker inspect` and out of the process environment, which
%% is the whole reason to prefer one.
secret_file_wins() ->
    Path = tmp_file(<<"  from-the-file\n">>),
    os:putenv("ASOBI_DGRAM_LINK_SECRET", "from-the-variable"),
    os:putenv("ASOBI_DGRAM_LINK_SECRET_FILE", Path),
    ok = asobi_dgram_env:apply(),
    ?assertEqual({ok, ~"from-the-file"}, application:get_env(asobi, dgram_link_secret)),
    file:delete(Path).

%% NOT a silent fallback to the variable. A deployment that mounted a secret and
%% got the path wrong must not come up quietly with the wrong one - or with none.
secret_file_unreadable() ->
    os:putenv("ASOBI_DGRAM_LINK_SECRET", "from-the-variable"),
    os:putenv("ASOBI_DGRAM_LINK_SECRET_FILE", "/nonexistent/asobi-secret"),
    ok = asobi_dgram_env:apply(),
    ?assertEqual(undefined, application:get_env(asobi, dgram_link_secret)).

%% --- Helpers ---

tmp_file(Contents) ->
    Path = lists:flatten(
        io_lib:format("/tmp/asobi-dgram-env-~p", [erlang:unique_integer([positive])])
    ),
    ok = file:write_file(Path, Contents),
    Path.

%% asobi#509. The plane cannot work without the binary wire - a pose names a slot
%% and only an `add` on that wire binds one - and until this existed the wire
%% could not be turned on from the published image at all, so the whole plane was
%% unreachable for the audience it was built for.
binary_wire_folds_in() ->
    os:putenv("ASOBI_BINARY_WIRE", "1"),
    asobi_dgram_env:apply(),
    ?assertEqual({ok, true}, application:get_env(asobi, binary_wire)),

    application:unset_env(asobi, binary_wire),
    os:putenv("ASOBI_BINARY_WIRE", "false"),
    asobi_dgram_env:apply(),
    ?assertEqual({ok, false}, application:get_env(asobi, binary_wire)),

    %% A configured sys.config wins, the same as every other key here.
    application:set_env(asobi, binary_wire, true),
    os:putenv("ASOBI_BINARY_WIRE", "0"),
    asobi_dgram_env:apply(),
    ?assertEqual({ok, true}, application:get_env(asobi, binary_wire)).

%% asobi#509. Configuring the manifest and leaving the wire off looks like a
%% working plane and is not one: every pose names a slot no client can resolve,
%% because the frame that binds slots is the one the server refuses to send.
pose_without_binary_wire_is_reported() ->
    os:putenv("ASOBI_DGRAM_POSE_FIELDS", "x:100,y:100"),
    asobi_dgram_env:apply(),
    ?assertMatch({ok, #{fields := [_ | _]}}, application:get_env(asobi, dgram_pose)),
    ?assertEqual({error, no_binary_wire}, asobi_dgram_env:check_pose_carrier()),

    application:set_env(asobi, binary_wire, true),
    ?assertEqual(ok, asobi_dgram_env:check_pose_carrier()),

    %% No manifest is not a misconfiguration: the plane is simply off.
    application:unset_env(asobi, dgram_pose),
    application:unset_env(asobi, binary_wire),
    ?assertEqual(ok, asobi_dgram_env:check_pose_carrier()).
