-module(asobi_console_controller).
-moduledoc """
HTTP surface of the operator console: the shell, its assets, and the session
the browser exchanges the operator secret for.

This route group is **unauthenticated on purpose**, and that is a narrower
statement than it looks. It serves three things: a document with no data in
it, content-hashed static files, and the login endpoint - which cannot
require the credential it exists to accept. Every byte of game data the
console shows comes from `/api/v1/ops`, behind `asobi_ops_auth`.

When the console is not enabled these routes answer **404**, not 403, and it
is the same 404 an unknown asset gets. A deployment that has the console
switched off is indistinguishable from one that has it on and was asked for a
file that does not exist.
""".

-include_lib("kernel/include/logger.hrl").

-export([index/1, asset/1, session/1, login/1, logout/1]).

-define(COOKIE, ~"asobi_console").
-define(CSRF_COOKIE, ~"asobi_console_csrf").
-define(IMMUTABLE, ~"public, max-age=31536000, immutable").

-type response() ::
    {json, integer(), map(), cowboy_req:req(), map()}
    | {status, integer(), map(), binary()}
    | {asobi_error, asobi_error:code()}.

-doc "The shell document. Never cached: it carries a per-response CSP nonce.".
-spec index(cowboy_req:req()) -> response().
index(_Req) ->
    case asobi_console:enabled() of
        true -> shell();
        false -> {asobi_error, ~"console.not_found"}
    end.

