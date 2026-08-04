-module(asobi_console_shell).
-moduledoc """
The console's shell document, rendered by Erlang.

The bundler emits hashed chunks and nothing else. The one document is built
here, because the two things it has to carry are only knowable at response
time: the CSP nonce, and where this deployment's ops API answers.

**Runtime configuration travels in `<meta>` tags, not in an inline script.**
That is the difference between a page with zero inline scripts and a page
with one, and it is the reason `script-src` can be a bare nonce with no
`'unsafe-inline'` anywhere. It also means the only escaping this module needs
is HTML-attribute escaping - there is no JavaScript string context for a
value to break out of.

Fonts are declared by family and never fetched from a CDN. Loading Fraunces
and Instrument Sans from a font host would need `font-src` and `style-src` to
name it, and committing the woff2 files would put roughly 800 KB of binaries
into a Hex package for a page an operator opens during an incident. The
console asks for the families and falls back through the system stack, so it
matches asobi.dev where the fonts are installed and stays legible where they
are not.
""".

-export([render/3, escape/1]).

-define(BASE, ~"/console").

-doc """
The shell document.

`Nonce` goes on the single script tag and nowhere else. `Version` is reported
to the operator so a console and a node that have drifted apart say so.
""".
-spec render(binary(), asobi_console:bundle(), binary()) -> binary().
render(Nonce, #{script := Script, styles := Styles}, Version) ->
    iolist_to_binary([
        ~"<!doctype html>\n",
        ~"<html lang=\"en\">\n<head>\n",
        ~"<meta charset=\"utf-8\">\n",
        ~"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
        ~"<meta name=\"robots\" content=\"noindex, nofollow\">\n",
        ~"<title>asobi ops</title>\n",
        meta(~"asobi-api-base", api_base()),
        meta(~"asobi-node-version", Version),
        [stylesheet(Style) || Style <- Styles],
        ~"<script type=\"module\" nonce=\"",
        escape(Nonce),
        ~"\" src=\"",
        asset_url(Script),
        ~"\"></script>\n",
        ~"</head>\n<body>\n<div id=\"root\"></div>\n",
        ~"<noscript>The asobi operator console needs JavaScript. The same data is available from <code>/api/v1/ops</code>.</noscript>\n",
        ~"</body>\n</html>\n"
    ]).

-doc """
HTML-escape a value bound for an attribute.

Both quote forms as well as the three structural characters, so the same
function is correct in a double-quoted attribute, a single-quoted one and
element content.
""".
-spec escape(binary()) -> binary().
escape(Value) ->
    binary:replace(
        binary:replace(
            binary:replace(
                binary:replace(
                    binary:replace(Value, ~"&", ~"&amp;", [global]),
                    ~"<",
                    ~"&lt;",
                    [global]
                ),
                ~">",
                ~"&gt;",
                [global]
            ),
            ~"\"",
            ~"&quot;",
            [global]
        ),
        ~"'",
        ~"&#39;",
        [global]
    ).

%% Empty content rather than an omitted tag: the client reads one shape and
%% treats the empty string as "same origin", so it needs no absent-key branch.
-spec api_base() -> binary().
api_base() ->
    case asobi_console_csp:api_base() of
        {ok, Base} -> Base;
        none -> ~""
    end.

-spec meta(binary(), binary()) -> iolist().
meta(Name, Content) ->
    [~"<meta name=\"", Name, ~"\" content=\"", escape(Content), ~"\">\n"].

-spec stylesheet(binary()) -> iolist().
stylesheet(Style) ->
    [~"<link rel=\"stylesheet\" href=\"", asset_url(Style), ~"\">\n"].

-spec asset_url(binary()) -> binary().
asset_url(Name) ->
    escape(<<?BASE/binary, "/assets/", Name/binary>>).
