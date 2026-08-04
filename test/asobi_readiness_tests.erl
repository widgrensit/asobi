-module(asobi_readiness_tests).

-include_lib("eunit/include/eunit.hrl").

readiness_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun closed_until_migrations_have_run/0,
        fun open_once_migrations_have_run/0,
        fun the_seam_returns_a_503_error_object/0
    ]}.

setup() ->
    asobi_readiness:reset(),
    ok.

cleanup(_) ->
    asobi_readiness:reset(),
    ok.

%% The route table compiles inside nova_sup:init/1; migrations run later, from
%% asobi_app:start/2. Anything reachable in between must fail closed.
closed_until_migrations_have_run() ->
    ?assertNot(asobi_readiness:ready()),
    ?assertMatch({error, #{error := #{code := ~"not_ready"}}}, asobi_readiness:guard()).

open_once_migrations_have_run() ->
    ok = asobi_readiness:mark_ready(),
    ?assert(asobi_readiness:ready()),
    ?assertEqual(ok, asobi_readiness:guard()).

%% The Wave 2b RPC dispatcher returns this verbatim. 503 rather than 500,
%% because retrying works.
the_seam_returns_a_503_error_object() ->
    {error, Object} = asobi_readiness:guard(),
    #{error := #{code := Code, message := Message, details := Details}} = Object,
    ?assertEqual(503, asobi_error:status(Code)),
    ?assert(is_binary(Message)),
    ?assertEqual(#{}, Details).
