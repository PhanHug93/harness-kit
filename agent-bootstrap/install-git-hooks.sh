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

ROOT="$(git rev-parse --show-toplevel)"
current="$(git -C "$ROOT" config --get core.hooksPath || true)"
if [[ -n "$current" && "$current" != "scripts/githooks" && "$force" != "true" ]]; then
  printf 'agent-bootstrap: core.hooksPath already set to "%s". Refusing to overwrite. Re-run with --force to override.\n' "$current" >&2
  exit 1
fi

chmod +x "$ROOT/scripts/githooks/pre-push" 2>/dev/null || true
git -C "$ROOT" config core.hooksPath scripts/githooks
printf 'agent-bootstrap: git pre-push gate armed (core.hooksPath=scripts/githooks). Bypass once with: git push --no-verify\n'
