#!/usr/bin/env bash
# Deploy HEAD to the Docker Compose installation in this checkout.
#
# The only deployment is the Compose project in compose.yml, pinned by
# RYKER_VERSION and RYKER_IMAGE in .ryker/compose.env. This is the one way a
# commit gets there:
#
#   1. refuse a dirty tree and, unless --allow-not-main says otherwise, a
#      HEAD that is not main's, so what runs is always an exact named commit;
#   2. build the image from a clean git worktree of HEAD, so nothing in the
#      working directory that git does not know about can reach the image;
#      a build that fails stops here, before the backup, with nothing changed;
#   3. pause Ryker and back up the database and encrypted state into .ryker/backups/:
#      the container runs its migrations when it boots, and a migration that
#      fails on real rows is undone from that archive, not by hand;
#   4. replace only the ryker container (`up --detach --no-build --wait
#      --no-deps ryker`); PostgreSQL, the bundled worker and its Docker
#      daemon keep running and are never rebuilt here;
#   5. wait, from the host's side, for /healthz, /readyz and the exact
#      x-ryker-version header, and only then pin the new version in
#      compose.env — a failed deploy prints the container's log tail, stops
#      the unverified replacement and leaves the previous version pinned;
#   6. remove the worktree whatever happened, and say what is running.
#
# PostgreSQL custody resumes pending admission, Work, delivery, schedule and
# remote-worker state after the normal one-writer restart; there is no
# canary/promote state.
set -euo pipefail
umask 077

usage() {
  cat >&2 <<'USAGE'
usage: scripts/deploy.sh [--allow-not-main]

  --allow-not-main   deploy a HEAD that is not main's HEAD (a branch or a
                     detached commit); refused unless asked for on purpose
USAGE
  exit 2
}

allow_not_main=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --allow-not-main)
      allow_not_main=1
      shift
      ;;
    *) usage ;;
  esac
done

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"
ready_timeout=${RYKER_DEPLOY_READY_TIMEOUT:-180}
poll_seconds=${RYKER_DEPLOY_POLL_SECONDS:-2}
keep_images=${RYKER_KEEP_IMAGES:-2}
keep_backups=${RYKER_KEEP_BACKUPS:-10}
started=$SECONDS

say() { echo "deploy: $*"; }
fail() {
  echo "deploy: $*" >&2
  exit 1
}

cd "$repository"

# --- what would run --------------------------------------------------------
if [[ -n $(git status --porcelain) ]]; then
  fail "refusing to deploy a dirty tree — commit first"
fi

head=$(git rev-parse HEAD)
main=$(git rev-parse --verify --quiet refs/heads/main || true)
if [[ $head != "$main" && $allow_not_main -ne 1 ]]; then
  fail "HEAD ${head:0:12} is not main's HEAD ${main:0:12}; deploy from main, or pass --allow-not-main on purpose"
fi

version=$(scripts/elixir-release-version.sh)
image="ryker:$version"

# --- where it would run ----------------------------------------------------
for tool in git docker curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 (the 'docker compose' command) is required"
[[ -r $env_file ]] || fail "Ryker is not installed here: $env_file is missing. Run ./install.sh first, or restore a backup."

env_value() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
previous_version=$(env_value RYKER_VERSION)
previous_image=$(env_value RYKER_IMAGE)
control_port=$(env_value RYKER_CONTROL_PORT)
control_port=${control_port:-4321}
control_bind=$(env_value RYKER_CONTROL_BIND)
# Ryker does not start with the console published beyond loopback.
control_bind=${control_bind:-127.0.0.1}
origin="http://$control_bind:$control_port"

# --- cleanup, whatever happens ---------------------------------------------
worktree=
scratch=
restart_controller=0
cleanup() {
  local status=$?
  if [[ $restart_controller -eq 1 ]]; then
    "${compose[@]}" start ryker >/dev/null || status=1
  fi
  if [[ -n $worktree && -d $worktree ]]; then
    git -C "$repository" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf -- "$worktree"
    git -C "$repository" worktree prune >/dev/null 2>&1 || true
  fi
  [[ -n $scratch ]] && rm -rf -- "$scratch"
  release_lifecycle_lock
  exit "$status"
}
trap cleanup EXIT
take_lifecycle_lock deploy

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-deploy-scratch.XXXXXX")
worktree=$(mktemp -d "${TMPDIR:-/tmp}/ryker-deploy.XXXXXX")
git worktree add --detach "$worktree" HEAD >/dev/null 2>&1 ||
  fail "could not create a worktree of HEAD at $worktree"
