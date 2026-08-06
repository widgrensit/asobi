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

# Build the release.
COPY config/ config/
COPY include/ include/
COPY src/ src/
COPY priv/ priv/
RUN rebar3 as prod release

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
    ASOBI_DB_HOST=db \
    ASOBI_DB_NAME=asobi \
    ASOBI_DB_USER=postgres \
    ASOBI_DB_PASSWORD=postgres

# Anonymous guest auth (POST /api/v1/auth/guest) is off by default. The game
# opts in with `guest_auth = true` in its Lua; the operator only supplies the
# secret pepper (ADR 0004). Guest auth is on iff both are set. Use a base64/hex
# pepper from >= 32 random bytes (NOT raw /dev/urandom bytes, whose quotes/
# newlines would break the rendered config):  openssl rand -base64 48
# A pepper under 32 bytes is treated as unconfigured, so guest auth fails closed.
# The rendered sys.config holds the pepper in cleartext - treat it as
# secret-bearing (the release already sets a small crash-dump policy).
ENV ASOBI_GUEST_VERIFIER_PEPPER=""

# Erlang term fragment spliced into kura's socket_options list.
# Default forces IPv4; set to "inet6" for IPv6-only Postgres networks.
ENV ASOBI_DB_SOCKET_OPTS=inet

# vm.args has `-setcookie ${ERLANG_COOKIE}`. Left unset, relx renders an
# EMPTY value and erlexec silently consumes the next flag (+pc) as the
# cookie, so `+pc unicode` never applies and bin/asobi rpc/remote
# can't attach. Distribution stays container-internal (-sname, no epmd
# port exposed), so a static default is fine; override per deploy if you
# expose distribution.
ENV ERLANG_COOKIE=asobi

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi", "foreground"]
