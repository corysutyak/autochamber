#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load shared helpers
source "$ROOT/scripts/lib.sh"

# Detect current user for systemd services and docker group
CURRENT_USER="${SUDO_USER:-$USER}"
CURRENT_HOME="$(eval echo "~$CURRENT_USER")"

usage() {
  echo "Usage: bash scripts/install.sh [options]"
  echo ""
  echo "Bootstrap OpenCode, OpenChamber, and Swarm Tools on a Linux VM."
  echo ""
  echo "Options:"
  echo "  --config <path>  Use custom config file instead of template"
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

INSTALL_START=$(date +%s)

banner "OpenChamber Full Stack Install"

# ── Node.js + Bun ──────────────────────────────────────────────────────────────
step_start "Node.js + Bun"
bash "$ROOT/scripts/install-node.sh" || { step_error "Node.js install failed"; exit 1; }
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"
NODE_VER=$(node --version 2>/dev/null || echo "?")
BUN_VER=$(bun --version 2>/dev/null || echo "?")
step_ok "Node $NODE_VER + Bun $BUN_VER"

# ── Docker ─────────────────────────────────────────────────────────────────────
step_start "Docker"
if command -v docker >/dev/null 2>&1; then
  DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "?")
  step_skip "already installed ($DOCKER_VER)"
else
  bash "$ROOT/scripts/install-docker.sh" || { step_error "Docker install failed"; exit 1; }
  DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "?")
  step_ok "Docker $DOCKER_VER installed"
fi

# ── OpenCode ───────────────────────────────────────────────────────────────────
step_start "OpenCode CLI"
bash "$ROOT/scripts/install-opencode.sh" || { step_error "OpenCode install failed"; exit 1; }
if [ ! -f ~/.opencode/bin/opencode ]; then
  step_error "OpenCode binary not found at ~/.opencode/bin/opencode"
  exit 1
fi
OC_VER=$(~/.opencode/bin/opencode --version 2>/dev/null || echo "?")
step_ok "OpenCode $OC_VER"

# ── Git Configuration ──────────────────────────────────────────────────────────
step_start "Git configuration"
ENV_FILE=""
if [ -f "$ROOT/config/.env" ]; then
  ENV_FILE="$ROOT/config/.env"
elif [ -f "$ROOT/config/default.env" ]; then
  ENV_FILE="$ROOT/config/default.env"
fi
setup_git_config "$ENV_FILE"
step_ok "git configured as $(git config --global user.name 2>/dev/null) <$(git config --global user.email 2>/dev/null)>"

# ── Git Hooks ──────────────────────────────────────────────────────────────────
step_start "Git hooks"
bash "$ROOT/scripts/install-git-hooks.sh" || step_warn "Git hooks install failed"
step_ok "pre-push hook installed"

# ── GitHub CLI ─────────────────────────────────────────────────────────────────
step_start "GitHub CLI (gh)"
if command -v gh >/dev/null 2>&1; then
  GH_VER=$(gh --version 2>/dev/null | grep -oP 'gh version \K[\d.]+' || echo "?")
  step_skip "already installed ($GH_VER)"
else
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y -qq gh >/dev/null 2>&1 || step_warn "Failed to install gh"
fi
GH_VER=$(gh --version 2>/dev/null | grep -oP 'gh version \K[\d.]+' || echo "?")
GH_TOKEN=$(read_env_var "$ENV_FILE" "GH_TOKEN" "")
if [ -n "$GH_TOKEN" ]; then
  echo "$GH_TOKEN" | GH_TOKEN="" gh auth login --with-token >/dev/null 2>&1 && step_ok "gh $GH_VER (authenticated)" || { step_warn "gh auth failed"; step_ok "gh $GH_VER (run 'gh auth login' to connect)"; }
else
  step_ok "gh $GH_VER (run 'gh auth login' to connect)"
fi

# Configure git credential helper so HTTPS pushes use gh's token
git config --global credential.helper '!gh auth setup-git' || true

# ── Ollama ─────────────────────────────────────────────────────────────────────
step_start "Ollama (embeddings)"
bash "$ROOT/scripts/install-ollama.sh" || { step_error "Ollama install failed"; exit 1; }
OLLA_VER=$(ollama --version 2>/dev/null || echo "?")
step_ok "Ollama $OLLA_VER"

# ── MCP Server Dependencies ────────────────────────────────────────────────────
step_start "MCP server packages (global)"

