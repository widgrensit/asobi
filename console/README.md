# asobi operator console

A React console for `/api/v1/ops`. Vite builds it to `../priv/console`, and
asobi serves it from there at `/console`.

```
npm install
npm run build     # -> ../priv/console
npm run dev       # vite dev server, proxying nothing: see "Running it" below
```

## Extensions compile into this bundle, and here that set is empty

An installed extension can add screens to the console by shipping React source
in its own `priv/console`. `rebar3 asobi console`, run by a **host** release,
copies this tree into `_build/asobi_console`, symlinks every such extension
under it, generates `src/registry.generated.js` with one static import each,
and builds the result into an application of the host's own. See
[Extending the operator console](../guides/console-extensions.md) and
[ADR 0009](../docs/adr/0009-console-extensions-compose-at-build-time.md).

In *this* repository `src/registry.generated.js` is a committed stub exporting
an empty array, and that is load-bearing rather than incidental: asobi's own
bundle is built from asobi's own tree with no extension in it, which is what
keeps the committed `priv/console` reproducible and the drift gate below a real
check. Never commit a non-empty version of it.

`src/public.js` is the surface an extension may import, aliased as
`@asobi/console`. It is frozen the way the wire is frozen - everything it
re-exports ends up compiled into releases this repository never sees - and
`CONSOLE_API_VERSION` in `src/registry.js` is what an extension declares itself
against. Everything this tree does not re-export through it stays free to
change, which is the whole reason it exists rather than extensions importing
`./ui.jsx`.

## The build output is committed

`priv/console` is in git. That is a decision with a cost on both sides, so
here is the reasoning.

Committing it means:

- A Hex consumer needs no Node. `priv` ships in the package, so `{deps,
  [asobi]}` gets a working console. A generated bundle would mean every
  consumer of an Erlang library builds JavaScript, which is not a trade an
  Erlang library gets to make.
- The diff is reviewable. A change to the bundle shows up in the same pull
  request as the change to the source that produced it.
- One artefact. No release-time ordering between an Erlang build and a Node
  build, and no window where the two disagree.

The cost is that a committed bundle rots: it can drift from the source that
claims to produce it, and nothing notices. That is answered by the CI job in
`.github/workflows/console.yml`, which rebuilds from the lockfile and fails on
`git diff --exit-code`. The bundle cannot drift from its source without the
build going red.

Vite's output is content-hashed and deterministic for a given lockfile and
Node major, so the gate is a real check rather than a coin flip. `package.json`
pins exact dependency versions, `package-lock.json` is committed, and the
workflow pins the Node major to match `engines`.

## The CSP, and what it forbids

`asobi_console_csp` emits the policy; `asobi_console_shell` renders the one
document it applies to. The shell's policy is:

```
default-src 'none'; script-src 'nonce-<per-response>'; style-src 'self';
img-src 'self' data:; font-src 'self'; connect-src 'self' [api base];
base-uri 'none'; form-action 'none'; frame-ancestors 'none';
frame-src 'none'; object-src 'none'; worker-src 'none'
```

Three consequences bind this source tree:

1. **One chunk.** `script-src` is a bare nonce with no host source, and a
   nonce does not propagate to a module's static imports. `vite.config.js`
   sets `codeSplitting: false`; a code-split build produces a blank console
   with nothing in the server logs. `asobi_console_tests` asserts the
   committed bundle is one `.js` file.
2. **No inline styles.** `style-src-attr` is absent, so it falls back to
   `style-src 'self'` and a `style={{...}}` prop is refused by the browser.
   Use a class. Nothing in this tree computes a declaration.
3. **No string-to-code.** `'unsafe-eval'` is not in the policy.
   `asobi_console_tests` greps the committed bundle for `eval(` and
   `new Function(`. If a dependency starts needing either, that is a reason to
   drop the dependency, not to widen the policy.

Runtime configuration travels in `<meta>` tags, not an inline script. That is
what keeps the page at zero inline scripts.

## Fonts

Fraunces, Instrument Sans and JetBrains Mono are asked for by family and never
fetched. A font CDN would need `font-src` and `style-src` to name it, and
self-hosting the woff2 files would put roughly 800 KB of binaries into a Hex
package. The stacks fall through to the system serif, sans and mono, so the
console matches asobi.dev where those fonts are installed and stays legible
where they are not.

## Running it

The console is **off by default**. Nova starts one listener, so it would
otherwise appear on the same public port as the game API.

```erlang
{asobi, [
    {console, true},
    {ops_secret, <<"...">>}
]}.
```

Then `http://localhost:8082/console`. Sign in with the operator secret; the
node exchanges it for an `HttpOnly` session cookie and the page never holds
the secret again.

`npm run dev` serves the source with hot reload but no shell document and no
ops API, so it is useful for style work and not much else. For anything
involving data, `npm run build` and reload the Erlang-served page - the build
takes under a second.

From a host release, `rebar3 asobi console --dev` is the better loop: it
generates the document this tree does not carry and proxies `/api/v1/ops` and
`/console/session` at a running node, so hot reload runs against real data.

## Cloud

The API base is configuration, never a compile-time constant, so one bundle
serves both deployments:

- **Self-hosted**: no `console_api_base`. The console calls `/api/v1/ops` on
  its own origin and authenticates with the session cookie.
- **Managed**: the host that serves the shell emits
  `<meta name="asobi-api-base">` pointing at the environment's ingress and
  `<meta name="asobi-auth-token">` carrying a short-lived environment-scoped
  token it minted after its own ownership check. `src/api.js` prefers the
  token when it is present and sends no cookies.

asobi itself never emits `asobi-auth-token`: it has no control plane and
nothing to mint against. Setting `console_api_base` on a self-hosted node adds
the origin to `connect-src` and nothing else.
