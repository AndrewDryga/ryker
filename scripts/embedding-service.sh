#!/usr/bin/env bash
# Runs bge-m3 on this Mac's GPU for Ryker's search by meaning: a llama.cpp
# server on 127.0.0.1 that turns a message, or Ryker's summary of a request,
# into a vector, kept running by launchd. bge-m3 reads more than a hundred
# languages into one space, so a Ukrainian or Spanish message finds work that
# was discussed in English.
#
# Ryker's container reaches it at host.docker.internal (Docker Desktop and
# OrbStack name the host). After `install`, set in .ryker/compose.env
#
#   RYKER_EMBEDDINGS_URL=http://host.docker.internal:8180
#
# and run scripts/compose.sh start. Without it, or while this server is down,
# Ryker searches for earlier work by words and identifiers only.
#
# usage: scripts/embedding-service.sh install|status|uninstall
set -euo pipefail

model_dir=${RYKER_EMBEDDINGS_MODEL_DIR:-$HOME/.local/share/ryker/embeddings}
model=$model_dir/bge-m3-q8_0.gguf
# The revision and digest are pinned: a moved branch or a replaced file is refused.
model_url=https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF/resolve/9eba04c5d75ba5a1595e45de734d36bef4e5cb98/bge-m3-q8_0.gguf
model_sha256=aa473d51f451a22f0fcf39ba3330c14bed38a385712b1113440f69df4047a173
log_dir=$HOME/.local/state/ryker/embeddings
agents=$HOME/Library/LaunchAgents
label=ai.emisar.ryker.embeddings
port=${RYKER_EMBEDDINGS_PORT:-8180}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/model-download.sh
. "$here/model-download.sh"

usage() {
  echo "usage: scripts/embedding-service.sh install|status|uninstall" >&2
  exit 2
}

# The LaunchAgent: llama-server on 127.0.0.1 with the model, restarted if it
# stops, logging beside Ryker's other state. bge-m3 reads up to 8192 tokens
# and pools its first token (CLS), as the model was trained.
write_plist() {
  local server
  server=$(command -v llama-server)
  {
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>' \
      "<key>Label</key><string>$label</string>" \
      '<key>ProgramArguments</key><array>' \
      "<string>$server</string><string>-m</string><string>$model</string>" \
      "<string>--embeddings</string><string>--pooling</string><string>cls</string>" \
      "<string>-c</string><string>8192</string><string>-b</string><string>8192</string>" \
      "<string>-ub</string><string>8192</string><string>-ngl</string><string>99</string>" \
      "<string>--host</string><string>127.0.0.1</string>" \
      "<string>--port</string><string>$port</string>" \
      '</array>' \
      '<key>RunAtLoad</key><true/>' \
      '<key>KeepAlive</key><true/>' \
      "<key>StandardOutPath</key><string>$log_dir/$label.log</string>" \
      "<key>StandardErrorPath</key><string>$log_dir/$label.log</string>" \
      '</dict></plist>'
  } >"$agents/$label.plist"
}

answering() {
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/health"
}

status() {
  if answering; then
    echo "$label (search by meaning): answering on 127.0.0.1:$port"
  else
    echo "$label (search by meaning): not answering on 127.0.0.1:$port"
    return 1
  fi
}

install() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "The embedding service runs bge-m3 on a Mac's GPU; elsewhere Ryker searches by words." >&2
    exit 1
  fi
  command -v brew >/dev/null || {
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  }
  command -v llama-server >/dev/null || brew install llama.cpp
  mkdir -p "$model_dir" "$log_dir" "$agents"
  download_model "$model_url" "$model_sha256" "$model" "bge-m3 (635 MB)"

  write_plist
  "$here/launch-agent.sh" load "$label" "$agents/$label.plist"

  # Loading the model takes a few seconds on first start.
  for _ in $(seq 1 60); do
    answering && break
    sleep 1
  done
  status
  echo
  echo "Set in .ryker/compose.env, then run scripts/compose.sh start:"
  echo "  RYKER_EMBEDDINGS_URL=http://host.docker.internal:$port"
}

uninstall() {
  "$here/launch-agent.sh" unload "$label"
  rm -f "$agents/$label.plist"
  echo "Stopped. The model stays in $model_dir; delete it to free 635 MB."
}

case ${1:-} in
  install) install ;;
  status) status ;;
  uninstall) uninstall ;;
  *) usage ;;
esac
