#!/usr/bin/env bash
set -euo pipefail

# One-shot previews (--status, --diff, --upgrade-plan) stage only the harness's
# own files: the generated outputs (inventoried by one --dry-run on the real
# tree), the user-owned files and the harness data files. Project sources and
# personal files never reach $TMPDIR, detection reads the real tree, and a
# --dry-run leaves the target byte-identical. The second part runs the one-shot
# orchestrator (harness-kit-run.sh) offline through the entry script: install,
# reinstall, --reset/--rollback, pins, updates from a historical bundle,
# migration decisions and the edge cases of the design's Verification table.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/oneshot-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
BOOTSTRAP="$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh"

fail() {
  printf 'oneshot-test: FAIL: %s\n' "$*" >&2
  exit 1
}

# Every entry with its type, mode and content hash (symlinks by target).
tree_state() {
  python3 -B - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
for base, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(dirs + files):
        path = os.path.join(base, name)
        info = os.lstat(path)
        rel = os.path.relpath(path, root)
        if stat.S_ISLNK(info.st_mode):
            print("L", rel, os.readlink(path))
        elif stat.S_ISDIR(info.st_mode):
            print("D", rel, oct(info.st_mode))
        else:
            with open(path, "rb") as handle:
                print("F", rel, oct(info.st_mode), hashlib.sha256(handle.read()).hexdigest())
PY
}

# Case 8/9 fixture: personal files and a sizeable source tree.
proj="$TMP_ROOT/a6"; mkdir -p "$proj"; git -C "$proj" init -q
printf '{"name":"x"}\n' > "$proj/package.json"
printf 'SECRET=a6-sentinel-env\n' > "$proj/.env"
printf '{"mcpServers":{"a6-sentinel-mcp":{}}}\n' > "$proj/.mcp.json"
printf 'A6_SENTINEL_XC = 1\n' > "$proj/x.xcconfig"
mkdir -p "$proj/src"; for i in $(seq 1 200); do printf 'x\n' > "$proj/src/f$i.js"; done
bash "$BOOTSTRAP" --target "$proj" --workflow full >/dev/null 2>&1
export TMPDIR="$TMP_ROOT/private-tmp"; mkdir -p "$TMPDIR"

# 8 personal files never reach staging; the plan generates at most twice
# (inventory dry-run + staging generation).
trace="$TMP_ROOT/trace"; : > "$trace"
AGENT_BOOTSTRAP_TRACE_FILE="$trace" AGENT_BOOTSTRAP_KEEP_STAGING=1 bash "$BOOTSTRAP" --target "$proj" --upgrade-plan --json \
  >"$TMP_ROOT/plan.json" 2>"$TMP_ROOT/plan.err" || fail "upgrade plan failed: $(tail -5 "$TMP_ROOT/plan.err")"
staging="$(sed -n 's/^agent-bootstrap: kept staging //p' "$TMP_ROOT/plan.err" | head -1)"
[[ -n "$staging" && -f "$staging/AGENTS.md" ]] || fail "kept staging directory was not reported: $(cat "$TMP_ROOT/plan.err")"
grep -rl 'a6-sentinel' "$TMPDIR" 2>/dev/null && fail "personal files must never reach staging"
for rel in .env .mcp.json x.xcconfig; do
  [[ ! -e "$staging/$rel" ]] || fail "personal file staged: $rel"
done
generations="$(grep -c '^generate' "$trace" || true)"
[[ "$generations" -ge 1 && "$generations" -le 2 ]] ||
  fail "upgrade plan must generate at most twice (inventory dry-run + staging): $generations"

# 9 staging copies the harness files, not the project sources.
seeded="$(sed -n 's/^seed //p' "$trace" | head -1)"
[[ -n "$seeded" ]] || fail "staging seed was not traced: $(cat "$trace")"
[[ "$seeded" -lt 200 ]] || fail "staging must not copy project sources ($seeded)"
[[ ! -e "$staging/src" ]] || fail "project sources reached staging"
rm -rf "$(dirname "$staging")"

# 10 a freshly generated target is clean; status seeds staging once and
# generates at most twice.
: > "$trace"
status_json="$(AGENT_BOOTSTRAP_TRACE_FILE="$trace" bash "$BOOTSTRAP" --target "$proj" --status --json 2>/dev/null)" ||
  fail "status failed"
[[ "$status_json" == *'"generated_file_drift":"clean"'* ]] || fail "fresh target must report no drift: $status_json"
[[ "$status_json" == *'"pending_generated_candidates":0'* ]] || fail "fresh target has no candidates: $status_json"
generations="$(grep -c '^generate' "$trace" || true)"
[[ "$generations" -le 2 ]] || fail "status must generate at most twice: $generations"
[[ "$(grep -c '^seed' "$trace" || true)" -eq 1 ]] || fail "status must seed staging once: $(cat "$trace")"

# 11 --diff on a fresh target is empty, also when $TMPDIR ends in a slash (as
# on macOS), which must not leak the staging path into the output.
diff_out="$(TMPDIR="$TMPDIR/" bash "$BOOTSTRAP" --target "$proj" --diff 2>/dev/null)" || fail "diff failed"
[[ "$diff_out" == *"No generated-file differences."* ]] || fail "fresh target diff must be empty: $diff_out"
if printf '%s\n' "$diff_out" | grep -q '^--- '; then
  fail "fresh target diff lists files: $diff_out"
fi

# 12 detection reads the real tree: the local.properties warning, which the
# staged copy never holds, appears in previews as in a real generation.
android="$TMP_ROOT/android"; mkdir -p "$android/app"; git -C "$android" init -q
printf 'rootProject.name = "a"\ninclude(":app")\n' > "$android/settings.gradle.kts"
printf 'plugins { id("com.android.application") }\n' > "$android/app/build.gradle.kts"
printf 'sdk.dir=/nowhere\n' > "$android/local.properties"
bash "$BOOTSTRAP" --target "$android" --workflow full >/dev/null 2>&1
grep -q 'local.properties exists' "$android/docs/agent-configs/agent-bootstrap.lock.json" ||
  fail "fixture: a real generation must record the local.properties warning"
diff_out="$(AGENT_BOOTSTRAP_KEEP_STAGING=1 bash "$BOOTSTRAP" --target "$android" --diff 2>"$TMP_ROOT/android.err")" ||
  fail "android diff failed"
