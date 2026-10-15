#!/usr/bin/env bash
set -euo pipefail

# Preview staging (--status, --diff, --upgrade-plan): a staged generation holds
# only the inventoried harness outputs and the fixed harness inputs, classifies
# a drifted project exactly as a real run does, generates twice per preview,
# and a failed staging directory never takes anything else with it.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/staging-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
BOOTSTRAP="$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh"
STAMP_A="20990102-030405"

fail() {
  printf 'staging-test: FAIL: %s\n' "$*" >&2
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

kept_staging() {
  sed -n 's/^agent-bootstrap: kept staging //p' "$1" | head -1
}

# Drifted project: an edited kit file, an older kit output, a conflicting and
# a kept JSON kit file, a USER block, a filled user-owned file, customised seats, a
# legacy profile, codegen and retired-path candidates, personal files, sources.
proj="$TMP_ROOT/proj"
mkdir -p "$proj/src"
git -C "$proj" init -q
printf '{"name":"staging"}\n' > "$proj/package.json"
printf 'node_modules/\n' > "$proj/.gitignore"
for i in $(seq 1 40); do printf 'x\n' > "$proj/src/f$i.js"; done
bash "$BOOTSTRAP" --target "$proj" --workflow full >/dev/null 2>&1 || fail "fixture generation failed"
baseline="$proj/.tools/agent-state/harness-baseline/files"
printf '\n# local note\n' >> "$proj/GEMINI.md"
printf '# older kit line\n' >> "$proj/CLAUDE.md"
printf '# older kit line\n' >> "$baseline/CLAUDE.md"
python3 -B - "$proj" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
baseline = root / ".tools/agent-state/harness-baseline/files"
def edit(path, key):
    doc = json.loads(path.read_text())
    doc[key] = True
    path.write_text(json.dumps(doc, indent=2) + "\n")
# Local edit and an older kit output: a JSON conflict. A local edit alone of
# an unchanged kit output is kept.
edit(root / ".claude/settings.json", "localSetting")
edit(baseline / ".claude/settings.json", "olderKitSetting")
edit(root / "docs/agent-configs/context-policy.json", "localPolicy")
seats = root / "docs/agent-configs/seats.json"
doc = json.loads(seats.read_text())
doc["seats"]["build"]["occupant"]["effort"] = "high"
seats.write_text(json.dumps(doc, indent=2) + "\n")
agents = root / "AGENTS.md"
text = agents.read_text()
marker = "<!-- BEGIN USER: agents:extra -->\n"
assert marker in text, "AGENTS.md has no USER block"
agents.write_text(text.replace(marker, marker + "Local rule kept across upgrades.\n", 1))
brief = root / "docs/agent-configs/project-brief.md"
brief.write_text(brief.read_text().replace("<!-- UNFILLED -->", ""))
PY
cp "$ROOT_DIR/agent-bootstrap/model-profiles/codex-model-profiles.json" "$proj/docs/agent-configs/model-profiles.json"
printf 'export const api = 1;\n' > "$proj/src/api.generated.ts"
mkdir -p "$proj/.github/workflows"
printf 'old retired candidate\n' > "$proj/.github/workflows/agent-guard.yml.generated.20990101-000000"
printf 'SECRET=staging-sentinel\n' > "$proj/.env"
printf '{"mcpServers":{"staging-sentinel":{}}}\n' > "$proj/.mcp.json"

export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"
trace="$TMP_ROOT/trace"

# 1 the plan JSON classifies every file as a real run does, with the same kit
# output (a real run with the plan log on a cp -a copy, under the same stamp).
copy="$TMP_ROOT/copy"
cp -a "$proj" "$copy"
: > "$trace"
AGENT_BOOTSTRAP_STAMP="$STAMP_A" AGENT_BOOTSTRAP_TRACE_FILE="$trace" AGENT_BOOTSTRAP_KEEP_STAGING=1 \
  bash "$BOOTSTRAP" --target "$proj" --upgrade-plan --json >"$TMP_ROOT/plan.json" 2>"$TMP_ROOT/plan.err" ||
  fail "upgrade plan failed: $(tail -5 "$TMP_ROOT/plan.err")"
staging="$(kept_staging "$TMP_ROOT/plan.err")"
[[ -n "$staging" && -f "$staging/AGENTS.md" ]] || fail "kept staging was not reported: $(cat "$TMP_ROOT/plan.err")"
AGENT_BOOTSTRAP_STAMP="$STAMP_A" AGENT_BOOTSTRAP_PLAN_LOG="$TMP_ROOT/real.tsv" \
  bash "$BOOTSTRAP" --target "$copy" --workflow full --no-backup >/dev/null 2>"$TMP_ROOT/real.err" ||
  fail "real run failed: $(tail -5 "$TMP_ROOT/real.err")"
python3 -B - "$TMP_ROOT/plan.json" "$(dirname "$staging")/plan.tsv" "$TMP_ROOT/real.tsv" "$proj" "$copy" <<'PY' ||
import hashlib, json, os, sys
plan_json, staged_log, real_log, proj, copy = sys.argv[1:6]

def rows(path):
    with open(path, encoding="utf-8") as handle:
        return sorted(line.rstrip("\n") for line in handle if line.strip())

def outputs(log, root):
    base = log + ".new"
    found = {}
    for top, _, names in os.walk(base):
        for name in names:
            path = os.path.join(top, name)
            with open(path, "rb") as handle:
                found[os.path.relpath(path, base)] = handle.read().replace(root.encode(), b"<T>")
    return found

def embeds_root(rel):
    # A file naming the project root differs on the copy by construction.
    try:
        with open(os.path.join(proj, rel), "rb") as handle:
            return proj.encode() in handle.read()
    except OSError:
        return False

errors = []
staged = [row for row in rows(staged_log) if not embeds_root(row.split("\t", 1)[1])]
real = [row for row in rows(real_log) if not embeds_root(row.split("\t", 1)[1])]
if staged != real:
    errors.append("plan log differs:\n  staged-only %s\n  real-only %s" % (
        sorted(set(staged) - set(real)), sorted(set(real) - set(staged))))
new_staged, new_real = outputs(staged_log, proj), outputs(real_log, copy)
for rel in sorted(set(new_staged) | set(new_real)):
    if new_staged.get(rel) != new_real.get(rel):
        errors.append("kit output differs: " + rel)
actions = {}
for line in real:
    action, rel = line.split("\t", 1)
    if not rel.startswith(".tools/") and ".generated." not in rel:
        actions.setdefault(rel, action)
doc = json.load(open(plan_json, encoding="utf-8"))
planned = {item["path"]: item["action"] for item in doc["files"] if not embeds_root(item["path"])}
if planned != actions:
    errors.append("plan JSON actions differ: %s" % sorted(set(planned.items()) ^ set(actions.items())))
lock = "docs/agent-configs/agent-bootstrap.lock.json"
if planned.get(lock) != actions.get(lock):
    errors.append("lock class differs: plan %s, real %s" % (planned.get(lock), actions.get(lock)))
for rel, want in (("GEMINI.md", "kept"), ("CLAUDE.md", "update"), (".claude/settings.json", "conflict"),
                  ("docs/agent-configs/context-policy.json", "kept"),
                  ("docs/agent-configs/project-brief.md", "preserved")):
    if planned.get(rel) != want:
        errors.append("fixture: %s is %s, expected %s" % (rel, planned.get(rel), want))
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
  fail "preview and real run disagree (see above)"
[[ "$(grep -c '^generate' "$trace" || true)" -eq 2 ]] || fail "plan JSON must generate exactly twice: $(cat "$trace")"

# 2 the staged tree is a subset of the inventory, the fixed harness inputs,
# candidates beside inventoried outputs and harness state under .tools.
inventory="$TMP_ROOT/inventory"
: > "$inventory"
AGENT_BOOTSTRAP_WRITE_LOG="$inventory" bash "$BOOTSTRAP" --target "$proj" --workflow full --force --no-backup \
  --dry-run --ignore-target none >/dev/null 2>&1 || fail "inventory dry-run failed"
python3 -B - "$staging" "$inventory" <<'PY' || fail "staging holds files outside the seed set (see above)"
import os, sys
staging, inventory_file = sys.argv[1:3]
inventory = {line.strip() for line in open(inventory_file, encoding="utf-8") if line.strip()}
fixed = {
    "docs/agent-configs/project-agent-context.md", "docs/agent-configs/project-brief.md",
    "docs/superpowers/specs/project-tech-stack.md", "docs/superpowers/specs/project-tech-stack.json",
    "docs/agent-configs/agent-bootstrap.lock.json", "docs/agent-configs/seats.json",
}
allowed = inventory | fixed
stray = []
for top, dirs, names in os.walk(staging):
    for name in names:
        rel = os.path.relpath(os.path.join(top, name), staging)
        if rel in allowed or rel.startswith(".tools/"):
            continue
        if ".generated." in rel and rel.split(".generated.", 1)[0] in inventory:
            continue
        stray.append(rel)
if not inventory:
    stray.append("<empty inventory>")
if stray:
    print("stray staged files: %s" % sorted(stray))
    sys.exit(1)
PY
for rel in .gitignore docs/agent-configs/model-profiles.json; do
  [[ ! -e "$staging/$rel" ]] || fail "$rel must not be staged (exclude target; legacy input read in place)"
done
if grep -rl 'staging-sentinel' "$TMPDIR" >/dev/null 2>&1; then
  fail "personal files reached \$TMPDIR"
fi
rm -rf "$(dirname "$staging")"

# 3 status and diff generate exactly twice and seed once; the allowlist actions
# only inventory (one dry-run, no seed).
for action in --status --diff; do
  : > "$trace"
  AGENT_BOOTSTRAP_TRACE_FILE="$trace" bash "$BOOTSTRAP" --target "$proj" "$action" >/dev/null 2>&1 ||
    fail "$action failed"
  [[ "$(grep -c '^generate' "$trace" || true)" -eq 2 ]] || fail "$action must generate exactly twice: $(cat "$trace")"
  [[ "$(grep -c '^seed ' "$trace" || true)" -eq 1 ]] || fail "$action must seed once: $(cat "$trace")"
done
for action in --apply-candidates --cleanup-backups; do
  : > "$trace"
  AGENT_BOOTSTRAP_TRACE_FILE="$trace" bash "$BOOTSTRAP" --target "$proj" "$action" --dry-run >/dev/null 2>&1 ||
    fail "$action failed"
  [[ "$(grep -c '^seed' "$trace" || true)" -eq 0 ]] || fail "$action must not seed staging: $(cat "$trace")"
  [[ "$(cat "$trace")" == "generate dry-run" ]] || fail "$action must only inventory: $(cat "$trace")"
done

# 4 a staging directory that cannot be created fails the preview and never
# removes the working directory or touches the target.
cwd="$TMP_ROOT/cwd"
mkdir -p "$cwd"
printf 'keep\n' > "$cwd/keep.txt"
shim="$TMP_ROOT/shim"
mkdir -p "$shim"
printf '#!/bin/sh\ncase "$*" in *agent-staging.*) echo "mktemp: injected failure" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v mktemp)" > "$shim/mktemp"
chmod +x "$shim/mktemp"
before="$(tree_state "$proj")"
status_json="$(cd "$cwd" && PATH="$shim:$PATH" bash "$BOOTSTRAP" --target "$proj" --status --json 2>/dev/null)" ||
  fail "status must still report when staging fails"
[[ "$status_json" == *'"generated_file_drift":"stale"'* ]] || fail "failed staging must not report clean: $status_json"
[[ -f "$cwd/keep.txt" ]] || fail "failed staging removed the working directory (status)"
(cd "$cwd" && PATH="$shim:$PATH" bash "$BOOTSTRAP" --target "$proj" --upgrade-plan >/dev/null 2>&1) || true
[[ -f "$cwd/keep.txt" ]] || fail "failed staging removed the working directory (upgrade plan)"
rc=0
(cd "$cwd" && PATH="$shim:$PATH" bash "$BOOTSTRAP" --target "$proj" --diff >/dev/null 2>"$TMP_ROOT/diff.err") || rc=$?
[[ "$rc" -ne 0 ]] || fail "--diff must fail without a staging directory"
grep -q 'could not create a preview staging directory' "$TMP_ROOT/diff.err" || fail "missing staging diagnostic: $(cat "$TMP_ROOT/diff.err")"
[[ -f "$cwd/keep.txt" ]] || fail "failed staging removed the working directory (diff)"
rc=0
(cd "$cwd" && TMPDIR="$TMP_ROOT/missing" bash "$BOOTSTRAP" --target "$proj" --status >/dev/null 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] || fail "--status must fail when \$TMPDIR is missing"
[[ -f "$cwd/keep.txt" ]] || fail "missing \$TMPDIR removed the working directory"
[[ "$(tree_state "$proj")" == "$before" ]] || fail "failed previews changed the target"

# 5 AGENT_BOOTSTRAP_STAMP names the run: the real run above journaled and
# stamped its candidate under it, and --rollback finds that journal.
[[ -f "$copy/.claude/settings.json.generated.$STAMP_A" ]] || fail "candidate does not carry AGENT_BOOTSTRAP_STAMP"
rollback_out="$(bash "$BOOTSTRAP" --target "$copy" --rollback "$STAMP_A" 2>&1)" || fail "rollback of the stamped run failed: $rollback_out"
[[ "$rollback_out" == *"Rollback $STAMP_A:"* ]] || fail "rollback did not report the stamped run: $rollback_out"
rc=0
AGENT_BOOTSTRAP_STAMP="2099-01-02" bash "$BOOTSTRAP" --target "$proj" --status >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "an invalid AGENT_BOOTSTRAP_STAMP must exit 2 (got $rc)"

leftover="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)"
[[ -z "$leftover" ]] || fail "previews left scratch files behind: $leftover"

printf 'staging-test: ok\n'
