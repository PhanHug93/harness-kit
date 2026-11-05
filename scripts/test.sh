#!/usr/bin/env bash
set -uo pipefail

# One runner for every kit test suite. The table below is the only list of
# suites: `fast` rows run on every edit, `--full` adds the slow ones, and each
# CI matrix job runs one `--group`. Parallel rows share a batch (`-j`); `serial`
# rows run alone after it. Every suite gets an empty stdin and its own log.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNNER="$ROOT_DIR/scripts/test.sh"

# Started with `&`, the runner inherits an ignored SIGINT and so would every
# suite: the Ctrl-C checks (seats W10, retirement R9) then hang. Bash cannot
# undo an inherited ignore; python can, so restart once through it.
if [[ -z "${TEST_RUNNER_SIGINT_RESET:-}" ]] &&
  python3 -I -S -c 'import signal, sys; sys.exit(0 if signal.getsignal(signal.SIGINT) == signal.SIG_IGN else 1)' 2>/dev/null; then
  export TEST_RUNNER_SIGINT_RESET=1
  exec python3 -I -S -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$BASH" "$RUNNER" "$@"
fi

# Slow rows first: the batch starts them early, so they do not finish last.
# Groups are CI jobs (ci-1..ci-4 on both OSes, lint on Linux), balanced by
# measured time; scripts/test.sh --check-ci keeps .github/workflows/test.yml in step.
# name                 tier group    mode   command
DEFAULT_SUITES='
drift-inventory        full ci-3     par    bash scripts/test-bootstrap-multi-agent-project.sh --group inventory
drift-lifecycle        full ci-2     par    bash scripts/test-bootstrap-multi-agent-project.sh --group lifecycle
tiers                  fast ci-1     par    bash scripts/test-change-tiers.sh
drift-install          full ci-1     par    bash scripts/test-bootstrap-multi-agent-project.sh --group install
one-shot-upgrade       full ci-4     par    bash scripts/test-one-shot-upgrade.sh
drift-contracts        full ci-1     par    bash scripts/test-bootstrap-multi-agent-project.sh --group contracts
oneshot                fast ci-3     par    bash scripts/test-harness-kit-oneshot.sh
historical-fixtures    full ci-4     par    bash scripts/test-historical-fixtures.sh
matrix                 fast ci-2     par    bash scripts/test-harness-kit-matrix.sh
drift-prefinal         full ci-3     par    bash scripts/test-bootstrap-multi-agent-project.sh --group prefinal
verification-evidence  fast ci-2     par    bash scripts/test-verification-evidence.sh
drift-focus            full ci-4     par    bash scripts/test-bootstrap-multi-agent-project.sh --group focus
seats-no-path          full ci-4     par    bash scripts/test-seats-no-path.sh
upgrade-merge          full ci-3     par    bash scripts/test-upgrade-merge.sh
release-script         fast ci-4     par    bash scripts/test-release.sh
migrations             fast ci-2     par    bash scripts/test-harness-migrations.sh
onboarding             fast ci-1     par    bash scripts/test-onboarding-fixtures.sh
guard                  fast ci-4     par    python3 scripts/test-workspace-repository-guard.py
path-policy            fast ci-2     par    bash scripts/test-path-policy.sh
staging                fast ci-3     par    bash scripts/test-harness-kit-staging.sh
local-only             fast ci-4     par    bash scripts/test-local-only-mode.sh
retirement             fast ci-4     par    python3 scripts/test-agent-retirement.py
agentmemory            fast ci-4     par    bash scripts/test-agentmemory-check.sh
rules                  fast ci-4     par    bash scripts/test-rule-inventory.sh
runner                 fast ci-4     par    bash scripts/test-runner-selftest.sh
release-pins           fast lint     par    bash scripts/release.sh --check
entry                  fast ci-4     par    bash scripts/test-harness-kit-entry.sh
knowledge              fast ci-4     par    python3 -B scripts/test-harness-knowledge.py
syntax                 fast ci-4     par    run_syntax
detector               fast ci-4     par    bash scripts/test-detector-fixtures.sh
pipe-safety            fast lint     par    bash scripts/test-pipe-safety.sh
hook-hot-path          fast ci-4     par    bash scripts/test-hook-hot-path.sh
edit-guard-hosts       fast ci-4     par    bash scripts/test-edit-guard-hosts.sh
seat-contracts         fast ci-4     par    bash scripts/test-seat-contracts.sh
packet-seats           fast ci-4     par    bash scripts/test-packet-seats.sh
guard-race             fast ci-4     serial bash scripts/test-guard-concurrency.sh
shellcheck             fast lint     par    bash scripts/test-shellcheck.sh
ci-groups              fast lint     par    bash scripts/test.sh --check-ci
ci-gate                fast lint     par    bash scripts/test-ci-gate.sh
'

