ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
COPY *.mjs native-socket /opt/fleet-proof/
RUN chmod 755 /opt/fleet-proof/native-socket /opt/fleet-proof/claude-agent-acp.mjs && rm -f /opt/coop/bin/claude-agent-acp && ln -s /opt/fleet-proof/claude-agent-acp.mjs /opt/coop/bin/claude-agent-acp && chmod 755 /opt/fleet-proof/codex-agent-acp.mjs && rm -f /opt/coop/bin/codex-acp && ln -s /opt/fleet-proof/codex-agent-acp.mjs /opt/coop/bin/codex-acp
USER node