sudo npm install -g next-devtools-mcp chrome-devtools-mcp @biomejs/biome >/dev/null 2>&1 || {
  step_warn "Global npm install partially failed, retrying individually..."
  sudo npm install -g next-devtools-mcp >/dev/null 2>&1 || step_warn "next-devtools-mcp install failed"
  sudo npm install -g chrome-devtools-mcp >/dev/null 2>&1 || step_warn "chrome-devtools-mcp install failed"
  sudo npm install -g @biomejs/biome >/dev/null 2>&1 || step_warn "@biomejs/biome install failed"
}

for cmd in next-devtools-mcp chrome-devtools-mcp biome; do
  if command -v "$cmd" >/dev/null 2>&1; then
    step_info "$cmd installed ($(command -v "$cmd"))"
  else
    step_warn "$cmd not found on PATH — MCP servers or formatter may fall back to npx"
  fi
done

step_ok "MCP server packages installed globally (no npx overhead on spawn)"

# ── OpenCode Config ────────────────────────────────────────────────────────────
step_start "OpenCode config"

# Clone upstream config repo for agents, commands, skills, knowledge files
if [ -d ~/.config/opencode/.git ]; then
  step_info "Config repo exists, pulling latest..."
  (cd ~/.config/opencode && timeout 60 git pull) >/dev/null 2>&1 || true
elif [ -d ~/.config/opencode ]; then
  step_info "Removing stale config dir, re-cloning..."
  rm -rf ~/.config/opencode
  git clone --quiet https://github.com/joelhooks/opencode-config ~/.config/opencode || { step_error "Config repo clone failed"; exit 1; }
else
  git clone --quiet https://github.com/joelhooks/opencode-config ~/.config/opencode || { step_error "Config repo clone failed"; exit 1; }
fi
step_info "Running bun install in config dir..."
(cd ~/.config/opencode && bun install) || step_warn "bun install failed"
cd "$ROOT" || { echo "FATAL: cannot cd back to $ROOT"; exit 1; }
step_info "bun install done, pwd=$(pwd)"

# Deploy config: --config flag > local opencode.jsonc > render template from .env
CONFIG_APPLIED=false
if [ -n "$CONFIG_PATH" ]; then
  if [ ! -f "$CONFIG_PATH" ]; then
    step_error "Config file not found: $CONFIG_PATH"
    exit 1
  fi
  cp "$CONFIG_PATH" ~/.config/opencode/opencode.json
  cp "$CONFIG_PATH" ~/.config/opencode/opencode.jsonc
  step_info "Custom config: $(basename "$CONFIG_PATH")"
  CONFIG_APPLIED=true
elif [ -f "$ROOT/config/opencode.jsonc" ]; then
  cp "$ROOT/config/opencode.jsonc" ~/.config/opencode/opencode.json
  cp "$ROOT/config/opencode.jsonc" ~/.config/opencode/opencode.jsonc
  step_info "Local override: config/opencode.jsonc"
  CONFIG_APPLIED=true
else
  render_config_template "$ROOT" ~/.config/opencode/opencode.json
  cp ~/.config/opencode/opencode.json ~/.config/opencode/opencode.jsonc
  step_info "Rendered from template + .env"
  CONFIG_APPLIED=true
fi

step_ok "Config deployed to ~/.config/opencode/"

# ── Skills ─────────────────────────────────────────────────────────────────────
step_start "OpenCode skills"
step_info "Downloading skills (may take a moment)..."
bash "$ROOT/scripts/install-skills.sh" || step_warn "Some skills failed to install"
step_ok "skills installed (systematic-debugging, test-driven-development, ask-questions-if-underspecified)"

# ── OpenChamber ────────────────────────────────────────────────────────────────
step_start "OpenChamber Web UI"
step_info "Installing @openchamber/web (sudo prompt may appear)..."
bash "$ROOT/scripts/install-openchamber.sh" || { step_error "OpenChamber install failed"; exit 1; }
OCB_VER=$(openchamber --version 2>/dev/null || echo "?")
step_ok "OpenChamber $OCB_VER (port 3000)"

# ── Systemd Services ───────────────────────────────────────────────────────────
step_start "Systemd services"

for svc in opencode openchamber ollama; do
  sed -e "s/\$DEV_USER/$CURRENT_USER/g" \
      -e "s|\$DEV_HOME|$CURRENT_HOME|g" \
      "$ROOT/systemd/${svc}.service" \
    | sudo tee "/etc/systemd/system/${svc}.service" >/dev/null
