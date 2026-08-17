FROM erlang:29.0.4-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install rebar3
RUN curl -fsSL https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Copy dependency specs first for layer caching
COPY rebar.config rebar.lock ./
RUN rebar3 compile --deps_only

# Build the releases. Two of them since asobi#513: the engine, and the datagram
# gateway, whose release contains no nova, kura or shigoto at all. `-n` is now
# required - relx refuses to guess when a project declares more than one.
COPY config/ config/
COPY include/ include/
COPY src/ src/
COPY apps/ apps/
COPY priv/ priv/
RUN rebar3 as prod release -n asobi && rebar3 as prod release -n asobi_dgram

# --- The datagram gateway image ---
# `docker build --target gateway`. Its own image and not a role of the engine's,
# which is the whole of asobi#513: OTP starts an application's dependencies
# before its start callback runs, so a role checked in code could never stop the
# engine image from opening a database pool in the container that parses packets
# from the internet. This image has no driver to open one with.
#
# Deliberately before the engine stage so the default build target is unchanged.
FROM debian:trixie-slim AS gateway

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi_dgram/ ./
RUN chown -R asobi:asobi /app

USER asobi
# UDP, and nothing else. No HTTP listener exists in this image.
EXPOSE 7777/udp

ENV ASOBI_ROLE=dgram_gw \
    ASOBI_NODE_HOST=127.0.0.1 \
    ASOBI_NODE_NAME=asobi_dgram \
    ASOBI_DGRAM_PORT=7777 \
    ASOBI_DGRAM_LINK_PORT=7778

# Same trap as the engine's, and sharper: this node shares a network namespace
# with the engine, so a shared cookie is a path out of the process handling
# hostile packets into the one running the game. Override it, per deploy.
ENV ERLANG_COOKIE=asobi

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi_dgram", "foreground"]

# --- Runtime ---
# Must match the builder's Debian release (erlang:28.4.2-slim is trixie-based)
# so the linked-against GLIBC matches at runtime.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi/ ./

# Game scripts mount point
RUN mkdir -p /app/game && chown -R asobi:asobi /app
VOLUME ["/app/game"]

USER asobi
EXPOSE 8084

ENV ASOBI_PORT=8084 \
    ASOBI_NODE_HOST=127.0.0.1 \
    ASOBI_NODE_NAME=asobi \
    ASOBI_DB_HOST=db \
    ASOBI_DB_NAME=asobi \
    ASOBI_DB_USER=postgres \
    ASOBI_DB_PASSWORD=postgres

# Anonymous guest auth (POST /api/v1/auth/guest) is off by default. The game
# opts in with `guest_auth = true` in its Lua, or the operator does it in a
# mounted sys.config, which wins when set (ADR 0011); the operator always
# supplies the secret pepper (ADR 0004). Guest auth is on iff both are set. Use a base64/hex
# pepper from >= 32 random bytes (NOT raw /dev/urandom bytes, whose quotes/
# newlines would break the rendered config):  openssl rand -base64 48
# A pepper under 32 bytes is treated as unconfigured, so guest auth fails closed.
# The rendered sys.config holds the pepper in cleartext - treat it as
# secret-bearing (the release already sets a small crash-dump policy).
ENV ASOBI_GUEST_VERIFIER_PEPPER=""

# The datagram plane (ADR 0013). Every one of these is unset by default and the
# plane does not exist until they are: ASOBI_ROLE stays `engine`, nothing binds a
# UDP port, and a client asking to open the plane is told it is unavailable.
#
#   ASOBI_ROLE                     `engine` (default) or `dgram_gw`. One image,
#                                  two roles, run as two containers - the gateway
#                                  parses packets from the internet and must not
#                                  share a process tree with the Lua sandbox or
#                                  the database credentials.
#   ASOBI_DGRAM_PORT               UDP port the gateway binds (default 7777).
#   ASOBI_DGRAM_LINK_PORT          Engine link, loopback only (default 7778).
#   ASOBI_DGRAM_SHARDS             SO_REUSEPORT receivers. Fixed at boot.
#   ASOBI_DGRAM_LINK_SECRET        Shared secret for the engine link. Prefer the
#   ASOBI_DGRAM_LINK_SECRET_FILE   file form: it stays out of `docker inspect`.
#   ASOBI_DGRAM_GATEWAY            host:port the ENGINE dials. Its opt-in.
#   ASOBI_DGRAM_ENDPOINT           host:port clients are told to send to.
#   ASOBI_DGRAM_POSE_FIELDS        `x:100,y:100,vx:100,vy:100` - name and scale,
#                                  in canonical order. Reordering changes what
#                                  every field on the wire means.
#   ASOBI_DGRAM_POSE_PERIOD        Axial refresh, in ticks (default 20).
#
# See guides/self-hosting.md for a two-service compose file.

# Erlang term fragment spliced into kura's socket_options list.
# Default forces IPv4; set to "inet6" for IPv6-only Postgres networks.
ENV ASOBI_DB_SOCKET_OPTS=inet

# vm.args has `-setcookie ${ERLANG_COOKIE}`. Left unset, relx renders an
# EMPTY value and erlexec silently consumes the next flag (+pc) as the
# cookie, so `+pc unicode` never applies and bin/asobi rpc/remote
# can't attach. The default is the literal string `asobi` and therefore
# public: override it per deploy. It is not enough that no epmd port is
# published - two containers sharing a network namespace share a loopback
# and an epmd, so the engine and the datagram gateway must be given
# DIFFERENT cookies or either one can rpc into the other.
ENV ERLANG_COOKIE=asobi

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi", "foreground"]
