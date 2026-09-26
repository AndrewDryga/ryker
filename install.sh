#!/bin/sh
# Install Ryker with Docker Compose. The lifecycle helper owns the project
# and every one of its commands, so this is `scripts/compose.sh install`
# under the name the documentation promises.
set -eu

[ "$#" -eq 0 ] || {
  echo "usage: ./install.sh" >&2
  exit 2
}

exec "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/scripts/compose.sh" install
