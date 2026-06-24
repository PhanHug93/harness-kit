#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_DIR="$ROOT_DIR/agent-bootstrap/templates"
MIRROR_DIR="$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates"
MODE="sync"

usage() {
  printf '%s\n' \
    "Usage: scripts/sync-template-catalog.sh [--check]" \
    "" \
    "Sync docs template catalog mirror from agent-bootstrap/templates."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "check" ]]; then
  diff -qr "$SOURCE_DIR" "$MIRROR_DIR"
  exit 0
fi

mkdir -p "$MIRROR_DIR"
find "$MIRROR_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$SOURCE_DIR"/. "$MIRROR_DIR"/
