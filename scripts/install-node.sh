#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

echo "== Installing Node.js =="

if command -v node >/dev/null 2>&1; then
  echo "Node already installed"
else
  TMP_NODE_SETUP=$(mktemp)
  trap "rm -f $TMP_NODE_SETUP" EXIT
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$TMP_NODE_SETUP"

  # Log checksum for transparency (NodeSource doesn't publish release checksums)
  NODE_SETUP_CHECKSUM=$(sha256sum "$TMP_NODE_SETUP" | awk '{print $1}')
  echo "  NodeSource setup script sha256: $NODE_SETUP_CHECKSUM"

  sudo -E bash "$TMP_NODE_SETUP"
  trap - EXIT
  rm -f "$TMP_NODE_SETUP"
  sudo apt install -y nodejs
fi

node -v
npm -v

echo "== Installing Bun =="

if command -v bun >/dev/null 2>&1; then
  echo "Bun already installed"
else
  sudo apt install -y unzip
  TMP_BUN_INSTALL=$(mktemp)
  trap "rm -f $TMP_BUN_INSTALL" EXIT
  curl -fsSL https://bun.sh/install -o "$TMP_BUN_INSTALL"
  bash "$TMP_BUN_INSTALL"
  trap - EXIT
  rm -f "$TMP_BUN_INSTALL"
fi

# Ensure bun is on PATH for the current session
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
bun --version

# Mark that we installed Node.js (for uninstall cleanup)
sudo mkdir -p /var/lib/autochamber
sudo touch /var/lib/autochamber/node-installed-by-us
