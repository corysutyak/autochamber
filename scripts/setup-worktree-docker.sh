#!/usr/bin/env bash
set -euo pipefail

# Per-worktree Docker isolation setup generator.
#
# Generates a setup-worktree command that creates a .env file with:
#   - COMPOSE_PROJECT_NAME (unique per branch)
#   - PORT_0 through PORT_99 (100 sequential ports from an unused base)
#
# Port bases are scanned in 8000-8900 range (step 100), so each worktree
# gets 100 ports without colliding with other worktrees on the same VM.
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
branch=$(git branch --show-current) && slug=$(echo "$branch" | tr '/_' '--' | tr '[:upper:]' '[:lower:]' | head -c 24) && PORT_BASE= && for base in $(seq 8000 100 8900); do if ! ss -ltn 2>/dev/null | grep -q ":${base} "; then PORT_BASE=$base; break; fi; done && if [ -z "$PORT_BASE" ]; then echo "ERROR: No available port base in 8000-8900 range" >&2; exit 1; fi && { echo "COMPOSE_PROJECT_NAME=wt-${slug}"; echo "PORT_BASE=${PORT_BASE}"; for i in $(seq 0 99); do echo "PORT_${i}=$((PORT_BASE + i))"; done; } > .env && echo "Worktree .env written: COMPOSE_PROJECT_NAME=wt-${slug} PORT_BASE=${PORT_BASE}"
SETUP_CMD

echo ""
echo "Also enable: Settings > Worktrees > 'Wait for setup commands'"
echo ""

# ── Print docker-compose.yml migration guide ─────────────────────────────

cat <<'EOF'
# ── Parameterize your docker-compose.yml ──
#
# Replace hardcoded ports with PORT_N variables. Each service gets a
# sequential PORT_ index. Example:
#
# Before:
#
#   services:
#     web:
#       ports:
#         - "8080:8080"
#     api:
#       ports:
#         - "3000:3000"
#     db:
#       ports:
#         - "5432:5432"
#     redis:
#       ports:
#         - "6379:6379"
#
# After:
#
#   services:
#     web:
#       ports:
#         - "${PORT_0:-8080}:8080"
#     api:
#       ports:
#         - "${PORT_1:-3000}:3000"
#     db:
#       ports:
#         - "${PORT_2:-5432}:5432"
#     redis:
#       ports:
#         - "${PORT_3:-6379}:6379"
#
# The :-default keeps non-worktree usage working (main branch, CI, etc.).
#
# ── How it works ──
#
# When OpenChamber creates a worktree, the setup command runs inside the
# new worktree directory. It:
#
# 1. Reads the branch name (git branch --show-current)
# 2. Scans ports 8000-8900 in steps of 100 to find the first unused base
# 3. Writes .env with COMPOSE_PROJECT_NAME + PORT_0 through PORT_99
# 4. The .env file is automatically picked up by `docker compose up`
#
# Each worktree gets its own compose project name and 100 ports.
# No collisions, no manual port management.
#
# ── Verify ──
#
# After creating a worktree:
#   cat .env                    # Check generated ports
#   docker compose up -d        # Start with isolated ports
#   docker compose ps           # Verify correct ports
#   docker compose down         # Tear down when done
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
echo "  6. Create a worktree and verify .env is generated"