[[ "$diff_out" == *"No generated-file differences."* ]] || fail "preview detection must match the real generation: $diff_out"
staging="$(sed -n 's/^agent-bootstrap: kept staging //p' "$TMP_ROOT/android.err" | head -1)"
[[ -n "$staging" && -f "$staging/docs/agent-configs/agent-bootstrap.lock.json" ]] || fail "android staging was not kept"
grep -q 'local.properties exists' "$staging/docs/agent-configs/agent-bootstrap.lock.json" ||
  fail "staged generation lost the local.properties warning"
[[ ! -e "$staging/local.properties" ]] || fail "local.properties must not be staged"
rm -rf "$(dirname "$staging")"
plan_counts="$(bash "$BOOTSTRAP" --target "$android" --upgrade-plan --json 2>/dev/null |
  python3 -B -c 'import json,sys; d=json.load(sys.stdin); print(",".join(f["path"] for f in d["files"] if f["path"].endswith("lock.json") and f["action"] != "unchanged"))')"
[[ -z "$plan_counts" ]] || fail "upgrade plan must keep an unchanged lock: $plan_counts"

# 13 a dry-run writes nothing: no file, directory, seed, ignore block or journal.
before="$(tree_state "$proj")"
bash "$BOOTSTRAP" --target "$proj" --workflow full --dry-run >/dev/null 2>&1 || fail "dry-run failed"
[[ "$(tree_state "$proj")" == "$before" ]] || fail "dry-run changed the generated target"
fresh="$TMP_ROOT/fresh"; mkdir -p "$fresh"; git -C "$fresh" init -q
printf '{"name":"fresh"}\n' > "$fresh/package.json"
before="$(tree_state "$fresh")"
bash "$BOOTSTRAP" --target "$fresh" --workflow full --dry-run >/dev/null 2>&1 || fail "fresh dry-run failed"
[[ "$(tree_state "$fresh")" == "$before" ]] || fail "dry-run changed an ungenerated target"
# Outside Git the ignore block would go to .gitignore.
plain="$TMP_ROOT/plain"; mkdir -p "$plain"
printf 'node_modules/\n' > "$plain/.gitignore"
before="$(tree_state "$plain")"
bash "$BOOTSTRAP" --target "$plain" --workflow full --dry-run >/dev/null 2>&1 || fail "non-Git dry-run failed"
[[ "$(tree_state "$plain")" == "$before" ]] || fail "dry-run changed a non-Git target"

