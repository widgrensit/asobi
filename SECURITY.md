# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in Asobi, please report it
**privately** so we can fix it before it is publicly disclosed.

**Do not open a public GitHub issue for security issues.**

### How to report

Either of these channels work:

- **GitHub Security Advisory (preferred):**
  [Report privately](https://github.com/widgrensit/asobi/security/advisories/new)
- **Email:** security@asobi.dev

### What to expect

- Acknowledgement within **48 hours**
- Initial assessment within **7 days**
- Coordinated disclosure timeline agreed with you
- Credit in the security advisory if you want it

## Supported versions

| Version | Supported |
|---------|-----------|
| latest stable | ✅ |
| older releases | ❌ — please upgrade |

## Scope

**In scope:**
- The `asobi` Erlang/OTP library (this repository)
- Bundled client SDKs in this org

**Out of scope:**
- The hosted asobi.dev SaaS — see https://asobi.dev/security
- Third-party dependencies — please report upstream

## Acknowledgements

We credit security researchers who report responsibly. Past advisories:
[Security advisories](https://github.com/widgrensit/asobi/security/advisories).

## Security architecture

Engineering documentation about how the runtime defends itself, and what
operators are responsible for, is published as part of the project
guides:

- [Threat model](guides/security-threat-model.md) — what asobi treats
  as trusted vs. untrusted, the single-node design constraint, BEAM
  distribution and public-ETS assumptions.
- [Authentication & rate limiting](guides/security-auth.md) — Apple
  StoreKit 2 JWS verification chain, per-route rate-limit groups, the
  brute-force surface, and the integration test suite that pins it.
- [Known limitations](guides/security-known-limitations.md) — the
  resource-exhaustion gaps the runtime does **not** close (mostly
  operator-facing), and the rationale for each.
