# ADR 0000: Record architecture decisions

Date: 2026-05-05

## Status

Accepted.

## Context

asobi is changing fast and several decisions have non-obvious trade-offs
(behaviour API shape, broadcast strategy, sandboxing model). Without a
durable record, future contributors and our future selves rediscover the
same arguments and sometimes reverse them on weaker grounds than the
original choice.

## Decision

Record significant architecture decisions as numbered markdown files in
`docs/adr/`. One file per decision. Filename: `NNNN-short-slug.md`.

Use Michael Nygard's lightweight ADR template:

- **Title** — `ADR NNNN: short imperative phrase`
- **Date** — `YYYY-MM-DD`
- **Status** — `Proposed` | `Accepted` | `Superseded by ADR NNNN` | `Deprecated`
- **Context** — what's true now that motivates this decision
- **Decision** — the choice, in one or two short paragraphs
- **Consequences** — what this enables, what it costs, what it forecloses
- **Alternatives considered** — options ruled out, with one-line rationale

Keep them short. An ADR is a record, not an essay. If you need more than
one screen, split it.

What counts as ADR-worthy:

- New behaviour callbacks or wire-format additions to public APIs
- Changes to how the runtime handles untrusted code (sandbox, timeouts,
  heap limits)
- Optimisations that change observable semantics or trade safety for speed
- Decisions that we know we'll be tempted to reverse later

What does NOT need an ADR:

- Bug fixes
- Pure refactors
- Renames
- Adding tests

## Consequences

- Future readers can recover *why* a thing was done, not just *what*.
- The discipline forces the author to articulate the alternative they
  rejected — which is usually where the real argument lives.

## Alternatives considered

- **Inline comments / module docs** — too local; cross-cutting decisions
  span many files and the comment rots first.
- **CHANGELOG / git history** — captures *what* changed but not *why we
  picked this over the obvious alternative*.
- **A wiki / Notion** — drifts from the code; ADRs in-repo travel with
  the branch and PRs reference them.
