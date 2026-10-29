# Base images are pinned by digest as well as tag (2026-10-04 review).
FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS build

ARG COOP_VERSION=v12.0.1-20-gd3a76385
ARG COOP_REVISION=d3a76385acb0a9a832b02904af8296051b3e3f80

# Only the pinned commit, and each download tried again: on 2026-10-17 the tenant host's network
# broke off a clone of Coop's whole history twice, after 397 s and 36 s, and its worker stayed on
# the Coop it ran.
RUN git init --quiet /build/coop \
 && cd /build/coop \
 && for attempt in 1 2 3 4 5; do \
      git fetch --quiet --depth 1 https://github.com/AndrewDryga/coop.git "$COOP_REVISION" && break; \
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
FROM docker:28.2.2-dind-alpine3.21@sha256:bbc590727c1e4fe707877314ff4f0f977bdda2985c485f2b044db0e18979efb3 AS docker

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

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
ARG COMPOSE_VERSION=v5.1.2
RUN case "$(dpkg --print-architecture)" in \
      arm64) arch=aarch64 sum=d5ce4020039cdbe81679b770e64f89d2cc601398d3b1aacd84a02a9176cd9d20 ;; \
      amd64) arch=x86_64 sum=c372e512a36e67716b0b3a1264ccdc461dec7a7beff601b81f7c5fb008e3511e ;; \
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
 && coop help sessions connect >/dev/null

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
