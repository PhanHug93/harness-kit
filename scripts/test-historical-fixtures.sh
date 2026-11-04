#!/usr/bin/env bash
set -euo pipefail

# Historical migration campaign from the pinned fixtures, in a copy with no
# Git tags: the path a user gets from a tarball. The tags campaign runs inside
# test-one-shot-upgrade.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
campaign="$(mktemp -d)"
trap 'rm -rf "$campaign"' EXIT
mkdir -p "$campaign/source/scripts"
cp -R "$ROOT_DIR/agent-bootstrap" "$campaign/source/"
cp "$ROOT_DIR/scripts/test-agent-seats-migration.py" "$campaign/source/scripts/"
cp -R "$ROOT_DIR/scripts/fixtures" "$campaign/source/scripts/"
python3 "$campaign/source/scripts/test-agent-seats-migration.py" \
  --historical-source fixtures --evidence-dir "$campaign/evidence"
