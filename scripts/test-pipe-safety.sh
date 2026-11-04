#!/usr/bin/env bash
set -euo pipefail

# Under `set -o pipefail`, a producer piped into `grep -q` or `head` can turn a
# match into a failure: the reader exits early, the producer gets SIGPIPE
# (exit 141) and the pipeline fails. It shows only on a busy machine (found
# 2026-11-04 when the drift groups first ran in parallel). Kit and test scripts
# use here-strings (`grep -q P <<<"$x"`) or process substitution
# (`grep -q P < <(cmd)`) instead.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

pipe_into_grep_q='(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*q'
printf_into_head='printf[[:space:]][^|]*(^|[^|])\|[[:space:]]*head'
hits="$(grep -nE "$pipe_into_grep_q|$printf_into_head" \
  scripts/*.sh agent-bootstrap/*.sh agent-bootstrap/lib/*.sh agent-bootstrap/migrations/*.sh \
  agent-bootstrap/githooks/pre-push | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$hits" ]]; then
  printf 'pipe-safety: FAIL: early-exit readers fed by a pipe (use <<< or < <(…)):\n%s\n' "$hits" >&2
  exit 1
fi
echo "pipe-safety: ok"
