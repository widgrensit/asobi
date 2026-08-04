-module(asobi_console_session_tests).

-include_lib("eunit/include/eunit.hrl").

%% The console's session is the only credential a browser holds, and the CSRF
%% token is the only thing standing between a cookie and a cross-site request
%% that bans a player. These pin both.

setup() ->
    {ok, Pid} = asobi_console_session:start_link(),
    Pid.

%% Synchronous: `exit/2` is asynchronous, so returning before the process is
%% gone leaves the registered name taken and the next setup fails.
cleanup(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> ok
    end.

fixture(Tests) ->
    {setup, fun setup/0, fun cleanup/1, Tests}.

session_test_() ->
    fixture(fun(_) ->
        [
            {"a fresh session resolves with its own token", fun resolves/0},
            {"the cookie alone is not a credential", fun cookie_alone/0},
            {"another session's token does not open this one", fun crossed/0},
            {"the token is derived, so it is stable", fun derived/0},
            {"ids are unguessable and never repeat", fun unique/0},
            {"logout ends it", fun logout/0},
            {"logging out twice is not an error", fun logout_twice/0},
            {"an unknown cookie resolves to nothing", fun unknown/0},
            {"a non-binary cookie resolves to nothing", fun malformed/0},
            {"a hostile label is replaced, not stored", fun label/0},
            {"the ttl is clamped", fun ttl/0}
        ]
    end).

resolves() ->
    {ok, #{id := Id, csrf := Csrf, label := Label}} = asobi_console_session:create(~"kaito"),
    ?assertMatch({ok, #{id := Id, label := ~"kaito"}}, asobi_console_session:resolve(Id, Csrf)),
    ?assertEqual(~"kaito", Label).

%% The whole reason the second layer exists: a cross-site form post carries
%% the browser's cookie and cannot carry the header.
cookie_alone() ->
    {ok, #{id := Id}} = asobi_console_session:create(~"kaito"),
    ?assertEqual({error, bad_csrf}, asobi_console_session:resolve(Id, ~"")),
    ?assertEqual({error, bad_csrf}, asobi_console_session:resolve(Id, ~"guessed")).

crossed() ->
    {ok, #{id := Mine}} = asobi_console_session:create(~"kaito"),
    {ok, #{csrf := Theirs}} = asobi_console_session:create(~"yuki"),
    ?assertEqual({error, bad_csrf}, asobi_console_session:resolve(Mine, Theirs)).

derived() ->
    {ok, #{id := Id, csrf := Csrf}} = asobi_console_session:create(~"kaito"),
    ?assertEqual(Csrf, asobi_console_session:csrf(Id)),
    ?assertEqual(Csrf, asobi_console_session:csrf(Id)).

unique() ->
    Ids = [
        begin
            {ok, #{id := Id}} = asobi_console_session:create(~"kaito"),
            Id
        end
     || _ <- lists:seq(1, 25)
    ],
    ?assertEqual(25, length(lists:usort(Ids))),
    [?assert(byte_size(Id) >= 40) || Id <- Ids].

logout() ->
    {ok, #{id := Id, csrf := Csrf}} = asobi_console_session:create(~"kaito"),
    ok = asobi_console_session:delete(Id),
    ?assertEqual({error, unknown}, asobi_console_session:resolve(Id, Csrf)).

logout_twice() ->
    {ok, #{id := Id}} = asobi_console_session:create(~"kaito"),
    ok = asobi_console_session:delete(Id),
    ?assertEqual(ok, asobi_console_session:delete(Id)).

unknown() ->
    ?assertEqual({error, unknown}, asobi_console_session:resolve(~"nope", ~"nope")).

malformed() ->
    ?assertEqual({error, unknown}, asobi_console_session:resolve(undefined, ~"x")).

%% The label lands in audit rows and logs. It is self-asserted, so it is held
%% to a shape rather than trusted.
label() ->
    [
        begin
            {ok, #{label := Stored}} = asobi_console_session:create(Given),
            ?assertEqual(~"operator", Stored)
        end
     || Given <- [~"", <<"nul\0byte">>, binary:copy(~"x", 65), ~"line\nbreak", 42]
    ].

ttl() ->
    Was = application:get_env(asobi, console_session_ttl),
    try
        application:set_env(asobi, console_session_ttl, 1),
        ?assertEqual(60, asobi_console_session:ttl_seconds()),
        application:set_env(asobi, console_session_ttl, 999999),
        ?assertEqual(86400, asobi_console_session:ttl_seconds()),
        application:set_env(asobi, console_session_ttl, 3600),
        ?assertEqual(3600, asobi_console_session:ttl_seconds())
    after
        case Was of
            {ok, Value} -> application:set_env(asobi, console_session_ttl, Value);
            undefined -> application:unset_env(asobi, console_session_ttl)
        end
    end.

%% Expiry is absolute and `resolve/2` does not extend it. Ageing the row is the
%% only way to exercise that without waiting out a real TTL.
expiry_test_() ->
    fixture(fun(_) ->
        [
            {"an expired session does not resolve", fun expired/0},
            {"the sweeper removes it", fun swept/0}
        ]
    end).

expired() ->
    {ok, #{id := Id, csrf := Csrf}} = asobi_console_session:create(~"kaito"),
    ok = asobi_console_session:expire(Id),
    ?assertEqual({error, expired}, asobi_console_session:resolve(Id, Csrf)).

swept() ->
    {ok, #{id := Live, csrf := LiveCsrf}} = asobi_console_session:create(~"kaito"),
    {ok, #{id := Dead}} = asobi_console_session:create(~"yuki"),
    ok = asobi_console_session:expire(Dead),
    ok = asobi_console_session:sweep(),
    ?assertEqual([], ets:lookup(asobi_console_session, Dead)),
    ?assertMatch({ok, _}, asobi_console_session:resolve(Live, LiveCsrf)).

%% A restart takes the table and the node secret with it, so every session in
%% flight ends. That is the intended coupling, not a gap, and it is worth a
%% test because a future change that persists sessions without persisting the
%% secret would silently invalidate every token instead.
restart_ends_every_session_test() ->
    Pid = setup(),
    {ok, #{id := Id, csrf := Csrf}} = asobi_console_session:create(~"kaito"),
    cleanup(Pid),
    Pid2 = setup(),
    try
        ?assertEqual({error, unknown}, asobi_console_session:resolve(Id, Csrf))
    after
        cleanup(Pid2)
    end.
