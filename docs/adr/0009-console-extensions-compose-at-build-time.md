# ADR 0009: An extension's console screens are composed into one bundle at build time

Date: 2026-08-10

## Status

Accepted. Extends `asobi_extension` with a discovered UI seam alongside the
declared `ops/0` seam that ADR 0003's no-routes rule already put behind
`/api/v1/ops/ext/:extension/:action`.

## Context

An extension can serve operator actions. `ops/0` declares them, core owns the
one route they answer on, and `asobi_ops_extension` dispatches them with the
capability check and the audit row already applied. What an extension could not
do is show them to anybody. `guides/extensions.md` said so outright: "The
console cannot invoke an ops action today. The surface is HTTP only."

So an extension with an operator surface had two halves of a working feature and
no way to join them. The gap was closed with `curl`, or with a second web
application beside the node, which is a second deployment, a second credential
path and a second thing to keep in sync with the schema.

`asobi_ops_features` already anticipated the fix - "the endpoint the console uses
to decide which of its built-in screens to render" - but only for screens asobi
itself ships. asobi shipping a screen per extension does not scale past the
extensions asobi knows about, and asobi must not know about them: every extension
depends on asobi, and the reverse edge is a cycle relx and Hex both reject.

### What the CSP decides

`asobi_console_csp:shell/1` emits `script-src 'nonce-<per-response>'` with no
host source, no `'unsafe-inline'` and no `'unsafe-eval'`. A nonce does not
propagate to a module's static imports, which is why `console/vite.config.js`
pins a single chunk and why `asobi_console_shell` emits exactly one script tag.

Every runtime plugin mechanism there is needs that policy widened:

| Mechanism | Needs |
| --- | --- |
| Dynamic `import()` of an extension chunk | `'strict-dynamic'` |
| Module federation, SystemJS, any runtime loader | `'strict-dynamic'` or a host source |
| An import map for shared React | A second inline script, so a second nonce |
| An interpreted UI description evaluated in the browser | `'unsafe-eval'`, unless the interpreter is compiled in |
| An iframe per extension | `frame-src`, and a second shell, policy and session hop |

The console's strongest property is that even an injected `<script src>` pointing
at its own origin is refused. Every option above trades that away.

### What the committed bundle decides

`priv/console` is in git and `.github/workflows/console.yml` rebuilds it and
fails on `git diff --exit-code`. That is what lets a Hex consumer have a working
console with no Node. Whatever composition mechanism arrives must leave asobi's
own bundle byte-identical to a fresh build of asobi's own tree, or the gate stops
meaning anything.

## Decision

**An extension ships React source under `priv/console`, and a build step
composes core's screens and every installed extension's into one chunk.**

- Discovery is the file being there. `priv/console/index.jsx` default-exports a
  manifest of nav entries, routes and slot components. Nothing is declared in
  `<app>_extension`, matching how migrations and schemas are already discovered
  rather than announced.
- `rebar3 asobi console` performs the composition in a workspace under `_build`,
  symlinking each extension's source under Vite's root and generating one static
  import per extension. It writes the bundle into an application of the host's,
  named by `console_bundle_app`.
- `asobi_console` reads `console_bundle_app` and serves that application's
  `priv/console` through unchanged code: same manifest parsing, same refusal of
  any name that is not a plain content-hashed basename, same memoisation.
- The composed bundle is still **one chunk**. The CSP is not touched.
- `console/src/public.js`, aliased as `@asobi/console`, is the only surface an
  extension may import, and is frozen. `CONSOLE_API_VERSION` in the manifest is
  checked, and a mismatch refuses the extension entirely rather than rendering it
  half-working.
- Everything an extension contributes hangs under `/ext/<name>`, keyed by
  `info().name`, so extension routes cannot collide with core's present or future
  ones, nor with each other.
- What renders is decided at runtime by `/api/v1/ops/features`. One composed
  bundle serves nodes whose installed sets differ.
- In asobi's own tree the generated registry is a committed stub exporting an
  empty array, so asobi's bundle is built from asobi's tree with no extension in
  it and the drift gate keeps working.

## Consequences

**A host with extension screens needs Node.** It did not before. The cost falls
only on hosts that opt in: the committed bundle still means a Hex consumer with
no extension screens needs nothing, and that promise is why `priv/console` is in
git in the first place.

**An extension's screens require the host to rebuild.** Adding an extension to a
release and not running `rebar3 asobi console` gives a node that reports the
extension installed and shows none of its screens. That is why
`/api/v1/ops/features` now reports a `console` capability: it is the only thing
that distinguishes "not rebuilt" from "not installed", and without it an operator
has nothing to read the difference from.

**Extension code is in the same chunk as core's.** A throw in an extension screen
would take the console down, so every extension route and slot renders inside an
error boundary that names the extension and leaves the rest of the console
running. A boundary is not isolation: extension code shares the origin, the
session and the module graph. It is trusted code from the same release, and
treating it as hostile would mean the iframe design this ADR rejects.

**`console/` now ships in the Hex package.** A host cannot compose a console out
of source it does not have. Roughly 30 KB.

**Two settings name the same application.** `console_bundle_app` is in
`rebar.config` for the build and in `sys.config` for the node. They answer
different questions and a release can be built and configured on different
machines, so they are not merged. `asobi_console` refuses a configured
application that is not in the release rather than falling back to asobi's own
bundle, so the two disagreeing is loud rather than silently stock.

**The frozen surface is now a compatibility obligation.** `public.js` and the
slot id set are compiled into releases this repository never sees. Adding to
either is additive; removing from either is a `CONSOLE_API_VERSION` bump.

## Alternatives considered

**Widen `script-src` with `'strict-dynamic'` and load extension chunks at
runtime.** One line of policy, and extensions could hot-plug into a stock node
with no host rebuild - the genuinely better ergonomics. Rejected because it
converts the console from "only the one script the shell emitted runs" to "and
anything that script decides to load", which is the property most worth having on
a page that holds an operator session for a production game. The ergonomics are
recoverable by other means; the property is not.

**An iframe per extension.** True isolation, and the only option that would make
untrusted extension UI safe. Rejected because extension code is not untrusted -
it is in the same release as the node - and the cost is a second shell document,
a second CSP, a session hop over `postMessage`, and `frame-src` opened on a
policy that currently says `'none'` three times over.

**A declarative UI vocabulary in the Erlang manifest**, rendered by an
interpreter compiled into core's bundle. No Node anywhere, no composition step,
and `ListScreen` is already a configuration interpreter, so most of it existed.
Rejected as the primary mechanism because it caps what an extension can express
at whatever the vocabulary covers, and the second screen anybody wrote would want
something outside it. It remains available as an additive layer later; nothing in
this decision forecloses it.

**asobi ships a screen per known extension.** What `asobi_ops_features` described.
Rejected because it makes core depend on the extensions it renders, which is the
dependency edge the extension contract exists to prevent.
