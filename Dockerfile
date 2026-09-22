ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20260610-slim

FROM ${ELIXIR_IMAGE} AS build

ARG RYKER_VERSION
ENV MIX_ENV=prod \
    RYKER_ELIXIR_VERSION=${RYKER_VERSION}

RUN test -n "$RYKER_VERSION" \
 && apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY mix.exs mix.lock ./
RUN mix local.hex --force \
 && mix local.rebar --force \
 && mix deps.get --only prod \
 && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY README.md CHANGELOG.md LICENSE SECURITY.md ./
COPY Dockerfile compose.yml install.sh ./
COPY deploy/compose deploy/compose
COPY deploy/nginx deploy/nginx
COPY docs docs
COPY scripts scripts

RUN mix compile --warnings-as-errors \
 && mix release ryker

FROM debian:bookworm-slim AS runtime

ARG RYKER_VERSION
LABEL org.opencontainers.image.title="Ryker" \
      org.opencontainers.image.version="$RYKER_VERSION" \
      org.opencontainers.image.source="https://github.com/AndrewDryga/responder"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client openssl libstdc++6 libncurses6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 ryker \
 && useradd --uid 1000 --gid ryker --home-dir /var/lib/ryker --create-home --shell /usr/sbin/nologin ryker

WORKDIR /opt/ryker
COPY --from=build --chown=ryker:ryker /build/_build/prod/rel/ryker ./
COPY --chown=ryker:ryker deploy/compose/entrypoint.sh /usr/local/bin/ryker-entrypoint

RUN chmod 0755 /usr/local/bin/ryker-entrypoint \
 && mkdir -p /var/lib/ryker \
 && chown ryker:ryker /var/lib/ryker

USER ryker
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/var/lib/ryker \
    RELEASE_DISTRIBUTION=none \
    RYKER_CONTAINER=true \
    RYKER_STATE_DIR=/var/lib/ryker

EXPOSE 4321 4319 4320 4322
ENTRYPOINT ["/usr/local/bin/ryker-entrypoint"]
CMD ["start"]
