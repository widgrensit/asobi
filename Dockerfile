FROM erlang:28.0.1-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install rebar3
RUN wget -q https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 -O /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Copy dependency specs first for layer caching
COPY rebar.config rebar.lock ./
RUN rebar3 compile --deps_only

# Copy source and build release
COPY config/ config/
COPY src/ src/
RUN rebar3 as prod release

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi/ ./

# Game scripts mount point for Lua users
RUN mkdir -p /app/game && chown -R asobi:asobi /app
VOLUME ["/app/game"]

USER asobi
EXPOSE 8080

ENV ASOBI_PORT=8080 \
    ASOBI_NODE_HOST=127.0.0.1 \
    ERLANG_COOKIE=asobi_cookie \
    ASOBI_DB_HOST=db \
    ASOBI_DB_NAME=asobi \
    ASOBI_DB_USER=postgres \
    ASOBI_DB_PASSWORD=postgres \
    ASOBI_CORS_ORIGINS=*

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi", "foreground"]
