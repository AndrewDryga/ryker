# shellcheck shell=bash
# shellcheck disable=SC2154 # root belongs to the script that sources this
# Where Ryker's test databases live, for scripts/elixir-test.sh and
# scripts/elixir-world-eval.sh alike. The world eval created its campaign
# databases on whatever answered at 127.0.0.1:5432, on this Mac another
# project's server (2026-10-04 review).

# use_test_database_server points PGHOST and PGPORT at compose.test.yml's
# server through Docker, or keeps the PGHOST a Coop box's sidecar names (a box
# has no Docker; .agent/project.yaml), and returns 1 when there is neither.
use_test_database_server() {
  if command -v docker >/dev/null 2>&1; then
    local compose=(docker compose --project-name ryker-kernel --file "$root/compose.test.yml")
    local address

    # `up` is a no-op when the healthy container already matches compose.test.yml
    # and recreates it when the file changed, so a capacity change lands on the
    # next run instead of after someone remembers to down it.
    "${compose[@]}" up --detach --wait episode-db >/dev/null
    address=$("${compose[@]}" port episode-db 5432)
    export PGHOST=127.0.0.1
    export PGPORT=${address##*:}
  elif [[ -z ${PGHOST:-} ]]; then
    return 1
  fi

  export PGPASSWORD=postgres
  export PGUSER=postgres
}
