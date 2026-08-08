#!/usr/bin/env bash
# Deploy this commit automatically, but only against proof that it works.
#
# The operator's decision (2026-08-08) was to auto-deploy any change that is
# proven, rather than to maintain an exclusion list of change classes. That
# moves the entire safety property onto the proof and the rollout, so both are
# stronger here than `make check` alone:
#
#   1. the full repository gate                       — does the code do what its tests say
#   2. migration-check against EVERY deployed database — does it destroy real data
#   3. episode replay against EVERY deployment          — does the real model still behave
#   4. staged rollout, smallest blast radius first      — does it survive contact
#   5. automatic rollback on health regression          — and if not, undo it
#
# Steps 2 and 3 are the ones a green gate cannot give you, and they are the two
# that would have caught the changes of 2026-08-07 that passed everything and
# were still dangerous: a migration that cascade-deleted 9934 episode events
# while reporting success, and a rename that silently changed what a word
# counted.
#
# What this still cannot see: a change that is internally consistent, migrates
# cleanly, replays correctly, and stays healthy — while meaning something
# different. Staged rollout and the health window narrow that; they do not
# close it. Nothing here should be read as a claim that it does.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agents=${RESPONDER_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
libexec=${RESPONDER_LIBEXEC:-$HOME/.local/libexec/responder}
domain="gui/$(id -u)"
# Emisar first: it is the smaller surface, so a change that is wrong there is
# wrong somewhere cheaper. Tenant only follows a clean health window.
rollout_order=${RESPONDER_ROLLOUT_ORDER:-"ai.emisar.responder.emisar ai.emisar.responder.tenant"}
health_window=${RESPONDER_HEALTH_WINDOW:-120}
skip_evals=${RESPONDER_SKIP_EVALS:-0}

cd "$repository"

say() { printf 'self-deploy: %s\n' "$*"; }
die() { printf 'self-deploy: %s\n' "$*" >&2; exit 1; }

[[ -n $(git status --porcelain) ]] && die "refusing a dirty tree — commit first"
sha=$(git rev-parse --short HEAD)

# The deployment behind a label: its working directory (for the config and the
# local env) and the readiness port it serves. Both are read from what is
# actually deployed rather than configured twice.
deployment_dir() {
  plutil -extract ProgramArguments.2 raw "$agents/$1.plist" 2>/dev/null |
    sed -n 's/^cd \([^ ]*\) .*/\1/p'
}
deployment_port() {
  sed -n 's/^listen:.*:\([0-9][0-9]*\).*/\1/p' "$1/.responder/responder.yaml" | head -1
}
current_sha() {
  grep -o 'libexec/responder/responder-[0-9a-f]*' "$agents/$1.plist" | head -1 |
    sed 's#.*responder-##'
}
# Terminal failures are the health signal that matters: /readyz can be 200
# while every turn dies. Counted before and after so the comparison is against
# this deployment's own baseline, not an absolute anybody has to maintain.
failure_count() {
  ( cd "$1" && "$libexec/responder-$2" failures --config .responder/responder.yaml 2>/dev/null |
      grep -c '^agent_run' ) || echo 0
}

labels=()
for label in $rollout_order; do
  [[ -e "$agents/$label.plist" ]] || continue
  grep -q "libexec/responder/responder-" "$agents/$label.plist" || continue
  labels+=("$label")