done

# Install journald log rotation config
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp "$ROOT/systemd/99-autochamber-journald.conf" /etc/systemd/journald.conf.d/
sudo systemctl restart systemd-journald >/dev/null 2>&1 || true
step_info "journald log rotation configured (500M max)"

sudo systemctl daemon-reload >/dev/null 2>&1
sudo systemctl enable opencode openchamber ollama docker >/dev/null 2>&1 || true

echo "Starting services (docker -> ollama -> opencode -> openchamber)..."
sudo systemctl restart docker >/dev/null 2>&1 || true
sudo systemctl restart ollama >/dev/null 2>&1 || true
sudo systemctl restart opencode >/dev/null 2>&1
sudo systemctl restart openchamber >/dev/null 2>&1

# Wait for services to report active before health check
for _svc in ollama opencode openchamber; do
  for _i in $(seq 1 10); do
    systemctl is-active --quiet "$_svc" && break
    sleep 1
  done
done

step_ok "opencode (4096), openchamber (3000)"

# ── CLI Backends ───────────────────────────────────────────────────────────────
step_start "CLI backends (swarm, CASS, UBS, uv)"

sudo npm install -g opencode-swarm-plugin >/dev/null 2>&1 || step_warn "Failed to install swarm plugin"

# Ensure ~/.local/bin is on PATH for installed binaries
export PATH="$HOME/.local/bin:$PATH"

# CASS — with checksum verification
TMP_CASS_INSTALL=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh?$(date +%s)" \
  -o "$TMP_CASS_INSTALL"
CASS_CHECKSUM=$(get_github_release_checksum Dicklesworthstone coding_agent_session_search cass-linux-amd64.tar.gz 2>/dev/null) || true
if [ -n "$CASS_CHECKSUM" ]; then
  bash "$TMP_CASS_INSTALL" --easy-mode --verify --checksum "$CASS_CHECKSUM" >/dev/null 2>&1 || step_warn "CASS install failed"
else
  bash "$TMP_CASS_INSTALL" --easy-mode --verify >/dev/null 2>&1 || step_warn "CASS install (no checksum) failed"
fi
rm -f "$TMP_CASS_INSTALL"
cass index >/dev/null 2>&1 || true

# UBS — with checksum verification
UBS_CHECKSUM=$(get_github_release_checksum Dicklesworthstone ultimate_bug_scanner install.sh 2>/dev/null) || true
if [ -n "$UBS_CHECKSUM" ]; then
  verify_and_run \
    "https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/main/install.sh?$(date +%s)" \
    "$UBS_CHECKSUM" \
    --easy-mode >/dev/null 2>&1 || step_warn "UBS install failed"
else
  verify_and_run \
    "https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/main/install.sh?$(date +%s)" \
    "" \
    --easy-mode >/dev/null 2>&1 || step_warn "UBS install (no checksum) failed"
fi

# uv/uvx
if command -v uv >/dev/null 2>&1; then
  step_skip "uv already installed"
else
  step_info "Installing uv..."
  ensure_local_bin
  curl -LsSf https://astral.sh/uv/install.sh | sh || step_warn "uv install failed"
fi

if command -v uv >/dev/null 2>&1; then
  UV_VER=$(uv --version 2>/dev/null || echo "?")
  step_ok "uv $UV_VER"
else
  step_warn "uv not on PATH — run 'curl -LsSf https://astral.sh/uv/install.sh | sh' manually"
fi

SWARM_VER=$(swarm --version 2>/dev/null || echo "ok")
CASS_VER=$(cass --version 2>/dev/null || echo "?")
if command -v ubs >/dev/null 2>&1; then
  UBS_VER=$(ubs --version 2>/dev/null || echo "installed")
else
  UBS_VER="(not found)"
fi

step_ok "swarm, CASS $CASS_VER, uv"
[ "$UBS_VER" != "(not found)" ] && step_info "UBS $UBS_VER" || step_warn "UBS not on PATH — run installer manually from https://github.com/Dicklesworthstone/ultimate_bug_scanner"

# ── Health Check ───────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - INSTALL_START ))
summary "$ELAPSED"

step_start "Health check"
bash "$ROOT/scripts/health.sh"
step_ok "all checks passed"

echo
banner "Install Complete"