# ---------------------------------------------------------------------------
# Orchestrator (harness-kit-run.sh) through the entry script, offline: design
# Verification cases 1-7, 10 and 11 plus the review fixes (take-kit gates,
# --resolved in its own run, this run's candidates, branch rules, versions,
# the run lock, the failure report, contradictory options), sharing three
# plain no-stack fixtures: c1 (current kit), c4 and c6 (v2026.09.07.1).
ENTRY="$ROOT_DIR/agent-bootstrap/harness-kit-one-shot.sh"
VERSION="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION" | tr -d '[:space:]')"
# A release renames the shipped migrations from next-<slug> to <version>-<slug>.
shipped_id() {
  local file
  file="$(compgen -G "$ROOT_DIR/agent-bootstrap/migrations/*-$1.sh" | head -1)"
  [[ -n "$file" ]] || { printf 'oneshot-test: FAIL: shipped migration %s is missing\n' "$1" >&2; exit 1; }
  basename "$file" .sh
}
UNTRACK_ID="$(shipped_id untrack-local-records)"
RETIRE_ID="$(shipped_id retire-files)"
TOEXCL_ID="$(shipped_id ignore-block-to-exclude)"
NEWER_VERSION="${VERSION%.*}.$((${VERSION##*.} + 1))"
MARKER='# >>> multi-agent bootstrap local state >>>'
OLD_KIT="$TMP_ROOT/old-kit"
mkdir -p "$OLD_KIT"
tar -xf "$ROOT_DIR/scripts/fixtures/historical-bundles/v2026.09.07.1.tar" -C "$OLD_KIT"

git_c() { git -C "$1" -c user.name=oneshot -c user.email=oneshot@example.invalid "${@:2}"; }
new_repo() { # a repository on main with one commit
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
  printf '# fixture\n' >"$1/README.md"
  git -C "$1" add README.md
  git_c "$1" commit -qm init
}
old_install() {
  bash "$OLD_KIT/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$1" --workflow full >/dev/null 2>&1 ||
    fail "fixture: the v2026.09.07.1 install failed in $1"
}
# hk DIR ARGS...: one run from DIR; console in OUT, exit code in RC, report in REPORT.
hk() {
  local dir="$1"
  shift
  RC=0
  OUT="$(cd "$dir" && bash "$ENTRY" --source-dir "$ROOT_DIR" "$@" 2>"$TMP_ROOT/hk.err")" || RC=$?
  REPORT="$dir/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
}
expect() { # code label: exit code, mode on the first line, at most 12 lines
  [[ "$RC" -eq "$1" ]] || fail "$2: exit $RC, expected $1
$OUT
$(tail -n 5 "$TMP_ROOT/hk.err")"
  [[ "$(sed -n '1p' <<<"$OUT")" == mode:* ]] || fail "$2: the first line must name the mode: $OUT"
  [[ "$(wc -l <<<"$OUT")" -le 12 ]] || fail "$2: console summary over 12 lines: $OUT"
  [[ ! -f "$REPORT" ]] || schema_check "$REPORT"
}
refused() { # label text: a refusal before any work, naming TEXT
  [[ "$RC" -eq 1 && "$OUT$(cat "$TMP_ROOT/hk.err")" == *"$2"* ]] ||
    fail "$1: expected a refusal naming '$2', got exit $RC: $OUT $(cat "$TMP_ROOT/hk.err")"
  [[ ! -f "$REPORT" ]] || schema_check "$REPORT"
}
jget() { python3 -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
sha_of() { python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
exclude_of() {
  local path
  path="$(git -C "$1" rev-parse --git-path info/exclude)"
  case "$path" in /*) ;; *) path="$1/$path" ;; esac
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}
# Project files outside .git/, .tools/ and .harness-kit/, with content hashes.
project_state() {
  python3 -I -B - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for base, dirs, files in os.walk(root):
    if base == root:
        dirs[:] = [d for d in dirs if d not in (".git", ".tools", ".harness-kit")]
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(base, name)
        with open(path, "rb") as handle:
            print(os.path.relpath(path, root), hashlib.sha256(handle.read()).hexdigest())
PY
}

# Run reports must match agent-bootstrap/schemas/harness-kit-run-report-v1.schema.json
# (a stdlib JSON-Schema subset: type, required, properties, items, enum, const,
# additionalProperties, $ref, pattern, minLength, minimum).
RUN_REPORT_SCHEMA="$ROOT_DIR/agent-bootstrap/schemas/harness-kit-run-report-v1.schema.json"
IFS= read -r -d '' SCHEMA_CHECK <<'PY' || true
import json, re, sys
schema = json.load(open(sys.argv[1]))
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool, "number": (int, float)}
def resolve(node):
    while "$ref" in node:
        target = schema
        for part in node["$ref"].lstrip("#/").split("/"):
            target = target[part]
        node = target
    return node
def check(node, value, where, errs):
    node = resolve(node)
    kind = node.get("type")
    if kind and (not isinstance(value, TYPES[kind]) or (kind in ("integer", "number") and isinstance(value, bool))):
        errs.append("%s: expected %s" % (where, kind))
        return
    if "const" in node and value != node["const"]:
        errs.append("%s: expected %r" % (where, node["const"]))
    if "enum" in node and value not in node["enum"]:
        errs.append("%s: %r not in %r" % (where, value, node["enum"]))
    if isinstance(value, str):
        if "pattern" in node and not re.search(node["pattern"], value):
            errs.append("%s: does not match %s" % (where, node["pattern"]))
        if len(value) < node.get("minLength", 0):
            errs.append("%s: too short" % where)
    if isinstance(value, int) and not isinstance(value, bool) and value < node.get("minimum", value):
        errs.append("%s: below the minimum" % where)
    if isinstance(value, dict):
        errs.extend("%s: missing %s" % (where, key) for key in node.get("required", []) if key not in value)
        props, extra = node.get("properties", {}), node.get("additionalProperties", True)
        for key, item in value.items():
            if key in props:
                check(props[key], item, where + "." + key, errs)
            elif extra is False:
                errs.append("%s: unexpected key %s" % (where, key))
            elif isinstance(extra, dict):
                check(extra, item, where + "." + key, errs)
    if isinstance(value, list) and "items" in node:
        for index, item in enumerate(value):
            check(node["items"], item, "%s[%d]" % (where, index), errs)
source = sys.argv[2]
doc = json.loads(source) if source.lstrip().startswith("{") else json.load(open(source))
errors = []
check(schema, doc, "report", errors)
if errors:
    sys.exit("\n".join(errors[:10]))
PY
schema_check() { # report.json path or JSON text
  python3 -I -B -c "$SCHEMA_CHECK" "$RUN_REPORT_SCHEMA" "$1" 2>&1 ||
    fail "report does not match the run-report schema: ${1:0:200}"
}
# The validator itself rejects an unknown key, a wrong enum and a missing field.
for bad in '{"schema":"harness-kit-run-report/v1","extra":1}' '{"schema":"other"}'; do
  if python3 -I -B -c "$SCHEMA_CHECK" "$RUN_REPORT_SCHEMA" "$bad" >/dev/null 2>&1; then
    fail "schema validator accepted an invalid report: $bad"
  fi
done

# 1 install on a new repository on main.
c1="$TMP_ROOT/c1"
new_repo "$c1"
hk "$c1"
expect 0 "case 1 install"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: install $VERSION" ]] || fail "case 1: mode line: $OUT"
[[ -z "$(git -C "$c1" status --porcelain)" ]] || fail "case 1: git status must stay clean: $(git -C "$c1" status --porcelain)"
grep -Fxq "$MARKER" "$(exclude_of "$c1")" || fail "case 1: the ignore block must be in the exclude file"
[[ ! -e "$c1/.gitignore" ]] || fail "case 1: an install must not write .gitignore"
[[ "$(jget "$c1/.tools/agent-state/project-knowledge.json" 'd["kit"]["version"]')" == "$VERSION" ]] ||
  fail "case 1: project knowledge was not written"
[[ "$(jget "$REPORT" '(d["result"], [v["check"] + "=" + v["status"] for v in d["verify"]])')" == \
  "('done', ['scripts/agent-hook.sh doctor=pass', 'scripts/agent-guard.sh preflight=pass'])" ]] ||
  fail "case 1: verification must run doctor and preflight once each: $(cat "$REPORT")"
[[ ! -e "$c1/.tools/agent-state/run.lock" ]] || fail "case 1: the run lock must be released"

# 10 checker: a tracked plain .gitignore beside the block in exclude passes.
printf 'node_modules/\n' >"$c1/.gitignore"
git -C "$c1" add .gitignore
git_c "$c1" commit -qm "plain gitignore"
(cd "$c1" && bash scripts/agent-local-only-check.sh status >"$TMP_ROOT/c10.out" 2>&1) ||
  fail "case 10: a tracked .gitignore with the block in exclude must pass: $(cat "$TMP_ROOT/c10.out")"

# Run lock: a live holder refuses a second run; a dead one is taken over.
lockdir="$c1/.tools/agent-state/run.lock"
mkdir "$lockdir"
printf '%s\n' "$$" >"$lockdir/pid"
hk "$c1" --skip-verify
refused "run lock" ".tools/agent-state/run.lock"
if [[ "$(id -u)" -ne 0 ]]; then
  printf '1\n' >"$lockdir/pid"
  hk "$c1" --skip-verify
  refused "run lock held by another user's live process" ".tools/agent-state/run.lock"
fi
dead_pid="$(bash -c 'printf "%s" "$$"')"
printf '%s\n' "$dead_pid" >"$lockdir/pid"
# Kit copies: keep the one in use, the previous one, newer ones and any whose
# name does not parse; prune older ones.
mkdir -p "$c1/.harness-kit/v2026.01.01.1" "$c1/.harness-kit/v2026.02.01.1" "$c1/.harness-kit/vjunk" \
  "$c1/.harness-kit/v2026.10.13.2-rc1"

# 2 reinstall restores a deleted kit file and keeps a local patch; 5 a pin.
rm "$c1/.claude/commands/council.md"
printf 'local patch\n' >>"$c1/.claude/commands/coding.md"
printf 'pinned text\n' >>"$c1/.claude/commands/planning.md"
HARNESS_KIT_TEST_FAIL=apply hk "$c1" --skip-verify --keep-local .claude/commands/planning.md
expect 0 "case 2 reinstall (the failure hook is off without HARNESS_KIT_TEST_HOOKS=1)"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: reinstall $VERSION" ]] || fail "case 2: mode line: $OUT"
[[ -f "$c1/.claude/commands/council.md" ]] || fail "case 2: a deleted kit file must be restored"
grep -qx 'local patch' "$c1/.claude/commands/coding.md" || fail "case 2: a local patch must be kept"
[[ "$OUT" == *"RESULT: done (verify skipped)"* ]] || fail "case 2: the result line must say verify skipped: $OUT"
grep -q 'taking over a stale run lock' "$TMP_ROOT/hk.err" || fail "run lock: a dead holder must be taken over with a note"
[[ ! -e "$lockdir" ]] || fail "run lock: not released"
kits="$(for dir in "$c1"/.harness-kit/v*; do printf '%s\n' "${dir##*/}"; done | LC_ALL=C sort | tr '\n' ' ')"
want="$(printf '%s\n' v2026.02.01.1 "v$VERSION" v2026.10.13.2-rc1 vjunk | LC_ALL=C sort | tr '\n' ' ')"
[[ "$kits" == "$want" ]] || fail "kit copy pruning: $kits (want $want)"
knowledge_out="$(cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" --knowledge 2>&1)" || fail "case 2: --knowledge failed: $knowledge_out"
[[ "$(wc -l <<<"$knowledge_out")" -le 15 && "$knowledge_out" == *"patch: .claude/commands/coding.md"* &&
  "$knowledge_out" == *"pin: .claude/commands/planning.md"* ]] ||
  fail "case 2: --knowledge must list the patch and the pin within 15 lines: $knowledge_out"
