#!/usr/bin/env bash
set -euo pipefail

echo "== Installing OpenChamber =="

if ! sudo -n true 2>/dev/null; then
  echo "WARNING: sudo requires password, prompt will appear below"
fi

sudo timeout 300 npm install -g @openchamber/web

command -v openchamber >/dev/null 2>&1 || {
  echo "OpenChamber install failed"
  exit 1
}

openchamber --version || true