ARG COOP_BASE_IMAGE=coop-box
FROM ${COOP_BASE_IMAGE}

USER root
COPY ryker-ca.pem /usr/local/share/ca-certificates/ryker-ca.crt
RUN chmod 0644 /usr/local/share/ca-certificates/ryker-ca.crt \
 && update-ca-certificates

# Jobs and Coop's trusted review gate run in this box, not in a repository's
# own image, so it carries what repositories' gates commonly need. On
# 2026-09-28 emisar's review gate failed eight browser tests with "no
# Chrome/Chromium found".
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium-headless-shell imagemagick \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

USER node
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ryker-ca.crt