[[ "$knowledge_out" != *"patch: docs/"* ]] || fail "case 2: --knowledge must not list project-owned files as kit patches: $knowledge_out"

# 5 a pinned file stays untouched where the kit would update it; --resolved
# keeps its file byte-identical in its own run and moves the baseline. Both
# simulate a kit change by giving the baseline the local text.
base_dir="$c1/.tools/agent-state/harness-baseline/files"
cp "$c1/.claude/commands/planning.md" "$base_dir/.claude/commands/planning.md"
cp "$c1/.claude/commands/planning.md" "$TMP_ROOT/planning.pinned"
printf 'old kit text\n' >"$c1/.claude/commands/council.md"
cp "$c1/.claude/commands/council.md" "$base_dir/.claude/commands/council.md"
printf 'example\n' >"$c1/.claude/commands/council.md.generated.example"
hk "$c1" --skip-verify --resolved .claude/commands/council.md --reason "older wording"
expect 0 "case 5 pin and --resolved"
cmp -s "$c1/.claude/commands/planning.md" "$TMP_ROOT/planning.pinned" || fail "case 5: a pinned file was updated"
[[ "$(jget "$REPORT" '(d["files"]["pinned"], d["files"]["resolved"])')" == \
  "(['.claude/commands/planning.md'], ['.claude/commands/council.md'])" ]] ||
  fail "case 5: report pinned/resolved: $(jget "$REPORT" 'd["files"]')"
[[ "$(cat "$c1/.claude/commands/council.md")" == "old kit text" ]] || fail "--resolved must keep its file byte-identical in its own run"
if grep -q 'old kit text' "$base_dir/.claude/commands/council.md" || [[ ! -s "$base_dir/.claude/commands/council.md" ]]; then
  fail "--resolved must move the baseline to the kit output"
fi
[[ -f "$c1/.claude/commands/council.md.generated.example" ]] || fail "--resolved must drop only stamped candidates"
rm "$c1/.claude/commands/council.md.generated.example"

# 11 --plan --json: report fields, nothing written in the project and no
# knowledge change; 5 an edited pinned file is reported as a stale pin; a plan
# whose real run would be refused (here: the tracked .gitignore on main) ends
# needs review.
printf 'edited again\n' >>"$c1/.claude/commands/planning.md"
before="$(project_state "$c1")"
know_before="$(sha_of "$c1/.tools/agent-state/project-knowledge.json")"
RC=0
json="$(cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" --plan --json --ignore-target gitignore 2>"$TMP_ROOT/hk.err")" || RC=$?
[[ "$RC" -eq 3 ]] || fail "case 11: --plan --json of a refusable run must exit 3, got $RC: $(cat "$TMP_ROOT/hk.err")"
schema_check "$json"
python3 -I -B - "$json" <<'PY' || fail "case 11: --json report fields"
import json, sys
report = json.loads(sys.argv[1])
assert report["schema"] == "harness-kit-run-report/v1", report
for key in ("mode", "from", "to", "stamp", "phases", "files", "migrations", "verify", "next", "memory_note"):
    assert key in report, key
assert report["plan_only"] is True and report["mode"] == "reinstall", report
assert report["result"] == "needs review" and "main is protected" in report["would_refuse"], report
assert [p["name"] for p in report["phases"] if p["status"] != "skipped"] == ["preflight", "stage", "report"], report["phases"]
assert all({"name", "status", "seconds"} <= set(p) for p in report["phases"])
assert {"counts", "conflicts", "kept", "pinned"} <= set(report["files"])
assert {"applied", "pending", "declined"} <= set(report["migrations"])
assert len(report["memory_note"].splitlines()) <= 3, report["memory_note"]
assert report["files"]["stale_pins"] == [".claude/commands/planning.md"], report["files"]
assert any(n.endswith("--keep-local .claude/commands/planning.md") and "--to " in n for n in report["next"]), report["next"]
PY
[[ "$(project_state "$c1")" == "$before" ]] || fail "case 11: --plan wrote outside .harness-kit/ and .tools/"
[[ "$(sha_of "$c1/.tools/agent-state/project-knowledge.json")" == "$know_before" ]] || fail "--plan changed project knowledge"

# 3 --reset (failing on purpose after apply): the kit wins, the patch is
# backed up, recorded resolutions and pins are cleared, project-owned files
# stay; 10 the failure still writes the report with the undo command.
printf '# Project brief\n\nOur own brief.\n' >"$c1/docs/agent-configs/project-brief.md"
cp "$c1/docs/agent-configs/seats.json" "$TMP_ROOT/seats.before"
python3 -I -B - "$c1/AGENTS.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = "<!-- BEGIN USER: agents:extra -->\n"
assert marker in text, "fixture: AGENTS.md has no agents:extra overlay"
open(path, "w", encoding="utf-8").write(text.replace(marker, marker + "Our USER overlay line.\n"))
PY
RC=0
OUT="$(cd "$c1" && HARNESS_KIT_TEST_HOOKS=1 HARNESS_KIT_TEST_FAIL=apply bash "$ENTRY" --source-dir "$ROOT_DIR" --skip-verify --reset 2>"$TMP_ROOT/hk.err")" || RC=$?
REPORT="$c1/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
expect 1 "case 10 injected failure"
stamp="$(jget "$REPORT" 'd["stamp"]')"
[[ "$(jget "$REPORT" '(d["result"], [p["status"] for p in d["phases"] if p["name"] == "apply"], "--rollback " + d["stamp"] in " ".join(d["next"]))')" == \
  "('failed', ['failed'], True)" ]] || fail "case 10: the failure report needs result, phase and undo: $(cat "$REPORT")"
