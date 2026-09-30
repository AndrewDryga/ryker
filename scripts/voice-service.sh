#!/usr/bin/env bash
# Runs whisper large-v3 on this Mac's GPU for Ryker's voice messages: two
# whisper.cpp servers on 127.0.0.1, one that only detects the language of a
# recording and one that writes its words, kept running by launchd.
#
# Ryker's container reaches them at host.docker.internal (Docker Desktop and
# OrbStack name the host). After `install`, set in .ryker/compose.env
#
#   RYKER_WHISPER_URL=http://host.docker.internal:8178
#   RYKER_WHISPER_DETECT_URL=http://host.docker.internal:8179
#   RYKER_VOICE_LANGUAGES=uk,en,es        # the languages people speak here
#
# and run scripts/compose.sh start. Without them, or while these servers are down,
# Ryker transcribes with its own small model inside the container.
#
# usage: scripts/voice-service.sh install|status|uninstall
set -euo pipefail

model_dir=${RYKER_WHISPER_MODEL_DIR:-$HOME/.local/share/ryker/whisper}
model=$model_dir/ggml-large-v3.bin
model_url=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
log_dir=$HOME/.local/state/ryker/whisper
agents=$HOME/Library/LaunchAgents
write_label=ai.emisar.ryker.whisper
detect_label=ai.emisar.ryker.whisper-detect
write_port=${RYKER_WHISPER_PORT:-8178}
detect_port=${RYKER_WHISPER_DETECT_PORT:-8179}
here=$(cd "$(dirname "$0")" && pwd)

usage() {
  echo "usage: scripts/voice-service.sh install|status|uninstall" >&2
  exit 2
}

# One LaunchAgent: whisper-server on 127.0.0.1 with the model, restarted if it
# stops, logging beside Ryker's other state.
write_plist() {
  local label=$1 port=$2 server
  shift 2
  server=$(command -v whisper-server)
  {
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>' \
      "<key>Label</key><string>$label</string>" \
      '<key>ProgramArguments</key><array>' \
      "<string>$server</string><string>-m</string><string>$model</string>" \
      "<string>--host</string><string>127.0.0.1</string>" \
      "<string>--port</string><string>$port</string>"
    for argument in "$@"; do
      printf '<string>%s</string>\n' "$argument"
    done
    printf '%s\n' \
      '</array>' \
      '<key>RunAtLoad</key><true/>' \
      '<key>KeepAlive</key><true/>' \
      "<key>StandardOutPath</key><string>$log_dir/$label.log</string>" \
      "<key>StandardErrorPath</key><string>$log_dir/$label.log</string>" \
      '</dict></plist>'
  } >"$agents/$label.plist"
}

answering() {
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$1/"
}

status() {
  local ok=0
  for entry in "$write_label:$write_port:writes the words" "$detect_label:$detect_port:detects the language"; do
    IFS=: read -r label port role <<<"$entry"
    if answering "$port"; then
      echo "$label ($role): answering on 127.0.0.1:$port"
    else
      echo "$label ($role): not answering on 127.0.0.1:$port"
      ok=1
    fi
  done
  return "$ok"
}

install() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "The voice service runs whisper on a Mac's GPU; elsewhere Ryker uses its own model." >&2
    exit 1
  fi
  command -v brew >/dev/null || {
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  }
  command -v whisper-server >/dev/null || brew install whisper-cpp
  mkdir -p "$model_dir" "$log_dir" "$agents"
  if [ ! -s "$model" ]; then
    echo "Downloading whisper large-v3 (3.1 GB) to $model_dir"
    curl -fL --retry 3 -o "$model.partial" "$model_url"
    mv "$model.partial" "$model"
  fi

  write_plist "$write_label" "$write_port"
  write_plist "$detect_label" "$detect_port" -dl
  for label in "$write_label" "$detect_label"; do
    "$here/launch-agent.sh" load "$label" "$agents/$label.plist"
  done

  # Loading the model takes a few seconds on first start.
  for _ in $(seq 1 60); do
    answering "$write_port" && answering "$detect_port" && break
    sleep 1
  done
  status
  echo
  echo "Set in .ryker/compose.env, then run scripts/compose.sh start:"
  echo "  RYKER_WHISPER_URL=http://host.docker.internal:$write_port"
  echo "  RYKER_WHISPER_DETECT_URL=http://host.docker.internal:$detect_port"
  echo "  RYKER_VOICE_LANGUAGES=<the languages people speak, e.g. uk,en,es>"
}

uninstall() {
  for label in "$write_label" "$detect_label"; do
    "$here/launch-agent.sh" unload "$label"
    rm -f "$agents/$label.plist"
  done
  echo "Stopped. The model stays in $model_dir; delete it to free 3.1 GB."
}

case ${1:-} in
  install) install ;;
  status) status ;;
  uninstall) uninstall ;;
  *) usage ;;
esac
