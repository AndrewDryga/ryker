#!/usr/bin/env bash
# Runs a small routing model (Qwen2.5 3B Instruct) on this Mac's GPU for
# Ryker's local routing comparison: a llama.cpp server on 127.0.0.1 that
# answers the OpenAI chat completions API with structured output, kept
# running by launchd. It only measures: routing always decides with the
# provider model, and the comparison asks this model the same question in
# the background (Settings › Models › Local routing model).
#
# Ryker's container reaches it at host.docker.internal. After `install`, in
# Settings › Models › Local routing model choose Compare in the background,
# endpoint http://host.docker.internal:8181/v1 and model qwen2.5:3b.
#
# usage: scripts/routing-model-service.sh install|status|uninstall
set -euo pipefail

model_dir=${RYKER_ROUTING_MODEL_DIR:-$HOME/.local/share/ryker/routing-model}
model=$model_dir/qwen2.5-3b-instruct-q4_k_m.gguf
# The revision and digest are pinned: a moved branch or a replaced file is refused.
model_url=https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/7dabda4d13d513e3e842b20f0d435c732f172cbe/qwen2.5-3b-instruct-q4_k_m.gguf
model_sha256=626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d
log_dir=$HOME/.local/state/ryker/routing-model
agents=$HOME/Library/LaunchAgents
label=ai.emisar.ryker.routing-model
port=${RYKER_ROUTING_MODEL_PORT:-8181}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/model-download.sh
. "$here/model-download.sh"

usage() {
  echo "usage: scripts/routing-model-service.sh install|status|uninstall" >&2
  exit 2
}

# The LaunchAgent: llama-server on 127.0.0.1 with the model, one request at a
# time with room for a whole routing prompt (they run to a few thousand tokens),
# restarted if it stops, logging beside Ryker's other state.
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
      "<string>--alias</string><string>qwen2.5:3b</string>" \
      "<string>-c</string><string>16384</string><string>-np</string><string>1</string>" \
      "<string>-ngl</string><string>99</string><string>--jinja</string>" \
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
    echo "$label (local routing model): answering on 127.0.0.1:$port"
  else
    echo "$label (local routing model): not answering on 127.0.0.1:$port"
    return 1
  fi
}

install() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "This runs the local routing model on a Mac's GPU; elsewhere point Settings at your own server." >&2
    exit 1
  fi
  command -v brew >/dev/null || {
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  }
  command -v llama-server >/dev/null || brew install llama.cpp
  mkdir -p "$model_dir" "$log_dir" "$agents"
  download_model "$model_url" "$model_sha256" "$model" "Qwen2.5 3B Instruct (2.1 GB)"

  write_plist
  "$here/launch-agent.sh" load "$label" "$agents/$label.plist"

  for _ in $(seq 1 90); do
    answering && break
    sleep 1
  done
  status
  echo
  echo "In Settings › Models › Local routing model choose Compare in the background,"
  echo "endpoint http://host.docker.internal:$port/v1 and model qwen2.5:3b."
}

uninstall() {
  "$here/launch-agent.sh" unload "$label"
  rm -f "$agents/$label.plist"
  echo "Stopped. The model stays in $model_dir; delete it to free 2.1 GB."
}

case ${1:-} in
  install) install ;;
  status) status ;;
  uninstall) uninstall ;;
  *) usage ;;
esac