[[ "$(jget "$REPORT" 'd["reason"]')" == "test hook failure during apply" ]] || fail "case 10: the reason must name the test hook"
cmp -s "$c1/.claude/commands/coding.md" "$base_dir/.claude/commands/coding.md" ||
  fail "case 3: --reset must replace the patch with the kit output"
grep -lqx 'local patch' "$c1"/.claude/commands/coding.md.bak.* 2>/dev/null || fail "case 3: --reset must keep a backup"
grep -q 'edited again' "$c1/.claude/commands/planning.md" && fail "case 3: --reset must replace recorded pins too"
[[ "$(jget "$REPORT" 'sorted(d["files"]["cleared"])')" == "['.claude/commands/council.md', '.claude/commands/planning.md']" ]] ||
  fail "case 3: --reset must report the cleared resolutions: $(jget "$REPORT" 'd["files"]')"
[[ -z "$(cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" --knowledge 2>&1 | grep '^pin:')" ]] || fail "case 3: --reset must clear pins in knowledge"
grep -qx 'Our own brief.' "$c1/docs/agent-configs/project-brief.md" || fail "case 3: --reset replaced the brief"
cmp -s "$c1/docs/agent-configs/seats.json" "$TMP_ROOT/seats.before" || fail "case 3: --reset changed seats.json"
grep -qx 'Our USER overlay line.' "$c1/AGENTS.md" || fail "case 3: --reset dropped a USER overlay"
# 3 --rollback STAMP (JSON) restores the patch and refreshes knowledge.
RC=0
json="$(cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" --rollback "$stamp" --json 2>"$TMP_ROOT/hk.err")" || RC=$?
[[ "$RC" -eq 0 && "$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["result"])' "$json")" == "done" ]] ||
  fail "case 3: --rollback --json: exit $RC: $json $(cat "$TMP_ROOT/hk.err")"
# The rollback result has its own small shape (no schema file): check its keys.
python3 -I -B - "$json" <<'PY' || fail "case 3: rollback JSON shape: $json"
import json, sys
doc = json.loads(sys.argv[1])
assert set(doc) == {"schema", "stamp", "rollback_id", "result", "restored", "kept", "errors", "log"}, sorted(doc)
assert doc["schema"] == "harness-kit-rollback/v1" and doc["result"] in ("done", "needs review", "failed"), doc
assert all(isinstance(doc[key], list) for key in ("restored", "kept", "errors")), doc
PY
grep -qx 'local patch' "$c1/.claude/commands/coding.md" || fail "case 3: --rollback must restore the patch"
[[ "$(jget "$c1/.tools/agent-state/project-knowledge.json" 'd["files"][".claude/commands/coding.md"]["local_sha256"]')" == \
  "$(sha_of "$c1/.claude/commands/coding.md")" ]] || fail "case 3: --rollback must refresh knowledge"
[[ "$(jget "$c1/.tools/agent-state/project-knowledge.json" '[d["files"][p].get("resolution", {}).get("kind") for p in (".claude/commands/planning.md", ".claude/commands/council.md")]')" == \
  "['keep-local', 'resolved']" ]] || fail "--rollback of a --reset run must restore the cleared pin and resolution"

# 11 edges: downgrade and an unparseable installed version are refused; an
# interrupt writes a failed report; usage errors and contradictions exit 2.
lock="$c1/docs/agent-configs/agent-bootstrap.lock.json"
cp "$lock" "$TMP_ROOT/lock.saved"
set_lock_version() {
  python3 -I -B - "$lock" "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["version"] = sys.argv[2]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
}
set_lock_version 2099.01.01.1
hk "$c1" --skip-verify
expect 1 "case 11 downgrade"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: refused"* && "$OUT" == *"--rollback"* ]] ||
  fail "case 11: a downgrade must be refused with a --rollback hint: $OUT"
set_lock_version 2099.01.01.1-rc1
hk "$c1" --skip-verify
expect 1 "unparseable installed version"
[[ "$OUT" == *"no valid kit version"* ]] || fail "an unparseable installed version must be refused clearly: $OUT"
rm "$lock"
mkdir "$lock"
hk "$c1" --skip-verify
expect 1 "unreadable lock"
[[ "$OUT" == *"no valid kit version"* ]] || fail "an unreadable lock must be refused, never run as an update: $OUT"
rmdir "$lock"
cp "$TMP_ROOT/lock.saved" "$lock"
RC=0
OUT="$(cd "$c1" && HARNESS_KIT_TEST_HOOKS=1 HARNESS_KIT_TEST_FAIL=preflight:INT bash "$ENTRY" --source-dir "$ROOT_DIR" --plan 2>"$TMP_ROOT/hk.err")" || RC=$?
[[ "$RC" -eq 130 && "$OUT" == *"RESULT: failed"*"interrupted (INT) during preflight"* ]] ||
  fail "an interrupt must write a failed report and exit 130: $RC $OUT"
schema_check "$c1/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
[[ ! -e "$lockdir" ]] || fail "an interrupted run must release the run lock"
for args in "--bogus" "--branch main" "--workflow nope" "--take-kit ../x" "--take-kit /etc/hosts" \
  "--accept no-such-id" "--reason why" "--take-kit .tools/x" "--resolved AGENTS.md.generated.20260101-000000" \
  "--plan --accept $UNTRACK_ID" "--plan --take-kit AGENTS.md" "--rollback 20260101-000000 --reset" \
  "--knowledge --plan" "--take-kit AGENTS.md --resolved AGENTS.md" "--keep-local AGENTS.md --resolved AGENTS.md" \
  "--accept $RETIRE_ID --decline $RETIRE_ID" "--skip-verify --project-verify" "--json --knowledge"; do
  RC=0
  # shellcheck disable=SC2086 # split on purpose
  (cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" $args) >/dev/null 2>&1 || RC=$?
  [[ "$RC" -eq 2 ]] || fail "case 11: '$args' must be a usage error (exit 2), got $RC"
done
ln -s .claude "$c1/linkdir"
RC=0
(cd "$c1" && bash "$ENTRY" --source-dir "$ROOT_DIR" --keep-local linkdir/commands/coding.md) >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] || fail "a path through a symbolic link must be rejected, got $RC"
rm "$c1/linkdir"

