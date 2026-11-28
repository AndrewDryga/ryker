# Base images are pinned by digest as well as tag (2026-10-04 review).
FROM scratch AS coop-upstream

FROM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS build

ARG COOP_VERSION=v15.5.0-9-g4cdfe027
ARG COOP_REVISION=4cdfe027fd40eeb41fe2f3dd5a76430a7e4f5dc0

# Only the pinned commit, and each download tried again: on 2026-10-17 the tenant host's network
# broke off a clone of Coop's whole history twice, after 397 s and 36 s, and its worker stayed on
# the Coop it ran.
# A local rollout can supply a bare Git repository as the coop-upstream build context.
# Both sources must resolve to the pinned commit.
RUN --mount=type=bind,from=coop-upstream,target=/upstream \
    upstream=https://github.com/AndrewDryga/coop.git \
 && if test -f /upstream/HEAD; then upstream=/upstream; fi \
 && git init --quiet /build/coop \
 && cd /build/coop \
 && for attempt in 1 2 3 4 5; do \
      git -c safe.directory=/upstream fetch --quiet --depth 1 "$upstream" "$COOP_REVISION" && break; \
      [ "$attempt" -lt 5 ] || exit 1; sleep $((attempt * 10)); \
    done \
 && git checkout --quiet --detach FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$COOP_REVISION" \
 && for attempt in 1 2 3 4 5; do \
      go mod download && break; \
      [ "$attempt" -lt 5 ] || exit 1; sleep $((attempt * 10)); \
    done \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/AndrewDryga/coop/internal/cli.Version=$COOP_VERSION" \
      -o /out/coop .

# The image the worker's Docker daemon runs (compose.yml `ryker-coop-docker`), by the same digest.
FROM docker:29.10.0-dind-alpine3.24@sha256:4bbc7223f81db790097c6dea42fb93e05b8fead4f0431fbe6ccaba6e8473201c AS docker

FROM debian:bookworm-20261104-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git git-lfs jq openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 coop \
 && useradd --uid 1000 --gid coop --home-dir /var/lib/coop --create-home --shell /bin/sh coop

# Coop builds a filtered run's network images with `docker build`, which Debian's Docker CLI 20.10
# never hands to Buildx: a worker with it could not run one (2026-10-07). The CLI and Buildx are
# the pair the daemon's own image ships, so they always match the daemon they talk to.
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins/docker-buildx \
     /usr/libexec/docker/cli-plugins/docker-buildx
RUN docker --version \
 && docker buildx version

# Coop starts a review's declared service stack with `docker compose`. The plugin is a pinned
# release, its checksum checked for this image's architecture.
ARG COMPOSE_VERSION=v5.8.0
RUN case "$(dpkg --print-architecture)" in \
      arm64) arch=aarch64 sum=1a9c918b2fb49b9c87f0018c64b5abd0d30715155e98dc939779fbaee6c414d3 ;; \
      amd64) arch=x86_64 sum=b8840f5008c447f41fce0a57ae3adeab42c89b1eb6e6012524bcabbfb4ffbaf6 ;; \
      *) echo "no pinned Docker Compose for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
 && mkdir -p /usr/libexec/docker/cli-plugins \
 && curl -fsSL -o /usr/libexec/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$arch" \
 && echo "$sum  /usr/libexec/docker/cli-plugins/docker-compose" | sha256sum -c - \
 && chmod 0755 /usr/libexec/docker/cli-plugins/docker-compose \
 && docker compose version

COPY --from=build /out/coop /usr/local/bin/coop
RUN coop version \
 && coop help sessions connect >/dev/null \
 && coop help credentials transfer >/dev/null

# Root's, so a compromised worker cannot rewrite the entrypoint it restarts into.
COPY deploy/compose/coop/entrypoint.sh /usr/local/bin/ryker-coop-entrypoint
COPY deploy/compose/coop/Box.Dockerfile /usr/local/share/ryker/Box.Dockerfile
# Readable by the coop user whatever umask the build context was made under.
RUN chmod 0755 /usr/local/bin/ryker-coop-entrypoint \
 && chmod 0644 /usr/local/share/ryker/Box.Dockerfile

USER coop
ENV HOME=/var/lib/coop \
    COOP_CONFIG_DIR=/var/lib/coop/agents \
    COOP_NO_UPDATE_CHECK=1 \
    COOP_RUNTIME=docker \
    TMPDIR=/var/lib/coop/tmp

WORKDIR /tmp
ENTRYPOINT ["/usr/local/bin/ryker-coop-entrypoint"]
