#!/usr/bin/env bash
set -euo pipefail

# The bash fast paths of the generator and detector path policies give the same
# verdict as the Python policy, and a preview snapshot spawns the same number of
# python3 processes whatever the size of ignored build trees (downstream report
# on 2026.10.13.1: hours for --status on a 157k-file Android checkout).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/path-policy-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'path-policy-test: FAIL: %s\n' "$*" >&2
  exit 1
}

target="$TMP_ROOT/policy"
outside="$TMP_ROOT/outside"
mkdir -p "$target/src/app" "$target/.agents/skills" "$target/.agents/state" "$target/build" \
  "$target/app/build/intermediates" "$target/name with space" "$target/.gradle-local/caches" "$outside"
touch "$target/src/app/Main.kt" "$target/.env.local" "$target/release.jks" "$target/.agents/skills/x.md" \
  "$target/.agents/state/s.json" "$target/local.properties" "$target/build/out.txt" \
  "$target/app/build/intermediates/x" "$target/name with space/a b.txt" "$target/key.pem.txt" "$outside/secret"
ln -s ../outside "$target/link-out"
ln -s "$outside/secret" "$target/secret-link"
ln -s src "$target/src-link"
ln -s build "$target/to-build"
ln -s "$target" "$TMP_ROOT/root-link"

paths=(
  "$target" "$target/" "$target/src/app/Main.kt" "$target/src/app/missing/deeper.kt" "$target/.env.local"
  "$target/release.jks" "$target/.agents/skills/x.md" "$target/.agents/state/s.json" "$target/.agents/state"
  "$target/.agents" "$target/local.properties" "$target/link-out" "$target/link-out/secret" "$target/secret-link"
  "$target/src-link/app/Main.kt" "$target/to-build/out.txt" "$target/app/build/intermediates/x"
  "$target/name with space/a b.txt" "$target/.gradle-local/caches" "$target/src/../src/app/Main.kt"
  "$target/./src" "$target//src" "src/app/Main.kt" "$outside/secret" "$target/out" "$target/outbound/x"
  "$target/Build/x" "$target/.agents/runtime" "$target/x/.agents/cache/y" "$target/key.pem.txt" "$target/a.key"
  "$target/.git/config" "$target/.tools/x" "$target/.idea/x" "$target/.next/x" "$target/web/node_modules/x"
  "$target/ios/Pods/x" "$target/vendor/x" "$target/web/dist/x" "$target/keystore.properties" "$target/a.keystore"
  "$target/a.pem" "$target/a.p8" "$target/.agents/runtime/x" "$target/.agents/runtimes/x" "$target/.gradle/x"
)

verdict() {
  if "$@"; then printf 'yes'; else printf 'no'; fi
}

# Generator policy (lib/core.sh): fast path vs. Python, and no process for the
# plain spellings.
(
  # shellcheck source=/dev/null
  source "$ROOT_DIR/agent-bootstrap/lib/core.sh"
  TARGET_DIR="$target"
  for path in "${paths[@]}"; do
    fast="$(verdict bootstrap_path_is_within_root "$path")"
    slow="$(verdict bootstrap_path_policy_python "$path")"
    [[ "$fast" == "$slow" ]] || fail "generator policy disagrees for $path: fast=$fast python=$slow"
  done
  spawns=0
  # shellcheck disable=SC2317,SC2329  # called indirectly by the policy functions
  python3() { spawns=$((spawns + 1)); command python3 "$@"; }
  bootstrap_path_is_within_root "$target/src/app/Main.kt"
  bootstrap_path_is_within_root "$target/app/build/intermediates/x" || true
  [[ "$spawns" -eq 0 ]] || fail "generator fast path spawned python3 $spawns time(s)"
) || exit 1

