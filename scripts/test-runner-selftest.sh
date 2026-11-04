#!/usr/bin/env bash
set -euo pipefail

# Self-test for scripts/test.sh on a fake suite table. It covers results and
# the failure summary, empty stdin for every suite, a real parallel batch,
# serial rows after the batch, and selection by tier, group and name.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNNER="$ROOT_DIR/scripts/test.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "runner-selftest: FAIL: $*" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

export RUNNER_SELFTEST_DIR="$work"
mkdir -p "$work/running"
# pair-a and pair-b wait for each other's marker, so they pass only when the
# batch runs them at the same time. `alone` (serial) must not overlap `slow`.
# xargs already gives batch rows an empty stdin; stdin-s checks serial rows.
# The quotes are meant for the runner's eval, not for this assignment.
# shellcheck disable=SC2016,SC2089
TEST_RUNNER_SUITES='
ok      fast g1 par    true
broken  fast g1 par    echo broken-output; false
stdin   fast g1 par    test -z "$(cat)"
stdin-s fast g1 serial test -z "$(cat)"
pair-a  fast g2 par    touch "$RUNNER_SELFTEST_DIR/a"; for i in $(seq 50); do [ -e "$RUNNER_SELFTEST_DIR/b" ] && exit 0; sleep 0.1; done; exit 1
pair-b  fast g2 par    touch "$RUNNER_SELFTEST_DIR/b"; for i in $(seq 50); do [ -e "$RUNNER_SELFTEST_DIR/a" ] && exit 0; sleep 0.1; done; exit 1
alone   fast g3 serial test ! -e "$RUNNER_SELFTEST_DIR/running/busy"
slow    full g3 par    touch "$RUNNER_SELFTEST_DIR/running/busy"; sleep 1; rm -f "$RUNNER_SELFTEST_DIR/running/busy"
sigint  full g4 par    python3 -I -S -c "import signal, sys; sys.exit(signal.getsignal(signal.SIGINT) == signal.SIG_IGN)"
'
# shellcheck disable=SC2090
export TEST_RUNNER_SUITES

# 1. Fast tier: results, failure summary, empty stdin, parallel pair.
rc=0
out="$(printf 'data on stdin\n' | bash "$RUNNER" -j 3 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "a failing suite must exit 1 (got $rc): $out"
for name in ok stdin stdin-s pair-a pair-b alone; do has "$out" "PASS $name" "fast tier"; done
has "$out" "FAIL broken" "fast tier"
has "$out" "broken-output" "failure tail"
has "$out" "1 of 7 failed (broken)" "summary"
lacks "$out" "slow" "full-tier row stays out of the fast tier"

# 2. A serial row runs after the parallel batch.
rc=0
out="$(bash "$RUNNER" --group g3 -j 2 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "group g3 must pass (got $rc): $out"
has "$out" "PASS slow" "group selects every tier"
has "$out" "PASS alone" "serial row"
[[ "${out%%PASS alone*}" == *"PASS slow"* ]] || fail "serial row ran before the batch finished: $out"
has "$out" "tests: ok (2 suites" "success summary"

# 3. --only, --list and --full.
out="$(bash "$RUNNER" --only ok 2>&1)"
has "$out" "PASS ok" "--only"
lacks "$out" "pair-a" "--only runs nothing else"
out="$(bash "$RUNNER" --list)"
has "$out" "pair-a" "--list"
has "$out" "full" "--list shows tiers"
rc=0
out="$(bash "$RUNNER" --full --only slow 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "--full --only slow must pass (got $rc): $out"
out="$(bash "$RUNNER" --group g2 --skip pair-b 2>&1)" || true
lacks "$out" "pair-b" "--skip leaves the suite out"

# 4. A runner started with SIGINT ignored (as `cmd &` does) gives suites the default.
rc=0
out="$( (trap '' INT; bash "$RUNNER" --only sigint) 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "suites must get the default SIGINT (got $rc): $out"

# 5. Usage errors exit 2 and run nothing.
for args in "--only nope" "--group nope" "--skip nope" "--bogus" "-j 0" "-j x"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$RUNNER" $args >"$work/usage.out" 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "'$args' must exit 2 (got $rc): $(cat "$work/usage.out")"
done
echo "runner-selftest: ok"
