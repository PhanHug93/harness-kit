#!/usr/bin/env bash
set -uo pipefail

# Fast tier (about 5 minutes): run on every edit. Every check runs even when an
# earlier one fails, and the summary lists all failures at once. The full tier
# (scripts/test-bootstrap-multi-agent-project.sh and test-one-shot-upgrade.sh)
# runs in CI for every pull request and release tag; run it locally only to
# reproduce a CI failure or when CI cannot run.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECKS=(syntax release-pins release-script guard onboarding retirement detector path-policy guard-race local-only)

usage() {
  printf '%s\n' \
    "Usage: scripts/test-fast.sh [--only CHECK]..." \
    "" \
    "Checks: ${CHECKS[*]}"
}

run_check() {
  case "$1" in
    syntax)
      local file status=0
      while IFS= read -r file; do
        bash -n "$file" || status=1
      done < <(grep -lE '^#!/usr/bin/env bash|^#!/bin/bash' "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/agent-bootstrap/*.sh \
        "$ROOT_DIR"/agent-bootstrap/lib/*.sh "$ROOT_DIR"/agent-bootstrap/rtk "$ROOT_DIR"/agent-bootstrap/githooks/pre-push)
      return "$status"
      ;;
    release-pins) bash "$ROOT_DIR/scripts/release.sh" --check ;;
    release-script) bash "$ROOT_DIR/scripts/test-release.sh" ;;
    guard) python3 "$ROOT_DIR/scripts/test-workspace-repository-guard.py" ;;
    onboarding) bash "$ROOT_DIR/scripts/test-onboarding-fixtures.sh" ;;
    retirement) python3 "$ROOT_DIR/scripts/test-agent-retirement.py" ;;
    detector) bash "$ROOT_DIR/scripts/test-detector-fixtures.sh" ;;
    path-policy) bash "$ROOT_DIR/scripts/test-path-policy.sh" ;;
    guard-race) bash "$ROOT_DIR/scripts/test-guard-concurrency.sh" ;;
    local-only) bash "$ROOT_DIR/scripts/test-local-only-mode.sh" ;;
  esac
}

selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ " ${CHECKS[*]} " == *" ${2:-} "* ]] || { echo "ERROR: unknown check: ${2:-}" >&2; usage >&2; exit 2; }
      selected+=("$2")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ ${#selected[@]} -gt 0 ]] || selected=("${CHECKS[@]}")

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-fast.XXXXXX")"
failed=()
for check in "${selected[@]}"; do
  start=$SECONDS
  if run_check "$check" >"$log_dir/$check.log" 2>&1; then
    printf 'PASS %-15s %3ss\n' "$check" "$((SECONDS - start))"
  else
    printf 'FAIL %-15s %3ss  log: %s\n' "$check" "$((SECONDS - start))" "$log_dir/$check.log"
    tail -5 "$log_dir/$check.log" | sed 's/^/     | /'
    failed+=("$check")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'fast tier: %d failed (%s)\n' "${#failed[@]}" "${failed[*]}"
  exit 1
fi
rm -rf "$log_dir"
printf 'fast tier: ok (%d checks); pull request CI runs the full tier\n' "${#selected[@]}"