# Decision gate: the kind is read through the runner (a quoted value still
# counts), so accepting such a decision on main is refused before any work.
kit2="$TMP_ROOT/kit2"
mkdir -p "$kit2"
cp -R "$ROOT_DIR/agent-bootstrap" "$kit2/"
cat >"$kit2/agent-bootstrap/migrations/next-zz-quoted.sh" <<'EOF'
MIGRATION_ID=next-zz-quoted
MIGRATION_SINCE=next
MIGRATION_KIND="decision"
MIGRATION_SUMMARY="Quoted kind"
migration_needed() { return 1; }
migration_describe() { printf 'nothing\n'; }
migration_apply() { :; }
EOF
RC=0
OUT="$(bash "$kit2/agent-bootstrap/harness-kit-run.sh" --target "$c1" --skip-verify --accept next-zz-quoted 2>&1)" || RC=$?
refused "a quoted decision kind" "main is protected"
# Runner guards: a crashing migration_needed fails, an unknown kind is
# refused, and a declined decision whose facts change is asked again on
# reinstall too.
stubs="$TMP_ROOT/stub-migrations"
mkdir -p "$stubs" "$TMP_ROOT/mig-target" "$TMP_ROOT/mig-journal"
stub() { # id kind needed-body describe-body
  printf 'MIGRATION_ID=%s\nMIGRATION_SINCE=next\nMIGRATION_KIND=%s\nMIGRATION_SUMMARY="stub %s"\nmigration_needed() { %s; }\nmigration_describe() { %s; }\nmigration_apply() { :; }\n' \
    "$1" "$2" "$1" "$3" "$4" >"$stubs/$1.sh"
}
stub next-a-crash auto 'return 3' 'printf "crash\n"'
stub next-b-weird weird 'return 0' 'printf "weird\n"'
# shellcheck disable=SC2016 # expanded inside the stub
stub next-c-facts decision 'return 0' 'cat "$TARGET_DIR/facts.txt"'
printf 'one\n' >"$TMP_ROOT/mig-target/facts.txt"
(
  # shellcheck disable=SC1091
  . "$ROOT_DIR/agent-bootstrap/lib/migrations.sh"
  TARGET_DIR="$TMP_ROOT/mig-target" KIT_DIR="$ROOT_DIR/agent-bootstrap" MIGRATIONS_DIR="$stubs"
  STAMP=20260101-000000 JOURNAL_DIR="$TMP_ROOT/mig-journal"
  export TARGET_DIR KIT_DIR MIGRATIONS_DIR STAMP JOURNAL_DIR
  migrations_run "" next update "" "" 2>/dev/null && fail "a crashing migration_needed must fail the run"
  [[ "$(migrations_report)" == "next-a-crash	failed"* ]] || fail "crashing needed: $(migrations_report)"
  rm "$stubs/next-a-crash.sh"
  migrations_run "" next update "" "" 2>/dev/null && fail "an unknown migration kind must fail the run"
  [[ "$(migrations_report)" == *"next-b-weird	failed"*"unknown migration kind"* ]] || fail "unknown kind: $(migrations_report)"
  rm "$stubs/next-b-weird.sh"
  migrations_run "" next update "" next-c-facts 2>/dev/null || fail "decline run failed"
  [[ -z "$(migrations_select "" next reinstall)" ]] || fail "a declined decision with the same facts is not asked again"
  printf 'two\n' >"$TARGET_DIR/facts.txt"
  [[ "$(migrations_select "" next reinstall)" == next-c-facts ]] || fail "changed facts must ask a declined decision again on reinstall"
  rm "$stubs/next-c-facts.sh"
  printf 'MIGRATION_ID=next-d-broken\n(\n' >"$stubs/next-d-broken.sh"
  migrations_run "" next update "" "" 2>/dev/null && fail "unreadable migration metadata must fail the run"
  [[ "$(migrations_report)" == "next-d-broken	failed"*"metadata"* ]] || fail "unreadable metadata: $(migrations_report)"
  rm "$stubs/next-d-broken.sh"
  # The shipped untrack and retire checks: an internal error is a failure,
  # never "not needed".
  broken_kit="$TMP_ROOT/broken-kit"
  mkdir -p "$broken_kit"
  printf '#!/usr/bin/env bash\nexit 5\n' >"$broken_kit/agent-local-only-check.sh"
  printf '#!/usr/bin/env bash\nexit 5\n' >"$broken_kit/bootstrap-multi-agent-project.sh"
  for shipped in "$UNTRACK_ID" "$RETIRE_ID"; do
    cp "$ROOT_DIR/agent-bootstrap/migrations/$shipped.sh" "$stubs/"
    KIT_DIR="$broken_kit" migrations_select "" next update >/dev/null 2>&1 && fail "$shipped: a failing check must fail selection"
    [[ "$(migrations_report)" == *"$shipped	failed"*"exit 2"* ]] || fail "$shipped: a failing check: $(migrations_report)"
    rm "$stubs/$shipped.sh"
  done
) || exit 1

# A failed migration is retried: the next run (now a reinstall, since apply
# moved the lock) selects it again and applies it once the cause is gone.
printf '%s\n' "$NEWER_VERSION" >"$kit2/agent-bootstrap/VERSION"
sed -i.orig "s/^AGENT_BOOTSTRAP_VERSION=\"[^\"]*\"/AGENT_BOOTSTRAP_VERSION=\"$NEWER_VERSION\"/" "$kit2/agent-bootstrap/bootstrap-multi-agent-project.sh"
cat >"$kit2/agent-bootstrap/migrations/next-zz-flaky.sh" <<'EOF'
MIGRATION_ID=next-zz-flaky
MIGRATION_SINCE=next
MIGRATION_KIND=auto
MIGRATION_SUMMARY="Flaky"
migration_needed() { [ ! -f "$TARGET_DIR/flaky.done" ]; }
migration_describe() { printf 'flaky\n'; }
migration_apply() { [ ! -f "$TARGET_DIR/flaky.block" ] && touch "$TARGET_DIR/flaky.done"; }
EOF
RC=0
bash "$kit2/agent-bootstrap/harness-kit-run.sh" --target "$c1" --decline next-zz-flaky >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 2 ]] || fail "declining an auto migration must be a usage error, got $RC"
touch "$c1/flaky.block"
RC=0
OUT="$(bash "$kit2/agent-bootstrap/harness-kit-run.sh" --target "$c1" --skip-verify \
  --resolved .claude/commands/planning.md 2>"$TMP_ROOT/hk.err")" || RC=$?
