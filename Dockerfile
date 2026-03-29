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
COPY priv/ priv/
RUN rebar3 as prod release

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi/ ./
RUN chown -R asobi:asobi /app

USER asobi
EXPOSE 8080

ENV ASOBI_PORT=8080
ENV ASOBI_NODE_HOST=127.0.0.1
ENV ERLANG_COOKIE=asobi_cookie

ENTRYPOINT ["bin/asobi"]
CMD ["foreground"]
