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

# No overwrite: plain --apply-candidates keeps a locally edited file, --only
# replaces it, --keep pins it, and the JSON plan carries the three hashes.
sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}
need_contains "$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --help)" "--keep PATH" "usage lists --keep"
GONE_REL="$TEMPLATES/overlays/node_js.md"
guard="$TMP_ROOT/guard"
mkdir -p "$guard"
generate "$KIT_V1" "$guard" >/dev/null
printf '\nLocal generic.\n' >> "$guard/$CONFLICT_REL"
cp "$guard/$CONFLICT_REL" "$TMP_ROOT/guard-local"
v1_update_sha="$(sha_of "$guard/$UPDATE_REL")"
v1_conflict_sha="$(sha_of "$guard/$BASELINE/$CONFLICT_REL")"
v1_gone_sha="$(sha_of "$guard/$BASELINE/$GONE_REL")"
rm "$guard/$GONE_REL"
plan="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$guard" --upgrade-plan --json)"
generate "$KIT_V2" "$guard" >/dev/null
candidate="$(find "$guard/$TEMPLATES/overlays" -name 'generic.md.generated.*' -print | LC_ALL=C sort | tail -n1)"
[[ -n "$candidate" ]] || fail "an edited file with a conflicting kit change must get a candidate"
cp "$candidate" "$TMP_ROOT/guard-candidate"
python3 - "$plan" "$UPDATE_REL" "$CONFLICT_REL" "$GONE_REL" \
  "$v1_update_sha" "$(sha_of "$guard/$UPDATE_REL")" \
  "$v1_conflict_sha" "$(sha_of "$TMP_ROOT/guard-local")" "$(sha_of "$candidate")" \
  "$v1_gone_sha" "$(sha_of "$guard/$GONE_REL")" <<'PY' || fail "upgrade plan JSON carries the three hashes: $plan"
import json, re, sys
plan = json.loads(sys.argv[1])
files = {item["path"]: item for item in plan["files"]}
update, conflict, gone = sys.argv[2:5]
v1_update, v2_update, v1_conflict, local_conflict, candidate, v1_gone, v2_gone = sys.argv[5:12]
def hashes(rel):
    item = files[rel]
    return item["baseline_sha256"], item["local_sha256"], item["new_sha256"]
assert files[update]["action"] == "update", files[update]
assert hashes(update) == (v1_update, v1_update, v2_update), hashes(update)
assert files[conflict]["action"] == "conflict", files[conflict]
assert hashes(conflict) == (v1_conflict, local_conflict, candidate), hashes(conflict)
assert files[gone]["action"] == "create", files[gone]
assert hashes(gone) == (v1_gone, None, v2_gone), hashes(gone)
for item in plan["files"]:
    for key in ("baseline_sha256", "local_sha256", "new_sha256"):
        assert item[key] is None or re.fullmatch("[0-9a-f]{64}", item[key]), (item, key)
PY

printf 'Kit candidate for an unedited file.\n' > "$guard/$UPDATE_REL.generated.20990101-000000"
apply_out="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$guard" --apply-candidates)"
need_contains "$apply_out" "kept local edits: $CONFLICT_REL (name it with --only to replace)" "plain apply names the edited file"
cmp -s "$guard/$CONFLICT_REL" "$TMP_ROOT/guard-local" || fail "plain --apply-candidates must keep a locally edited file"
cmp -s "$candidate" "$TMP_ROOT/guard-candidate" || fail "plain --apply-candidates must keep the candidate of an edited file"
need_contains "$apply_out" "Applied generated candidate $UPDATE_REL.generated.20990101-000000 -> $UPDATE_REL" \
  "plain apply still replaces a file equal to its baseline"
[[ "$(cat "$guard/$UPDATE_REL")" == "Kit candidate for an unedited file." ]] || fail "unedited file must take its candidate"

bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$guard" --apply-candidates --only "$CONFLICT_REL" >/dev/null
cmp -s "$guard/$CONFLICT_REL" "$TMP_ROOT/guard-candidate" || fail "--only must replace the named edited file"
[[ ! -e "$candidate" ]] || fail "--only must consume the candidate"
backup="$(find "$guard/$TEMPLATES/overlays" -name 'generic.md.bak.*' -print | LC_ALL=C sort | tail -n1)"
[[ -n "$backup" ]] || fail "--only must keep a backup"
cmp -s "$backup" "$TMP_ROOT/guard-local" || fail "the --only backup must hold the local file"

# A pin: kit v1 would change the file again, but --keep leaves it, its
# baseline and its candidates alone in plans, previews and generation.
printf '\nPinned local.\n' >> "$guard/$CONFLICT_REL"
cp "$guard/$CONFLICT_REL" "$TMP_ROOT/guard-pinned"
cp "$guard/$BASELINE/$CONFLICT_REL" "$TMP_ROOT/guard-pinned-base"
keep_plan="$(bash "$KIT_V1/bootstrap-multi-agent-project.sh" --target "$guard" --upgrade-plan --json --keep "./$CONFLICT_REL")"
python3 - "$keep_plan" "$CONFLICT_REL" "$(sha_of "$TMP_ROOT/guard-pinned")" <<'PY' || fail "JSON plan classifies a pinned file: $keep_plan"
import json, sys
plan = json.loads(sys.argv[1])
item = {entry["path"]: entry for entry in plan["files"]}[sys.argv[2]]
assert item["action"] == "pinned", item
assert item["local_sha256"] == sys.argv[3], item
assert plan["counts"].get("pinned") == 1, plan["counts"]
PY
need_contains "$(bash "$KIT_V1/bootstrap-multi-agent-project.sh" --target "$guard" --upgrade-plan --keep "$CONFLICT_REL")" \
  "pinned $CONFLICT_REL" "text plan lists the pinned file"
need_not_contains "$(bash "$KIT_V1/bootstrap-multi-agent-project.sh" --target "$guard" --diff --keep "$CONFLICT_REL")" \
  "--- $CONFLICT_REL" "diff leaves a pinned file out"
generate "$KIT_V1" "$guard" --keep "$CONFLICT_REL" >/dev/null
cmp -s "$guard/$CONFLICT_REL" "$TMP_ROOT/guard-pinned" || fail "--keep must leave the file byte-identical"
[[ -z "$(find "$guard/$TEMPLATES/overlays" -name 'generic.md.generated.*' -print -quit)" ]] ||
  fail "--keep must not write a candidate"
cmp -s "$guard/$BASELINE/$CONFLICT_REL" "$TMP_ROOT/guard-pinned-base" || fail "--keep must leave the baseline alone"
if bash "$KIT_V1/bootstrap-multi-agent-project.sh" --target "$guard" --upgrade-plan --keep ../outside >/dev/null 2>&1; then
  fail "--keep must refuse a path outside the target"
fi

# The lock is machine state: without a baseline a changed lock is rewritten in
# place (with its backup), never left behind as a candidate.
LOCK_REL=docs/agent-configs/agent-bootstrap.lock.json
lockless="$TMP_ROOT/lockless"
mkdir -p "$lockless"
generate "$KIT_V1" "$lockless" >/dev/null
rm -rf "${lockless:?}/.tools/agent-state/harness-baseline"
python3 -B - "$lockless/$LOCK_REL" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
doc["version"] = "1900.01.01.0"
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
generate "$KIT_V1" "$lockless" >/dev/null
[[ -z "$(find "$lockless/docs/agent-configs" -name 'agent-bootstrap.lock.json.generated.*' -print -quit)" ]] ||
  fail "a changed lock without a baseline must not become a candidate"
need_contains "$(cat "$lockless/$LOCK_REL")" "\"version\": \"$(sed -n '1p' "$KIT_V1/VERSION")\"" "the lock is rewritten to the kit version"
[[ -n "$(find "$lockless/docs/agent-configs" -name 'agent-bootstrap.lock.json.bak.*' -print -quit)" ]] ||
  fail "the rewritten lock keeps its backup"