# Detector policy (agent-tech-stack-lib.sh), also with a root spelled through a
# link.
(
  # shellcheck source=/dev/null
  source "$ROOT_DIR/agent-bootstrap/agent-tech-stack-lib.sh"
  for root in "$target" "$TMP_ROOT/root-link"; do
    for path in "${paths[@]}"; do
      path="${path/#$target/$root}"
      fast="$(verdict agent_path_is_eligible "$root" "$path")"
      slow="$(verdict agent_path_policy_python "$root" "$path")"
      [[ "$fast" == "$slow" ]] || fail "detector policy disagrees for root=$root path=$path: fast=$fast python=$slow"
    done
  done
  spawns=0
  # shellcheck disable=SC2317,SC2329  # called indirectly by the policy functions
  python3() { spawns=$((spawns + 1)); command python3 "$@"; }
  agent_path_is_eligible "$target" "$target/src/app/Main.kt"
  [[ "$spawns" -eq 0 ]] || fail "detector fast path spawned python3 $spawns time(s)"
) || exit 1

# Snapshot cost does not grow with ignored build trees.
project="$TMP_ROOT/android"
mkdir -p "$project"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$project" --workflow full >/dev/null 2>&1
shim="$TMP_ROOT/shim"
mkdir -p "$shim"
# The shim counts python3 processes and records the snapshot copy list.
# shellcheck disable=SC2016  # the shim expands these at run time
printf '#!/bin/sh\nprintf x >> "$PYTHON_SPAWN_LOG"\nif [ -n "${AGENT_SNAPSHOT_DEST:-}" ]; then tee -a "$SNAPSHOT_COPY_LOG" | %s "$@"; exit $?; fi\nexec %s "$@"\n' \
  "$(command -v python3)" "$(command -v python3)" > "$shim/python3"
chmod +x "$shim/python3"

spawns_for() {
  local log="$TMP_ROOT/spawns.$1"
  shift
  : > "$log"
  : > "$TMP_ROOT/copied.list"
  PYTHON_SPAWN_LOG="$log" SNAPSHOT_COPY_LOG="$TMP_ROOT/copied.list" PATH="$shim:$PATH" \
    bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$project" "$@" \
    >/dev/null 2>"$TMP_ROOT/stderr.last" || fail "$* failed: $(tail -5 "$TMP_ROOT/stderr.last")"
  wc -c < "$log" | tr -d ' '
}

small_status="$(spawns_for small-status --status)"
small_plan="$(spawns_for small-plan --upgrade-plan --json)"
python3 - "$project" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for base in ("app/build/intermediates", "wear/build/tmp", ".gradle-local/caches/modules"):
    for index in range(2000):
        path = root / base / f"d{index % 40}" / f"f{index}.bin"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
PY
big_status="$(spawns_for big-status --status)"
[[ "$((big_status - small_status))" -le 2 ]] ||
  fail "--status python3 spawns grew with ignored files: $small_status -> $big_status"
big_plan="$(spawns_for big-plan --upgrade-plan --json)"
[[ "$((big_plan - small_plan))" -le 2 ]] ||
  fail "--upgrade-plan python3 spawns grew with ignored files: $small_plan -> $big_plan"
if grep -Eq 'omitted unsafe preview entry: .*/(build|\.gradle-local)/' "$TMP_ROOT/stderr.last"; then
  fail "ignored build trees must not be walked into preview warnings"
fi

# Personal and secret files never reach a snapshot under $TMPDIR.
personal=(.claude/settings.local.json app/google-services.json ios/Runner/GoogleService-Info.plist
  ios/Config/Secrets.xcconfig signing/release.p12 ios/App.mobileprovision docs/agent-configs/notes.local.md .npmrc)
for rel in "${personal[@]}"; do
  mkdir -p "$project/$(dirname "$rel")"
  printf 'PERSONAL-SENTINEL\n' > "$project/$rel"
done
spawns_for personal-plan --upgrade-plan --json >/dev/null
tr '\0' '\n' < "$TMP_ROOT/copied.list" > "$TMP_ROOT/copied.txt"
grep -qx 'AGENTS.md' "$TMP_ROOT/copied.txt" || fail "snapshot copy list was not observed"
for rel in "${personal[@]}"; do
  if grep -qxF "$rel" "$TMP_ROOT/copied.txt"; then
    fail "personal file copied into the snapshot: $rel"
  fi
done

printf 'path-policy-test: ok (status %s->%s, plan %s->%s python3 processes)\n' \
  "$small_status" "$big_status" "$small_plan" "$big_plan"
