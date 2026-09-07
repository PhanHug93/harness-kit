#!/usr/bin/env bash
set -euo pipefail

WORKTREE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../" && pwd -P)"
exec env BOOTSTRAP_GUARD_FOCUS_ONLY=true bash "$WORKTREE_DIR/scripts/test-bootstrap-multi-agent-project.sh"
