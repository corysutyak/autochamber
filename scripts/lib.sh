#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared helper library for auto-openchamber-vm scripts.
# Source this file from other scripts: source "$ROOT/scripts/lib.sh"

STATE_DIR="/var/lib/autochamber"
BACKUP_BASE="$STATE_DIR/backups"

# ── Output formatting ────────────────────────────────────────────────────────
# Color-aware, step-tracked output helpers for install/update scripts.
# Detects TTY and NO_COLOR; falls back to plain text when disabled.

_COLORS=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _COLORS=1
fi

_reset() { [ "$_COLORS" = "1" ] && echo -ne "\033[0m" || true; }
_color() { local c="$1"; shift; if [ "$_COLORS" = "1" ]; then printf "\033[%sm" "$c"; fi; echo "$@"; _reset; }

# Print a section header with box-style banner
banner() {
  local title="$1"
  local width=60
  local pad=$(( (width - ${#title} - 2) / 2 ))
  [ "$pad" -lt 2 ] && pad=2
  _color "36;1" "$(printf '%*s' $width '' | tr ' ' '=')"
  _color "36;1" "|$(printf '%*s' $pad '') $title $(printf '%*s' $pad '')|"
  _color "36;1" "$(printf '%*s' $width '' | tr ' ' '=')"
  echo
}

# Print a step header: [N] Step name ...
# Sets STEP_START_TIME for elapsed tracking
step_start() {
  local msg="$1"
  _color "37;1" "> $msg..."
  STEP_START_TIME=$(date +%s)
}

# Mark current step as done with optional detail message
step_ok() {
  local msg="${1:-done}"
  local elapsed=$(( $(date +%s) - STEP_START_TIME ))
  if [ "$elapsed" -gt 5 ]; then
    _color "32" "  [OK] $msg (${elapsed}s)"
  else
    _color "32" "  [OK] $msg"
  fi
}

# Mark current step as skipped with reason
step_skip() {
  local msg="${1:-already installed}"
  _color "33" "  [SKIP] $msg"
}

# Print an indented info line
step_info() {
  local msg="$1"
  _color "37" "       $msg"
}

# Print a warning
step_warn() {
  local msg="$1"
  _color "33;1" "  [WARN] $msg"
}

# Print an error
step_error() {
  local msg="$1"
  _color "31;1" "  [ERR] $msg"
}

# Print a summary footer with total elapsed time
summary() {
  local total="${1:-0}"
  echo
  _color "36;1" "$(printf '%*s' 60 '' | tr ' ' '-')"
  if [ "$total" -gt 60 ]; then
    local min=$((total / 60))
    local sec=$((total % 60))
    _color "37;1" "  Total time: ${min}m ${sec}s"
  else
    _color "37;1" "  Total time: ${total}s"
  fi
  _color "36;1" "$(printf '%*s' 60 '' | tr ' ' '-')"
}

# ── Safe curl install ────────────────────────────────────────────────────────
# Downloads a remote script to a temp file, executes it with given args, and
# cleans up on exit.  Returns the exit code of the executed command.
#
# Usage: safe_curl_install <url> [args...]
safe_curl_install() {
  local url="$1"; shift
  local tmp_file
  tmp_file=$(mktemp)

  _cleanup_tmp() { rm -f "$tmp_file"; }
  trap '_cleanup_tmp' EXIT INT TERM

  curl -fsSL "$url" -o "$tmp_file" || { echo "ERROR: Failed to download $url"; return 1; }

  bash "$tmp_file" "$@"
  local rc=$?

  trap - EXIT INT TERM
  rm -f "$tmp_file"
  return $rc
}

# ── Verify and run remote script ─────────────────────────────────────────────
# Downloads a remote script, logs a preview line, optionally verifies its
# sha256 checksum, then executes it with given args. Cleans up on exit.
#
# Usage: verify_and_run <url> [checksum] [args...]
#   url      - URL to download
#   checksum - optional sha256 hex digest (omit if empty string)
verify_and_run() {
  local url="$1"
  local checksum="${2:-}"
  shift 2

  local tmp_file
  tmp_file=$(mktemp)

  _cleanup_tmp_vr() { rm -f "$tmp_file"; }
  trap '_cleanup_tmp_vr' EXIT INT TERM

  curl -fsSL "$url" -o "$tmp_file" || { step_error "Failed to download $url"; return 1; }

  # Log a preview line (second non-empty line, usually a comment)
  local preview
  preview=$(grep -m1 '^#[^!]' "$tmp_file" 2>/dev/null | head -1 | sed 's/^#[[:space:]]*//' || true)
  [ -n "$preview" ] && step_info "Script: $preview"

  # Verify checksum if provided
  if [ -n "$checksum" ]; then
    local actual
    actual=$(sha256sum "$tmp_file" | awk '{print $1}')
    if [ "$actual" != "$checksum" ]; then
      step_error "Checksum mismatch for $url (expected $checksum, got $actual)"
      rm -f "$tmp_file"
      trap - EXIT INT TERM
      return 1
    fi
    step_info "Checksum verified"
  fi

  bash "$tmp_file" "$@"
  local rc=$?

  trap - EXIT INT TERM
  rm -f "$tmp_file"
  return $rc
}

# ── Read env var from file ───────────────────────────────────────────────────
# Extract a single variable from an .env file without sourcing it.
# This avoids executing arbitrary code or leaking secrets into the shell.
#
# Usage: read_env_var <file> <var_name> [default]
read_env_var() {
  local file="$1" name="$2" default="${3:-}"
  if [ -f "$file" ]; then
    local val
    val=$(grep -m1 "^${name}=" "$file" | cut -d'=' -f2- | tr -d '\r\n' | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/' || true)
    if [ -n "$val" ]; then
      echo "$val"
    else
      echo "$default"
    fi
  else
    echo "$default"
  fi
}

# ── GitHub release checksum ──────────────────────────────────────────────────
# Fetches the sha256 digest for a release asset from the GitHub API.
# Returns empty string on failure.
#
# Usage: get_github_release_checksum <owner> <repo> [asset_name]
get_github_release_checksum() {
  local owner="$1" repo="$2" asset="${3:-}"
  local api_url="https://api.github.com/repos/$owner/$repo/releases/latest"

  local response
  response=$(curl -fsSL "$api_url" 2>/dev/null) || return 1

  if [ -n "$asset" ]; then
    # Use python3 for reliable JSON parsing (minified, nested objects)
    echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a.get('name') == '$asset' and a.get('digest', '').startswith('sha256:'):
        print(a['digest'][7:])
        break
" 2>/dev/null || true
  else
    # Return digest of first asset
    echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a.get('digest', '').startswith('sha256:'):
        print(a['digest'][7:])
        break
" 2>/dev/null || true
  fi
}

# ── State management ─────────────────────────────────────────────────────────
# Ensure the state directory exists (requires sudo for /var/lib).
ensure_state_dir() {
  sudo mkdir -p "$STATE_DIR" "$BACKUP_BASE"
}

# Ensure ~/.local/bin exists for tool installs (uv, pipx, etc.).
ensure_local_bin() {
  mkdir -p "$HOME/.local/bin"
}

# Create a timestamped backup of current system state.
# Returns the backup directory path via stdout.
create_backup() {
  ensure_state_dir
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local backup_dir="$BACKUP_BASE/$ts"
  sudo mkdir -p "$backup_dir"

  # Systemd services
  for svc in opencode openchamber ollama; do
    if [ -f "/etc/systemd/system/${svc}.service" ]; then
      sudo cp "/etc/systemd/system/${svc}.service" "$backup_dir/"
    fi
  done

  # Ollama profile.d env vars
  if [ -f "/etc/profile.d/swarm-ollama.sh" ]; then
    sudo cp "/etc/profile.d/swarm-ollama.sh" "$backup_dir/"
  fi

  # OpenCode config
  if [ -d "$HOME/.config/opencode" ]; then
    sudo mkdir -p "$backup_dir/opencode-config"
    for f in opencode.json opencode.jsonc; do
      [ -f "$HOME/.config/opencode/$f" ] && sudo cp "$HOME/.config/opencode/$f" "$backup_dir/opencode-config/"
    done

    # Agent .md files
    if [ -d "$HOME/.config/opencode/agent" ]; then
      sudo mkdir -p "$backup_dir/agent"
      for f in "$HOME/.config/opencode/agent/"*.md; do
        [ -f "$f" ] && sudo cp "$f" "$backup_dir/agent/"
      done
    fi

  fi

  # Component versions snapshot
  {
    echo "=== Version Snapshot: $ts ==="
    command -v node >/dev/null 2>&1 && echo "node=$(node --version 2>/dev/null)" || echo "node=not installed"
    command -v npm >/dev/null 2>&1 && echo "npm=$(npm --version 2>/dev/null)" || echo "npm=not installed"
    command -v bun >/dev/null 2>&1 && echo "bun=$(bun --version 2>/dev/null)" || echo "bun=not installed"
    command -v docker >/dev/null 2>&1 && echo "docker=$(docker --version 2>/dev/null)" || echo "docker=not installed"
    [ -f "$HOME/.opencode/bin/opencode" ] && echo "opencode=$($HOME/.opencode/bin/opencode --version 2>/dev/null)" || echo "opencode=not installed"
    command -v openchamber >/dev/null 2>&1 && echo "openchamber=$(openchamber --version 2>/dev/null)" || echo "openchamber=not installed"
    command -v cass >/dev/null 2>&1 && echo "cass=$(cass --version 2>/dev/null)" || echo "cass=not installed"
  } | sudo tee "$backup_dir/versions.txt" > /dev/null

  echo "$backup_dir"
}

# Restore state from a backup directory.
restore_backup() {
  local backup_dir="$1"

  if [ ! -d "$backup_dir" ]; then
    echo "ERROR: Backup directory not found: $backup_dir"
    return 1
  fi

  echo "== Restoring from backup: $backup_dir =="

  # Restore systemd services
  for svc in opencode openchamber ollama; do
    if [ -f "$backup_dir/${svc}.service" ]; then
      sudo cp "$backup_dir/${svc}.service" "/etc/systemd/system/${svc}.service"
      echo "  Restored ${svc}.service"
    fi
  done

  # Restore Ollama profile.d env vars
  if [ -f "$backup_dir/swarm-ollama.sh" ]; then
    sudo cp "$backup_dir/swarm-ollama.sh" "/etc/profile.d/swarm-ollama.sh"
    sudo chmod 0644 /etc/profile.d/swarm-ollama.sh
    echo "  Restored swarm-ollama.sh"
  fi

  # Restore OpenCode config
  if [ -d "$backup_dir/opencode-config" ]; then
    for f in opencode.json opencode.jsonc; do
      [ -f "$backup_dir/opencode-config/$f" ] && cp "$backup_dir/opencode-config/$f" "$HOME/.config/opencode/$f"
    done
    echo "  Restored OpenCode config"
  fi

  # Restore agent files
  if [ -d "$backup_dir/agent" ]; then
    for f in "$backup_dir/agent/"*.md; do
      [ -f "$f" ] && cp "$f" "$HOME/.config/opencode/agent/"
    done
    echo "  Restored agent files"
  fi

  # Reload systemd and restart services
  sudo systemctl daemon-reload || true
  sudo systemctl restart ollama || true
  sudo systemctl restart opencode || true
  sudo systemctl restart openchamber || true

  echo "== Restore complete =="
}

# List available backups (newest first).
list_backups() {
  if [ ! -d "$BACKUP_BASE" ]; then
    echo "No backups found."
    return 1
  fi

  local count=0
  for dir in $(ls -1d "$BACKUP_BASE"/[0-9]* 2>/dev/null | sort -r); do
    if [ -f "$dir/versions.txt" ]; then
      echo "  $(basename "$dir")"
      head -1 "$dir/versions.txt" | sed 's/^/    /'
      count=$((count + 1))
    fi
  done

  if [ "$count" -eq 0 ]; then
    echo "No backups found."
    return 1
  fi

  return 0
}

# ── Git setup ────────────────────────────────────────────────────────
# Configures git identity, safe directories, and installs pre-push hook.
#
# Usage: setup_git_config [user_name] [user_email]
setup_git_config() {
  local env_file="${1:-}"
  local user_name user_email

  if [ -n "$env_file" ] && [ -f "$env_file" ]; then
    user_name=$(read_env_var "$env_file" "AGENT_NAME" "OpenChamber Agent")
    user_email=$(read_env_var "$env_file" "AGENT_EMAIL" "")
    # If email still empty, derive from hostname
    [ -z "$user_email" ] && user_email="agent@$(hostname -f 2>/dev/null || echo 'localvm')"
  else
    user_name="${AGENT_NAME:-OpenChamber Agent}"
    user_email="${AGENT_EMAIL:-agent@$(hostname -f 2>/dev/null || echo 'localvm')}"
  fi

  step_start "Git configuration"

  # Set identity
  git config --global user.name "$user_name" || true
  git config --global user.email "$user_email" || true
  step_info "Identity: $user_name <$user_email>"

  # Scope safe.directory to home and common workspace paths only
  git config --global safe.directory "$HOME" || true
  step_info "Safe directory: $HOME"

  step_ok "git configured"
}

# ── Config templating ────────────────────────────────────────────────────────
# Reads config/.env (or default.env as fallback) and renders the template
# default.opencode.jsonc into a final config file at the given output path.
#
# Usage: render_config_template <root_dir> <output_path>
render_config_template() {
  local root="$1"
  local output="$2"
  local env_file=""

  # Prefer .env over default.env; error if neither exists
  if [ -f "$root/config/.env" ]; then
    env_file="$root/config/.env"
  elif [ -f "$root/config/default.env" ]; then
    env_file="$root/config/default.env"
    echo "WARNING: config/.env not found, using default.env"
  else
    echo "ERROR: No .env file found in config/"
    return 1
  fi

  # Read env vars without sourcing — avoids leaking secrets to child processes
  local model
  local small_model
  local custom_provider
  local provider_url
  local provider_api_key

  model=$(read_env_var "$env_file" "OPENCODE_MODEL" "openai/gpt-5.2-codex")
  small_model=$(read_env_var "$env_file" "OPENCODE_SMALL_MODEL" "openai/gpt-5.2")
  custom_provider=$(read_env_var "$env_file" "OPENCODE_CUSTOM_PROVIDER" "false")
  provider_url=$(read_env_var "$env_file" "OPENCODE_PROVIDER_URL" "")
  provider_api_key=$(read_env_var "$env_file" "OPENCODE_PROVIDER_API_KEY" "")

  # Read template
  local template="$root/config/default.opencode.jsonc"
  if [ ! -f "$template" ]; then
    echo "ERROR: Template not found: $template"
    return 1
  fi

  # Step 1: substitute model placeholders
  sed \
    -e "s|__MODEL__|$model|g" \
    -e "s|__SMALL_MODEL__|$small_model|g" \
    "$template" > "$output.tmp"

  # Step 2: always inject plugins
  sed -i 's|  __PLUGIN_BLOCK__|  "plugin": ["opencode-models-discovery@latest", "opencode-synced"],|' "$output.tmp"

  # Step 3: handle provider block
  if [ "$custom_provider" = "true" ]; then
    if [ -z "$provider_url" ]; then
      echo "ERROR: OPENCODE_CUSTOM_PROVIDER=true but OPENCODE_PROVIDER_URL is not set"
      return 1
    fi

    # Build provider JSON — modelsDiscovery fills in models at runtime
    {
      echo '  "provider": {'
      echo '    "llama-local": {'
      echo '      "name": "Llama.cpp",'
      echo '      "npm": "@ai-sdk/openai-compatible",'
      echo '      "options": {'
      echo "        \"baseURL\": \"$provider_url\","
      echo '        "timeout": 3000000,'
      if [ -n "$provider_api_key" ]; then
        echo '        "chunkTimeout": 150000,'
        echo "        \"apiKey\": \"$provider_api_key\","
      else
        echo '        "chunkTimeout": 150000,'
      fi
      echo '        "modelsDiscovery": {'
      echo '          "enabled": true'
      echo '        }'
      echo '      },'
      echo '      "models": {}'
      echo '    }'
      echo '  },'
    } > "$output.provider"

    # Replace the __PROVIDER_BLOCK__ line with the provider content
    sed -i "/__PROVIDER_BLOCK__/r $output.provider" "$output.tmp"
    sed -i "/__PROVIDER_BLOCK__/d" "$output.tmp"
    rm -f "$output.provider"
  else
    # Remove the placeholder line entirely
    sed -i "/__PROVIDER_BLOCK__/d" "$output.tmp"
  fi

  mv "$output.tmp" "$output"
}