# An edited JSON output whose kit output did not change is kept: no candidate,
# the local edit stays, and the plan says kept.
SETTINGS_REL=.claude/settings.json
jsonkept="$TMP_ROOT/json-kept"
mkdir -p "$jsonkept"
generate "$KIT_V1" "$jsonkept" >/dev/null
python3 -B - "$jsonkept/$SETTINGS_REL" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
doc["localSetting"] = True
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
cp "$jsonkept/$SETTINGS_REL" "$TMP_ROOT/settings-local"
plan="$(bash "$KIT_V1/bootstrap-multi-agent-project.sh" --target "$jsonkept" --upgrade-plan --json)"
python3 - "$plan" "$SETTINGS_REL" <<'PY' || fail "an edited JSON file with unchanged kit output is planned as kept: $plan"
import json, sys
item = {entry["path"]: entry for entry in json.loads(sys.argv[1])["files"]}[sys.argv[2]]
assert item["action"] == "kept", item
PY
kept_out="$(generate "$KIT_V1" "$jsonkept")"
need_contains "$kept_out" "Kept local edits (kit output unchanged): $jsonkept/$SETTINGS_REL" "JSON kept log"
[[ -z "$(find "$jsonkept/.claude" -name 'settings.json.generated.*' -print -quit)" ]] ||
  fail "an edited JSON file with unchanged kit output must not get a candidate"
cmp -s "$jsonkept/$SETTINGS_REL" "$TMP_ROOT/settings-local" || fail "the kept JSON file keeps its local edit"