compose=(docker compose --env-file "$env_file" --file "$worktree/compose.yml")

say "deploying ryker $version (commit ${head:0:12}) from a clean worktree at $worktree"
say "currently pinned: ${previous_version:-nothing} (${previous_image:-no image})"

# --- the image is built before anything changes -----------------------------
# A build that fails leaves the running release, the database and compose.env
# exactly as they were, and takes no backup.
say "building $image"
if ! env RYKER_VERSION="$version" RYKER_IMAGE="$image" "${compose[@]}" build ryker; then
  echo "deploy: FAILED — $image did not build; nothing was replaced and ${previous_version:-nothing} is still running" >&2
  exit 1
fi

# --- the database is backed up before anything changes ---------------------
"${compose[@]}" exec -T database pg_isready -U ryker -d ryker >/dev/null 2>&1 ||
  fail "the database container is not running; start the project first (scripts/compose.sh start)"

backup_dir=$state_dir/backups
mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"
running_services=$("${compose[@]}" ps --status running --services)
if grep -qx ryker <<<"$running_services"; then
  say "pausing Ryker to capture the database and encrypted files consistently"
  restart_controller=1
  "${compose[@]}" stop ryker
fi
"${compose[@]}" exec -T database pg_dump -U ryker -d ryker --format=custom --no-owner --no-privileges \
  >"$scratch/database.dump"
[[ -s $scratch/database.dump ]] || fail "the database backup is empty"
"${compose[@]}" exec -T database pg_restore --list <"$scratch/database.dump" >/dev/null ||
  fail "the database backup does not read back as a PostgreSQL archive"
"${compose[@]}" run --rm --no-deps -T --entrypoint tar volume-init \
  -czf - -C /var/lib/ryker . >"$scratch/ryker-state.tar.gz"
tar -tzf "$scratch/ryker-state.tar.gz" >/dev/null || fail "the encrypted state backup does not read back"
cp "$env_file" "$scratch/compose.env"
chmod 0600 "$scratch/database.dump" "$scratch/ryker-state.tar.gz" "$scratch/compose.env"
backup="$backup_dir/pre-deploy-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$backup" -C "$scratch" database.dump ryker-state.tar.gz compose.env
chmod 0600 "$backup"
say "database and encrypted state backed up to $backup (scripts/compose.sh restore takes it)"

# --- replace the container ---------------------------------------------------
# The newest migration the database has run, read before and after the new
# release boots, so a failure says which way back is safe instead of leaving
# "did it migrate?" to whoever reads it (2026-10-04 review). The previous
# release refuses a database a newer one migrated.
schema_version() {
  "${compose[@]}" exec -T database psql -X -U ryker -d ryker -Atc \
    'SELECT max(version) FROM schema_migrations' 2>/dev/null || true
}
schema_before=$(schema_version)

report_failure() {
  echo "deploy: FAILED — $1" >&2
  echo "--- docker compose logs --tail 60 ryker ---" >&2
  "${compose[@]}" logs --no-color --tail 60 ryker >&2 2>/dev/null || true
  echo "--- end of logs ---" >&2
  if "${compose[@]}" stop ryker >/dev/null; then
    echo "deploy: stopped the unverified ryker container" >&2
  else
    echo "deploy: could not confirm the unverified ryker container is stopped; inspect Docker before restarting" >&2
  fi
  echo "deploy: $env_file still pins ${previous_version:-nothing}" >&2
  local schema_after
  schema_after=$(schema_version)
  if [[ -n $schema_before && $schema_after == "$schema_before" ]]; then
    echo "deploy: the database was not migrated, so scripts/compose.sh start brings back ${previous_version:-the previous version}" >&2
  elif [[ -n $schema_before && -n $schema_after ]]; then
    echo "deploy: the new release migrated the database (from $schema_before to $schema_after); restore $backup with scripts/compose.sh restore before starting ${previous_version:-the previous version}" >&2
  else
    echo "deploy: the database's migrations could not be read; if the new release migrated it, restore $backup with scripts/compose.sh restore, otherwise scripts/compose.sh start brings back the previous version" >&2
  fi
  exit 1
}

