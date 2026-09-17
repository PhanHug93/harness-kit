#!/usr/bin/env bash
set -euo pipefail

# Upgrade behaviour with a harness baseline: unmodified files update in place,
# local edits merge with kit changes, overlapping edits become candidates,
# --upgrade-plan --json predicts all of it without writing, and --rollback
# undoes an upgrade. "Kit v2" is a copy of the bundle with edited templates.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/upgrade-merge-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'upgrade-merge-test: FAIL: %s\n' "$*" >&2
  exit 1
}

need_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"
}

need_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"
}

KIT_V1="$ROOT_DIR/agent-bootstrap"
KIT_V2="$TMP_ROOT/kit-v2"
cp -R "$KIT_V1" "$KIT_V2"
TEMPLATES=docs/agent-configs/bootstrap-multi-agent-project/templates
MERGE_REL="$TEMPLATES/base/README.md"
CONFLICT_REL="$TEMPLATES/overlays/generic.md"
UPDATE_REL="$TEMPLATES/overlays/python.md"
BASELINE=.tools/agent-state/harness-baseline/files
printf '\nKit v2 note.\n' >> "$KIT_V2/templates/base/README.md"
printf '\nKit v2 generic.\n' >> "$KIT_V2/templates/overlays/generic.md"
printf '\nKit v2 python.\n' >> "$KIT_V2/templates/overlays/python.md"

generate() {
  local kit="$1" target="$2"
  shift 2
  bash "$kit/bootstrap-multi-agent-project.sh" --target "$target" --workflow full "$@" 2>&1
}

tree_digest() {
  (cd "$1" && find . -path ./.tools -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256) | shasum -a 256
}

upgrade_id() {
  printf '%s\n' "$1" | sed -n 's/^Upgrade id: \([0-9-]*\) .*/\1/p' | tail -n1
}

target="$TMP_ROOT/target"
mkdir -p "$target"
generate "$KIT_V1" "$target" >/dev/null
[[ -f "$target/$BASELINE/$MERGE_REL" ]] || fail "generation must record a baseline"
rerun_out="$(generate "$KIT_V1" "$target")"
need_contains "$rerun_out" "Existing file up to date: $target/scripts/agent-hook.sh" "unchanged preset hook is up to date"
[[ -z "$(find "$target/scripts" -name 'agent-hook.sh.*' -print -quit)" ]] ||
  fail "an unchanged preset hook must not leave candidates or backups"

# Local edits: one above the kit change (mergeable), one at the same place
# (conflict), and one in a file the kit does not change (kept).
v1_update="$(cat "$target/$UPDATE_REL")"
printf 'Local note.\n%s\n' "$(cat "$target/$MERGE_REL")" > "$target/$MERGE_REL"
local_merge="$(cat "$target/$MERGE_REL")"
printf '\nLocal generic.\n' >> "$target/$CONFLICT_REL"
local_conflict="$(cat "$target/$CONFLICT_REL")"
printf '\nuser drift\n' >> "$target/AGENTS.md"

before="$(tree_digest "$target")"
plan="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$target" --upgrade-plan --json)"
[[ "$(tree_digest "$target")" == "$before" ]] || fail "--upgrade-plan --json must not change the target"
python3 - "$plan" "$MERGE_REL" "$CONFLICT_REL" "$UPDATE_REL" <<'PY' || fail "upgrade plan classifies files: $plan"
import json, sys
plan = json.loads(sys.argv[1])
actions = {item["path"]: item["action"] for item in plan["files"]}
expected = {sys.argv[2]: "merge", sys.argv[3]: "conflict", sys.argv[4]: "update", "AGENTS.md": "kept"}
assert plan["schema"] == "agent-bootstrap-upgrade-plan/v1", plan["schema"]
assert plan["baseline"] == "present", plan["baseline"]
for path, action in expected.items():
    assert actions.get(path) == action, (path, actions.get(path), action)
PY

upgrade_out="$(generate "$KIT_V2" "$target")"
id="$(upgrade_id "$upgrade_out")"
[[ -n "$id" ]] || fail "upgrade must print its id: $upgrade_out"
need_contains "$upgrade_out" "Merged kit changes into local edits: $target/$MERGE_REL" "merge log"
need_contains "$upgrade_out" "Updated unmodified file: $target/$UPDATE_REL" "update log"
need_contains "$upgrade_out" "Kept local edits (kit output unchanged): $target/AGENTS.md" "kept log"
merged="$(cat "$target/$MERGE_REL")"
need_contains "$merged" "Local note." "merge keeps the local edit"
need_contains "$merged" "Kit v2 note." "merge brings the kit change"
need_contains "$(cat "$target/$UPDATE_REL")" "Kit v2 python." "unmodified file is updated in place"
[[ "$(cat "$target/$CONFLICT_REL")" == "$local_conflict" ]] || fail "conflicting file must keep local content"
[[ -n "$(find "$target/$TEMPLATES/overlays" -name 'generic.md.generated.*' -print -quit)" ]] ||
  fail "conflict must produce a candidate"
