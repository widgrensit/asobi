# ADR 0003: Docs are single-sourced by truth-holder, not by repo

Date: 2026-07-17

## Status

Accepted.

## Context

The same endpoints are documented twice. `asobi/guides/*.md` ships to
hexdocs.pm/asobi as ex_doc extras. asobi.dev hand-writes its own copy as
34 Erlang view modules (`asobi_site/src/views/asobi_site_docs_*_view.erl`).
Nothing couples the two, and nothing notices when they disagree.

They disagree, measurably:

- **A whole feature reached one surface and not the other.** Guest auth
  shipped 2026-07-14 (backend #164, all 7 SDKs) fully documented in
  `guides/authentication.md`. asobi.dev carried zero mentions of it across
  every page until asobi_site#90 — three days later, and only because
  someone looked.
- **The error tables drifted from the controller.** `guides/authentication.md`
  documented 11 of the 15 atoms `asobi_guest_controller` returns (#176). One
  of the four missing was the retryable `409 device_already_registered`,
  which a client reading the docs would treat as fatal.
- **Three API ports are documented for the same server.** `guides/`
  says 8080, asobi.dev and all 7 SDK READMEs say 8084, and asobi's own
  dev config listens on 8082.

The obvious fix — make `guides/` the single source and generate asobi.dev
from it — does not survive contact with the boundaries this project
already holds:

- **It would put a closed product's docs in a public library.** `/docs/cloud`
  documents the managed offering (console.asobi.dev), which is developed
  closed-source on its own release cadence. Hosting its docs in `asobi`'s
  hexdocs publishes a commercial surface from a public library — one whose
  own `comparison.md` and `exit.md` sell independence from closed managed
  clouds.
- **asobi does not own the Lua docs it already ships.** `asobi` has no
  luerl dependency and no `luerl` reference in `src/`, yet publishes
  `lua-scripting.md` and `lua-bots.md` (173 lines) to hexdocs.
  `asobi_lua` — which actually implements the runtime — carries its own
  richer set (1,255 lines across six guides). asobi holds a stale copy of
  docs for a library it does not depend on.
- **It cannot cover the site anyway.** Only 16 of asobi.dev's 34 doc pages
  have a `guides/` counterpart. 18 do not, and 9 guides have no site page.

"The docs drifted" is real. "Therefore one repo owns all docs" does not
follow.

## Decision

Each doc page is generated from the repo whose CI can verify its claims.
The truth-holder is the repo that would fail a build if the claim became
false — not the repo that happens to want the page.

| Source repo | Pages it owns |
|---|---|
| `asobi` | authentication, configuration, protocols/rest, protocols/websocket, matchmaking, economy, voting, world-server, clustering, performance, quickstart, security/{auth,threat-model,known-limitations} |
| `asobi_lua` | lua/{api,bots}, security/{lua-sandbox,lua-trust-model,lua-known-limitations}, self-host |
| `asobi-{unity,godot,defold}` | the matching quickstart/\<engine\> page |
| `asobi_site` | cloud, samples, tutorials/\*, concepts, errors, leaderboards, lua/{callbacks,cookbook}, security overview |

Corollaries:

- **`asobi` drops its Lua guides.** `lua-scripting.md` and `lua-bots.md`
  leave asobi's ex_doc extras; asobi links to asobi_lua's hexdocs instead.
  A library documents what it implements.
- **`/docs/cloud` is never single-sourced into a public library.** It stays
  hand-written site-side. The one-line pointers in `glossary.md` and
  `comparison.md` are the correct register for a public library
  acknowledging a commercial option.
- **Pages with no truth-holder guide stay hand-written.** Writing a guide
  in `asobi` purely so the site can generate from it inverts the
  relationship: it warps the library to serve the website.
- **Docs examples agree on port 8084.** The port is not a fact to be
  discovered — prod reads `${ASOBI_PORT}` and each setup path simply chose
  differently. It is a convention, so the docs pick one. 8084 wins on
  count: 7 SDK repos across 34 files, plus 26 uses on the site, against
  29 uses in `guides/` alone.

## Consequences

- asobi.dev consumes generated content from three repo families rather
  than one, so the site build fetches from each. More moving parts than a
  single source, and the price of not violating the boundaries.
- The 18 site-only pages keep drifting by hand. That is accepted: they
  have no truth-holder, so there is nothing to generate them from. The
  drift guards (`scripts/check-error-drift.sh` here and in asobi_site)
  cover the factual tables regardless of who writes the prose.
- hexdocs and asobi.dev keep different registers — library users and game
  developers are different audiences — so generation carries content, not
  layout. The site keeps its own shell, callouts, and SDK tabs.
- Two guides in `asobi` become one-line pointers to asobi_lua. Anyone
  landing on the old hexdocs anchors follows a link instead of reading a
  stale copy.
- Reconciling the existing divergences into the owning repos, and fixing
  the port, are prerequisites. Generating first would propagate whichever
  copy happened to win.
