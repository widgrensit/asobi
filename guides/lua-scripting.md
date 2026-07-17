# Lua Scripting

Lua scripting is provided by [asobi_lua](https://github.com/widgrensit/asobi_lua),
a standalone runtime that wraps this library with
[Luerl](https://github.com/rvirding/luerl). asobi has no Lua dependency of its
own, so asobi_lua's own documentation is the reference — this page points to it
rather than keeping a copy that drifts.

Start the runtime:

```bash
docker run -v ./game:/game -p 8084:8084 ghcr.io/widgrensit/asobi_lua
```

Then read, in asobi_lua:

- [Lua scripting](https://github.com/widgrensit/asobi_lua/blob/main/guides/lua-scripting.md)
  — callbacks, match and world modes, script globals, and using it from an
  Erlang project
- [Lua bots](https://github.com/widgrensit/asobi_lua/blob/main/guides/lua-bots.md)
  — AI-controlled players
- [Self-hosting](https://github.com/widgrensit/asobi_lua/blob/main/guides/self-hosting.md)
  — running the image
- [Sandbox](https://github.com/widgrensit/asobi_lua/blob/main/guides/security-sandbox.md),
  [trust model](https://github.com/widgrensit/asobi_lua/blob/main/guides/security-trust-model.md),
  and [known limitations](https://github.com/widgrensit/asobi_lua/blob/main/guides/security-known-limitations.md)
  — what Lua code can and cannot reach

For what the runtime is configured with, see [Configuration](configuration.md).
