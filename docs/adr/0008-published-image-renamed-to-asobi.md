# ADR 0008: The published image is ghcr.io/widgrensit/asobi

Date: 2026-08-06

## Status

Accepted. The old name stops publishing on 2027-02-01.

## Context

The runnable image used to be published from `widgrensit/asobi_lua`, back when
the Lua runtime was a separate OTP application in a separate repository. That
repository has held no source of its own since the merge: its workflow pinned
asobi by git ref, built a release entirely out of this repository, and pushed
the result under its own name. The image was an alias.

An alias needs a staleness gate, because it can silently republish an old
commit when the pin is not moved. It also names the image after the smaller
half of what is inside it. What ships is one node containing the game backend,
the Lua runtime and the operator console - `asobi_lua` names one of the three.

The name is also load-bearing in a way a repository name is not. It is pasted
into every compose file, Dockerfile and Kubernetes manifest that runs asobi, so
changing it breaks running deployments unless the old one keeps resolving for
long enough for people to notice on their own schedule.

## Decision

Publish `ghcr.io/widgrensit/asobi` from this repository
(`.github/workflows/docker-publish.yml`), tagged `latest` on the default branch
alongside the branch, long-SHA and semver tags. The release binary inside it is
`bin/asobi`.

Keep publishing `ghcr.io/widgrensit/asobi_lua` in parallel until **2027-02-01**,
after which that name stops receiving new tags. Images already pushed under it
stay pullable; they simply stop moving. Six months is long enough to cover a
studio that ships on a quarterly cadence and short enough that the alias does
not become permanent.

Documentation uses the new name only. The rename is noted as one sentence in
exactly two places: beside the quickstart compose in
`guides/getting-started.md`, and beside the production compose in
`guides/self-hosting.md`. A one-word change does not get a migration section.

Add an `asobi_lua` row to `scripts/check-archived-refs.sh` so CI fails if a
guide sends a reader to the retired repository.

## Consequences

- Compose files, Dockerfiles and manifests naming `asobi_lua` keep working
  until 2027-02-01 and then stop receiving updates. They do not break at that
  moment; they freeze, which is the failure mode that gets noticed slowly. The
  two doc notes are what make it get noticed sooner.
- `bin/asobi_lua` no longer exists in the image. Anything that shells into the
  container to run `bin/asobi_lua rpc` or `remote_console` has to change, and
  unlike the image name this one fails loudly.
- The staleness gate is gone with the alias. An image built from this
  repository's own `HEAD` cannot be behind itself.
- `asobi_lua` remains correct as a *module and configuration* prefix -
  `asobi_lua_config`, `asobi_lua_api`, `ASOBI_LUA_RELOAD`, and the
  `{asobi_lua, [...]}` application key that `asobi_lua_env:get_env/2` still
  reads first. This ADR renames an image and a repository reference, nothing
  else. Renaming those would break every reader's configuration.

## Alternatives considered

- **Cut over with no window.** Rejected: every deployment pinning the old name
  breaks on its next pull, and the people it breaks are self-hosters who did
  nothing wrong.
- **Keep the alias indefinitely.** Rejected: an alias with no end date is two
  names for one artefact forever, and the second one is the one that goes
  stale without saying so. A deprecation without an end is not a decision.
- **Publish under both names permanently and treat `asobi_lua` as the
  Lua-flavoured variant.** Rejected: there is one image and one product. Two
  names would imply a choice that does not exist.
