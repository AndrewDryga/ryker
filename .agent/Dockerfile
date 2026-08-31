# Keep Coop's security posture, agent adapters, and output-contract tooling in one
# trusted base. This project layer adds only the exact language versions it pins.
ARG COOP_BASE_IMAGE=coop-box
FROM ${COOP_BASE_IMAGE}

# Install whatever .tool-versions pins: an asdf plugin per listed tool, then `asdf install`.
# Docker-cached until .tool-versions changes. A plugin that fails to install must fail the
# BUILD — swallowing it here just moves the error to the first agent that runs the tool.
COPY --chown=node:node .tool-versions /home/node/.tool-versions
RUN cd /home/node \
 && awk 'NF && $1 !~ /^#/ {print $1}' .tool-versions | while read -r tool; do asdf plugin add "$tool" || exit 1; done \
 && MAKEFLAGS="-j$(nproc)" asdf install \
 && asdf reshim

WORKDIR /workspace