for rel in "$MERGE_REL" "$UPDATE_REL" AGENTS.md; do
  [[ -z "$(find "$target" -path "$target/.tools" -prune -o -path "$target/$rel.generated.*" -print -quit)" ]] ||
    fail "$rel must not produce a candidate"
done
need_contains "$(cat "$target/AGENTS.md")" "user drift" "kept file keeps local edits"
need_contains "$(cat "$target/$BASELINE/$MERGE_REL")" "Kit v2 note." "baseline follows the merged kit output"
need_not_contains "$(cat "$target/$BASELINE/$MERGE_REL")" "Local note." "baseline stores kit output only"

# Rollback restores the pre-upgrade files and baseline, once.
rollback_out="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$target" --rollback "$id")" ||
  fail "rollback failed: $rollback_out"
[[ "$(cat "$target/$MERGE_REL")" == "$local_merge" ]] || fail "rollback must restore the locally edited file"
[[ "$(cat "$target/$UPDATE_REL")" == "$v1_update" ]] || fail "rollback must restore the updated file"
[[ -z "$(find "$target/$TEMPLATES/overlays" -name 'generic.md.generated.*' -print -quit)" ]] ||
  fail "rollback must remove the candidate it created"
need_not_contains "$(cat "$target/$BASELINE/$MERGE_REL")" "Kit v2 note." "rollback restores the baseline"
if bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$target" --rollback "$id" >/dev/null 2>&1; then
  fail "a second rollback of the same upgrade must be refused"
fi
if bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$target" --rollback 19990101-000000 >/dev/null 2>&1; then
  fail "rollback of an unknown id must fail"
fi

# A file edited after the upgrade is kept by rollback (exit 3).
sleep 1
upgrade_out="$(generate "$KIT_V2" "$target")"
id="$(upgrade_id "$upgrade_out")"
printf '\nedited after upgrade\n' >> "$target/$UPDATE_REL"
set +e
partial_out="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$target" --rollback "$id" 2>&1)"
partial_rc=$?
set -e
[[ "$partial_rc" == 3 ]] || fail "partial rollback must exit 3, got $partial_rc: $partial_out"
need_contains "$partial_out" "kept $UPDATE_REL: changed after the upgrade" "partial rollback names the kept file"
need_contains "$(cat "$target/$UPDATE_REL")" "edited after upgrade" "partial rollback keeps later edits"

# Legacy target without a baseline keeps the candidate flow; applying the
# candidate adopts it as the baseline.
legacy="$TMP_ROOT/legacy"
mkdir -p "$legacy"
generate "$KIT_V1" "$legacy" >/dev/null
rm -rf "$legacy/.tools/agent-state/harness-baseline"
generate "$KIT_V2" "$legacy" >/dev/null
[[ "$(cat "$legacy/$UPDATE_REL")" == "$v1_update" ]] || fail "without a baseline an existing file is not overwritten"
[[ -n "$(find "$legacy/$TEMPLATES/overlays" -name 'python.md.generated.*' -print -quit)" ]] ||
  fail "without a baseline a changed file becomes a candidate"
bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$legacy" --apply-candidates --only "$UPDATE_REL" >/dev/null
cmp -s "$legacy/$UPDATE_REL" "$legacy/$BASELINE/$UPDATE_REL" || fail "applied candidate must become the baseline"

# A linked baseline directory is never read or written through.
linked="$TMP_ROOT/linked"
outside="$TMP_ROOT/outside-baseline"
mkdir -p "$linked"
generate "$KIT_V1" "$linked" >/dev/null
mv "$linked/$BASELINE" "$outside"
printf 'OUTSIDE-BASELINE-SENTINEL\n' > "$outside/$UPDATE_REL"
outside_before="$(cd "$outside" && find . -type f -print | LC_ALL=C sort | xargs shasum -a 256)"
ln -s "$outside" "$linked/$BASELINE"
linked_out="$(generate "$KIT_V2" "$linked")"
need_contains "$linked_out" "refusing unsafe harness state path" "linked baseline is refused"
[[ "$(cd "$outside" && find . -type f -print | LC_ALL=C sort | xargs shasum -a 256)" == "$outside_before" ]] ||
  fail "a linked baseline must not be written through"
need_not_contains "$(cat "$linked/$UPDATE_REL")" "OUTSIDE-BASELINE-SENTINEL" "linked baseline content stays unread"

printf 'upgrade-merge-test: ok\n'
