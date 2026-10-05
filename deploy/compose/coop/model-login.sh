#!/bin/sh
# Signs a model account in on the bundled worker:
#
#   ryker-model-login ACCOUNT
#
# where ACCOUNT is what `coop login` takes, such as codex or claude@work.
#
# coop login deletes the account's sign-in as it starts, so a login that did
# not finish, such as Ctrl-C at the device-code prompt, left the worker
# signed out and took routing down (2026-09-27). The sign-in files are kept
# aside and put back when the login does not finish.
set -u

[ "$#" -eq 1 ] || {
  echo "usage: ryker-model-login ACCOUNT" >&2
  exit 2
}

account=$1
profiles=${COOP_CONFIG_DIR:?}/${account%%@*}/profiles
saved=$(mktemp -d) || exit 1

if [ -d "$profiles" ]; then
  (cd "$profiles" &&
    find . -type f \( -name auth.json -o -name .credentials.json \) -print |
    tar -cf "$saved/sign-in.tar" -T -) || {
    rm -rf "$saved"
    echo "Could not keep the current sign-in aside, so no login was started." >&2
    exit 1
  }
fi

coop login "$account"
status=$?

if [ "$status" -ne 0 ] && [ -s "$saved/sign-in.tar" ]; then
  (cd "$profiles" && tar -xf "$saved/sign-in.tar")
  echo "The sign-in did not finish, so the previous one was put back." >&2
fi

rm -rf "$saved"
exit "$status"
