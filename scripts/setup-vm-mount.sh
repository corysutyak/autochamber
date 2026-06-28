#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

usage() {
  echo "Usage: bash scripts/setup-vm-mount.sh [env_file]"
  echo ""
  echo "Mount a Virtiofs share from the host into the VM."
  echo ""
  echo "Reads VM_MOUNT_TAG and VM_MOUNT_POINT from env_file (default: config/.env)."
  echo "If either variable is empty, the script exits silently."
  echo ""
  echo "Example:"
  echo "  VM_MOUNT_TAG=unraid-share"
  echo "  VM_MOUNT_POINT=/mnt/unraid-share"
  echo ""
}

ENV_FILE="${1:-}"
if [ -z "$ENV_FILE" ]; then
  if [ -f "$ROOT/config/.env" ]; then
    ENV_FILE="$ROOT/config/.env"
  elif [ -f "$ROOT/config/default.env" ]; then
    ENV_FILE="$ROOT/config/default.env"
  else
    echo "ERROR: No .env file found in config/"
    exit 1
  fi
fi

MOUNT_TAG=$(read_env_var "$ENV_FILE" "VM_MOUNT_TAG" "")
MOUNT_POINT=$(read_env_var "$ENV_FILE" "VM_MOUNT_POINT" "")

if [ -z "$MOUNT_TAG" ] || [ -z "$MOUNT_POINT" ]; then
  exit 0
fi

step_start "Virtiofs mount ($MOUNT_TAG -> $MOUNT_POINT)"

# Create mount point
if [ -d "$MOUNT_POINT" ]; then
  step_info "Mount point $MOUNT_POINT already exists"
else
  sudo mkdir -p "$MOUNT_POINT"
  step_info "Created mount point $MOUNT_POINT"
fi

# Add fstab entry (idempotent)
FSTAB_ENTRY="$MOUNT_TAG  $MOUNT_POINT  virtiofs  defaults  0  0"
if grep -qF "$MOUNT_TAG  $MOUNT_POINT  virtiofs" /etc/fstab 2>/dev/null; then
  step_info "fstab entry already exists"
else
  echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab >/dev/null
  step_info "Added fstab entry: $FSTAB_ENTRY"
fi

# Mount
sudo mount -a 2>/dev/null || true

# Verify mount
if findmnt -S "$MOUNT_POINT" -o TARGET -n 2>/dev/null | grep -qF "$MOUNT_POINT"; then
  step_ok "Mounted $MOUNT_TAG at $MOUNT_POINT"
else
  step_warn "Mount may not be active — Virtiofs device might not be attached to this VM"
  step_warn "Verify with: ls -la $MOUNT_POINT"
  exit 0
fi

# Create symlink in user's home directory
CURRENT_USER="${SUDO_USER:-$USER}"
CURRENT_HOME="$(eval echo "~$CURRENT_USER")"
SYMLINK="$CURRENT_HOME/$MOUNT_TAG"

if [ -L "$SYMLINK" ]; then
  EXISTING_TARGET=$(readlink -f "$SYMLINK" 2>/dev/null || echo "")
  if [ "$EXISTING_TARGET" = "$(readlink -f "$MOUNT_POINT" 2>/dev/null || echo "$MOUNT_POINT")" ]; then
    step_info "Symlink $SYMLINK already points to $MOUNT_POINT"
  else
    step_info "Updating symlink $SYMLINK (was -> $EXISTING_TARGET)"
    rm -f "$SYMLINK"
    ln -s "$MOUNT_POINT" "$SYMLINK"
    step_info "Updated symlink $SYMLINK -> $MOUNT_POINT"
  fi
elif [ -e "$SYMLINK" ]; then
  step_warn "Path $SYMLINK exists but is not a symlink — skipping"
else
  ln -s "$MOUNT_POINT" "$SYMLINK"
  step_info "Created symlink $SYMLINK -> $MOUNT_POINT"
fi

step_ok "Virtiofs mount ready: $SYMLINK -> $MOUNT_POINT"
