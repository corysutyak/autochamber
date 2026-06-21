#!/usr/bin/env bash
set -euo pipefail

# Load shared helpers
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

SKILLS_DIR="$HOME/.config/opencode/skills"

echo "== Installing OpenCode Skills =="

# Create global skills directory
mkdir -p "$SKILLS_DIR"

install_skill() {
  local name="$1" url="$2"
  local skill_dir="$SKILLS_DIR/$name"

  step_start "Skill: $name"
  step_info "Fetching from $url"
  mkdir -p "$skill_dir"

  if curl -fsSL --max-time 60 "$url" -o "$skill_dir/SKILL.md"; then
    # Verify the file has content and frontmatter
    if ! grep -q "^---" "$skill_dir/SKILL.md" 2>/dev/null; then
      step_warn "downloaded file missing YAML frontmatter, skipping"
      rm -f "$skill_dir/SKILL.md"
      return 1
    fi

    # Verify expected sections exist (name, description, at least one bullet)
    local has_name has_description has_content
    has_name=$(grep -ci "^name:" "$skill_dir/SKILL.md" 2>/dev/null || echo "0")
    has_description=$(grep -ci "^description:" "$skill_dir/SKILL.md" 2>/dev/null || echo "0")
    has_content=$(wc -l < "$skill_dir/SKILL.md")

    if [ "$has_name" -eq 0 ] || [ "$has_description" -eq 0 ]; then
      step_warn "missing required frontmatter fields (name/description), skipping"
      rm -f "$skill_dir/SKILL.md"
      return 1
    fi

    if [ "$has_content" -lt 10 ]; then
      step_warn "file too small (${has_content} lines), likely corrupted, skipping"
      rm -f "$skill_dir/SKILL.md"
      return 1
    fi

    # Log checksum for audit trail
    local skill_checksum
    skill_checksum=$(sha256sum "$skill_dir/SKILL.md" | awk '{print $1}')
    step_info "sha256: ${skill_checksum:0:16}..."

    step_ok "installed"
    return 0
  else
    step_warn "failed to download from $url"
    return 1
  fi
}

# Track installed count
INSTALLED=0
FAILED=0

# Systematic Debugging (obra/superpowers)
if install_skill "systematic-debugging" \
  "https://raw.githubusercontent.com/obra/superpowers/main/skills/systematic-debugging/SKILL.md"; then
  INSTALLED=$((INSTALLED + 1))
else
  FAILED=$((FAILED + 1))
fi

# Test-Driven Development (obra/superpowers)
if install_skill "test-driven-development" \
  "https://raw.githubusercontent.com/obra/superpowers/main/skills/test-driven-development/SKILL.md"; then
  INSTALLED=$((INSTALLED + 1))
else
  FAILED=$((FAILED + 1))
fi

# Ask Questions If Underspecified (trailofbits/skills)
if install_skill "ask-questions-if-underspecified" \
  "https://raw.githubusercontent.com/trailofbits/skills/main/plugins/ask-questions-if-underspecified/skills/ask-questions-if-underspecified/SKILL.md"; then
  INSTALLED=$((INSTALLED + 1))
else
  FAILED=$((FAILED + 1))
fi

echo ""
echo "Skills installed: $INSTALLED, failed: $FAILED"
echo "Skills directory: $SKILLS_DIR"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "Some skills failed to install. Re-run this script or download manually."
fi
