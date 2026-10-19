#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

force=false
case "${1:-}" in
  --force)
    force=true
    ;;
  -h|--help)
    printf '%s\n' \
      "Usage: scripts/install-git-hooks.sh [--force]" \
      "" \
      "Opt in to the agent-bootstrap pre-push close-out gate."
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'agent-bootstrap: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

# The hooks live next to this script. core.hooksPath is relative to the Git
# top level, so a kit installed in a subdirectory (app/) needs app/scripts/githooks.
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/githooks" && pwd -P)"
ROOT="$(cd "$(git -C "$HOOKS" rev-parse --show-toplevel)" && pwd -P)"
case "$HOOKS" in
  "$ROOT"/*) hooks_path="${HOOKS#"$ROOT"/}" ;;
  *)
    printf 'agent-bootstrap: %s is not inside the Git work tree %s\n' "$HOOKS" "$ROOT" >&2
    exit 1
    ;;
esac
current="$(git -C "$ROOT" config --get core.hooksPath || true)"
if [[ -n "$current" && "$current" != "$hooks_path" && "$force" != "true" ]]; then
  printf 'agent-bootstrap: core.hooksPath already set to "%s". Refusing to overwrite. Re-run with --force to override.\n' "$current" >&2
  exit 1
fi

chmod +x "$HOOKS/pre-push" 2>/dev/null || true
git -C "$ROOT" config core.hooksPath "$hooks_path"
printf 'agent-bootstrap: git pre-push gate armed (core.hooksPath=%s). Bypass once with: git push --no-verify\n' "$hooks_path"
