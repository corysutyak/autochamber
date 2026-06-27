#!/usr/bin/env bash
set -euo pipefail

# Per-worktree Docker isolation setup generator.
#
# Generates a setup-worktree command that creates autochamber.env with:
#   - COMPOSE_PROJECT_NAME (unique per branch)
#   - PORT_0 through PORT_99 (100 sequential ports from an unused base)
#
# Port bases are scanned in 8000-8900 range (step 100). Collision detection
# checks both listening ports (ss -ltn) and existing autochamber.env files
# in sibling worktree directories, so ports are unique even when containers
# aren't running yet.
#
# Usage:
#   bash scripts/setup-worktree-docker.sh [project_path]
#
# The generated command is printed to stdout for copy-pasting into
# OpenChamber Settings > Worktrees > Setup commands.

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-worktree-docker.sh [project_path]

Generate a setup-worktree command for per-worktree Docker isolation.

Arguments:
  project_path    Path to the project repo (default: current directory)

Output:
  Prints the setup command to copy into OpenChamber Settings > Worktrees > Setup commands.
  Also prints the docker-compose.yml changes needed.

Example:
  bash scripts/setup-worktree-docker.sh ~/projects/myapp
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROJECT_PATH="${1:-.}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "ERROR: Directory not found: $PROJECT_PATH" >&2
  exit 1
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

echo "=== Per-Worktree Docker Isolation Setup ==="
echo ""
echo "Project: $PROJECT_PATH"
echo ""

# ── Print the setup command ──────────────────────────────────────────────

cat <<'SETUP_CMD'
# ── Copy this command into OpenChamber Settings > Worktrees > Setup commands ──
branch=$(git branch --show-current) && slug=$(echo "$branch" | tr '/_' '--' | tr '[:upper:]' '[:lower:]' | head -c 24) && ROOT_DIR=$(cd "$(git rev-parse --show-toplevel)" && pwd) && WORKTREE_DIR=$(pwd) && USED_BASES="" && while IFS= read -r wt_line; do wt_path=$(echo "$wt_line" | awk '{print $1}'); [ -z "$wt_path" ] && continue; [ "$wt_path" = "$WORKTREE_DIR" ] && continue; [ "$wt_path" = "$ROOT_DIR" ] && continue; if [ -f "$wt_path/autochamber.env" ]; then existing=$(grep '^PORT_BASE=' "$wt_path/autochamber.env" 2>/dev/null | cut -d= -f2); [ -n "$existing" ] && USED_BASES="$USED_BASES $existing"; fi; done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | cut -d' ' -f2-) && PORT_BASE= && for base in $(seq 8000 100 8900); do skip=0; echo "$USED_BASES" | grep -qw "$base" && skip=1; [ "$skip" = "0" ] && ss -ltn 2>/dev/null | grep -q ":${base} " && skip=1; if [ "$skip" = "0" ]; then PORT_BASE=$base; break; fi; done && if [ -z "$PORT_BASE" ]; then echo "ERROR: No available port base in 8000-8900 range" >&2; exit 1; fi && { echo "COMPOSE_PROJECT_NAME=wt-${slug}"; echo "PORT_BASE=${PORT_BASE}"; for i in $(seq 0 99); do echo "PORT_${i}=$((PORT_BASE + i))"; done; } > autochamber.env && echo "Worktree autochamber.env written: COMPOSE_PROJECT_NAME=wt-${slug} PORT_BASE=${PORT_BASE}"
SETUP_CMD

echo ""
echo "Also enable: Settings > Worktrees > 'Wait for setup commands'"
echo ""

# ── Print docker-compose.yml migration guide ─────────────────────────────

cat <<'EOF'
# ── Parameterize your docker-compose.yml ──
#
# A. Replace hardcoded ports with PORT_N variables. Each service gets a
#    sequential PORT_ index.
#
# B. Replace hardcoded container_name values. Without this, container names
#    collide across worktrees since they bypass the automatic project prefix.
#
# C. Replace hardcoded network names. Without this, all worktrees share the
#    same Docker network and containers can cross-connect.
#
# Example:
#
# Before:
#
#   services:
#     web:
#       container_name: web
#       ports:
#         - "8080:8080"
#     api:
#       container_name: api
#       ports:
#         - "3000:3000"
#     db:
#       container_name: db
#       ports:
#         - "5432:5432"
#
#   networks:
#     appnet:
#       driver: bridge
#
# After:
#
#   services:
#     web:
#       container_name: "${COMPOSE_PROJECT_NAME:-default}-web"
#       ports:
#         - "${PORT_0:-8080}:8080"
#     api:
#       container_name: "${COMPOSE_PROJECT_NAME:-default}-api"
#       ports:
#         - "${PORT_1:-3000}:3000"
#     db:
#       container_name: "${COMPOSE_PROJECT_NAME:-default}-db"
#       ports:
#         - "${PORT_2:-5432}:5432"
#
#   networks:
#     ${COMPOSE_PROJECT_NAME:-default}-appnet:
#       driver: bridge
#
# The :-default keeps non-worktree usage working (main branch, CI, etc.).
#
# ── How it works ──
#
# When OpenChamber creates a worktree, the setup command runs inside the
# new worktree directory. It:
#
# 1. Reads the branch name (git branch --show-current)
# 2. Scans sibling worktrees for existing autochamber.env files
# 3. Scans ports 8000-8900 in steps of 100 to find the first unused base
# 4. Writes autochamber.env with COMPOSE_PROJECT_NAME + PORT_0 through PORT_99
#
# Each worktree gets its own compose project name and 100 ports.
# No collisions, no manual port management.
#
# ── Run containers ──
#
# Always pass --env-file to use the generated port assignments:
#
#   docker compose --env-file autochamber.env up -d
#   docker compose --env-file autochamber.env ps
#   docker compose --env-file autochamber.env down
EOF

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Parameterize your docker-compose.yml (see above)"
echo "  2. Open OpenChamber at http://localhost:3000"
echo "  3. Go to Settings > Worktrees > Setup commands"
echo "  4. Paste the command from above"
echo "  5. Enable 'Wait for setup commands' toggle"
echo "  6. Create a worktree and verify autochamber.env is generated"
