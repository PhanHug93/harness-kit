#!/usr/bin/env bash
set -euo pipefail

# The agentmemory version check reads package.json and never runs agentmemory;
# it prints one line only when the installed copy is older than the tested
# version or unreadable, and never changes an exit status. The Codex doctor
# relays the line; the docs name the same version.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERIFY="$ROOT_DIR/agent-bootstrap/verify-ai-deps.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentmemory-check.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() {
  printf 'agentmemory-check-test: FAIL: %s\n' "$*" >&2
  exit 1
}

tested="$(sed -n 's/^AGENTMEMORY_TESTED="\(.*\)"$/\1/p' "$VERIFY")"
[[ -n "$tested" ]] || fail "AGENTMEMORY_TESTED missing in the verifier"
mkdir -p "$TMP_ROOT/py"
ln -s "$(command -v python3)" "$TMP_ROOT/py/python3"

# fake_install NAME VERSION [PACKAGE-NAME]: an npm global layout whose command
# leaves a marker if anything runs it.
fake_install() {
  local dir="$TMP_ROOT/$1" pkg="$TMP_ROOT/$1/lib/node_modules/@agentmemory/agentmemory"
  mkdir -p "$pkg/dist" "$dir/bin"
  printf '{"name": "%s", "version": "%s"}\n' "${3:-@agentmemory/agentmemory}" "$2" >"$pkg/package.json"
  printf '#!/bin/sh\ntouch "%s/ran"\n' "$TMP_ROOT" >"$pkg/dist/cli.mjs"
  chmod +x "$pkg/dist/cli.mjs"
  ln -s ../lib/node_modules/@agentmemory/agentmemory/dist/cli.mjs "$dir/bin/agentmemory"
}
check() { # BIN-DIR, or "" for no agentmemory on PATH
  local out rc=0
  out="$(PATH="${1:+$1:}$TMP_ROOT/py:/usr/bin:/bin" bash "$VERIFY" --agentmemory)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "--agentmemory exited $rc"
  printf '%s' "$out"
}

fake_install old 0.9.21
line="$(check "$TMP_ROOT/old/bin")"
want="agentmemory 0.9.21 is older than the version this kit was tested with ($tested): stop it,"
want+=" npm install -g @agentmemory/agentmemory@$tested, start it, then re-run agentmemory connect claude-code"
want+=" --with-hooks and agentmemory connect codex --with-hooks."
[[ "$line" == "$want" ]] || fail "old version line: $line"
fake_install same "$tested"
[[ -z "$(check "$TMP_ROOT/same/bin")" ]] || fail "the tested version printed a line"
fake_install newer 0.10.0
[[ -z "$(check "$TMP_ROOT/newer/bin")" ]] || fail "a newer version printed a line"
fake_install build "$tested+build.7"
[[ -z "$(check "$TMP_ROOT/build/bin")" ]] || fail "build metadata printed a line"
fake_install pre "$tested-beta.1"
[[ "$(check "$TMP_ROOT/pre/bin")" == "agentmemory $tested-beta.1 is older than"* ]] ||
  fail "a prerelease of the tested version printed no line"
[[ -z "$(check "")" ]] || fail "no agentmemory printed a line"
fake_install other 9.9.9 some-other-package
[[ "$(check "$TMP_ROOT/other/bin")" == "agentmemory: could not read its version; this kit was tested with $tested:"* ]] ||
  fail "an unreadable version printed no line"
[[ ! -e "$TMP_ROOT/ran" ]] || fail "the check ran agentmemory"

# The docs name the same version.
grep -Fq "@agentmemory/agentmemory@$tested" "$ROOT_DIR/README.md" || fail "README installs another version"
grep -Fq "(this one: \`$tested\`)" "$ROOT_DIR/README.md" || fail "README names another tested version"
grep -Fq "agentmemory $tested" "$ROOT_DIR/agent-bootstrap/lib/writers-docs.sh" || fail "the skill names another version"

# The doctor relays the line as a warning; its exit status does not change.
target="$TMP_ROOT/plain-full"
mkdir -p "$target"
git -C "$target" init -q
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null 2>&1 ||
  fail "generation failed"
rc_same=0
rc_old=0
(cd "$target" && PATH="$TMP_ROOT/same/bin:$PATH" bash .codex/codex-mode.sh doctor) >"$TMP_ROOT/doctor-same.out" 2>&1 || rc_same=$?
(cd "$target" && PATH="$TMP_ROOT/old/bin:$PATH" bash .codex/codex-mode.sh doctor) >"$TMP_ROOT/doctor-old.out" 2>&1 || rc_old=$?
[[ "$rc_same" -eq "$rc_old" ]] || fail "doctor exit changed: $rc_same with the tested version, $rc_old with an old one"
grep -Fq "WARN  agentmemory 0.9.21 is older" "$TMP_ROOT/doctor-old.out" || fail "doctor did not relay the line"
if grep -Fq "is older than the version this kit was tested with" "$TMP_ROOT/doctor-same.out"; then
  fail "doctor warned for the tested version"
fi
[[ ! -e "$TMP_ROOT/ran" ]] || fail "the doctor ran agentmemory"
printf 'agentmemory-check-test: ok\n'
