#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

step_start "Git hooks"

GIT_HOOKS_DIR="$HOME/.git-templates/hooks"
mkdir -p "$GIT_HOOKS_DIR"

# Install pre-push hook that blocks force pushes and protected branch pushes
cat > "$GIT_HOOKS_DIR/pre-push" << 'HOOK'
#!/usr/bin/env bash
# Pre-push hook: blocks force pushes and pushes to protected branches.
# Installed by auto-openchamber-vm for agent safety.

PROTECTED_BRANCHES="main master production"

# Check for force push flags in the command line
if [[ "$*" == *"--force"* ]] || [[ "$*" == *"-f"* ]]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  BLOCKED: Force push attempted"
  echo ""
  echo "  Agents are not allowed to force push."
  echo "  This protects shared history from accidental rewrites."
  echo ""
  echo "  To override manually, run without the agent or remove"
  echo "  the hook: git config --unset core.hooksPath"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  exit 1
fi

# Read the ref information from stdin
while read -r local_ref local_sha remote_ref remote_sha; do
  # Extract branch name from ref (e.g., refs/heads/main -> main)
  branch="${local_ref#refs/heads/}"

  for protected in $PROTECTED_BRANCHES; do
    if [ "$branch" = "$protected" ]; then
      echo ""
      echo "═══════════════════════════════════════════════════════════"
      echo "  BLOCKED: Push to protected branch '$protected'"
      echo ""
      echo "  Agents cannot push directly to: $PROTECTED_BRANCHES"
      echo "  Use a feature branch and create a PR instead."
      echo ""
      echo "  To override manually, run without the agent or remove"
      echo "  the hook: git config --unset core.hooksPath"
      echo "═══════════════════════════════════════════════════════════"
      echo ""
      exit 1
    fi
  done
done

exit 0
HOOK

chmod +x "$GIT_HOOKS_DIR/pre-push"

# Configure git to use the hooks template for all repos
git config --global init.templateDir "$GIT_HOOKS_DIR" || true
step_info "Pre-push hook installed (blocks force pushes, protected branches)"

# Apply to existing repos that don't have custom hooks
for repo in "$HOME"/*/; do
  if [ -d "${repo}.git" ] && [ ! -f "${repo}.git/hooks/pre-push" ]; then
    cp "$GIT_HOOKS_DIR/pre-push" "${repo}.git/hooks/pre-push" 2>/dev/null || true
  fi
done

step_ok "git hooks installed"
