#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load shared helpers
source "$ROOT/scripts/lib.sh"

step_start "Ollama"

# Skip if already installed and running
if command -v ollama >/dev/null 2>&1 && systemctl is-active --quiet ollama; then
  step_skip "already installed and running"
else
  TMP_OLLAMA_INSTALL=$(mktemp)
  curl -fsSL "https://ollama.com/install.sh" -o "$TMP_OLLAMA_INSTALL" || { step_error "Failed to download Ollama installer"; exit 1; }

  # Log checksum for transparency (Ollama doesn't publish installer checksums publicly)
  OLLAMA_ACTUAL_CHECKSUM=$(sha256sum "$TMP_OLLAMA_INSTALL" | awk '{print $1}')
  step_info "Ollama installer sha256: $OLLAMA_ACTUAL_CHECKSUM"

  bash "$TMP_OLLAMA_INSTALL" >/dev/null 2>&1 || true
  rm -f "$TMP_OLLAMA_INSTALL"
fi

# Note: systemd service is managed by install.sh (ollama.service unit with resource limits)
# This script only installs the binary and pulls the model.

# Wait for Ollama to be ready
for _i in $(seq 1 30); do
  if curl -sf http://localhost:11434/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Pull the embedding model — read .env without sourcing it
MODEL=$(read_env_var "$ROOT/config/.env" "OLLAMA_MODEL" "")
if [ -z "$MODEL" ]; then
  MODEL=$(read_env_var "$ROOT/config/default.env" "OLLAMA_MODEL" "nomic-embed-text")
fi

ollama pull "$MODEL" >/dev/null 2>&1 || step_warn "Failed to pull model $MODEL, run 'ollama pull $MODEL' manually"

# Write env vars for swarm-tools runtime
sudo tee /etc/profile.d/swarm-ollama.sh >/dev/null <<EOF
export OLLAMA_HOST=http://localhost:11434
export OLLAMA_MODEL=$MODEL
EOF
sudo chmod 0644 /etc/profile.d/swarm-ollama.sh

step_ok "Ollama with $MODEL"
