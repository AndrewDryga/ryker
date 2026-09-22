FROM golang:1.26.6-bookworm AS build

ARG COOP_VERSION=v9.0.0-389-gcb5178eb
ARG COOP_REVISION=cb5178ebb9f0e6c53999df51ffffe73bd5f84e6c

RUN git clone https://github.com/AndrewDryga/coop.git /build/coop \
 && cd /build/coop \
 && git checkout --detach "$COOP_REVISION" \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/AndrewDryga/coop/internal/cli.Version=$COOP_VERSION" \
      -o /out/coop .

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl docker.io git jq openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 coop \
 && useradd --uid 1000 --gid coop --home-dir /var/lib/coop --create-home --shell /bin/sh coop

COPY --from=build /out/coop /usr/local/bin/coop
RUN coop version \
 && coop help sessions policies >/dev/null \
 && coop help sessions connect >/dev/null

COPY --chown=coop:coop deploy/compose/coop/entrypoint.sh /usr/local/bin/ryker-coop-entrypoint
COPY deploy/compose/coop/Box.Dockerfile /usr/local/share/ryker/Box.Dockerfile
RUN chmod 0755 /usr/local/bin/ryker-coop-entrypoint

USER coop
ENV HOME=/var/lib/coop \
    COOP_CONFIG_DIR=/var/lib/coop/agents \
    COOP_NO_UPDATE_CHECK=1 \
    COOP_REPO=/var/lib/ryker-workspaces/seed \
    COOP_RUNTIME=docker \
    TMPDIR=/var/lib/coop/tmp

ENTRYPOINT ["/usr/local/bin/ryker-coop-entrypoint"]