REPORT="$c1/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
expect 1 "a failing migration"
[[ "$(jget "$REPORT" '[m["id"] for m in d["migrations"]["failed"]]')" == "['next-zz-flaky']" ]] ||
  fail "the failing migration must be reported: $(jget "$REPORT" 'd["migrations"]')"
rm "$c1/flaky.block"
RC=0
OUT="$(bash "$kit2/agent-bootstrap/harness-kit-run.sh" --target "$c1" --skip-verify 2>"$TMP_ROOT/hk.err")" || RC=$?
REPORT="$c1/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
expect 0 "the retried migration"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: reinstall $NEWER_VERSION" && -f "$c1/flaky.done" ]] ||
  fail "a failed migration must be retried by the next run: $OUT"
[[ "$(jget "$REPORT" '[m["id"] for m in d["migrations"]["applied"]]')" == "['next-zz-flaky']" ]] ||
  fail "the retried migration must be applied: $(jget "$REPORT" 'd["migrations"]')"

# 4 update from an old bundle with a conflicting patch; 7 its .gitignore block
# gives the ignore-block-to-exclude decision. The tracked .gitignore differs
# from HEAD only by that block, so accepting it on main is allowed.
c4="$TMP_ROOT/c4"
new_repo "$c4"
printf 'node_modules/\n' >"$c4/.gitignore"
git -C "$c4" add .gitignore
git_c "$c4" commit -qm "plain gitignore"
old_install "$c4"
printf 'legacy patch\n' >>"$c4/.claude/commands/coding.md"
hk "$c4" --skip-verify
expect 3 "case 4 update with a conflicting patch"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: update 2026.09.07.1 -> $VERSION" ]] || fail "case 4: mode line: $OUT"
grep -qx 'legacy patch' "$c4/.claude/commands/coding.md" || fail "case 4: a conflict overwrote the local file"
cand="$(jget "$REPORT" '[c["candidate"] for c in d["files"]["conflicts"] if c["path"] == ".claude/commands/coding.md"][0]')"
if [[ ! -f "$c4/$cand" ]] || grep -q 'legacy patch' "$c4/$cand"; then
  fail "case 4: no kit candidate for the conflict: $cand"
fi
[[ "$OUT" == *"--take-kit all"* ]] || fail "many conflicts must suggest --take-kit all: $OUT"
[[ "$(jget "$REPORT" '[p["id"] for p in d["migrations"]["pending"]]')" == *"$TOEXCL_ID"* ]] ||
  fail "case 7: ignore-block-to-exclude must be pending: $(jget "$REPORT" 'd["migrations"]')"
[[ "$OUT" == *"--accept $TOEXCL_ID"* ]] || fail "case 7: the console must give the accept command: $OUT"
grep -Fq "$MARKER" "$c4/.gitignore" || fail "case 7: a decision ran without --accept"
user_conflicts=()
while IFS= read -r rel; do
  [[ -n "$rel" ]] && user_conflicts+=(--take-kit "$rel")
done < <(jget "$REPORT" '"\n".join(c["path"] for c in d["files"]["conflicts"] if c["path"].startswith(("docs/agent-configs/project-", "docs/superpowers/specs/project-tech-stack")))')
# A stale candidate from an older kit must never be promoted.
printf 'stale kit output\n' >"$c4/.claude/README.md.generated.29991231-235959"
hk "$c4" --skip-verify --resolved .claude/commands/coding.md --reason "local wording" \
  --accept "$TOEXCL_ID" --apply-retirements --take-kit all ${user_conflicts[@]+"${user_conflicts[@]}"}
expect 0 "case 4 --resolved and --take-kit all"
grep -qx 'legacy patch' "$c4/.claude/commands/coding.md" || fail "case 4: --resolved must keep the local file"
grep -q 'legacy patch' "$c4/.tools/agent-state/harness-baseline/files/.claude/commands/coding.md" &&
  fail "case 4: --resolved must move the baseline to the kit output"
grep -q 'stale kit output' "$c4/.claude/README.md" && fail "--take-kit promoted a stale candidate"
cmp -s "$c4/.claude/README.md" "$c4/.tools/agent-state/harness-baseline/files/.claude/README.md" ||
  fail "--take-kit all must install this run's kit output"
leftover_candidates="$(find "$c4" \( -path "$c4/.git" -o -path "$c4/.tools" -o -path "$c4/.harness-kit" \) -prune -o -name '*.generated.*' -print)"
[[ -z "$leftover_candidates" ]] || fail "case 4: candidates left after --resolved/--take-kit: $leftover_candidates"
[[ "$(jget "$c4/.tools/agent-state/project-knowledge.json" '(lambda r: (r["kind"], d["files"][".claude/commands/coding.md"]["reason"]))(d["files"][".claude/commands/coding.md"]["resolution"])')" == \
  "('resolved', 'local wording')" ]] || fail "case 4: the resolution must be recorded in knowledge"
if ! git -C "$c4" diff --quiet -- .gitignore || ! grep -Fq "$MARKER" "$(exclude_of "$c4")"; then
  fail "case 7: --accept must move the block to the exclude file and leave the committed .gitignore"
fi
grep -q -- "--apply-retirements means --accept $RETIRE_ID" "$TMP_ROOT/hk.err" ||
  fail "old flag --apply-retirements must print its note: $(cat "$TMP_ROOT/hk.err")"
hk "$c4" --skip-verify
expect 0 "case 4 next run"
[[ "$(sed -n '1p' <<<"$OUT")" == "mode: reinstall $VERSION" ]] || fail "case 4: the next run must be a reinstall: $OUT"
[[ "$(jget "$REPORT" '".claude/commands/coding.md" in d["files"]["kept"]')" == True ]] ||
  fail "case 4: the next run must keep the resolved file: $(jget "$REPORT" 'd["files"]')"
compgen -G "$c4/.claude/commands/coding.md.generated.*" >/dev/null && fail "case 4: the resolved file got a new candidate"

