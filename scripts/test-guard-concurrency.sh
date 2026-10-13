#!/usr/bin/env bash
set -euo pipefail

# preflight rewrites .agents/state/context-pack.json while check, doctor,
# pre-final and host hooks may read it. A slow detector stub widens the write
# window so a non-atomic write fails here every time (downstream report F4:
# 273 of 302 concurrent checks failed).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guard-concurrency-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'guard-concurrency-test: FAIL: %s\n' "$*" >&2
  exit 1
}

target="$TMP_ROOT/target"
mkdir -p "$target"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null 2>&1
summary="$(cd "$target" && scripts/detect-agent-tech-stack.sh --summary)"
printf '#!/usr/bin/env bash\nsleep 0.3\ncat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$summary" > "$target/scripts/detect-agent-tech-stack.sh"

guard() {
  (cd "$target" && bash scripts/agent-guard.sh "$@")
}

guard preflight >/dev/null 2>&1 || fail "preflight failed"
guard check >/dev/null 2>&1 || fail "check must pass on a fresh pack"

(for _ in 1 2 3 4 5 6 7 8 9 10; do guard preflight >/dev/null 2>&1; done) &
writer=$!
checks=0
failures=0
while kill -0 "$writer" 2>/dev/null; do
  if ! out="$(guard check 2>&1)"; then
    failures=$((failures + 1))
    last="$out"
  fi
  checks=$((checks + 1))
done
wait "$writer" || fail "background preflight failed"

[[ "$checks" -ge 5 ]] || fail "only $checks checks overlapped the writer; the race was not exercised"
[[ "$failures" -eq 0 ]] || fail "$failures of $checks concurrent checks failed: ${last:-}"
[[ -z "$(find "$target/.agents/state" -name 'context-pack.json.*' -print -quit)" ]] ||
  fail "temporary context packs must not be left behind"

printf 'guard-concurrency-test: ok (%s concurrent checks)\n' "$checks"
