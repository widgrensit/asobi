# Extending the operator console

An extension can add screens to the operator console: its own pages in the
navigation, and panels on the screens core already owns. This guide is how.

You write the UI in your extension, as React source under `priv/console`. It is
not registered anywhere and it is not declared in the manifest - the file being
there is the declaration, the same way a migration or a Kura schema is
discovered rather than announced. A build step composes core's screens and every
installed extension's into one bundle, and the node serves that instead of the
stock one.

Read [Writing an extension](extensions.md) first. This guide assumes you have an
extension with an `ops/0` manifest, because a screen with no endpoint behind it
has nothing to draw.

## The two halves

| Half | Where | What it is |
| --- | --- | --- |
| Data | `ops/0` in your `<app>_extension` module | Operator actions, reached at `/api/v1/ops/ext/<name>/<action>`, class-gated and audited by core |
| UI | `priv/console/index.jsx` in the same application | Screens that call those actions |

Neither half needs the other to exist. An extension with `ops/0` and no
`priv/console` is reachable with `curl`, which is how every extension worked
before this. An extension with screens and no `ops/0` renders, and has nothing
to show.

## A screen, end to end

Start from the data. This is the ops half, unchanged from
[Writing an operator action](extensions.md#writing-an-operator-action):

```erlang
-module(asobi_quests_extension).
-behaviour(asobi_extension).

-export([info/0, rpc/0, ops/0, owns/0, codes/0]).

info() -> #{name => quests, extension_version => 1}.

ops() ->
    #{~"list" => #{method => get,
                   mfa    => {asobi_quests_ops, list, 2},
                   class  => read},
      ~"disable" => #{method => post,
                      mfa    => {asobi_quests_ops, disable, 2},
                      class  => config}}.
```

A read action answers the same envelope core's own list routes answer, so the
console's paging and sorting work against it without being told anything:

```erlang
-spec list(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
list(Params, _Ctx) ->
    Page = asobi_ops_params:page(Params),
    {ok, Rows, Total} = asobi_quests:page(Page),
    {ok, #{data => [render(Row) || Row <- Rows],
           page => #{limit  => maps:get(limit, Page),
                     offset => maps:get(offset, Page),
                     total  => Total}}}.
```

Now the UI half. Two files:

```
apps/asobi_quests/
  priv/console/
    index.jsx
    quests.jsx
```

```jsx
// apps/asobi_quests/priv/console/quests.jsx
import { DataTable, ErrorBanner, Mono, Pager, Screen, ago, count, useListParams, useOps }
  from '@asobi/console';

export default function Quests() {
  const params = useListParams();
  const { data, error, loading, refresh } = useOps('/ext/quests/list', {
    limit: params.limit,
    offset: params.offset,
  });

  return (
    <Screen title="Quests" subtitle="Definitions this node will serve.">
      <ErrorBanner error={error} onRetry={refresh} />
      <DataTable
        columns={[
          { key: 'key', label: 'Key', render: (row) => <Mono>{row.key}</Mono> },
          { key: 'reward', label: 'Reward', numeric: true, render: (row) => count(row.reward) },
          { key: 'updated_at', label: 'Updated', render: (row) => ago(row.updated_at) },
        ]}
        rows={data?.data}
        rowKey={(row) => row.key}
        loading={loading}
        empty="No quests defined."
      />
      <Pager page={data?.page} loading={loading} onOffset={(offset) => params.set({ offset })} />
    </Screen>
  );
}
```

```jsx
// apps/asobi_quests/priv/console/index.jsx
import Quests from './quests.jsx';

export default {
  name: 'quests',
  apiVersion: 1,
  nav: [{ path: '', label: 'Quests', section: 'game', order: 10 }],
  routes: [{ path: '', element: <Quests /> }],
};
```

Then build it, which is the next section. The screen appears at
`/console#/ext/quests`.

## The manifest

`priv/console/index.jsx` default-exports one object.

```jsx
export default {
  name: 'quests',      // required, and must equal info().name
  apiVersion: 1,       // required, and must equal the console's own
  nav: [...],          // optional
  routes: [...],       // optional
  slots: {...},        // optional
};
```

`name` is the extension's name from `info/0`, not the application name: an
application called `asobi_quests` serves an extension called `quests`. It is
what every path is keyed by, and it is why two extensions cannot collide.

### `nav`

```js
nav: [
  { path: '',        label: 'Quests',    section: 'game', order: 10 },
  { path: 'rewards', label: 'Rewards',   section: 'game', order: 20, caps: ['config'] },
]
```

| Key | | |
| --- | --- | --- |
| `path` | required | Relative, under `/ext/<name>`. `''` is the extension's own root |
| `label` | required | What the operator reads |
| `section` | optional | `game` or `ops`. Anything else, including `core` and an absent value, becomes `game` |
| `order` | optional | Within the section. Default 100, ties break on label |
| `caps` | optional | Capability classes the session must hold for the item to render at all |

Sections render in the order `core`, `game`, `ops`, and core's own screens are
all in `core` - which is why `core` is not a section an extension may name. An
extension cannot place itself above the screens an operator navigates by muscle
memory, whatever `order` it declares, because the ordering an operator relies on
is not something an installed extension should be able to rearrange.

`caps` does not authorise anything. The ops plane already refuses a call whose
class the session does not hold; this is so an operator is not offered a door
that answers 403. `erasure` is the class a console session does not get unless
the deployment sets `console_erasure`, so it is the one this matters for most.

### `routes`

```js
routes: [
  { path: '',    element: <Quests /> },
  { path: ':id', element: <Quest /> },
]
```

React Router routes, relative to `/ext/<name>`. A path that is not relative -
anything with a scheme, a host or a dot segment - is refused rather than
normalised, and the whole route is dropped.

Link between your own screens with `Link` from `@asobi/console`, using the
absolute path: `<Link to={`/ext/quests/${id}`}>`.

### `slots`

For the case that is not a new page. A clan panel belongs on the player an
operator is already looking at, not behind another click.

```js
slots: {
  'player.detail':  ClanPanel,      // rendered with { player }
  'player.actions': RemoveFromClan, // rendered with { player }
}
```

The set is closed, and each id is a promise about what is passed with it:

| Slot | Rendered with | Where |
| --- | --- | --- |
| `overview.stats` | `{ core, vm }` | Overview, below the stat tiles |
| `player.detail` | `{ player }` | Player detail, below the metadata block |
| `player.actions` | `{ player }` | Player detail, in the Related chips |
| `match.detail` | `{ match }` | Match detail, below the result |

Adding an id is a contract change and changing what an existing one passes is a
breaking one, so the set grows deliberately. If you need one that is not here,
say what screen and what context, and it can be added.

The set is closed in the enforced sense: an id that is not in it is dropped and
reported, because nothing renders it and a mistyped `player.details` would
otherwise look exactly like a panel that decided it had nothing to show. Import
`SLOTS` from `@asobi/console` to check against the console you are being
composed into rather than against this table.

A slot component that throws is caught: it renders an error banner naming your
extension, and the rest of the console carries on. That boundary is the reason
one extension's bad render does not take out the core screens an operator needs
during whatever incident produced the bad data.

## What you may import

One specifier, `@asobi/console`. It is not frozen - the extension contract is
experimental until a second consumer has said what it is missing - but
everything it exports is compiled into somebody else's release, so it changes
shape only behind a `CONSOLE_API_VERSION` bump.

```js
// The ops plane
ops, opsExt, opsUrl, ApiError

// Data fetching, with the staleness and URL-carried paging every core list has
useOps, useListParams, useDebounced

// Formatters. None of them throw on a null column
ago, bytes, count, duration, json, shortId, text, timestamp

// Components
Bool, DataTable, Detail, Empty, ErrorBanner, JsonBlock, Mono, Pager,
Pill, Screen, Search, Select, Stat, Toolbar

// This console and this node
useActor, useCapability, useFeatures

// Routing
Link, NavLink, useNavigate, useParams, useSearchParams

CONSOLE_API_VERSION
```

Two things you import from elsewhere, on purpose:

- `react`, for hooks and the JSX runtime. The composed bundle resolves one copy
  for everybody.
- your own CSS, as `*.module.css`. Vite scopes the class names, and the build
  merges every extension's styles into the one stylesheet the shell links. Plain
  `.css` works and shares one global namespace with every other extension, which
  is why it is a worse default.

Anything else the console happens to contain is not surface and will move.

### Calling your own actions

```js
import { opsExt } from '@asobi/console';

// GET /api/v1/ops/ext/quests/list?state=active
await opsExt('quests', 'list', { params: { state: 'active' } });

// POST /api/v1/ops/ext/quests/disable
await opsExt('quests', 'disable', { method: 'post', body: { key, reason } });
```

A `get` carries its parameters in the query string and a write carries them as a
JSON body, because that is what `asobi_ops_extension` reads in each case.

Anything but `get` is wrapped in `asobi_ops_audit:mutation/4` by core before your
handler runs, so a write from this console is durably attributed to the operator
who made it whether or not your extension does anything about it. You do not opt
in and you cannot opt out.

For a list screen, `useOps` is usually better than `opsExt` directly: it keeps
the previous rows on screen while the next page loads, which matters at exactly
the moment an operator is typing a player name off a support ticket.

```js
const { data, error, loading, refresh } = useOps('/ext/quests/list', query, { poll: 5000 });
```

### Asking what this node has

One composed bundle serves deployments that differ. A screen that renders a
Steam column should ask rather than assume:

```js
import { useCapability } from '@asobi/console';

const steam = useCapability('steam');
```

Your own screens are already gated: nothing you contribute renders unless
`/api/v1/ops/features` reports your extension installed on the node the console
is pointed at. You never have to check that yourself.

## Building it

The composed bundle is written into an application of your own. Not into
asobi's - the bundle is yours, it changes when your extensions change, and
writing into a dependency is a change that vanishes on the next fetch.

One application holding nothing but the bundle is enough:

```
apps/game_console/
  src/game_console.app.src
  priv/console/          <- written by the build
```

Name it in `rebar.config`, which is where the build looks:

```erlang
{asobi, [{console_bundle_app, game_console}]}.

{project_plugins, [
    {asobi, {git, "https://github.com/widgrensit/asobi.git", {tag, "v0.83.5"}}}
]}.
```

and in `sys.config`, which is what makes the node serve it:

```erlang
{asobi, [
    {console, true},
    {console_bundle_app, game_console},
    {ops_secret, ~"..."}
]}.
```

Two places because they answer two questions - where the build writes, and what
the node reads - and a release can be built on one machine and configured on
another. A `console_bundle_app` that is not in the release makes the console
answer 503 and log `bundle_app_unavailable`; it does not quietly fall back to
asobi's own bundle, because a host that asked for its composed console and
silently got the stock one would be missing exactly the screens it built the
thing for.

Then:

```bash
rebar3 asobi console
rebar3 release
```

`game_console` goes in the relx release list like any other application.

### What the build does

1. Runs `asobi_extensions:check/0`, the same validation `rebar3 asobi check`
   runs, so a broken extension set fails before an npm install rather than after.
2. Copies asobi's `console/` into `_build/asobi_console`. Everything generated
   lives there; neither the asobi dependency nor your extensions are written to.
3. Symlinks each extension's `priv/console` under `extensions/<name>` and
   generates one static import per extension.
4. `npm ci` from asobi's own committed lockfile. Your extensions have no
   `package.json`, no `node_modules` and no React of their own.
5. `vite build` into your `console_bundle_app`'s `priv/console`.

Node is needed on the machine that runs step 4 and 5, and nowhere else. A host
with no extension screens never runs this and never needs Node, which is the
promise the committed bundle in asobi's own `priv` exists to keep.

Options:

```bash
rebar3 asobi console --out some/other/dir   # ignore console_bundle_app for one run
rebar3 asobi console --reinstall            # npm ci again; it is skipped when node_modules exists
```

## The dev loop

```bash
rebar3 shell                       # in one terminal, the node on 8082
rebar3 asobi console --dev         # in another
```

Vite serves the console on `http://localhost:5173` with hot reload, proxying
`/api/v1/ops` and `/console/session` at the node. Editing a `.jsx` in your
extension is visible in the browser in milliseconds, against real data from a
real node, with no rebuild and no `rebar3` restart.

The proxy is same-origin, so the console takes the same path a self-hosted node
takes and needs no API base configured. The session cookie the node sets
survives the hop because the generated config rewrites its domain.

```bash
rebar3 asobi console --dev --target http://10.0.0.4:8084 --port 5174
```

The dev server has no shell document of its own from the node, so the node
version and the deployment label read as unset. Everything else is real.

## What the CSP forbids

The console is served under `script-src 'nonce-<per-response>'` with no host
source. Your code lives under the same policy as core's:

- **No `style={{...}}`.** There is no `style-src-attr`, so it falls back to
  `style-src 'self'` and the browser refuses the declaration. Use a class.
- **No `eval` and no `new Function`.** `'unsafe-eval'` is not in the policy, and
  CI greps the built bundle for both. A dependency that needs either is a reason
  to drop the dependency.
- **No dynamic `import()`, and no lazy screens.** A nonce does not propagate to
  a module's static imports, so a second chunk would be refused by the browser.
  This is also why the composition is a build step: see
  [ADR 0009](https://github.com/widgrensit/asobi/blob/main/docs/adr/0009-console-extensions-compose-at-build-time.md).
- **No remote anything.** `default-src 'none'`; `connect-src` is the ops API and
  nothing else. No font CDN, no analytics, no image host. Inline small images as
  `data:` URIs and the bundler will handle it.

None of this is a rule your screen has to remember. Each one fails visibly the
first time you run the dev server.

## Versioning

`apiVersion` in your manifest is checked against the console's own
`CONSOLE_API_VERSION`. A mismatch means the extension is refused entirely, with
one line in the browser console naming it, rather than rendered half-working.

The version bumps when the surface changes shape in a way an existing extension
would not survive. Adding an export does not bump it. React and react-router
count: your screens compile against those too, so a major of either is the same
kind of move as renaming an export.

The other version to keep straight is the plugin. `rebar3 asobi console` runs
from the copy of asobi in `project_plugins`, but it composes the console out of
the `console/` source of the copy in `deps` - so the surface your screens
compile against, `CONSOLE_API_VERSION` included, is the dependency's, and the
plugin supplies only the provider itself. Pin both to the same tag, for the
same reason [`rebar3 asobi check`](extensions.md) does: a plugin older than the
dependency composes a console the node's own extension set may not match.

## When something does not appear

| Symptom | Cause |
| --- | --- |
| Nav item missing, `/features` shows `console: true` for the extension | The bundle was not recomposed after the extension was added. Run `rebar3 asobi console` |
| Nav item missing, `/features` does not list the extension at all | The extension is not in the release. It is an OTP application dependency question, not a console one |
| `/console` answers 503, log says `bundle_app_unavailable` | `console_bundle_app` names an application that is not in this release |
| `/console` answers 503, log says `manifest_unreadable` | The named application is in the release but its `priv/console` is empty. The build never ran, or ran with `--out` pointing elsewhere |
| Screen is blank, browser console says an extension was refused | `apiVersion` mismatch, or a `name` that is not `^[a-z][a-z0-9_]*$` |
| Your panel never appears, browser console names the slot | The slot id is not one this console renders. Check it against `SLOTS` |
| Nav item missing, nothing refused and nothing logged | A well-formed `name` that is not this extension's. It does not match what `/features` reports, so it is treated as an extension this node does not have - which is silent on purpose, because that is the normal case |
| Panel shows an error banner naming your extension | Your component threw. The boundary caught it; the message is in the banner and the stack is in the browser console |
| A request answers 403 and the console returns to the sign-in screen | The action's `class` is not one the session holds - every 401 and 403 is read as a lost session. `erasure` needs `console_erasure` set on the deployment |

## Also

- [A worked example](https://github.com/widgrensit/asobi/tree/main/examples/console-extension) -
  a release with one extension that ships screens, an application to build the
  bundle into, and the `rebar.config` and `sys.config` that wire the two
- [Writing an extension](extensions.md) - the manifest, `ops/0`, and what a
  handler is given
- [Operator console](console.md) - turning the console on, and what the ops
  plane is
- [ADR 0009](https://github.com/widgrensit/asobi/blob/main/docs/adr/0009-console-extensions-compose-at-build-time.md) - why
  this is a build step and not a runtime plugin loader
