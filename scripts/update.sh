#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"

# Load shared helpers
source "$ROOT/scripts/lib.sh"

usage() {
  echo "Usage: bash scripts/update.sh [options]"
  echo ""
  echo "Update all OpenChamber components and restart services."
  echo "Creates a rollback backup before making changes."
  echo ""
  echo "Options:"
  echo "  --config <path>  Hot-swap to a custom config file"
  echo "  -h, --help       Show this help message"
}

# Parse flags
CONFIG_PATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

UPDATE_START=$(date +%s)

banner "System Update"

# ── Backup ─────────────────────────────────────────────────────────────────────
step_start "Rollback backup"
BACKUP_DIR=$(create_backup 2>/dev/null)
step_ok "saved to $(basename "$BACKUP_DIR")"

# ── OS Package Index ───────────────────────────────────────────────────────────
step_start "OS package index"
sudo apt update >/dev/null 2>&1
step_ok "package index refreshed"

# ── Node.js ────────────────────────────────────────────────────────────────────
step_start "Node.js"
if command -v node >/dev/null 2>&1; then
  bash "$ROOT/scripts/install-node.sh" >/dev/null 2>&1 || step_warn "Node.js update failed"
  NODE_VER=$(node --version 2>/dev/null || echo "?")
  step_ok "Node $NODE_VER"
else
  step_skip "not installed"
fi

# ── Docker ─────────────────────────────────────────────────────────────────────
step_start "Docker"
if command -v docker >/dev/null 2>&1; then
  bash "$ROOT/scripts/install-docker.sh" >/dev/null 2>&1 || step_warn "Docker update failed"
  DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "?")
  step_ok "Docker $DOCKER_VER"
else
  step_skip "not installed"
fi

# ── OpenChamber ────────────────────────────────────────────────────────────────
step_start "OpenChamber"
sudo npm update -g @openchamber/web >/dev/null 2>&1 || true
OCB_VER=$(openchamber --version 2>/dev/null || echo "?")
step_ok "OpenChamber $OCB_VER"

# ── Bun ────────────────────────────────────────────────────────────────────────
step_start "Bun"
if command -v bun >/dev/null 2>&1; then
  bun upgrade --bun >/dev/null 2>&1 || true
  BUN_VER=$(bun --version 2>/dev/null || echo "?")
  step_ok "Bun $BUN_VER"
else
  step_skip "not installed"
fi

# ── CLI Backends ───────────────────────────────────────────────────────────────
step_start "CLI backends (swarm, CASS, UBS)"

sudo npm update -g opencode-swarm-plugin >/dev/null 2>&1 || true

if command -v cass >/dev/null 2>&1; then
  TMP_CASS_INSTALL=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh?$(date +%s)" \
    -o "$TMP_CASS_INSTALL"
  CASS_CHECKSUM=$(get_github_release_checksum Dicklesworthstone coding_agent_session_search cass-linux-amd64.tar.gz 2>/dev/null) || true
  if [ -n "$CASS_CHECKSUM" ]; then
    bash "$TMP_CASS_INSTALL" --easy-mode --verify --checksum "$CASS_CHECKSUM" >/dev/null 2>&1 || step_warn "CASS update failed"
  else
    bash "$TMP_CASS_INSTALL" --easy-mode --verify >/dev/null 2>&1 || step_warn "CASS update (no checksum) failed"
  fi
  rm -f "$TMP_CASS_INSTALL"
fi
cass index >/dev/null 2>&1 || true

if command -v ubs >/dev/null 2>&1; then
  UBS_CHECKSUM=$(get_github_release_checksum Dicklesworthstone ultimate_bug_scanner install.sh 2>/dev/null) || true
  if [ -n "$UBS_CHECKSUM" ]; then
    verify_and_run \
      "https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/main/install.sh?$(date +%s)" \
      "$UBS_CHECKSUM" \
      --easy-mode >/dev/null 2>&1 || step_warn "UBS update failed"
  else
    verify_and_run \
      "https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/main/install.sh?$(date +%s)" \
      "" \
      --easy-mode >/dev/null 2>&1 || step_warn "UBS update (no checksum) failed"
  fi
fi

step_ok "swarm, CASS updated"
if command -v ubs >/dev/null 2>&1; then
  step_info "UBS updated ($(ubs --version 2>/dev/null || echo 'ok'))"
else
  step_warn "UBS not installed — see https://github.com/Dicklesworthstone/ultimate_bug_scanner"
fi

# ── Reverse API Engineer ───────────────────────────────────────────────────────
if command -v reverse-api-engineer >/dev/null 2>&1; then
  uv tool upgrade reverse-api-engineer >/dev/null 2>&1 || true
  step_info "reverse-api-engineer updated"
fi

