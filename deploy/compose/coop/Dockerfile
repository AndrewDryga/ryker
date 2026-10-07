# Base images are pinned by digest as well as tag (2026-10-04 review).
FROM golang:1.27.1-bookworm@sha256:8d48e12ec56735e9358640898b9d9b9fcca110612ed8a5567438c0a1baa24e66 AS build

ARG COOP_VERSION=v10.1.2-24-gd019c807
ARG COOP_REVISION=d019c807ea6373b25ec7d145441bd9163f637564

RUN git clone https://github.com/AndrewDryga/coop.git /build/coop \
 && cd /build/coop \
 && git checkout --detach "$COOP_REVISION" \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/AndrewDryga/coop/internal/cli.Version=$COOP_VERSION" \
      -o /out/coop .

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl docker.io git git-lfs jq openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 coop \
 && useradd --uid 1000 --gid coop --home-dir /var/lib/coop --create-home --shell /bin/sh coop

# Coop starts a review's declared service stack with `docker compose`, which Debian's docker.io
# lacks. The plugin is a pinned release, its checksum checked for this image's architecture.
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

ENTRYPOINT ["/usr/local/bin/ryker-coop-entrypoint"]
