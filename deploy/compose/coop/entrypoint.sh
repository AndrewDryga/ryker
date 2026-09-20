#!/bin/sh
set -eu

state=/var/lib/coop
shared=/var/lib/ryker-coop
workspaces=/var/lib/ryker-workspaces
policies=$workspaces/session-policies.yaml
repositories=$workspaces/repositories.json
worker=$state/worker.json
identity=$state/identity.pem
token=$shared/enrollment-token
ca=$shared/worker-ca.pem

mkdir -p "$state/sessions" "$state/journal" "$state/agents"
chmod 0700 "$state" "$state/sessions" "$state/journal" "$state/agents"

until [ -r "$ca" ] && [ -r "$policies" ] && [ -r "$repositories" ] &&
      { [ -r "$identity" ] || [ -r "$token" ]; }; do
  sleep 1
done

if ! docker image inspect coop-box >/dev/null 2>&1 &&
   ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^coop-box:'; then
  coop build
fi

while :; do
  if ! policy_json=$(coop sessions policies --policies "$policies" --json 2>/dev/null); then
    echo "Ryker's worker is waiting for model access. Open Settings to connect a model account." >&2
    sleep 10
    continue
  fi

  sandbox_digest=$(coop version | sha256sum | awk '{print $1}')
  policy_sha=$(sha256sum "$policies" "$repositories" | sha256sum | awk '{print $1}')

  jq -n \
    --arg ca "$ca" \
    --arg identity "$identity" \
    --arg journal "$state/journal" \
    --arg policies "$policies" \
    --arg responder "https://ryker:4322" \
    --arg sandbox "$sandbox_digest" \
    --arg socket "$state/sessions/control.sock" \
    --arg state "$state/sessions" \
    --arg token "$token" \
    --arg worker_id "${RYKER_BUNDLED_COOP_WORKER_ID:-ryker-compose}" \
    --arg workspace_ref "${RYKER_BUNDLED_COOP_WORKSPACE:-ryker-compose}" \
    --argjson authority "$(printf '%s' "$policy_json" | jq '.policy_authority_digests')" \
    --argjson digests "$(printf '%s' "$policy_json" | jq '.policy_digests')" \
    --argjson repositories "$(cat "$repositories")" \
    '{
      version: 1,
      worker_id: $worker_id,
      workspace_ref: $workspace_ref,
      responder_url: $responder,
      ca_file: $ca,
      identity_file: $identity,
      enrollment_token_file: $token,
      coop_socket: $socket,
      session_state_dir: $state,
      session_policy_path: $policies,
      journal_dir: $journal,
      sandbox_digest: $sandbox,
      policy_digests: $digests,
      policy_authority_digests: $authority,
      repositories: $repositories,
      capabilities: [],
      capacity: {
        session_slots_free: 4,
        session_slots_total: 4,
        turn_slots_free: 4,
        turn_slots_total: 4,
        workspace_slots_free: 3,
        workspace_slots_total: 3,
        state: "eligible",
        cooldown_until: null
      },
      poll_interval_ms: 1000,
      request_timeout_ms: 30000,
      renew_before_seconds: 3600
    }' >"$worker.tmp"
  chmod 0600 "$worker.tmp"
  mv "$worker.tmp" "$worker"

  coop sessions connect --config "$worker" &
  connector=$!

  while kill -0 "$connector" 2>/dev/null; do
    if [ -r "$identity" ]; then
      : >"$shared/enrolled"
      chmod 0600 "$shared/enrolled"
    fi

    current=$(sha256sum "$policies" "$repositories" | sha256sum | awk '{print $1}')
    if [ "$current" != "$policy_sha" ]; then
      kill "$connector" 2>/dev/null || true
      break
    fi
    sleep 2
  done

  wait "$connector" || true
  sleep 1
done
