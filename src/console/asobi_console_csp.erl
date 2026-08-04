-module(asobi_console_csp).
-moduledoc """
The console's Content-Security-Policy, and the nonce it is built around.

One emitter. The policy is assembled where the response is, because two of
its directives are not knowable at build time: the nonce is per response, and
`connect-src` depends on which origin this deployment's ops API answers on.

The shell policy, directive by directive, with the reason each one is there:

| Directive | Value | Why |
|---|---|---|
| `default-src` | `'none'` | Nothing falls back to a permissive default. Every fetch the page makes is listed below or refused. |
| `script-src` | `'nonce-N'` | Only the one script tag the shell emits runs. **No `'self'`**, so an injected `<script src>` pointing at our own origin is refused too. No `'unsafe-inline'`, no `'unsafe-eval'`. |
| `style-src` | `'self'` | One content-hashed stylesheet. Inline `style=` attributes fall back to this directive and are therefore blocked - which is enforcement of a rule the console follows, not an accident. |
| `img-src` | `'self' data:` | The bundler inlines small icons as `data:` URIs. |
| `font-src` | `'self'` | No font CDN. See `m:asobi_console_shell` for what that costs. |
| `connect-src` | `'self'` + configured base | The ops API. Same-origin self-hosted; an explicit origin when the API is fronted elsewhere. |
| `base-uri` | `'none'` | An injected `<base>` would repoint every relative script and style URL on the page. |
| `form-action` | `'none'` | The console never navigates a form; it fetches. If script fails, the login form fails closed instead of posting a secret somewhere. |
| `frame-ancestors` | `'none'` | Clickjacking, and the modern half of the `X-Frame-Options` the security-headers plugin already sends. |
| `frame-src`, `object-src`, `worker-src` | `'none'` | Redundant under `default-src 'none'`, and stated anyway: plugin and worker content are the classic fallback bypasses and cost nothing to name. |

`script-src` carrying a nonce and *no* host source is what forces the bundle
to be a single chunk. A nonce does not propagate to a module's static
imports, so a code-split build would load its second chunk and be refused.
`console/vite.config.js` pins `inlineDynamicImports` for that reason, and
`asobi_console_shell` emits exactly one script tag.

Assets get their own, much shorter policy: they are never a document.
""".

-export([shell/1, asset/0, nonce/0, api_base/0]).

-define(NONCE_BYTES, 16).

-doc """
A fresh nonce, base64.

Per response, always. The shell is served `no-store` for exactly this reason:
a cached document would reuse its nonce, and a reused nonce is no nonce.
""".
-spec nonce() -> binary().
nonce() ->
    base64:encode(crypto:strong_rand_bytes(?NONCE_BYTES)).

-doc "The shell document's policy, built around `Nonce`.".
-spec shell(binary()) -> binary().
shell(Nonce) ->
    join([
        ~"default-src 'none'",
        <<"script-src 'nonce-", Nonce/binary, "'">>,
        ~"style-src 'self'",
        ~"img-src 'self' data:",
        ~"font-src 'self'",
        <<"connect-src ", (connect_src())/binary>>,
        ~"base-uri 'none'",
        ~"form-action 'none'",
        ~"frame-ancestors 'none'",
        ~"frame-src 'none'",
        ~"object-src 'none'",
        ~"worker-src 'none'"
    ]).

-doc """
The policy served with a script, stylesheet or font.

An asset is a subresource. Reached as a top-level document - which is how a
stored-XSS-in-a-static-file gets its origin - it can load nothing and frame
nothing.
""".
-spec asset() -> binary().
asset() ->
    join([~"default-src 'none'", ~"frame-ancestors 'none'", ~"base-uri 'none'"]).

-doc """
The ops API base the shell advertises, or `none` for same-origin.

`console_api_base` is configuration because one console binary serves both a
self-hosted node, where the API is same-origin, and a managed environment,
where the browser authenticates to the control plane and then calls the
environment's own ingress. Anything that is not an absolute `http`/`https`
origin is dropped rather than guessed at, so a typo degrades to same-origin
instead of widening `connect-src` to a string nobody checked.
""".
-spec api_base() -> {ok, binary()} | none.
api_base() ->
    case application:get_env(asobi, console_api_base) of
        {ok, Base} when is_binary(Base) -> origin(Base);
        _ -> none
    end.

-spec connect_src() -> binary().
connect_src() ->
    case api_base() of
        {ok, Base} -> <<"'self' ", Base/binary>>;
        none -> ~"'self'"
    end.

%% Scheme and authority only. A path would be ignored by `connect-src` and
%% would mislead anyone reading the header, and a value carrying a space or a
%% semicolon could close the directive and open another.
-spec origin(binary()) -> {ok, binary()} | none.
origin(<<"https://", Rest/binary>> = Base) -> authority(Rest, Base);
origin(<<"http://", Rest/binary>> = Base) -> authority(Rest, Base);
origin(_Base) -> none.

-spec authority(binary(), binary()) -> {ok, binary()} | none.
authority(Rest, Base) ->
    case Rest =/= ~"" andalso lists:all(fun is_authority_char/1, binary_to_list(Rest)) of
        true -> {ok, Base};
        false -> none
    end.

-spec is_authority_char(term()) -> boolean().
is_authority_char(Char) when Char >= $a, Char =< $z -> true;
is_authority_char(Char) when Char >= $A, Char =< $Z -> true;
is_authority_char(Char) when Char >= $0, Char =< $9 -> true;
is_authority_char($.) -> true;
is_authority_char($-) -> true;
is_authority_char($:) -> true;
is_authority_char(_Char) -> false.

-spec join([binary(), ...]) -> binary().
join([First | Rest]) ->
    iolist_to_binary([First | [[~"; ", Directive] || Directive <- Rest]]).