usage() {
  printf '%s\n' \
    "Usage: scripts/test.sh [--full] [--group G]... [--only NAME]... [-j N] | --list" \
    "" \
    "  (no option)   fast tier, in parallel" \
    "  --full        every suite" \
    "  --group G     every suite in CI group G (any tier); repeatable" \
    "  --only NAME   just this suite; repeatable" \
    "  --skip NAME   leave this suite out; repeatable" \
    "  -j N          parallel jobs (default: CPU count, at most 4); -j 1 runs one at a time" \
    "  --list        print the table" \
    "  --check-ci    check that .github/workflows/test.yml runs every group"
}
usage_error() { echo "test.sh: $*" >&2; usage >&2; exit 2; }

NAMES=() TIERS=() SUITE_GROUPS=() MODES=() CMDS=()
load_suites() {
  local line name tier group mode cmd
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    read -r name tier group mode cmd <<<"$line"
    NAMES+=("$name") TIERS+=("$tier") SUITE_GROUPS+=("$group") MODES+=("$mode") CMDS+=("$cmd")
  done <<<"${TEST_RUNNER_SUITES:-$DEFAULT_SUITES}"
}

suite_index() {
  local i
  for ((i = 0; i < ${#NAMES[@]}; i++)); do
    [[ "${NAMES[$i]}" == "$1" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

run_syntax() {
  local file status=0
  while IFS= read -r file; do
    bash -n "$file" || status=1
  done < <(grep -lE '^#!/usr/bin/env bash|^#!/bin/bash' "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/agent-bootstrap/*.sh \
    "$ROOT_DIR"/agent-bootstrap/lib/*.sh "$ROOT_DIR"/agent-bootstrap/githooks/pre-push)
  return "$status"
}

# Internal: run one suite, write <log_dir>/<name>.log and .status, print one line.
run_one() {
  local log_dir="$1" name="$2" index rc=0 start
  index="$(suite_index "$name")" || { echo "test.sh: unknown suite: $name" >&2; return 2; }
  start=$SECONDS
  # The commands come from the table above (or the self-test's fake table).
  (cd "$ROOT_DIR" && eval "${CMDS[$index]}") </dev/null >"$log_dir/$name.log" 2>&1 || rc=$?
  printf '%s %s\n' "$rc" "$((SECONDS - start))" >"$log_dir/$name.status"
  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS %-22s %4ss\n' "$name" "$((SECONDS - start))"
  else
    printf 'FAIL %-22s %4ss  log: %s\n' "$name" "$((SECONDS - start))" "$log_dir/$name.log"
  fi
}

default_jobs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=2
  [[ "$n" -le 4 ]] || n=4
  [[ "$n" -ge 1 ]] || n=1
  printf '%s' "$n"
}

load_suites
FULL=false
LIST=false
JOBS=""
SELECT_GROUPS=()
SELECT_ONLY=()
SELECT_SKIP=()
CHECK_CI=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-one) run_one "${2:?}" "${3:?}"; exit $? ;;
    --full) FULL=true; shift ;;
    --group)
      { [[ -n "${2:-}" ]] && in_list "$2" "${SUITE_GROUPS[@]}"; } || usage_error "unknown group: ${2:-}"
      SELECT_GROUPS+=("$2")
      shift 2
      ;;
    --only)
      { [[ -n "${2:-}" ]] && suite_index "$2" >/dev/null; } || usage_error "unknown suite: ${2:-}"
      SELECT_ONLY+=("$2")
      shift 2
      ;;
    --skip)
      { [[ -n "${2:-}" ]] && suite_index "$2" >/dev/null; } || usage_error "unknown suite: ${2:-}"
      SELECT_SKIP+=("$2")
      shift 2
      ;;
    --check-ci) CHECK_CI=true; shift ;;
    -j)
      [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage_error "-j needs a positive number"
      JOBS="$2"
      shift 2
      ;;
    --list) LIST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[[ -n "$JOBS" ]] || JOBS="$(default_jobs)"

