#!/usr/bin/env bash
set -euo pipefail

# Configuration
MAX_RETRIES=6          # 2^6 = 64s theoretical cap; we floor at 30s
MAX_WAIT=30            # Cap backoff at 30 seconds
TIMEOUT=5              # curl timeout per request (seconds)

echo "== Health Check =="

FAIL=0

# ── Helpers ────────────────────────────────────────────────────────

check_service() {
  local svc="$1"
  systemctl is-active --quiet "$svc" && echo "✅ $svc running" || { echo "❌ $svc down"; FAIL=1; }
}

# Wait with exponential backoff for a condition to become true.
# Args: <label> <command...>
# Returns 0 on success, 1 on timeout (sets FAIL=1).
wait_for() {
  local label="$1"; shift
  local attempt=0 delay=1

  while ! "$@" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      echo "❌ $label timed out after $((delay * (MAX_RETRIES - 1)))s (${attempt} attempts)"
      diagnose_failure "$@"
      FAIL=1
      return 1
    fi
    echo "⏳ $label waiting... (${attempt}/${MAX_RETRIES}, ${delay}s)"
    sleep "$delay"
    # Exponential backoff, capped at MAX_WAIT
    delay=$((delay * 2))
    if [ "$delay" -gt "$MAX_WAIT" ]; then
      delay=$MAX_WAIT
    fi
  done

  echo "✅ $label ready (attempt ${attempt})"
  return 0
}

# Print diagnostic info when a check fails.
diagnose_failure() {
  echo "  ┌─ Diagnostics:"

  for port_svc_pair in "4096:opencode" "3000:openchamber" "11434:ollama"; do
    local port="${port_svc_pair%%:*}"
    local svc="${port_svc_pair##*:}"
    ss -ltn | grep -q ":${port} " \
      && echo "  │ Port ${port} (${svc}): Listening" \
      || echo "  │ Port ${port} (${svc}): NOT LISTENING"
    systemctl is-active --quiet "$svc" 2>/dev/null \
      && echo "  │   → service: active" \
      || echo "  │   → service: INACTIVE"
  done

  # Show last lines of service logs if available
  for svc in opencode openchamber ollama; do
    if journalctl -u "$svc" --no-pager -n 5 >/dev/null 2>&1; then
      echo "  │ ${svc} (last 5 log lines):"
      journalctl -u "$svc" --no-pager -n 5 2>/dev/null | sed 's/^/  │   /'
    fi
  done

  echo "  └──────────────"
}

# ── Git safety checks ────────────────────────────────────────────────

echo ""
GIT_USER=$(git config --global user.name 2>/dev/null || echo "")
if [ -n "$GIT_USER" ]; then
  echo "✅ git user.name: $GIT_USER"
else
  echo "⚠️  git user.name not set"
fi

HOOK_EXISTS=false
for hook_path in \
  "$HOME/.git-templates/hooks/pre-push" \
  "$HOME/.config/git/hooks/pre-push"; do
  if [ -f "$hook_path" ]; then
    HOOK_EXISTS=true
    break
  fi
done
if [ "$HOOK_EXISTS" = true ]; then
  echo "✅ git pre-push hook: installed"
else
  echo "⚠️  git pre-push hook: NOT INSTALLED (force push protection missing)"
fi

# ── Service checks (immediate) ─────────────────────────────────────

echo ""
check_service opencode
check_service openchamber
if command -v ollama >/dev/null 2>&1; then
  check_service ollama
else
  echo "⏭️  ollama skipped (not installed)"
fi

# ── Port checks with retry ─────────────────────────────────────────

echo ""

port_open_4096() { ss -ltn | grep -q ":4096 "; }
port_open_3000() { ss -ltn | grep -q ":3000 "; }
port_open_11434() { ss -ltn | grep -q ":11434 "; }

wait_for "Port 4096 (OpenCode)" port_open_4096 || true
wait_for "Port 3000 (OpenChamber)" port_open_3000 || true
if command -v ollama >/dev/null 2>&1; then
  wait_for "Port 11434 (Ollama)" port_open_11434 || true
fi

# ── HTTP checks with retry ─────────────────────────────────────────

echo ""

http_openchamber_ok() { curl -sf --max-time "$TIMEOUT" "http://127.0.0.1:3000" >/dev/null 2>&1; }
http_ollama_ok() { curl -sf --max-time "$TIMEOUT" "http://127.0.0.1:11434/" >/dev/null 2>&1; }

wait_for "OpenChamber HTTP" http_openchamber_ok || true
if command -v ollama >/dev/null 2>&1; then
  wait_for "Ollama HTTP" http_ollama_ok || true
fi

# ── Final verdict ───────────────────────────────────────────────────

echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "🎉 ALL SYSTEMS OK"
else
  echo "💥 SYSTEM ISSUES DETECTED"
  exit 1
fi
