# shellcheck shell=sh
# shellcheck disable=SC2154 # state_dir and env_file belong to the script that sources this
# What scripts/deploy.sh and scripts/compose.sh share about the Compose
# project: one lifecycle command at a time, and how a release is pinned.

# Two deploys, or a backup beside a restore, each stopped and started the one
# ryker project under the other: a backup lost its quiet database and a probe
# passed the wrong release (2026-10-04 review).
#
# The lock is a directory, because mkdir is atomic and macOS has no flock. Its
# owner file names the process and the command; a lock whose process is gone
# is taken over.

take_lifecycle_lock() {
  lifecycle_lock=$state_dir/lifecycle.lock
  mkdir -p "$state_dir"

  if ! mkdir "$lifecycle_lock" 2>/dev/null; then
    holder=$(cat "$lifecycle_lock/owner" 2>/dev/null || true)
    holder_pid=${holder%% *}

    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
      echo "Another Ryker lifecycle command is running (process $holder). Wait for it to finish; if nothing is running, remove $lifecycle_lock." >&2
      exit 1
    fi

    rm -rf -- "$lifecycle_lock"
    mkdir "$lifecycle_lock" 2>/dev/null || {
      echo "Could not take the lifecycle lock at $lifecycle_lock." >&2
      exit 1
    }
  fi

  echo "$$ $1" >"$lifecycle_lock/owner"
  lifecycle_locked=1
}

release_lifecycle_lock() {
  if [ "${lifecycle_locked:-0}" = 1 ]; then
    rm -rf -- "$lifecycle_lock"
    lifecycle_locked=0
  fi
}

# Pins RYKER_VERSION and RYKER_IMAGE in the environment file and keeps every
# other line. The new file is written beside it and moved over it, so nothing
# ever reads half a file.
pin_release() {
  pinned=$(mktemp "$state_dir/.compose.env.XXXXXX")
  awk -v version="$1" -v image="$2" '
    /^RYKER_VERSION=/ { print "RYKER_VERSION=" version; seen_version = 1; next }
    /^RYKER_IMAGE=/ { print "RYKER_IMAGE=" image; seen_image = 1; next }
    { print }
    END {
      if (!seen_version) print "RYKER_VERSION=" version
      if (!seen_image) print "RYKER_IMAGE=" image
    }' "$env_file" >"$pinned"
  chmod 0600 "$pinned"
  mv -f "$pinned" "$env_file"
}
