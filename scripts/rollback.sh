#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

source "$ROOT/scripts/lib.sh"

usage() {
  echo "Usage: bash scripts/rollback.sh [timestamp]"
  echo ""
  echo "Restore system state from a backup created by update.sh."
  echo ""
  echo "If no timestamp is given, lists available backups and prompts for selection."
  echo ""
  echo "Examples:"
  echo "  bash scripts/rollback.sh              # interactive selection"
  echo "  bash scripts/rollback.sh 20260620_143000  # restore specific backup"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# If a timestamp argument is provided, restore directly
if [ -n "${1:-}" ]; then
  BACKUP_DIR="$BACKUP_BASE/$1"
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup not found: $BACKUP_DIR"
    echo ""
    echo "Available backups:"
    list_backups || true
    exit 1
  fi
  restore_backup "$BACKUP_DIR"

  echo ""
  echo "== Running health check =="
  bash "$ROOT/scripts/health.sh"
  exit 0
fi

# Interactive mode: list backups and let user pick
echo "== Available Rollback Backups =="
echo ""

BACKUPS=()
while IFS= read -r dir; do
  [ -f "$dir/versions.txt" ] && BACKUPS+=("$(basename "$dir")")
done < <(ls -1d "$BACKUP_BASE"/[0-9]* 2>/dev/null | sort -r)

if [ ${#BACKUPS[@]} -eq 0 ]; then
  echo "No backups found. Run 'bash scripts/update.sh' first to create a backup."
  exit 1
fi

for i in "${!BACKUPS[@]}"; do
  ts="${BACKUPS[$i]}"
  echo "  $((i + 1)). $ts"
  head -1 "$BACKUP_BASE/$ts/versions.txt" | sed 's/^/     /'
done

echo ""
echo -n "Select backup [1-${#BACKUPS[@]}], or press Enter to cancel: "
read -r choice

if [ -z "${choice:-}" ]; then
  echo "Cancelled."
  exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#BACKUPS[@]} ]; then
  echo "Invalid selection."
  exit 1
fi

SELECTED="${BACKUPS[$((choice - 1))]}"
echo ""
echo "Restoring from backup: $SELECTED"
restore_backup "$BACKUP_BASE/$SELECTED"

echo ""
echo "== Running health check =="
bash "$ROOT/scripts/health.sh"
