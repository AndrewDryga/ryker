ARG COOP_BASE_IMAGE=coop-box
# The image the release builds with (Dockerfile ELIXIR_IMAGE), so a job or review
# of Ryker's own repository builds and tests it with the release's toolchain.
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.6-erlang-28.5.0.8-debian-bookworm-20261005-slim@sha256:85799e31abac9c2636d9f5068f9b11ec7584cc6494ec7a211ddb4257782906a6

FROM ${ELIXIR_IMAGE} AS elixir

FROM ${COOP_BASE_IMAGE}

USER root
COPY ryker-ca.pem /usr/local/share/ca-certificates/ryker-ca.crt
RUN chmod 0644 /usr/local/share/ca-certificates/ryker-ca.crt \
 && update-ca-certificates

# Each package download is tried again, and what a build fetched stays in BuildKit's cache for the
# next build: neither cache is part of the image. On 2026-10-17 a tenant host on weak Wi-Fi fetched
# at a few KB/s, and every rebuild of this box started its packages over and gave up, so its worker
# could not move to a new Coop.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && printf '%s\n' 'Acquire::Retries "10";' 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
      >/etc/apt/apt.conf.d/90ryker-box-downloads

# Jobs and Coop's trusted review gate run in this box, not in a repository's
# own image, so it carries what repositories' gates commonly need. On
# 2026-09-28 emisar's review gate failed eight browser tests with "no
# Chrome/Chromium found".
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends chromium-headless-shell imagemagick

# The PostgreSQL server compose.test.yml pins. A job or review gets neither
# Docker nor sidecar services, so Ryker's scripts/elixir-test.sh starts a private
# server from these binaries; without one every review of Ryker failed its gate.
# The signing key is checked against its digest (key B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL --retry 5 -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && echo "0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76  /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc" \
      | sha256sum -c - \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends postgresql-common \
 && sed -ri 's/^#?(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf \
 && apt-get install -y --no-install-recommends postgresql-18 \
 && ln -s /usr/lib/postgresql/18/bin/initdb /usr/lib/postgresql/18/bin/pg_ctl /usr/local/bin/

COPY --from=elixir /usr/local/lib/erlang /usr/local/lib/erlang
COPY --from=elixir /usr/local/lib/elixir /usr/local/lib/elixir
RUN for tool in erl erlc escript epmd; do ln -s ../lib/erlang/bin/$tool /usr/local/bin/$tool; done \
 && for tool in elixir elixirc iex mix; do ln -s ../lib/elixir/bin/$tool /usr/local/bin/$tool; done

USER node
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ryker-ca.crt
