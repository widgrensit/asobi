# console-extension

An extension with its own operator console screens: a page in the navigation, a
panel on the player screen core already owns, and a write that goes through the
ops plane's audit.

The domain is deliberately trivial - operator notes about a player, held in ETS
so the example needs no migration and no table - because the point is the seam,
not the feature.

## The two halves

```
apps/asobi_notes/
  src/asobi_notes_extension.erl   ops/0: the actions
  src/asobi_notes_ops.erl         the handlers behind them
  src/asobi_notes.erl             the domain, such as it is
  priv/console/
    index.jsx                     the console manifest
    notes.jsx                     the page
    player-notes.jsx              the panel on the core player screen
```

`ops/0` is declared. `priv/console` is not declared anywhere: it is found by
being there, like a migration.

Nothing in `apps/asobi_notes` knows about routing, HTTP or the console shell.
Core owns `/api/v1/ops/ext/:extension/:action` and dispatches every declared
action behind it, and `rebar3 asobi console` compiles the screens into the
bundle. The extension contributes no routes, in either plane.

## What each piece demonstrates

| | |
| --- | --- |
| `ops/0` with `class => read` and `class => config` | The only thing that authorises. `config` is what the write needs, and the panel checks for it before offering the form |
| `codes/0` | `notes.empty` answers 400 with its own message. Without it an ordinary domain failure answers 500 and logs as a core defect |
| `sup/0` | A library application with no `mod`, supervised by core. An extension supervising itself can take the node with it |
| `nav` in the manifest | One entry, `section: 'game'`, which sits below every core screen |
| `slots: { 'player.detail': ... }` | The case that is not a new page: notes about the player an operator is already reading |
| `opsExt(..., { method: 'post' })` | A write. Core wraps it in an audit row naming the operator before the handler runs, and the extension does nothing to arrange that |
| `useOps` and `useListParams` | Paging that survives a refresh and a link that carries the page |

## Running it

```bash
rebar3 asobi check       # the extension set is valid
rebar3 asobi console     # compose the console into apps/game_console/priv/console
rebar3 shell
```

Then `http://localhost:8082/console`, sign in with the `ops_secret` from
`config/sys.config`, and there is a **Notes** entry in the navigation and an
**Operator notes** panel on any player.

While working on the screens, skip the rebuild:

```bash
rebar3 shell                    # one terminal
rebar3 asobi console --dev      # another
```

Hot reload on `http://localhost:5173`, with `/api/v1/ops` proxied at the node,
so the screens run against real data as you edit them.

## What it does not show

No database, no migration, no Kura schema, no Lua bindings and no `rpc/0`. Those
are [Writing an extension](../../guides/extensions.md). Notes are in ETS and go
away when the node stops, which is fine for a page whose subject is the console.

## Also

- [Extending the operator console](../../guides/console-extensions.md) - the
  manifest, the frozen import surface, the build, and what the CSP forbids
- [ADR 0009](../../docs/adr/0009-console-extensions-compose-at-build-time.md) -
  why this is a build step and not a runtime plugin loader
