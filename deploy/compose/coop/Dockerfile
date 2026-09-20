FROM debian:bookworm-slim

ARG COOP_VERSION=v9.0.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl docker.io git jq openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 coop \
 && useradd --uid 10001 --gid coop --home-dir /var/lib/coop --create-home --shell /bin/sh coop \
 && COOP_VERSION="$COOP_VERSION" COOP_BIN_DIR=/usr/local/bin COOP_NO_BUILD=1 \
      sh -c 'curl -fsSL "https://raw.githubusercontent.com/AndrewDryga/coop/${COOP_VERSION}/install.sh" | sh'

COPY --chown=coop:coop deploy/compose/coop/entrypoint.sh /usr/local/bin/ryker-coop-entrypoint
RUN chmod 0755 /usr/local/bin/ryker-coop-entrypoint

USER coop
ENV HOME=/var/lib/coop \
    COOP_CONFIG_DIR=/var/lib/coop/agents \
    COOP_NO_UPDATE_CHECK=1 \
    COOP_REPO=/var/lib/ryker-workspaces/seed \
    COOP_RUNTIME=docker

ENTRYPOINT ["/usr/local/bin/ryker-coop-entrypoint"]