# The local-only ignore block follows the kit: a stale block in the exclude
# file is refreshed in place (lines around it untouched, a current block is
# not rewritten); a stale block in the tracked .gitignore stays as it is while
# the exclude file gains the current block, unless --ignore-target gitignore
# --force asks for the refresh.
drop_kit_line() {
  python3 -B - "$1" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
out = [line for line in lines if not line.rstrip("\n").endswith("scripts/harness-kit.sh")]
assert len(out) == len(lines) - 1, "expected one scripts/harness-kit.sh entry"
open(path, "w", encoding="utf-8").write("".join(out))
PY
}
exclude_of() {
  local path
  path="$(git -C "$1" rev-parse --git-path info/exclude)"
  case "$path" in /*) printf '%s\n' "$path" ;; *) printf '%s/%s\n' "$1" "$path" ;; esac
}
ignore_repo="$TMP_ROOT/ignore-repo"
mkdir -p "$ignore_repo/apps/a"
git -C "$ignore_repo" init -q
exclude="$(exclude_of "$ignore_repo")"
for ignore_target in "$ignore_repo" "$ignore_repo/apps/a"; do
  generate "$KIT_V1" "$ignore_target" >/dev/null
done
cp "$exclude" "$TMP_ROOT/exclude-current"
printf 'user-before\n' > "$TMP_ROOT/exclude-stale"
cat "$exclude" >> "$TMP_ROOT/exclude-stale"
printf 'user-after\n' >> "$TMP_ROOT/exclude-stale"
cp "$TMP_ROOT/exclude-stale" "$exclude"
python3 -B - "$exclude" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
out = [line for line in lines if not line.rstrip("\n").endswith("scripts/harness-kit.sh")]
assert len(out) == len(lines) - 2, "expected the entry in both blocks"
open(path, "w", encoding="utf-8").write("".join(out))
PY
for ignore_target in "$ignore_repo" "$ignore_repo/apps/a"; do
  generate "$KIT_V1" "$ignore_target" >/dev/null
done
cmp -s "$exclude" "$TMP_ROOT/exclude-stale" || fail "stale exclude blocks must be refreshed in place: $(diff "$TMP_ROOT/exclude-stale" "$exclude")"
for ignore_target in "$ignore_repo" "$ignore_repo/apps/a"; do
  generate "$KIT_V1" "$ignore_target" >/dev/null
done
cmp -s "$exclude" "$TMP_ROOT/exclude-stale" || fail "a current exclude block must not be rewritten"

gitignored="$TMP_ROOT/gitignored"
mkdir -p "$gitignored"
git -C "$gitignored" init -q
git -C "$gitignored" config user.email t@example.invalid
git -C "$gitignored" config user.name t
printf 'node_modules/\n' > "$gitignored/.gitignore"
generate "$KIT_V1" "$gitignored" --ignore-target gitignore --force --no-backup >/dev/null
drop_kit_line "$gitignored/.gitignore"
git -C "$gitignored" add .gitignore
git -C "$gitignored" commit -q -m seed
printf '#!/bin/sh\n' > "$gitignored/scripts/harness-kit.sh"
need_contains "$(git -C "$gitignored" status --porcelain -uall)" "scripts/harness-kit.sh" "fixture: the stale block misses the new kit file"
cp "$gitignored/.gitignore" "$TMP_ROOT/gitignore-stale"
generate "$KIT_V1" "$gitignored" >/dev/null
cmp -s "$gitignored/.gitignore" "$TMP_ROOT/gitignore-stale" || fail "a stale tracked .gitignore block must not be rewritten implicitly"
grep -Fxq 'scripts/harness-kit.sh' "$(exclude_of "$gitignored")" || fail "the exclude file must gain the current block"
[[ -z "$(git -C "$gitignored" status --porcelain -uall)" ]] || fail "harness files must stay ignored: $(git -C "$gitignored" status --porcelain -uall)"
generate "$KIT_V1" "$gitignored" --ignore-target gitignore --force >/dev/null
grep -Fxq 'scripts/harness-kit.sh' "$gitignored/.gitignore" || fail "--ignore-target gitignore --force must refresh the .gitignore block"
need_contains "$(head -n1 "$gitignored/.gitignore")" "node_modules/" "the refresh keeps the user's lines"
[[ -n "$(find "$gitignored" -maxdepth 1 -name '.gitignore.bak.*' -print -quit)" ]] || fail "the .gitignore refresh keeps a backup"

# Two calls under one stamp (an apply run, then --apply-candidates --only for
# a take-kit) share one journal: the first pre-image of every file wins, so
# --rollback restores the content from before the first call.
STAMP_S=20990103-040506
shared="$TMP_ROOT/shared-stamp"
mkdir -p "$shared"
generate "$KIT_V1" "$shared" >/dev/null
printf 'Local note.\n%s\n' "$(cat "$shared/$MERGE_REL")" > "$shared/$MERGE_REL"
printf '\nLocal generic.\n' >> "$shared/$CONFLICT_REL"
cp "$shared/$MERGE_REL" "$TMP_ROOT/shared-merge-local"
cp "$shared/$CONFLICT_REL" "$TMP_ROOT/shared-conflict-local"
AGENT_BOOTSTRAP_STAMP="$STAMP_S" generate "$KIT_V2" "$shared" >/dev/null
need_contains "$(cat "$shared/$MERGE_REL")" "Kit v2 note." "fixture: the first call merges"
[[ -f "$shared/$CONFLICT_REL.generated.$STAMP_S" ]] || fail "fixture: the first call writes a conflict candidate"
cp "$KIT_V2/templates/base/README.md" "$shared/$MERGE_REL.generated.$STAMP_S"
AGENT_BOOTSTRAP_STAMP="$STAMP_S" bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$shared" --apply-candidates \
  --only "$MERGE_REL" --only "$CONFLICT_REL" >/dev/null
cmp -s "$shared/$MERGE_REL.bak.$STAMP_S" "$TMP_ROOT/shared-merge-local" || fail "the first backup under a stamp must win"
shared_rollback="$(bash "$KIT_V2/bootstrap-multi-agent-project.sh" --target "$shared" --rollback "$STAMP_S" 2>&1)" ||
  fail "rollback of a two-call stamp must succeed: $shared_rollback"
cmp -s "$shared/$MERGE_REL" "$TMP_ROOT/shared-merge-local" || fail "rollback must restore the pre-run merged file: $shared_rollback"
cmp -s "$shared/$CONFLICT_REL" "$TMP_ROOT/shared-conflict-local" || fail "rollback must restore the pre-run conflicting file: $shared_rollback"

printf 'upgrade-merge-test: ok\n'
