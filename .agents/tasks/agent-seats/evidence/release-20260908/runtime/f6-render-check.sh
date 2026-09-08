#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${AGENT_BOOTSTRAP_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd -P)}"
BOOTSTRAP="$REPO_ROOT/agent-bootstrap/bootstrap-multi-agent-project.sh"
TARGET="$(mktemp -d /tmp/agent-seats-f6-render.XXXXXX)"
RETIRED="$TARGET/docs/agent-configs/model-profiles.json.generated.f6-retired"
LOCK="$TARGET/docs/agent-configs/agent-bootstrap.lock.json"
SUMMARY="$REPO_ROOT/.agents/tasks/agent-seats/evidence/release-20260908/runtime/f6-render-summary.json"
trap 'rm -rf "$TARGET"' EXIT HUP INT TERM

run_bootstrap() {
  bash "$BOOTSTRAP" --target "$TARGET" --workflow full "$@" >/dev/null
}

check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label" >&2
    exit 1
  fi
}

run_bootstrap
mkdir -p "$(dirname "$RETIRED")"
printf '%s\n' 'retired legacy candidate; preserve these bytes' > "$RETIRED"
retired_before="$(shasum -a 256 "$RETIRED" | awk '{print $1}')"

run_bootstrap --refresh-lock
retired_after="$(shasum -a 256 "$RETIRED" | awk '{print $1}')"
apply_state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apply_state"])' "$LOCK")"
status_json="$(bash "$BOOTSTRAP" --target "$TARGET" --status --json)"
pending_count="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending_generated_candidates"])')"
check "retired-only candidate -> lock complete" test "$apply_state" = complete
check "retired-only candidate -> status pending count zero" test "$pending_count" = 0
check "retired candidate bytes preserved after refresh" test "$retired_before" = "$retired_after"

printf '%s\n' 'eligible generated candidate' > "$TARGET/AGENTS.md.generated.f6-real"
run_bootstrap --refresh-lock
retired_after="$(shasum -a 256 "$RETIRED" | awk '{print $1}')"
apply_state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apply_state"])' "$LOCK")"
status_json="$(bash "$BOOTSTRAP" --target "$TARGET" --status --json)"
pending_count="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending_generated_candidates"])')"
check "retired plus eligible candidate -> lock pending" test "$apply_state" = pending
check "retired plus eligible candidate -> status counts eligible candidate" test "$pending_count" = 1
check "retired candidate bytes preserved with eligible candidate" test "$retired_before" = "$retired_after"

# The lock must still notice eligible installer candidates; a second, partial
# path allowlist would silently classify these as complete.
rm "$TARGET/AGENTS.md.generated.f6-real"
printf '%s\n' 'eligible git hooks installer candidate' > "$TARGET/scripts/install-git-hooks.sh.generated.f6-installer"
run_bootstrap --refresh-lock
installer_state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apply_state"])' "$LOCK")"
status_json="$(bash "$BOOTSTRAP" --target "$TARGET" --status --json)"
installer_count="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending_generated_candidates"])')"
check "installer candidate -> lock pending" test "$installer_state" = pending
check "installer candidate -> status counts one" test "$installer_count" = 1

python3 - "$SUMMARY" "$apply_state" "$pending_count" "$retired_before" "$retired_after" <<'PY'
import json
import sys

path, apply_state, pending_count, retired_before, retired_after = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "bash": "/bin/bash",
        "apply_state_with_retired_only": "complete",
        "pending_count_with_retired_only": 0,
        "apply_state_with_retired_and_eligible": apply_state,
        "pending_count_with_retired_and_eligible": int(pending_count),
        "retired_sha256_before": retired_before,
        "retired_sha256_after": retired_after,
        "passed": 8,
        "failed": 0,
    }, fh, indent=2)
    fh.write("\n")
PY

printf '8 passed, 0 failed\n'