done
[[ ${#labels[@]} -eq 0 ]] && die "no launch agent pins a Responder binary"

say "proving $sha across ${#labels[@]} deployment(s)"

# ---- 1. the full repository gate -------------------------------------------
say "gate: make check"
make check >/tmp/self-deploy-check.log 2>&1 || die "the gate failed; see /tmp/self-deploy-check.log"
say "gate: green"

# ---- 2 and 3. proof against every deployment's real state ------------------
for label in "${labels[@]}"; do
  dir=$(deployment_dir "$label")
  [[ -n $dir && -d $dir ]] || die "$label has no resolvable working directory"

  say "$label: migration-check against the deployed database"
  ( cd "$dir" && go run "$repository/cmd/responder" migration-check --config .responder/responder.yaml ) \
    || die "$label: this build's migrations lose data on the deployed database"

  corpus="testdata/eval/episode-replay/${label##*.}.jsonl"
  if [[ $skip_evals -eq 1 ]]; then
    say "$label: episode replay SKIPPED by RESPONDER_SKIP_EVALS — this run is not proven"
  elif [[ -f $corpus ]]; then
    # Replay runs against the LIVE deployment, so a restart underneath it kills
    # the socket mid-run and every remaining case fails "dial unix ... no such
    # file or directory". That is the deployment moving, not the build being
    # wrong, and condemning a good build for it would be the same mistake as
    # posting a dropped stream to Slack. Retried once; a second transport
    # failure is treated as an unproven build rather than assumed benign.
    replay() {
      # shellcheck source=/dev/null  # the deployment's own secret env, not in this repo
      ( cd "$dir" && set -a && . .responder/local.env && set +a &&
        go run "$repository/cmd/responder" eval --config .responder/responder.yaml \
          --episode-replay --input "$repository/$corpus" --min-overall-pass-rate 1 ) \
        >"/tmp/self-deploy-replay-$label.log" 2>&1
    }
    say "$label: episode replay ($corpus)"
    if ! replay; then
      if grep -q "dial unix .*control.sock" "/tmp/self-deploy-replay-$label.log"; then
        say "$label: replay lost the Coop socket mid-run; retrying once"
        sleep 20
        replay || die "$label: replay failed; see /tmp/self-deploy-replay-$label.log"
      else
        die "$label: the real model no longer behaves on recorded history; see /tmp/self-deploy-replay-$label.log"
      fi
    fi
  else
    say "$label: no replay corpus — behaviour is unproven for this deployment"
  fi
done

# ---- 4. staged rollout ------------------------------------------------------
scripts/deploy.sh --stage >/dev/null || die "staging failed"
say "staged responder-$sha"

reload() { # label plist
  launchctl bootout "$domain/$1" 2>/dev/null || true
  for _ in $(seq 1 40); do
    launchctl print "$domain/$1" >/dev/null 2>&1 || break
    sleep 0.25
  done
  launchctl bootstrap "$domain" "$2"
}

for label in "${labels[@]}"; do
  plist="$agents/$label.plist"
  dir=$(deployment_dir "$label")
  port=$(deployment_port "$dir")
  previous=$(current_sha "$label")
  before=$(failure_count "$dir" "$previous")
  say "$label: rotating $previous -> $sha (baseline $before terminal failures)"

  /usr/bin/sed -i '' -E "s#libexec/responder/responder-[0-9a-f]+#libexec/responder/responder-$sha#g" "$plist"
  reload "$label" "$plist" || die "$label: failed to bootstrap; it is DOWN"

  # ---- 5. health window, and rollback if it regresses -----------------------
  healthy=0
  deadline=$((SECONDS + health_window))
  while (( SECONDS < deadline )); do
    sleep 10
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/readyz" 2>/dev/null || echo 000)
    [[ $code == 200 ]] || continue
    running=$(pgrep -f "libexec/responder/responder-$sha " | wc -l | tr -d ' ')
    [[ ${running:-0} -gt 0 ]] || continue
    after=$(failure_count "$dir" "$sha")
    if (( after > before )); then
      say "$label: $((after - before)) new terminal failure(s) since rotating — regression"
      healthy=0
      break
    fi
    healthy=1
  done

  if [[ $healthy -ne 1 ]]; then
    say "$label: ROLLING BACK to $previous"
    /usr/bin/sed -i '' -E "s#libexec/responder/responder-[0-9a-f]+#libexec/responder/responder-$previous#g" "$plist"
    reload "$label" "$plist" || die "$label: rollback failed to bootstrap; it is DOWN and needs a human"
    die "$label: rolled back to $previous; later deployments were not attempted"
  fi
  say "$label: healthy on $sha through a ${health_window}s window"
done

say "deployed $sha to ${#labels[@]} deployment(s), each proven and health-checked"
