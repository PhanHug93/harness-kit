#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUNDLE_DIR="$ROOT_DIR/agent-bootstrap"
MODE="sync"

usage() {
  printf '%s\n' \
    "Usage: scripts/sync-runtime-snapshots.sh [--check]" \
    "" \
    "Refresh agent-bootstrap runtime snapshots (files marked" \
    "# AGENT_BOOTSTRAP_GENERATED) from a fresh --workflow full generation."
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

work="$(mktemp -d "${TMPDIR:-/tmp}/runtime-snapshots.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/target"
if ! bash "$BUNDLE_DIR/bootstrap-multi-agent-project.sh" --target "$work/target" --workflow full \
  >"$work/generate.log" 2>&1; then
  cat "$work/generate.log" >&2
  echo "ERROR: full generation failed; snapshots not touched" >&2
  exit 1
fi

drift=0
while IFS= read -r snapshot; do
  base="${snapshot#"$BUNDLE_DIR"/}"
  generated="$work/target/scripts/$base"
  if [[ ! -f "$generated" ]]; then
    echo "ERROR: snapshot $base is not generated into scripts/" >&2
    drift=1
    continue
  fi
  cmp -s "$snapshot" "$generated" && continue
  if [[ "$MODE" == "check" ]]; then
    echo "drift: agent-bootstrap/$base differs from generated scripts/$base" >&2
    drift=1
  else
    cp "$generated" "$snapshot"
    echo "synced agent-bootstrap/$base"
  fi
done < <(grep -lE '^# AGENT_BOOTSTRAP_GENERATED' "$BUNDLE_DIR"/*.sh "$BUNDLE_DIR"/rtk 2>/dev/null | sort)

if [[ "$drift" != 0 ]]; then
  [[ "$MODE" == "check" ]] && echo "run scripts/sync-runtime-snapshots.sh to refresh" >&2
  exit 1
fi