# 6 tracked harness files: --take-kit of a tracked file is gated (protected,
# uncommitted, detached, any remote's default branch); the untrack decision is
# refused on main, a --decline is asked again when the facts change, pending
# never touches the index, and accepted on a feature branch it changes only
# the index. (A decline held while the facts are unchanged is covered by
# test-harness-migrations.sh.)
c6="$TMP_ROOT/c6"
new_repo "$c6"
old_install "$c6"
git -C "$c6" add -A
git -C "$c6" add -f AGENTS.md CLAUDE.md
git_c "$c6" commit -qm "legacy: tracked harness files"
hk "$c6" --skip-verify --take-kit AGENTS.md
refused "take-kit on main" "main is protected"
printf 'uncommitted\n' >>"$c6/AGENTS.md"
hk "$c6" --skip-verify --branch feature/take --take-kit AGENTS.md
refused "take-kit of an edited tracked file" "uncommitted changes"
git -C "$c6" checkout -q -- AGENTS.md
git -C "$c6" checkout -q --detach
hk "$c6" --skip-verify --take-kit AGENTS.md
refused "take-kit on a detached HEAD" "HEAD is detached"
git -C "$c6" checkout -q main
git -C "$c6" update-ref refs/remotes/upstream/trunk HEAD
git -C "$c6" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/trunk
git -C "$c6" checkout -q -b trunk
hk "$c6" --skip-verify --take-kit AGENTS.md
refused "take-kit on a remote's default branch" "trunk is protected"
git -C "$c6" checkout -q main
git -C "$c6" branch -q -D trunk
[[ "$(git -C "$c6" branch --list feature/take)" == "" ]] || fail "a refused run must not create its branch"
hk "$c6" --skip-verify --accept "$UNTRACK_ID"
refused "case 6 --accept on main" "--branch"
git -C "$c6" diff --cached --quiet || fail "case 6: a refused run changed the index"
hk "$c6" --skip-verify --decline "$UNTRACK_ID"
expect 3 "case 6 --decline"
[[ "$(jget "$REPORT" '([m["id"] for m in d["migrations"]["declined"]], [m["id"] for m in d["migrations"]["pending"]])')" == \
  "(['$UNTRACK_ID'], ['$TOEXCL_ID'])" ]] ||
  fail "case 6: decline: $(jget "$REPORT" 'd["migrations"]')"
git -C "$c6" add -f GEMINI.md
git_c "$c6" commit -qm "legacy: one more tracked harness file"
head="$(git -C "$c6" rev-parse HEAD)"
hk "$c6" --skip-verify
expect 3 "case 6 pending after new facts"
[[ "$(jget "$REPORT" '[p["accept"] for p in d["migrations"]["pending"] if p["id"] == "'"$UNTRACK_ID"'"]')" == *"--branch feature/"* ]] ||
  fail "case 6: untrack must be pending again, with a branch in its accept command: $(jget "$REPORT" 'd["migrations"]')"
git -C "$c6" diff --cached --quiet || fail "case 6: a decision ran without --accept"
hk "$c6" --skip-verify --branch feature/untrack --accept "$UNTRACK_ID"
expect 3 "case 6 --accept on a feature branch"
[[ "$(git -C "$c6" symbolic-ref --short HEAD)" == feature/untrack && "$(git -C "$c6" rev-parse HEAD)" == "$head" ]] ||
  fail "case 6: --branch must switch without committing"
staged="$(git -C "$c6" diff --cached --name-status)"
[[ "$(grep -cv "^D$(printf '\t')" <<<"$staged" || true)" -eq 0 ]] || fail "case 6: --accept may only remove index entries: $staged"
[[ -z "$(git -C "$c6" diff --name-only)" ]] || fail "case 6: --accept changed tracked work-tree files: $(git -C "$c6" diff --name-only)"
for rel in AGENTS.md CLAUDE.md GEMINI.md; do
  grep -qx "D$(printf '\t')$rel" <<<"$staged" || fail "case 6: $rel was not untracked: $staged"
  [[ -f "$c6/$rel" ]] || fail "case 6: untrack removed $rel from disk"
done
[[ "$(jget "$REPORT" '[m["id"] for m in d["migrations"]["applied"]]')" == "['$UNTRACK_ID']" ]] ||
  fail "case 6: untrack must be applied: $(jget "$REPORT" 'd["migrations"]')"

# 11 a worktree uses the common exclude file. Run directories beyond the
# newest 10 are pruned unless they hold migration backups or an applied run
# younger than 30 days.
wt_main="$TMP_ROOT/wt-main"
new_repo "$wt_main"
git -C "$wt_main" worktree add -q "$TMP_ROOT/wt" -b feature/wt
python3 -I -B - "$TMP_ROOT/wt/.tools/agent-state/upgrades" <<'PY'
import datetime, os, sys
base = sys.argv[1]
now = datetime.datetime.now()
def make(stamp, *files):
    path = os.path.join(base, stamp)
    os.makedirs(path)
    for rel in files:
        os.makedirs(os.path.dirname(os.path.join(path, rel)), exist_ok=True)
        open(os.path.join(path, rel), "w").close()
for minutes in range(11):
    make((now - datetime.timedelta(hours=1, minutes=minutes)).strftime("%Y%m%d-%H%M%S"), "report.json")
make((now - datetime.timedelta(days=2)).strftime("%Y%m%d-%H%M%S"), "apply.log")
make("20200101-000001", "apply.log")
make("20200101-000000", "journal/migrations/next-x/backup")
PY
hk "$TMP_ROOT/wt" --skip-verify
expect 0 "case 11 worktree install"
[[ "$(exclude_of "$TMP_ROOT/wt")" == "$wt_main/.git/info/exclude" ]] || fail "case 11: worktree exclude path"
grep -Fxq "$MARKER" "$wt_main/.git/info/exclude" || fail "case 11: a worktree must use the common exclude file"
[[ -z "$(git -C "$TMP_ROOT/wt" status --porcelain)" ]] ||
  fail "case 11: worktree status must stay clean: $(git -C "$TMP_ROOT/wt" status --porcelain)"
python3 -I -B - "$TMP_ROOT/wt/.tools/agent-state/upgrades" <<'PY' || fail "run directory pruning: $(ls "$TMP_ROOT/wt/.tools/agent-state/upgrades")"
import os, sys
base = sys.argv[1]
names = sorted(os.listdir(base))
applied = [n for n in names if os.path.exists(os.path.join(base, n, "apply.log"))]
plan_only = [n for n in names if n not in applied and not n.startswith("2020")]
assert len(plan_only) == 9, names
assert "20200101-000000" in names and "20200101-000001" not in names, names
assert len(applied) == 2, names
PY

leftover="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)"
[[ -z "$leftover" ]] || fail "previews left scratch files behind: $leftover"

printf 'oneshot-test: ok\n'
