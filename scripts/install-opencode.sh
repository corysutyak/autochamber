#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

echo "== Installing OpenCode =="

# Fetch checksum from GitHub releases for the Linux AMD64 binary
OPENCODE_CHECKSUM=$(get_github_release_checksum anomalyco opencode opencode-linux-amd64.tar.gz 2>/dev/null) || true
if [ -n "$OPENCODE_CHECKSUM" ]; then
  step_info "Checksum available, will verify post-install"
else
  OPENCODE_CHECKSUM=""
  step_info "No checksum found for OpenCode release, skipping verification"
fi

verify_and_run \
  "https://opencode.ai/install" \
  "" || { echo "ERROR: OpenCode installer failed"; exit 1; }

echo ""
echo "== Verifying install =="

# 1. Verify the binary exists at the expected path
if [ ! -f ~/.opencode/bin/opencode ]; then
  echo "ERROR: Binary not found at ~/.opencode/bin/opencode"
  echo "The installer may have failed or placed the binary elsewhere."
  exit 1
fi
echo "✓ Binary found at ~/.opencode/bin/opencode"

# 2. Verify binary checksum against GitHub release (if available)
if [ -n "$OPENCODE_CHECKSUM" ]; then
  # The installer downloads a tarball and extracts; verify the extracted binary
  # by computing its checksum and comparing with the release digest
  BINARY_CHECKSUM=$(sha256sum ~/.opencode/bin/opencode | awk '{print $1}')
  if [ "$BINARY_CHECKSUM" = "$OPENCODE_CHECKSUM" ]; then
    echo "✓ Binary checksum verified against GitHub release"
  else
    echo "⚠ Warning: Binary checksum mismatch (expected $OPENCODE_CHECKSUM, got $BINARY_CHECKSUM)"
    echo "  This may indicate a man-in-the-middle attack or corrupted download."
  fi
fi

# 3. Log version output and save to state file for update checks
VERSION=$(~/.opencode/bin/opencode --version 2>&1) || true
if [ -n "$VERSION" ]; then
  echo "✓ Version: $VERSION"
  mkdir -p ~/.opencode
  echo "$VERSION" > ~/.opencode/.installed-version
else
  echo "⚠ Warning: Could not retrieve version string"
fi

# 4. Validate the 'serve' subcommand exists by checking --help
echo ""
echo "== Checking serve subcommand =="

if ~/.opencode/bin/opencode serve --help >/dev/null 2>&1; then
  echo "✓ 'opencode serve' subcommand is available"
  echo ""
  echo "The 'serve' command starts OpenCode's local MCP server, exposing \
 tools (hive, swarm, search, etc.) to any AI coding agent connected \
 to this machine. Run 'opencode serve' in the background to enable \
 agent-assisted development."
else
  echo "⚠ Warning: 'opencode serve --help' returned non-zero exit code"
  echo "The serve subcommand may not be available in this version."
fi

echo ""
echo "== Done =="