if [[ "$LIST" == "true" ]]; then
  for ((i = 0; i < ${#NAMES[@]}; i++)); do
    printf '%-22s %-5s %-8s %s\n' "${NAMES[$i]}" "${TIERS[$i]}" "${SUITE_GROUPS[$i]}" "${MODES[$i]}"
  done
  exit 0
fi

# The CI matrix must list every group but lint (which has its own job), so no
# suite can drop out of CI without notice.
if [[ "$CHECK_CI" == "true" ]]; then
  workflow="$ROOT_DIR/.github/workflows/test.yml"
  want="$(printf '%s\n' "${SUITE_GROUPS[@]}" | grep -vx lint | sort -u | tr '\n' ' ')"
  got="$(sed -n 's/^ *group: *\[\(.*\)\] *$/\1/p' "$workflow" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u | tr '\n' ' ')"
  if [[ "$want" != "$got" ]]; then
    echo "test.sh: CI matrix groups ($got) differ from the table ($want)" >&2
    exit 1
  fi
  if ! grep -q -- 'scripts/test.sh --group lint' "$workflow"; then
    echo "test.sh: CI has no lint job" >&2
    exit 1
  fi
  echo "test.sh: CI groups match the table ($want)"
  exit 0
fi

selected=() parallel=() serial=()
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  if [[ ${#SELECT_ONLY[@]} -gt 0 ]]; then
    in_list "${NAMES[$i]}" "${SELECT_ONLY[@]}" || continue
  elif [[ ${#SELECT_GROUPS[@]} -gt 0 ]]; then
    in_list "${SUITE_GROUPS[$i]}" "${SELECT_GROUPS[@]}" || continue
  elif [[ "$FULL" != "true" && "${TIERS[$i]}" != "fast" ]]; then
    continue
  fi
  if [[ ${#SELECT_SKIP[@]} -gt 0 ]] && in_list "${NAMES[$i]}" "${SELECT_SKIP[@]}"; then
    continue
  fi
  selected+=("${NAMES[$i]}")
  if [[ "${MODES[$i]}" == "serial" ]]; then serial+=("${NAMES[$i]}"); else parallel+=("${NAMES[$i]}"); fi
done
[[ ${#selected[@]} -gt 0 ]] || usage_error "nothing selected"

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/kit-tests.XXXXXX")"
start=$SECONDS
if [[ ${#parallel[@]} -gt 0 ]]; then
  printf '%s\n' "${parallel[@]}" | xargs -n 1 -P "$JOBS" bash "$RUNNER" --run-one "$log_dir"
fi
if [[ ${#serial[@]} -gt 0 ]]; then
  for name in "${serial[@]}"; do bash "$RUNNER" --run-one "$log_dir" "$name"; done
fi

failed=()
for name in "${selected[@]}"; do
  rc=missing
  [[ -f "$log_dir/$name.status" ]] && read -r rc _ <"$log_dir/$name.status"
  [[ "$rc" == "0" ]] || failed+=("$name")
done
if [[ ${#failed[@]} -gt 0 ]]; then
  for name in "${failed[@]}"; do
    printf -- '--- %s: last lines of %s\n' "$name" "$log_dir/$name.log"
    tail -5 "$log_dir/$name.log" 2>/dev/null | sed 's/^/     | /'
  done
  printf 'tests: %d of %d failed (%s) in %ss; logs: %s\n' \
    "${#failed[@]}" "${#selected[@]}" "${failed[*]}" "$((SECONDS - start))" "$log_dir"
  exit 1
fi
rm -rf "$log_dir"
printf 'tests: ok (%d suites, -j %s) in %ss\n' "${#selected[@]}" "$JOBS" "$((SECONDS - start))"