say "replacing the ryker container with $image (migrations run when it boots)"
restart_controller=0
if ! env RYKER_VERSION="$version" RYKER_IMAGE="$image" \
  "${compose[@]}" up --detach --no-build --wait --wait-timeout "$ready_timeout" --no-deps ryker; then
  report_failure "the ryker container did not become healthy as $version"
fi

# --- the host's view: healthy, ready, and exactly this version --------------
healthz_code=000
readyz_code=000
readyz_body=
running_version=
probe() {
  healthz_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 3 \
    "$origin/healthz" 2>/dev/null || echo 000)
  readyz_code=$(curl --silent --dump-header "$scratch/readyz.headers" --output "$scratch/readyz.body" \
    --write-out '%{http_code}' --max-time 3 "$origin/readyz" 2>/dev/null || echo 000)
  readyz_body=$(head -n 1 "$scratch/readyz.body" 2>/dev/null || true)
  running_version=$(awk 'tolower($1) == "x-ryker-version:" { sub(/\r$/, "", $2); print $2; exit }' \
    "$scratch/readyz.headers" 2>/dev/null || true)
  [[ $healthz_code == 200 && $readyz_code == 200 && $running_version == "$version" ]]
}

deadline=$((SECONDS + ready_timeout))
until probe; do
  if ((SECONDS >= deadline)); then
    report_failure "$origin did not answer healthy, ready and as $version within ${ready_timeout}s (last: /healthz $healthz_code, /readyz $readyz_code${readyz_body:+ \"$readyz_body\"}, version ${running_version:-none})"
  fi
  sleep "$poll_seconds"
done

# --- pin, then tidy ----------------------------------------------------------
pin_release "$version" "$image"
say "pinned RYKER_VERSION=$version and RYKER_IMAGE=$image in $env_file"

# Every deploy leaves a 240 MB image behind, and a host that filled up once
# refused Coop workspaces and corrupted the Go cache. Keep the pinned image,
# the previous one for a rollback and a few more recent commit builds; tagged
# releases and hand-made tags are never touched.
pruned=()
while IFS= read -r tag; do
  [[ $tag =~ ^ryker:0\.1\.0-g[0-9a-f]{40}$ ]] || continue
  [[ $tag == "$image" || $tag == "$previous_image" ]] && continue
  if ((keep_images > 0)); then
    keep_images=$((keep_images - 1))
    continue
  fi
  if docker image rm "$tag" >/dev/null 2>&1; then
    pruned+=("$tag")
  fi
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' ryker 2>/dev/null || true)
if ((${#pruned[@]} > 0)); then
  say "pruned ${#pruned[@]} older image(s): ${pruned[*]}"
fi

# Every deploy writes a backup of about 20 MB and none was ever removed: 140
# of them held 2.4 GB on 2026-09-28. Keep the newest ten, the one this deploy
# wrote among them; other archives in the directory are never touched.
removed_backups=0
while IFS= read -r old_backup; do
  rm -f -- "$old_backup" && removed_backups=$((removed_backups + 1))
done < <(find "$backup_dir" -maxdepth 1 -name 'pre-deploy-*.tar.gz' | sort -r | tail -n +$((keep_backups + 1)))
if ((removed_backups > 0)); then
  say "removed $removed_backups older pre-deploy backup(s); the newest $keep_backups stay in $backup_dir"
fi

elapsed=$((SECONDS - started))
say "ryker $version is running at $origin (image $image): healthy, ready, version header verified"
"${compose[@]}" ps ryker 2>/dev/null || true
say "done in $((elapsed / 60))m $((elapsed % 60))s"
say "PostgreSQL custody resumes pending work after the normal restart"