-spec shell() -> response().
shell() ->
    case asobi_console:bundle() of
        {ok, Bundle} ->
            Nonce = asobi_console_csp:nonce(),
            Body = asobi_console_shell:render(Nonce, Bundle, version()),
            {status, 200,
                #{
                    ~"content-type" => ~"text/html; charset=utf-8",
                    ~"content-security-policy" => asobi_console_csp:shell(Nonce),
                    ~"cache-control" => ~"no-store"
                },
                Body};
        {error, Problem} ->
            %% The problem names a path on this machine, so it goes to the log
            %% and not into a body a browser renders.
            ?LOG_ERROR(#{msg => ~"console requested but no bundle is built", problem => Problem}),
            {asobi_error, ~"console.not_built"}
    end.

-doc """
One bundled asset, by basename.

The binding is a map key, never a path segment joined onto a directory - see
`m:asobi_console`. A name that is not in the bundle is 404 whether it is a
typo or a traversal attempt.
""".
-spec asset(cowboy_req:req()) -> response().
asset(#{bindings := #{~"file" := Name}} = Req) ->
    case asobi_console:enabled() andalso asobi_console:asset(Name) of
        {ok, Asset} -> serve(Asset, Req);
        _ -> {asobi_error, ~"console.not_found"}
    end;
asset(_Req) ->
    {asobi_error, ~"console.not_found"}.

-spec serve(asobi_console:asset(), cowboy_req:req()) -> response().
serve(#{body := Body, mime := Mime, etag := Etag}, Req) ->
    Headers = #{
        ~"content-type" => Mime,
        ~"cache-control" => ?IMMUTABLE,
        ~"etag" => Etag,
        ~"content-security-policy" => asobi_console_csp:asset()
    },
    case cowboy_req:header(~"if-none-match", Req) of
        Etag -> {status, 304, Headers, ~""};
        _ -> {status, 200, Headers, Body}
    end.

-doc """
Whether this browser has a live session, and who it says it is.

Requires the cookie *and* the CSRF header like every other ops read, so it is
not a way to learn the CSRF token - the browser already has that from the
companion cookie.
""".
-spec session(cowboy_req:req()) -> response().
session(Req) ->
    case asobi_console:enabled() andalso asobi_ops_auth:resolve(Req) of
        {ok, Actor} -> {json, 200, #{}, Req, #{data => actor(Actor)}};
        false -> {asobi_error, ~"console.not_found"};
        {error, _Reason} -> {asobi_error, ~"unauthenticated"}
    end.

-doc """
Exchange a credential for a session.

Two are accepted, and they are the two the ops plane already takes:

* `secret` - the operator secret, checked by `asobi_ops_auth:verify_secret/1`
  so the constant-time comparison and the no-default rule live in one place
  and this endpoint cannot drift from the bearer plane. It proves every
  capability class.
* `token` - a minted, env-scoped token from the control plane
  (`m:asobi_ops_token`). It proves only the classes it carries, and the
  session it opens carries exactly those and expires no later than the token
  does. A fifteen-minute credential must not buy a twelve-hour session.

The minted path is what makes a managed environment's console reachable: the
browser posts the token once and then holds a cookie, so the token never has
to live in JavaScript for the length of a session.

A wrong credential is `403 forbidden` with the same body a wrong bearer token
gets, so the two planes are indistinguishable to a caller guessing.
""".
-spec login(cowboy_req:req()) -> response().
login(Req) ->
    case asobi_console:enabled() of
        true -> authenticate(Req);
        false -> {asobi_error, ~"console.not_found"}
    end.

-spec authenticate(cowboy_req:req()) -> response().
authenticate(#{json := #{~"secret" := Secret} = Body} = Req) ->
    case asobi_ops_auth:verify_secret(Secret) of
        true ->
            {ok, Session} = asobi_console_session:create(maps:get(~"label", Body, ~"operator")),
            granted(Session, Req);
        false ->
            rejected(Req)
    end;
authenticate(#{json := #{~"token" := Token}} = Req) when is_binary(Token) ->
    minted(Token, Req, json);
%% A form POST, which is how the control plane hands a browser over: the token
%% rides in the body, so unlike a query parameter or a fragment it never enters
%% a URL, a referrer, an access log or the history. The reply is a redirect
%% rather than JSON because the caller is a navigating browser, and after it
%% the page is same-origin, so the SameSite=Strict cookies just set are sent
%% normally from then on.
%%
%% `body` rather than cowboy_req:read_urlencoded_body/1: nova_request_plugin
%% has already drained the one-shot stream, so reading it again finds nothing
%% (asobi_saas#100).
authenticate(#{body := Body} = Req) when is_binary(Body), Body =/= ~"" ->
    case lists:keyfind(~"token", 1, cow_qs:parse_qs(Body)) of
        {_, Token} when is_binary(Token), Token =/= ~"" -> minted(Token, Req, redirect);
        _ -> {asobi_error, ~"missing_field"}
    end;
authenticate(_Req) ->
    {asobi_error, ~"missing_field"}.

minted(Token, Req, Reply) ->
    case asobi_ops_token:verify(Token) of
        {ok, #{sub := Sub, caps := Caps, exp := Exp}} ->
            {ok, Session} = asobi_console_session:create(Sub, Caps, Exp),
            granted(Session, Req, Reply);
        {error, _Reason} ->
            rejected(Req)
    end.

%% One log line and one body for both credentials: which one was wrong, and
%% why, is not something a caller guessing gets to learn.
rejected(Req) ->
    ?LOG_WARNING(#{
        msg => ~"console login rejected",
        peer => asobi_peer:client_ip(Req)
    }),
    {asobi_error, ~"forbidden"}.

%% Two cookies. The session id is `HttpOnly` so script cannot read it; the
%% CSRF token deliberately is not, because the page has to send it back as a
%% header and holding it only in memory would log the operator out on every
%% reload. It is derived from the session and useless without it, so a page
%% that can read it can already act as the session it belongs to.
-spec granted(asobi_console_session:session(), cowboy_req:req()) -> response().
granted(Session, Req) ->
    granted(Session, Req, json).

granted(#{id := Id, csrf := Csrf, expires_at := ExpiresAt} = Session, Req, Reply) ->
    Options = cookie_options(Req),
    Req1 = cowboy_req:set_resp_cookie(?COOKIE, Id, Req, Options#{http_only => true}),
    Req2 = cowboy_req:set_resp_cookie(?CSRF_COOKIE, Csrf, Req1, Options#{http_only => false}),
    reply(Reply, Session, Csrf, ExpiresAt, Req2).

%% 303, not 302: the browser must follow with GET whatever it posted with.
reply(redirect, _Session, _Csrf, _ExpiresAt, Req) ->
    {status, 303, #{~"location" => ~"/console", ~"cache-control" => ~"no-store"}, Req};
reply(json, Session, Csrf, ExpiresAt, Req) ->
    {json, 200, #{~"cache-control" => ~"no-store"}, Req, #{
        data => #{
            display => maps:get(label, Session),
            expires_at => ExpiresAt,
            csrf => Csrf
        }
    }}.

-doc "End the session and clear both cookies. Idempotent.".
-spec logout(cowboy_req:req()) -> response().
logout(Req) ->
    case asobi_console:enabled() of
        true -> revoke(Req);
        false -> {asobi_error, ~"console.not_found"}
    end.

-spec revoke(cowboy_req:req()) -> response().
revoke(Req) ->
    ok = clear(Req),
    Options = (cookie_options(Req))#{max_age => 0},
    Req1 = cowboy_req:set_resp_cookie(?COOKIE, ~"", Req, Options#{http_only => true}),
    Req2 = cowboy_req:set_resp_cookie(?CSRF_COOKIE, ~"", Req1, Options#{http_only => false}),
    {json, 200, #{~"cache-control" => ~"no-store"}, Req2, #{data => #{ended => true}}}.

%% Logout is the one place a cookie alone is enough. It only ever destroys
%% authority, so requiring the CSRF header would mean a page that lost its
%% token could not end its own session.
-spec clear(cowboy_req:req()) -> ok.
clear(Req) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, Id} when is_binary(Id) -> asobi_console_session:delete(Id);
        _ -> ok
    end.

%% `SameSite=Strict`: nothing the console does is reached by following a link
%% from elsewhere, so the strictest value costs nothing and removes the whole
%% class of cross-site requests that arrive with cookies attached.
%%
%% `Secure` is set whenever the request looks like TLS, directly or through a
%% proxy that says so. A forwarded header can only *add* the flag here, so
%% believing an unverified one can make a cookie stricter and never weaker.
%%
%% `Lax`, not `Strict`. The managed hand-off arrives as a cross-site form POST
%% from the control plane, and a browser treats every hop of that redirect
%% chain as cross-site - so a `Strict` cookie is set and then not sent on the
%% redirect to `/console`, landing the operator on a login page holding a
%% session they cannot use until they reload.
%%
%% `Lax` still refuses to send these on a cross-site POST or an XHR, which is
%% the case that matters: every state-changing request also needs the
%% `x-csrf-token` header, and that is the defence doing the work. What `Lax`
%% adds is the top-level GET navigation, which is exactly the hop being fixed.
-spec cookie_options(cowboy_req:req()) -> map().
cookie_options(Req) ->
    #{
        path => ~"/",
        same_site => lax,
        secure => secure(Req),
        max_age => asobi_console_session:ttl_seconds()
    }.

-spec secure(cowboy_req:req()) -> boolean().
secure(Req) ->
    cowboy_req:scheme(Req) =:= ~"https" orelse
        cowboy_req:header(~"x-forwarded-proto", Req) =:= ~"https" orelse
        application:get_env(asobi, console_secure_cookie, false) =:= true.

-spec actor(asobi_ops_auth:actor()) -> map().
actor(#{display := Display, source := Source, caps := Caps, attested := Attested}) ->
    #{
        display => Display,
        source => Source,
        caps => Caps,
        attested => Attested
    }.

-spec version() -> binary().
version() ->
    case application:get_key(asobi, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> ~"unknown"
    end.