# ── OpenCode Config ────────────────────────────────────────────────────────────
step_start "OpenCode config"

if [ -f ~/.config/opencode/opencode-synced.jsonc ]; then
  SYNC_OWNER=$(grep -oP '"owner":\s*"\K[^"]+' ~/.config/opencode/opencode-synced.jsonc 2>/dev/null || echo "?")
  SYNC_REPO=$(grep -oP '"name":\s*"\K[^"]+' ~/.config/opencode/opencode-synced.jsonc 2>/dev/null || echo "?")
  step_info "sync repo: $SYNC_OWNER/$SYNC_REPO"

  SECRETS=$(grep -oP '"includeSecrets":\s*\K[^,}]+' ~/.config/opencode/opencode-synced.jsonc 2>/dev/null || echo "false")
  FAVS=$(grep -oP '"includeModelFavorites":\s*\K[^,}]+' ~/.config/opencode/opencode-synced.jsonc 2>/dev/null || echo "false")
  step_info "secrets: $SECRETS | model favorites: $FAVS"

  if [ -n "$CONFIG_PATH" ]; then
    step_warn "--config ignored: config sync repo is active, changes will be overwritten by git pull"
  fi

  cd ~/.config/opencode
  git pull >/dev/null 2>&1 || true
  bun install >/dev/null 2>&1 || true
  cd "$ROOT"
  step_ok "config pulled from sync repo"
elif [ -d ~/.config/opencode/.git ]; then
  cd ~/.config/opencode
  git pull >/dev/null 2>&1 || true
  bun install >/dev/null 2>&1 || true

  if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" opencode.json
    cp "$CONFIG_PATH" opencode.jsonc
    step_info "Hot-swap config: $(basename "$CONFIG_PATH")"
  elif [ -f "$ROOT/config/opencode.jsonc" ]; then
    cp "$ROOT/config/opencode.jsonc" opencode.json
    cp "$ROOT/config/opencode.jsonc" opencode.jsonc
    step_info "Local override applied"
  else
    render_config_template "$ROOT" opencode.json >/dev/null 2>&1
    cp opencode.json opencode.jsonc
    step_info "Re-rendered from template + .env"
  fi

  cd "$ROOT"
  step_ok "config updated"
else
  step_skip "no config repo found"
fi

# ── MCP Server Packages ────────────────────────────────────────────────────────
step_start "MCP server packages (global)"

sudo npm update -g next-devtools-mcp chrome-devtools-mcp @biomejs/biome >/dev/null 2>&1 || {
  step_warn "Batch update failed, retrying individually..."
  sudo npm update -g next-devtools-mcp >/dev/null 2>&1 || step_warn "next-devtools-mcp update failed"
  sudo npm update -g chrome-devtools-mcp >/dev/null 2>&1 || step_warn "chrome-devtools-mcp update failed"
  sudo npm update -g @biomejs/biome >/dev/null 2>&1 || step_warn "@biomejs/biome update failed"
}

step_ok "MCP server packages updated"

# ── OpenCode CLI ───────────────────────────────────────────────────────────────
step_start "OpenCode CLI"
bash "$ROOT/scripts/install-opencode.sh" >/dev/null 2>&1 || step_warn "OpenCode update failed"
OC_VER=$(~/.opencode/bin/opencode --version 2>/dev/null || echo "?")
step_ok "OpenCode $OC_VER"

# ── Ollama ─────────────────────────────────────────────────────────────────────
step_start "Ollama"
if command -v ollama >/dev/null 2>&1; then
  verify_and_run \
    "https://ollama.com/install.sh" \
    "" \
    >/dev/null 2>&1 || step_warn "Ollama binary update failed"
  sudo systemctl restart ollama >/dev/null 2>&1 || true
  MODEL=$(read_env_var "$ROOT/config/.env" "OLLAMA_MODEL" "")
  if [ -z "$MODEL" ]; then
    MODEL=$(read_env_var "$ROOT/config/default.env" "OLLAMA_MODEL" "nomic-embed-text")
  fi
  ollama pull "$MODEL" >/dev/null 2>&1 || true
  OLLA_VER=$(ollama --version 2>/dev/null || echo "?")
  step_ok "Ollama $OLLA_VER, model: $MODEL"
else
  step_skip "not installed"
fi

# ── Restart Services ───────────────────────────────────────────────────────────
step_start "Restarting services"
sudo systemctl restart ollama >/dev/null 2>&1 || true
sudo systemctl restart opencode >/dev/null 2>&1
sudo systemctl restart openchamber >/dev/null 2>&1
step_ok "services restarted"

# ── Health Check ───────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - UPDATE_START ))
summary "$ELAPSED"

step_start "Health check"
bash "$ROOT/scripts/health.sh"
step_ok "all checks passed"

echo
banner "Update Complete"
