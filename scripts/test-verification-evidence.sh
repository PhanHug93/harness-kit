#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted stub bodies; `a && b || c` asserts
set -euo pipefail

# Project-declared verification evidence: contract fields `scope` and `toolchain`.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verification-evidence-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'verification-evidence-test: FAIL: %s\n' "$*" >&2
  exit 1
}

target="$TMP_ROOT/project"
mkdir -p "$target"
git -C "$target" init -q
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null 2>&1
contract="$target/docs/superpowers/specs/project-tech-stack.json"

# Docs markers: the generated docs state the current rules, and the wording
# they replaced is gone.
doc_has() {  # <generated file> <phrase>...
  local file="$1" text phrase; shift
  text="$(cat "$target/$file")" || fail "missing generated doc $file"
  for phrase in "$@"; do
    [[ "$text" == *"$phrase"* ]] || fail "$file must contain: $phrase"
  done
}
doc_lacks() {  # <generated file> <phrase>...
  local file="$1" text phrase; shift
  text="$(cat "$target/$file")" || fail "missing generated doc $file"
  for phrase in "$@"; do
    [[ "$text" != *"$phrase"* ]] || fail "$file must not contain: $phrase"
  done
}
journal_rule='with each commit that changes tracked files'
severity_rule='Severity names its trigger condition and frequency, or is marked as an estimate.'
modes=docs/agent-configs/agent-mode-contracts.md
doc_has "$modes" "$severity_rule" 'the close included' 'the seat the user is talking to' \
  'the only writes a non-owner seat' 'counts returns to' 'beyond the doubt-driven skill' \
  '`@gate` runs `scripts/agent-guard.sh baseline` before its first round' \
  'not a git diff' 'The builder check:'
doc_lacks "$modes" 'defined by the reviewing launcher' 'Seats do not spawn extra reviewer helpers' \
  'names the condition that triggers it' 'diff since that revision'
doc_has docs/agent-configs/agent-handoff-schema.md 'is not `closed`' 'gate-review.md' 'verify-review.md' 'audit-review.md' \
  'An older `codex-review.md` keeps its two sections' \
  'listing the sections it changed'
doc_has docs/agent-configs/agent-handoff-reference.md 'owner: user' '### `gate-review.md`' '### `verify-review.md`' \
  '### `audit-review.md`' 'fail, error → fail; unverified → not_run' "the user's words" \
  'Then ask the user to decide: close, another bounded pass, or a prior phase.'
doc_lacks docs/agent-configs/agent-handoff-reference.md 'Mirroring is optional' 'budget → fail'
doc_has AGENTS.md 'The seat that changed code' 'short, plain words, and an example instead of jargon' 'plans never leave' "$journal_rule" \
  'USER and detected blocks) only warns' 'entries follow `docs/agent-configs/task-journal.md`' \
  'printed by the guard' 'session ends; do not run it again' 'agent-handoff-schema.md` for packets, resume and ownership'
for readme in README.md docs/agent-configs/bootstrap-multi-agent-project/README.md agent-bootstrap/README.md; do
  grep -q 'detector-filled managed blocks' "$ROOT_DIR/$readme" || fail "$readme must list detector-filled managed blocks as project content"
done
doc_lacks AGENTS.md 'Before completion, run' 'do not commit them until' 'not a closure gate'
# Change tiers: AGENTS.md says how to pick one; the contracts give each tier's
# phases and the coding rule; the schema says who writes tier.json.
doc_has AGENTS.md '## Pick a tier' 'scripts/agent-guard.sh tier suggest' 'a new request mid-task means' \
  'tier suggest --task' 'When the user says done: `tier close --task <id>`'
doc_has "$modes" 'A small or medium tier the user confirmed' \
  'small: `analysis` -> `implementation` -> `resolution`' \
  'medium: `analysis` -> `implementation` -> `verification` -> `resolution`' \
  'Skipped or unavailable checks never pass.' 'missing or inconsistent verdict blocks coding'
doc_has CLAUDE.md 'small or medium tier'
doc_has docs/agent-configs/agent-handoff-schema.md 'tier.json' 'written only by `scripts/agent-guard.sh`' \
  '`tier set` fills a null one with'
doc_has .claude/commands/coding.md 'a confirmed small or medium tier'
# The journal rule lives in AGENTS.md (read at startup), the journal guide and the plans README.
for journal_doc in AGENTS.md docs/agent-configs/task-journal.md docs/superpowers/plans/README.md; do
  doc_has "$journal_doc" "$journal_rule"
  doc_lacks "$journal_doc" 'when the task changed tracked files'
done
doc_lacks docs/agent-configs/task-journal.md 'Mirroring is optional'
ignore_file=.git/info/exclude; [[ -f "$target/.gitignore" ]] && ignore_file=.gitignore
doc_has "$ignore_file" 'plans never leave'
doc_lacks "$ignore_file" 'analyses and plans stay'
doc_has .claude/commands/planning.md 'builder-check answers' 'use a council only when the user asks for one'
doc_lacks .claude/commands/planning.md 'concrete plan'
doc_has .claude/commands/reviewing.md "mode contracts' severity rule"
for alias in planning coding reviewing; do
  doc_has ".claude/commands/$alias-full-flow.md" "Same as \`/$alias\`" ".claude/commands/$alias.md"
done
doc_has docs/agent-configs/llm-council-agent-workflow.md 'never changes the phase owner'
doc_has .claude/commands/codex/rescue.md 'whose host is `codex`'
doc_has .claude/commands/codex/setup.md 'whose host is `codex`'
doc_has .codex/codex-mode.sh 'gate-review.md' 'scripts/agent-guard.sh baseline' "mode contracts' severity rule" \
  'never ask for a project plan before approval'
doc_lacks .codex/codex-mode.sh 'codex-review.md' 'verify-review.md' 'Judge the spec and plan' 'diff since' \
  'Severity must name' 'mark the severity as an estimate' "$severity_rule"
doc_has .codex/README.md "@build's hand-off check"
doc_has .claude/commands/planning.md 'Enter = keep' '--answer' 'tier suggest'
doc_has .claude/commands/coding.md 'after task.md' 'Enter = keep' '--answer'
doc_has .codex/codex-mode.sh 'End with the tier checkpoint: run scripts/agent-guard.sh tier suggest --task <id> --by @spec' \
  'tier suggest --task <id> --by @gate' 'Add scope goes back to @spec' 'say '"'"'not recorded'"'"' if read-only'
# Every tier checkpoint passes the facts it knows: a suggest with no --paths
# would judge "files unknown".
doc_has .codex/codex-mode.sh '--by @spec --paths <files>' '--by @gate --paths <files>' '--by @build --paths <files>' \
  'l = large · m = medium · s = small'
doc_lacks .codex/codex-mode.sh 'Enter = keep · m · s'
doc_has docs/agent-configs/tier-medium.md '--by @build --paths <files>' '`--unclear`'
doc_has .claude/commands/planning.md '--by @spec --paths <files>'
doc_has .claude/commands/coding.md '--paths <files>` (and the AGENTS.md flags when true)'
doc_has docs/agent-configs/RECOVERY.md 'scripts/harness-kit.sh --take-kit' 'agent-init --apply-candidates --only' \
  'bash "$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target . --apply-candidates --only'
doc_lacks docs/agent-configs/RECOVERY.md 'scripts/bootstrap-multi-agent-project.sh'
doc_lacks docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md 'primary planning owner'
doc_has CLAUDE.md 'Stop hook when the session changed files'
doc_lacks CLAUDE.md 'tree has changes'

write_contract() {
  python3 - "$contract" "$1" <<'PY'
import json, sys
path, patch = sys.argv[1], json.loads(sys.argv[2])
doc = json.load(open(path)); doc.update(patch); json.dump(doc, open(path, "w"), indent=2)
PY
}

# C-1 scope and toolchain accepted
write_contract '{"verification":[{"command":"true","purpose":"stub","source":"test","scope":"full"}],"toolchain":["true"]}'
(cd "$target" && scripts/verify-ai-deps.sh >/dev/null) || fail "scope/toolchain must validate"
# C-2 bad scope rejected
write_contract '{"verification":[{"command":"true","purpose":"stub","source":"test","scope":"medium"}]}'
(cd "$target" && scripts/verify-ai-deps.sh >/dev/null 2>&1) && fail "scope medium must be rejected"
# C-3 empty toolchain entry rejected
write_contract '{"verification":[],"toolchain":[""]}'
(cd "$target" && scripts/verify-ai-deps.sh >/dev/null 2>&1) && fail "empty toolchain entry must be rejected"

# Pre-final command source and grading. Stub commands append a marker line.
mark="$TMP_ROOT/marks"; : > "$mark"
git -C "$target" add -A
git -C "$target" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m fixture
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null 2>&1)
# status lines name the real context pack, also outside the project
out="$(cd "$target" && AGENT_STATE_DIR="$TMP_ROOT/state-ext" scripts/agent-guard.sh preflight 2>&1)" || fail "external-state preflight: $out"
[[ "$out" == *"context_pack=$TMP_ROOT/state-ext/context-pack.json"* ]] || fail "preflight must print the real context pack path: $out"
# Case 13 below expects dirty:false: the contract it edits is git-ignored and
# nothing else has changed since the fixture commit.
git -C "$target" check-ignore -q docs/superpowers/specs/project-tech-stack.json || fail "contract must be git-ignored"
[[ -z "$(git -C "$target" status --porcelain)" ]] || fail "fixture tree must be clean after its commit"
stub() { printf "sh -c 'echo %s >> %s'" "$1" "$mark"; }
last_event() {  # assert a Python expression over the newest guard event `e`
  python3 - "$target/.agents/state/session-events.jsonl" "$1" <<'PY'
import json, sys
e = [json.loads(line) for line in open(sys.argv[1]) if line.strip()][-1]
assert e["event"] == "pre_final" and eval(sys.argv[2]), e
PY
}
# 13 contract commands run, detector commands do not
write_contract "{\"verification\":[{\"command\":\"$(stub contract)\",\"purpose\":\"stub\",\"source\":\"test\"}],\"toolchain\":[]}"
out="$(cd "$target" && scripts/agent-guard.sh pre-final --run-verify 2>&1)" || fail "contract pass must exit 0: $out"
grep -qx contract "$mark" || fail "contract command must run"
report="$(sed -n 's/^agent-guard: verify_report=//p' <<<"$out")"
[[ "$report" == /* && -f "$report" ]] || fail "pre-final must print an absolute verify_report path: $out"
python3 - "$report" "$(git -C "$target" rev-parse HEAD)" <<'PY' || fail "report v2 fields"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "agent-guard-verification/v2" and d["status"] == "pass", d
assert d["source"] == "contract" and len(d["results"]) == 1 and d["results"][0]["source"] == "contract", d
assert d["commit"] == sys.argv[2] and d["dirty"] is False, d
PY
# 13a report name override; names outside the report pattern are refused
out="$(cd "$target" && AGENT_GUARD_VERIFY_REPORT_NAME=closeout-verify.json scripts/agent-guard.sh pre-final --run-verify 2>&1)" || fail "named report run: $out"
[[ "$(sed -n 's/^agent-guard: verify_report=//p' <<<"$out")" == */.agents/state/closeout-verify.json ]] || fail "named report path: $out"
for name in context-pack.json ../escape-report.json; do
  rc=0; err="$(cd "$target" && AGENT_GUARD_VERIFY_REPORT_NAME="$name" scripts/agent-guard.sh pre-final --run-verify 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" -ne 0 && "$err" == *"AGENT_GUARD_VERIFY_REPORT_NAME must match"* ]] || fail "report name $name must be refused: $err"
done
[[ ! -e "$target/.agents/escape-report.json" ]] || fail "refused report name wrote a file"
# 14 empty contract falls back to the detector (this fixture's detector only
# yields a placeholder, so the run is deterministically unverified)
write_contract '{"verification":[]}'
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 4 ]] || fail "detector placeholder only must exit 4 (got $rc)"
python3 - "$target/.agents/state/last-verify-report.json" <<'PY' || fail "empty contract must fall back to the detector"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["source"] == "detector" and d["status"] == "unverified", d
assert d["results"] and all(r["source"] == "detector" for r in d["results"]), d["results"]
PY
# 15 nothing runnable: strict 4, advisory 0 with warn
write_contract '{"verification":[{"command":"run <placeholder>","purpose":"stub","source":"test"}]}'
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 4 ]] || fail "unverified must exit 4 in strict mode (got $rc)"
(cd "$target" && scripts/agent-guard.sh pre-final --advisory --run-verify >/dev/null 2>&1) || fail "advisory must not fail"
last_event 'e["gate_status"] == "warn" and e["verification"]["status"] == "unverified"' || fail "advisory unverified event"
# 16 discovery only
write_contract '{"verification":[{"command":"git --version","purpose":"stub","source":"test"}]}'
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 4 ]] || fail "discovery must not count (got $rc)"
# 17 scope full skipped under fast, runs under full
write_contract "{\"verification\":[{\"command\":\"$(stub full)\",\"purpose\":\"stub\",\"source\":\"test\",\"scope\":\"full\"}]}"
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 4 ]] || fail "full entry must skip under fast (got $rc)"
(cd "$target" && scripts/agent-guard.sh pre-final --run-verify --verify-scope full >/dev/null 2>&1) || fail "full entry must run under full"
grep -qx full "$mark" || fail "full command marker"
# 17a missing detector and empty contract: strict 4, advisory 0, event unavailable
write_contract '{"verification":[]}'
chmod -x "$target/scripts/detect-agent-tech-stack.sh"
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
strict_event_ok=0; last_event 'e["gate_status"] == "fail" and e["verification"]["available"] is False' || strict_event_ok=1
strict_report_ok=0; python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "unverified"' \
  "$target/.agents/state/last-verify-report.json" 2>/dev/null || strict_report_ok=1
advisory_rc=0; out="$(cd "$target" && scripts/agent-guard.sh pre-final --advisory --run-verify 2>&1)" || advisory_rc=$?
chmod +x "$target/scripts/detect-agent-tech-stack.sh"
[[ "$rc" -eq 4 ]] || fail "missing detector with empty contract must exit 4 (got $rc)"
[[ "$strict_event_ok" -eq 0 ]] || fail "missing detector must log available:false"
[[ "$strict_report_ok" -eq 0 ]] || fail "missing detector in strict mode must write an unverified report"
[[ "$advisory_rc" -eq 0 ]] || fail "missing detector in advisory mode must not fail (got $advisory_rc)"
# The early return still records a fresh unverified report (case 17 left a pass).
report="$(sed -n 's/^agent-guard: verify_report=//p' <<<"$out")"
[[ "$report" == "$target/.agents/state/last-verify-report.json" ]] || fail "early return must print verify_report: $out"
python3 - "$report" <<'PY' || fail "early return must write an unverified report"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == "unverified" and d["source"] == "detector" and d["results"] == [], d
assert d["summary"] == {"pass": 0, "fail": 0, "skipped": 0, "error": 0}, d
PY
# 17b a failing contract command still reports where its evidence is
write_contract '{"verification":[{"command":"false","purpose":"red","source":"test"}]}'
echo untracked > "$target/untracked-change.txt"
rc=0; out="$(cd "$target" && scripts/agent-guard.sh pre-final --run-verify 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "failing contract command must exit 1 (got $rc): $out"
report="$(sed -n 's/^agent-guard: verify_report=//p' <<<"$out")"
[[ -f "$report" ]] || fail "failing run must print verify_report: $out"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="fail" and d["dirty"] is True, d' "$report" || fail "failing run report status/dirty"
rm -f "$target/untracked-change.txt"
# 24 aborted pre-final logs the verification as unavailable (17b left a report)
printf '{broken' > "$target/.agents/state/context-pack.json"
rc=0; (cd "$target" && scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1) || rc=$?
[[ "$rc" -ne 0 ]] || fail "corrupt context pack must fail pre-final"
last_event 'e["verification"]["available"] is False' || fail "aborted pre-final must log available:false"
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight must restore the context pack"

# Baseline: keyed by commit, verification[] and the toolchain fingerprint.
baseline_report="$target/.agents/state/baseline-report.json"
cp -p "$target/.agents/state/last-verify-report.json" "$TMP_ROOT/last-verify-before.json"
# 18 baseline green twice: the second call reuses the result
write_contract "{\"verification\":[{\"command\":\"$(stub base)\",\"purpose\":\"stub\",\"source\":\"test\"}],\"toolchain\":[\"cat $TMP_ROOT/tool\"]}"
echo v1 > "$TMP_ROOT/tool"; : > "$mark"
git -C "$target" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null) || fail "baseline green"
(cd "$target" && scripts/agent-guard.sh baseline | grep -q cached) || fail "second baseline must be cached"
[[ "$(grep -c base "$mark")" -eq 1 ]] || fail "cached baseline must not run commands"
python3 - "$baseline_report" "$(git -C "$target" rev-parse HEAD)" <<'PY' || fail "baseline report fields"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "agent-guard-verification/v2" and d["status"] == "pass" and d["commit"] == sys.argv[2], d
assert len(d["baseline_key"]) == 64 and len(d["toolchain"]) == 1 and d["toolchain"][0].startswith("cat "), d
assert d["toolchain"][0].endswith("\n0\nv1\n"), d["toolchain"]
PY
# 19 toolchain output, commit and contract changes run it again; so does --refresh
echo v2 > "$TMP_ROOT/tool"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null); [[ "$(grep -c base "$mark")" -eq 2 ]] || fail "toolchain change must rerun"
git -C "$target" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m next
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null); [[ "$(grep -c base "$mark")" -eq 3 ]] || fail "commit change must rerun"
write_contract "{\"verification\":[{\"command\":\"$(stub base-changed)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null); [[ "$(grep -c base "$mark")" -eq 4 ]] || fail "contract change must rerun"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null); [[ "$(grep -c base "$mark")" -eq 4 ]] || fail "unchanged key must stay cached"
(cd "$target" && scripts/agent-guard.sh baseline --refresh >/dev/null); [[ "$(grep -c base "$mark")" -eq 5 ]] || fail "--refresh must rerun"
# a dirty tree always runs and records dirty:true; a dirty report is never reused
echo dirty > "$target/baseline-dirty.txt"
err="$(cd "$target" && scripts/agent-guard.sh baseline 2>&1 >/dev/null)"; (cd "$target" && scripts/agent-guard.sh baseline >/dev/null 2>&1)
[[ "$(grep -c base "$mark")" -eq 7 ]] || fail "dirty tree must always rerun"
[[ "$err" == *"agent-guard: warn: baseline on a dirty tree (working tree, not HEAD)"* ]] || fail "dirty baseline must warn: $err"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["dirty"] is True, d' "$baseline_report" || fail "dirty baseline must record dirty:true"
rm -f "$target/baseline-dirty.txt"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null); [[ "$(grep -c base "$mark")" -eq 8 ]] || fail "dirty report must not be reused on a clean tree"
# a cached fast result is not reused for --verify-scope full
(cd "$target" && scripts/agent-guard.sh baseline --verify-scope full >/dev/null); [[ "$(grep -c base "$mark")" -eq 9 ]] || fail "full scope must not reuse a fast result"
(cd "$target" && scripts/agent-guard.sh baseline --verify-scope full >/dev/null); [[ "$(grep -c base "$mark")" -eq 9 ]] || fail "full scope result must be cached"
# toolchain probes: a non-zero exit is recorded and stable, an unparseable
# command does not crash, and neither a hung probe nor a daemon it leaves
# holding its output blocks past AGENT_GUARD_TOOLCHAIN_TIMEOUT
printf '#!/bin/sh\necho broken\nexit 3\n' > "$TMP_ROOT/red-tool"
cat > "$TMP_ROOT/slow-tool" <<'SH'
#!/bin/sh
python3 -c 'import subprocess; subprocess.Popen(["sleep", "20"], start_new_session=True)'
[ "$1" = hang ] && sleep 20
exit 0
SH
chmod +x "$TMP_ROOT/red-tool" "$TMP_ROOT/slow-tool"
write_contract "{\"toolchain\":[\"$TMP_ROOT/red-tool\",\"bad \\\"quote\"]}"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null) || fail "toolchain failures must not fail baseline"
python3 - "$baseline_report" "$TMP_ROOT/red-tool" <<'PY' || fail "toolchain exit code and unparseable command must be recorded"
import json, sys
t = json.load(open(sys.argv[1]))["toolchain"]
assert t == [sys.argv[2] + "\n3\nbroken\n", 'bad "quote\n127\nunparseable command'], t
PY
(cd "$target" && scripts/agent-guard.sh baseline | grep -q cached) || fail "non-zero toolchain fingerprint must be stable"
write_contract "{\"toolchain\":[\"$TMP_ROOT/slow-tool exit\",\"$TMP_ROOT/slow-tool hang\"]}"
started=$SECONDS
(cd "$target" && AGENT_GUARD_TOOLCHAIN_TIMEOUT=1 scripts/agent-guard.sh baseline >/dev/null) || fail "slow toolchain baseline"
(( SECONDS - started < 12 )) || fail "toolchain probes must not block past the timeout ($((SECONDS - started))s)"
python3 - "$baseline_report" <<'PY' || fail "toolchain timeout must be recorded"
import json, sys
t = json.load(open(sys.argv[1]))["toolchain"]
assert t[0].endswith(" exit\n0\n") and t[1].endswith(" hang\ntimeout\n"), t
PY
# a tree changed by a toolchain probe or by the run itself is recorded as
# dirty and never reused
printf '#!/bin/sh\ntouch probe-made.txt\n' > "$TMP_ROOT/touch-tool"; chmod +x "$TMP_ROOT/touch-tool"
dirty_report() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["dirty"] is True, d' "$baseline_report"; }
write_contract "{\"toolchain\":[\"$TMP_ROOT/touch-tool\"]}"
err="$(cd "$target" && scripts/agent-guard.sh baseline 2>&1 >/dev/null)" || fail "probe-changed baseline: $err"
[[ "$err" == *"tree changed during the toolchain probes"* ]] || fail "probe tree change must warn: $err"
dirty_report || fail "probe tree change must record dirty:true"
rm -f "$target/probe-made.txt"
out="$(cd "$target" && scripts/agent-guard.sh baseline 2>/dev/null)" || fail "probe-changed baseline rerun: $out"
[[ "$out" != *cached* ]] || fail "probe tree change must not be reused: $out"
rm -f "$target/probe-made.txt"
write_contract "{\"verification\":[{\"command\":\"$TMP_ROOT/touch-tool\",\"purpose\":\"stub\",\"source\":\"test\"}],\"toolchain\":[\"cat $TMP_ROOT/tool\"]}"
err="$(cd "$target" && scripts/agent-guard.sh baseline 2>&1 >/dev/null)" || fail "run-changed baseline: $err"
[[ "$err" == *"tree changed during the baseline run"* ]] || fail "run tree change must warn: $err"
dirty_report || fail "run tree change must record dirty:true"
rm -f "$target/probe-made.txt"
write_contract "{\"verification\":[{\"command\":\"$(stub base-changed)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
rc=0; err="$(cd "$target" && AGENT_GUARD_TOOLCHAIN_TIMEOUT=0 scripts/agent-guard.sh baseline 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 1 && "$err" == *"AGENT_GUARD_TOOLCHAIN_TIMEOUT must be a positive integer"* ]] || fail "invalid toolchain timeout must be refused (got $rc): $err"
rc=0; err="$(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh baseline 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 1 && "$err" == *"AGENT_GUARD_VERIFY_SCOPE must be fast or full"* ]] || fail "invalid AGENT_GUARD_VERIFY_SCOPE must be refused (got $rc): $err"
rc=0; err="$(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh pre-final 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 1 && "$err" == *"AGENT_GUARD_VERIFY_SCOPE must be fast or full"* ]] || fail "pre-final must refuse an invalid AGENT_GUARD_VERIFY_SCOPE (got $rc): $err"
(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh baseline --verify-scope fast >/dev/null 2>&1) || fail "--verify-scope must override an invalid AGENT_GUARD_VERIFY_SCOPE (baseline)"
(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh pre-final --verify-scope fast >/dev/null 2>&1) || fail "--verify-scope must override an invalid AGENT_GUARD_VERIFY_SCOPE (pre-final)"
(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh pre-edit README.md >/dev/null 2>&1) || fail "pre-edit must ignore AGENT_GUARD_VERIFY_SCOPE"
(cd "$target" && AGENT_GUARD_VERIFY_SCOPE=medium scripts/agent-guard.sh check >/dev/null 2>&1) || fail "check must ignore AGENT_GUARD_VERIFY_SCOPE"
# a contract without toolchain[] records "undeclared"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("toolchain"); json.dump(d, open(p, "w"), indent=2)' "$contract"
(cd "$target" && scripts/agent-guard.sh baseline >/dev/null) || fail "baseline without toolchain"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["toolchain"] == "undeclared", d' "$baseline_report" || fail "missing toolchain must be undeclared"
# unverified: strict 4; advisory 0, also when the result is cached
write_contract '{"verification":[{"command":"run <placeholder>","purpose":"stub","source":"test"}]}'
rc=0; (cd "$target" && scripts/agent-guard.sh baseline >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 4 ]] || fail "unverified baseline must exit 4 (got $rc)"
out="$(cd "$target" && scripts/agent-guard.sh baseline --advisory 2>&1)" || fail "advisory unverified baseline must exit 0: $out"
[[ "$out" == *"baseline unverified (cached"* ]] || fail "advisory unverified baseline must reuse the result: $out"
# 20 baseline red: non-zero, also when cached
write_contract '{"verification":[{"command":"false","purpose":"red","source":"test"}]}'
rc=0; (cd "$target" && scripts/agent-guard.sh baseline >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 1 ]] || fail "red baseline must exit 1 (got $rc)"
rc=0; out="$(cd "$target" && scripts/agent-guard.sh baseline --advisory 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 && "$out" == *"baseline fail (cached"* ]] || fail "cached red baseline must exit 1 (got $rc): $out"
# an error (the command cannot start) is never reused
write_contract '{"verification":[{"command":"/nonexistent/baseline-missing","purpose":"error","source":"test"}]}'
for _ in 1 2; do
  rc=0; out="$(cd "$target" && scripts/agent-guard.sh baseline 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 2 && "$out" == *"baseline error ("* && "$out" != *cached* ]] || fail "error baseline must exit 2 and rerun (got $rc): $out"
done
cmp -s "$TMP_ROOT/last-verify-before.json" "$target/.agents/state/last-verify-report.json" || fail "baseline must not touch last-verify-report.json"

# Session-scoped Stop hook: close-out verifies only what changed since the
# session's snapshot, into its own closeout-<tag>-verify.json, and blocks with 2.
state="$target/.agents/state"
hook_json() { printf '{"session_id":"%s","stop_hook_active":%s}' "${1:-s1}" "${2:-false}"; }
start_session() { hook_json "${1:-s1}" | (cd "$target" && scripts/agent-hook.sh claude-session-start >/dev/null); }
close_out() { hook_json "$@" | (cd "$target" && scripts/agent-hook.sh close-out); }
report_for() { printf 'closeout-%s-verify.json' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-12)"; }
tcommit() { git -C "$target" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm "$1"; }
s1_report="$state/$(report_for s1)"
# 21 an unchanged session does not verify; a changed one does (a repeated
# SessionStart keeps the snapshot), and a pass advances the snapshot
write_contract "{\"verification\":[{\"command\":\"$(stub stop)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
echo dirty > "$target/other-seat.txt"   # change made before this session
start_session
[[ -f "$state/sessions/s1.snapshot" ]] || fail "session start must write a snapshot"
: > "$mark"
close_out || fail "unchanged session must not block"
[[ ! -s "$mark" ]] || fail "unchanged session must not verify"
[[ -f "$state/last-verify-report.json" ]] || fail "last-verify-report.json must exist before close-out"
before="$(shasum "$state/last-verify-report.json")"
echo edit >> "$target/via-bash.txt"      # this session's edit (Bash)
start_session                            # SessionStart again (resume/compact)
close_out || fail "passing change must not block"
grep -qx stop "$mark" || fail "changed session must verify (a repeated SessionStart must keep the snapshot)"
[[ -f "$s1_report" ]] || fail "close-out report file $s1_report"
[[ -f "$state/last-verify-report.json" && "$before" == "$(shasum "$state/last-verify-report.json")" ]] ||
  fail "close-out must not touch last-verify-report.json"
: > "$mark"
close_out || fail "verified session must not block"
[[ ! -s "$mark" ]] || fail "a passing close-out must advance the snapshot"
# 22 a failure blocks with 2 and keeps the snapshot; stop_hook_active never verifies
write_contract '{"verification":[{"command":"false","purpose":"red","source":"test"}]}'
echo edit2 >> "$target/via-bash.txt"
rc=0; err="$(close_out 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "failing change must block with 2 (got $rc): $err"
[[ "$err" == *"$s1_report"* ]] || fail "block must name the report path: $err"
rc=0; close_out >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "a blocked change must be verified again on the next Stop (got $rc)"
write_contract "{\"verification\":[{\"command\":\"$(stub active)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
: > "$mark"
close_out s1 true || fail "stop_hook_active must not block"
[[ ! -s "$mark" ]] || fail "stop_hook_active must not verify"
close_out || fail "fixed change must not block"
grep -qx active "$mark" || fail "fixed change must verify"
# what counts as a change: a mode change, a commit, a deletion and a rename
changed() {  # $1 label: the next close-out must verify, the one after must not
  : > "$mark"; close_out || fail "$1 must not block"
  grep -qx active "$mark" || fail "$1 must count as a change"
  : > "$mark"; close_out || fail "unchanged $1 must not block"
  [[ ! -s "$mark" ]] || fail "unchanged $1 must not verify"
}
chmod +x "$target/via-bash.txt"; changed "chmod +x"
printf 'a\n' > "$target/tracked-a.txt"; printf 'b\n' > "$target/tracked-b.txt"; changed "new files"
git -C "$target" add tracked-a.txt tracked-b.txt; tcommit "session files"; changed "commit"
# an edit committed before Stop leaves the path set unchanged; HEAD moves
printf 'a2\n' > "$target/tracked-a.txt"; git -C "$target" add tracked-a.txt; tcommit "session edit"
changed "commit after editing"
rm "$target/tracked-a.txt"; changed "deletion"
git -C "$target" mv tracked-b.txt renamed-b.txt; changed "rename"
# paths with spaces, tabs and newlines are compared by content
mkdir -p "$target/dir with space"
odd="$target/dir with space/tab	and
newline.txt"
echo one > "$odd"; changed "odd path"
echo two > "$odd"; changed "odd path content"
python3 - "$state/sessions/s1.snapshot" "$(git -C "$target" rev-parse HEAD)" <<'PY' || fail "snapshot must be HEAD then <path>\\t<sha256|deleted> lines"
import re, sys
lines = open(sys.argv[1], "rb").read().decode("utf-8").split("\n")
assert lines[0] == "HEAD\t" + sys.argv[2] and lines[-1] == "", lines
rows = dict(line.split("\t") for line in lines[1:-1])
assert all(re.fullmatch(r"[0-9a-f]{64}|deleted", v) for v in rows.values()), rows
assert sorted(rows) == ["dir with space/tab\\tand\\nnewline.txt", "other-seat.txt", "renamed-b.txt",
                        "tracked-a.txt", "tracked-b.txt", "via-bash.txt"], rows
assert rows["tracked-a.txt"] == rows["tracked-b.txt"] == "deleted", rows
PY
# 23 no snapshot skips; an unsafe session id is refused; a command that cannot
# start blocks; unverified warns and advances the snapshot
rc=0; err="$(close_out nosnap 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 0 && "$err" == *"agent-hook: close-out skipped (no session snapshot); run scripts/agent-guard.sh pre-final --run-verify"* ]] ||
  fail "missing snapshot must skip with exit 0 (got $rc): $err"
out="$(hook_json '../s1' | (cd "$target" && scripts/agent-hook.sh claude-session-start) 2>"$TMP_ROOT/start.err")" || fail "unsafe session id must not fail session start"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" || fail "session start stdout must stay JSON: $out"
[[ "$(cat "$TMP_ROOT/start.err")" == *session_id* ]] || fail "unsafe session id must warn: $(cat "$TMP_ROOT/start.err")"
[[ ! -e "$state/s1.snapshot" ]] || fail "unsafe session id must not name a file"
write_contract '{"verification":[{"command":"/nonexistent/x","purpose":"error","source":"test"}]}'
echo edit3 >> "$target/via-bash.txt"
rc=0; err="$(close_out 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 2 && "$err" == *"$s1_report"* ]] || fail "a command that cannot start must block (got $rc): $err"
write_contract '{"verification":[{"command":"run <placeholder>","purpose":"stub","source":"test"}]}'
rc=0; err="$(close_out 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 0 && "$err" == *unverified* ]] || fail "unverified must warn without blocking (got $rc): $err"
write_contract "{\"verification\":[{\"command\":\"$(stub after)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
: > "$mark"; close_out || fail "after unverified must not block"
[[ ! -s "$mark" ]] || fail "an unverified close-out must advance the snapshot"
# no report (pre-final aborted on a corrupt context pack) blocks
echo edit4 >> "$target/via-bash.txt"
printf '{broken' > "$state/context-pack.json"
rc=0; err="$(close_out 2>&1 >/dev/null)" || rc=$?
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight must restore the context pack"
[[ "$rc" -eq 2 && "$err" == *"report missing or unreadable"* ]] || fail "a missing report must block (got $rc): $err"
close_out || fail "restored verification must not block"
grep -qx after "$mark" || fail "a blocked missing report must re-verify"
# two sessions write two report files and logs
start_session s2
echo s2 >> "$target/via-bash.txt"
close_out s2 || fail "second session must not block"
[[ -f "$state/$(report_for s2)" && -f "$s1_report" && "$(report_for s2)" != "$(report_for s1)" ]] ||
  fail "each session must write its own close-out report"
[[ -f "$state/closeout-$(printf s2 | shasum -a 256 | cut -c1-12).err" ]] || fail "each session must write its own close-out log"
# AGENT_STATE_DIR inside the tree (not ignored): the snapshot follows it like
# the guard, and files under it never count as changes
inner="$target/inner-state"
git -C "$target" check-ignore -q inner-state/x && fail "inner-state must not be git-ignored"
(cd "$target" && AGENT_STATE_DIR="$inner" scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight with AGENT_STATE_DIR"
hook_json s3 | (cd "$target" && AGENT_STATE_DIR="$inner" scripts/agent-hook.sh claude-session-start >/dev/null)
[[ -f "$inner/sessions/s3.snapshot" && ! -e "$state/sessions/s3.snapshot" ]] || fail "session snapshot must honour AGENT_STATE_DIR"
: > "$mark"
hook_json s3 | (cd "$target" && AGENT_STATE_DIR="$inner" scripts/agent-hook.sh close-out) || fail "close-out with AGENT_STATE_DIR"
[[ ! -s "$mark" ]] || fail "files under the hook state dir must not count as changes"
echo inner >> "$target/via-bash.txt"
hook_json s3 | (cd "$target" && AGENT_STATE_DIR="$inner" scripts/agent-hook.sh close-out) || fail "changed close-out with AGENT_STATE_DIR"
grep -qx after "$mark" && [[ -f "$inner/$(report_for s3)" ]] || fail "close-out must verify into AGENT_STATE_DIR"
: > "$mark"
hook_json s3 | (cd "$target" && AGENT_STATE_DIR="$inner" scripts/agent-hook.sh close-out) || fail "settled close-out with AGENT_STATE_DIR"
[[ ! -s "$mark" ]] || fail "the close-out's own report and logs must not count as changes"
# the Stop hook allows the fast budget plus slack
python3 - "$target/.claude/settings.json" <<'PY' || fail "Stop hook must declare timeout 360"
import json, sys
stop = json.load(open(sys.argv[1]))["hooks"]["Stop"]
assert [(h["command"], h.get("timeout")) for e in stop for h in e["hooks"]] == [("./scripts/agent-hook.sh close-out", 360)], stop
PY

# 24 the close-out caps the guard's total budget at 300 s whatever the environment asks
: > "$mark"; echo cap >> "$target/via-bash.txt"
write_contract "{\"verification\":[{\"command\":\"$(stub cap)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
hook_json s4 | (cd "$target" && scripts/agent-hook.sh claude-session-start >/dev/null)
echo cap2 >> "$target/via-bash.txt"
hook_json s4 | (cd "$target" && AGENT_GUARD_VERIFY_TOTAL_FAST_SECONDS=9999 scripts/agent-hook.sh close-out) || fail "capped close-out must not block"
python3 - "$state/$(report_for s4)" <<'PY' || fail "close-out budget must be capped at 300"
import json, sys
assert json.load(open(sys.argv[1]))["budget_seconds"] == 300
PY

# 25 the Claude edit hook blocks (exit 2) on every guard refusal, not only protected paths
edit_json() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }
pretool() { local p="$1"; shift; rc=0; edit_json "$p" | (cd "$target" && env "$@" scripts/agent-hook.sh claude-pretool >"$TMP_ROOT/pre.out" 2>"$TMP_ROOT/pre.err") || rc=$?; }
echo hi > "$target/src.txt"
pretool "$target/src.txt" X=1
[[ "$rc" -eq 0 ]] || fail "a normal edit must pass (got $rc): $(cat "$TMP_ROOT/pre.err")"
pretool "$target/AGENTS.md" X=1
[[ "$rc" -eq 2 ]] || fail "a protected path must block with 2 (got $rc): $(cat "$TMP_ROOT/pre.err")"
pretool /etc/hosts X=1
[[ "$rc" -eq 2 ]] || fail "outside root must block (got $rc)"
ctx="$target/docs/agent-configs/project-agent-context.md"
mv "$ctx" "$TMP_ROOT/ctx.bak"
pretool "$target/src.txt" X=1
mv "$TMP_ROOT/ctx.bak" "$ctx"
[[ "$rc" -eq 2 ]] || fail "missing context must block (got $rc)"
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight must pass after restoring context"
pretool "$target/src.txt" AGENT_HOOK_PYTHON=/nonexistent
[[ "$rc" -eq 0 && "$(cat "$TMP_ROOT/pre.err")" == *warn* ]] || fail "missing python3 must warn, not block (got $rc)"

# ---- seats: strict validation, model-overlap fact, roster drift, legacy efforts
seats="$target/docs/agent-configs/seats.json"
seatsh() { (cd "$target" && scripts/agent-seats.sh "$@"); }
cp "$seats" "$TMP_ROOT/seats.orig"
seatsh validate >/dev/null 2>&1 || fail "default generated seats.json must validate"
seats_mutate() {  # python statement over the seats document `d`
  python3 - "$seats" "$1" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"))
PY
}
for mutation in 'd["extra"]=1' 'd["seats"]["extra"]=d["seats"]["spec"]' 'd["seats"]["build"]["bogus"]=1' \
  'd["seats"]["build"]["occupant"]["bogus"]=1' 'd["catalog"]["bogus"]=1' \
  'd["catalog"]["models"]["gpt-5.6-luna"]["bogus"]=1'; do
  seats_mutate "$mutation"
  seatsh validate >/dev/null 2>&1 && fail "seats.json mutation must be rejected: $mutation"
  cp "$TMP_ROOT/seats.orig" "$seats"
done
seatsh validate >/dev/null 2>&1 || fail "restored seats.json must validate"
# overlap is a fact, never an authorization
gate_model="$(seatsh resolve gate | sed -n 5p)"
build_model="$(seatsh resolve build | sed -n 5p)"
[[ "$(seatsh model-overlap build "$gate_model" 2>/dev/null)" == *gate* ]] || fail "overlap must name @gate"
[[ "$(seatsh model-overlap verify "$build_model" 2>/dev/null)" == *build* ]] || fail "verify on the build model must name build"
[[ -z "$(seatsh model-overlap build unrelated-model-x 2>/dev/null)" ]] || fail "unrelated model must print nothing"
seatsh model-overlap build "$gate_model" 2>&1 | grep -q gate_coding && fail "overlap output must not mention gate_coding"
seatsh model-overlap build "$gate_model" 2>&1 >/dev/null | grep -q 'is also the primary model of' || fail "model-overlap must note the overlap"
quiet_err="$(seatsh model-overlap --quiet build "$gate_model" 2>&1 >/dev/null)"
[[ -z "$quiet_err" && "$(seatsh model-overlap --quiet build "$gate_model" 2>/dev/null)" == *gate* ]] ||
  fail "model-overlap --quiet must print the seats and no note: $quiet_err"
# roster drift
seatsh roster-check AGENTS.md >/dev/null 2>&1 || fail "roster-check must pass on a fresh target"
cp "$target/AGENTS.md" "$TMP_ROOT/agents.orig"
sed -i.bak 's/`@verify` · verification/`@verifyX` · verification/' "$target/AGENTS.md"; rm -f "$target/AGENTS.md.bak"
drift_err="$(seatsh roster-check AGENTS.md 2>&1 >/dev/null)" && fail "roster drift must be reported"
[[ "$drift_err" == *"roster drift: run scripts/agent-seats.sh render"* ]] || fail "drift message: $drift_err"
cp "$TMP_ROOT/agents.orig" "$target/AGENTS.md"
printf '# no roster\n' > "$TMP_ROOT/plain.md"
nomark_err="$(seatsh roster-check "$TMP_ROOT/plain.md" 2>&1 >/dev/null)" && fail "missing markers must fail"
[[ "$nomark_err" == *markers* ]] || fail "missing-marker message: $nomark_err"
# legacy profile with an effort outside the allowed set must not break init
python3 - "$ROOT_DIR/agent-bootstrap/model-profiles/codex-model-profiles.json" "$target/docs/agent-configs/model-profiles.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["profiles"]["stable"]["reasoning_effort"] = "minimal"
d["profiles"]["stable"]["planning_model"] = "custom-planner"
json.dump(d, open(sys.argv[2], "w"))
PY
rm -f "$seats"
rc=0; init_out="$(seatsh init 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$init_out" == *minimal* ]] || fail "init must survive legacy effort 'minimal' and name it (rc=$rc): $init_out"
rm -f "$target/docs/agent-configs/model-profiles.json"
cp "$TMP_ROOT/seats.orig" "$seats"
seatsh validate >/dev/null 2>&1 || fail "seats.json must validate after restore"

# ---- codex-mode: routing, @gate lock, model_overlap seed, @build close-out, roster doctor
# A stub Codex records its arguments and exits with $STUB_CODEX_RC. With
# STUB_CODEX_STDIN it copies one stdin line there; with STUB_CODEX_SIGNAL_DIR it
# records its parent (the launcher), waits at most 20 s for SIGTERM and exits 42
# on it; with STUB_CODEX_INT_DIR it records its pid and becomes `sleep 20`, which
# only an un-ignored SIGINT ends early.
stubbin="$TMP_ROOT/bin"; mkdir -p "$stubbin"
codex_args="$TMP_ROOT/codex-args"
{ printf '#!/bin/sh\nargs_file=%s\n' "$codex_args"; cat <<'STUB'; } > "$stubbin/codex"
printf '%s\n' "$@" > "$args_file"
if [ -n "${STUB_CODEX_STDIN:-}" ]; then
  IFS= read -r line || line="no stdin"
  printf '%s\n' "$line" > "$STUB_CODEX_STDIN"
fi
if [ -n "${STUB_CODEX_SIGNAL_DIR:-}" ]; then
  trap 'echo TERM > "$STUB_CODEX_SIGNAL_DIR/term"; exit 42' TERM
  echo "$PPID" > "$STUB_CODEX_SIGNAL_DIR/ppid"
  i=0
  while [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  exit 0
fi
if [ -n "${STUB_CODEX_INT_DIR:-}" ]; then
  echo "$$" > "$STUB_CODEX_INT_DIR/pid"
  exec sleep 20
fi
exit "${STUB_CODEX_RC:-0}"
STUB
chmod +x "$stubbin/codex"
launch() {  # launch [VAR=value...] <codex-mode args...>; sets rc, writes launch.out/launch.err
  rc=0; rm -f "$codex_args"
  (cd "$target" && env -u CODEX_HARNESS_SESSION -u CODEX_SKIP_CLOSEOUT -u AGENT_WORKSPACE_CONTEXT \
    -u AGENT_HOST_SESSION_ID -u CODEX_MODEL_OVERRIDE -u CODEX_PLANNING_MODEL_OVERRIDE \
    -u CODEX_GATING_MODEL_OVERRIDE -u CODEX_CODING_MODEL_OVERRIDE -u CODEX_REVIEWING_MODEL_OVERRIDE \
    -u CODEX_USE_FALLBACK -u CODEX_REASONING_EFFORT PATH="$stubbin:$PATH" "$@") \
    >"$TMP_ROOT/launch.out" 2>"$TMP_ROOT/launch.err" || rc=$?
}
launched_ok() {  # the launch exited 0 and Codex received arguments
  [[ "$rc" -eq 0 && -s "$codex_args" ]] || fail "$1 (rc=$rc): $(launched)"
}
launched() { cat "$TMP_ROOT/launch.out" "$TMP_ROOT/launch.err"; }
write_contract "{\"verification\":[{\"command\":\"$(stub closeout)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
: > "$mark"
# 27 planning opens @spec; a seat held by another host is refused with the move hint
launch .codex/codex-mode.sh planning x
[[ "$rc" -ne 0 && ! -e "$codex_args" ]] || fail "planning on a claude-held @spec must refuse without launching (rc=$rc)"
grep -qF 'seat @spec is occupied by claude; open it there, or move it with scripts/agent-seats.sh set spec --host codex --model <id>' \
  "$TMP_ROOT/launch.err" || fail "planning must resolve @spec with the move hint: $(launched)"
# @gate gets the technical-review lock (baseline, verdict first, contract severity, later rounds read revisions)
launch .codex/codex-mode.sh @gate x
[[ "$rc" -eq 0 ]] || fail "@gate launch failed (rc=$rc): $(launched)"
grep -q 'MODE LOCK: TECHNICAL-REVIEW' "$codex_args" || fail "@gate must get the technical review lock"
grep -q 'MODE LOCK: PLANNING' "$codex_args" && fail "@gate must not get the planning lock"
for rule in 'agent-guard.sh baseline' 'Open with the verdict' "severity rule" 'previous verdict' 'Specification revision'; do
  grep -qF "$rule" "$codex_args" || fail "@gate lock must state: $rule"
done
grep -q 'authorization=' "$codex_args" "$TMP_ROOT/launch.err" && fail "launcher must never write authorization"
grep -qx 'mode=gating' "$target/.codex-mode-lock" || fail "@gate must persist route gating"
launch .codex/codex-mode.sh status
[[ "$rc" -eq 0 ]] && grep -qx 'Current mode: gating' "$TMP_ROOT/launch.out" || fail "status must accept route gating: $(launched)"
launch .codex/codex-mode.sh run x
launched_ok "run must relaunch the locked @gate"
grep -q 'MODE LOCK: TECHNICAL-REVIEW' "$codex_args" || fail "run must relaunch the locked @gate with its lock"
# a lock without seat= (mode=planning meant @gate) and no lock at all both relaunch @gate
cp "$target/.codex-mode-lock" "$TMP_ROOT/lock.orig"
printf 'mode=planning\nflow=full_flow\n' > "$target/.codex-mode-lock"
launch .codex/codex-mode.sh run x
launched_ok "a legacy planning lock must relaunch"
grep -q 'MODE LOCK: TECHNICAL-REVIEW' "$codex_args" && grep -qx "$gate_model" "$codex_args" ||
  fail "a legacy mode=planning lock must relaunch @gate: $(cat "$codex_args")"
rm -f "$target/.codex-mode-lock"
launch .codex/codex-mode.sh run x
launched_ok "run without a lock must launch"
grep -q 'MODE LOCK: TECHNICAL-REVIEW' "$codex_args" || fail "run without a lock must open @gate"
cp "$TMP_ROOT/lock.orig" "$target/.codex-mode-lock"
# the planning route override now belongs to @spec; @gate warns and names its own override
launch CODEX_PLANNING_MODEL_OVERRIDE=unrelated-model-x .codex/codex-mode.sh @gate x
launched_ok "@gate with a planning override must launch"
grep -qx "$gate_model" "$codex_args" || fail "the planning override must not reach @gate"
grep -q 'WARN: CODEX_PLANNING_MODEL_OVERRIDE.*CODEX_GATING_MODEL_OVERRIDE' "$TMP_ROOT/launch.err" ||
  fail "@gate must warn that the planning override moved: $(launched)"
[[ ! -s "$mark" ]] || fail "only @build runs the close-out"
# 26 (seed) @build on @gate's model: a model_overlap fact and a warning, never an authorization
cp "$target/AGENTS.md" "$TMP_ROOT/agents.orig"
seatsh set @build --model "$gate_model" >/dev/null 2>&1 || fail "cannot move @build onto $gate_model"
launch CODEX_SKIP_CLOSEOUT=1 .codex/codex-mode.sh @build x
cp "$TMP_ROOT/seats.orig" "$seats"; cp "$TMP_ROOT/agents.orig" "$target/AGENTS.md"
[[ "$rc" -eq 0 ]] || fail "overlapping @build launch must not be refused (rc=$rc): $(launched)"
grep -q 'model_overlap=gate' "$codex_args" || fail "seed must record model_overlap=gate: $(cat "$codex_args")"
grep -q 'WARN.*model_overlap=gate' "$TMP_ROOT/launch.err" || fail "overlap must warn on stderr: $(launched)"
grep -q 'authorization=\|policy_exception' "$codex_args" "$TMP_ROOT/launch.err" && fail "overlap must never be written as an authorization"
[[ "$(grep -c 'model_overlap=gate' "$TMP_ROOT/launch.err")" -eq 1 ]] || fail "one overlap warns once: $(launched)"
grep -q 'is also the primary model of' "$TMP_ROOT/launch.err" && fail "the launcher's overlap query must be quiet: $(launched)"
launch CODEX_SKIP_CLOSEOUT=1 .codex/codex-mode.sh @build x
launched_ok "default @build launch"
grep -q 'model_overlap=' "$codex_args" && fail "no overlap on the default roster"
# 27 @build: Codex runs as a child, pre-final runs once after it, Codex's exit code wins
[[ ! -s "$mark" ]] || fail "CODEX_SKIP_CLOSEOUT=1 must skip the close-out"
launched | grep -q 'verify_report=' && fail "CODEX_SKIP_CLOSEOUT=1 must not report a verification"
launch STUB_CODEX_RC=7 .codex/codex-mode.sh @build x
[[ "$rc" -eq 7 ]] || fail "@build must exit with Codex's exit code (got $rc): $(launched)"
[[ "$(grep -cx closeout "$mark")" -eq 1 ]] || fail "@build close-out must run pre-final --run-verify once"
closeout_report="$(launched | sed -n 's/.*verify_report=//p' | tail -n1)"
[[ -n "$closeout_report" && -f "$closeout_report" ]] || fail "@build close-out must print the report path: $(launched)"
launched | grep -q 'pre-final ok' || fail "@build close-out must print pre-final's last line: $(launched)"
# Codex keeps the terminal's stdin as a child
printf 'stdin-line\n' > "$TMP_ROOT/stdin-in"; : > "$mark"
launch STUB_CODEX_STDIN="$TMP_ROOT/stdin-got" .codex/codex-mode.sh @build x < "$TMP_ROOT/stdin-in"
launched_ok "@build with stdin"
grep -qx 'stdin-line' "$TMP_ROOT/stdin-got" || fail "stdin must reach the @build Codex child: $(cat "$TMP_ROOT/stdin-got")"
# a Codex that did not end normally (signal or exit >= 126) skips the close-out
: > "$mark"
launch STUB_CODEX_RC=130 .codex/codex-mode.sh @build x
[[ "$rc" -eq 130 && ! -s "$mark" ]] || fail "exit 130 must skip the close-out and keep 130 (rc=$rc)"
grep -qF '@build close-out skipped: Codex exited 130; run scripts/agent-guard.sh pre-final --run-verify' "$TMP_ROOT/launch.err" ||
  fail "a skipped close-out must say how to verify: $(launched)"
# background @build launch with one extra env assignment; sets bg_launch
launch_bg() {
  rm -f "$codex_args"
  (cd "$target" && env -u CODEX_HARNESS_SESSION -u CODEX_SKIP_CLOSEOUT -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID \
    PATH="$stubbin:$PATH" "$1" .codex/codex-mode.sh @build x) >"$TMP_ROOT/launch.out" 2>"$TMP_ROOT/launch.err" &
  bg_launch=$!
}
await_file() { for _ in $(seq 1 300); do [[ -s "$1" ]] && return 0; sleep 0.1; done; fail "stub did not write $1: $(launched)"; }
# SIGTERM to the launcher reaches Codex; the launcher exits with Codex's own status
sigdir="$TMP_ROOT/sig"; mkdir -p "$sigdir"; : > "$mark"
launch_bg STUB_CODEX_SIGNAL_DIR="$sigdir"
await_file "$sigdir/ppid"
kill -TERM "$(cat "$sigdir/ppid")"
rc=0; wait "$bg_launch" || rc=$?
[[ -s "$sigdir/term" ]] || fail "SIGTERM to the launcher must reach Codex (rc=$rc): $(launched)"
[[ "$rc" -eq 42 ]] || fail "the launcher must exit with Codex's status after SIGTERM (got $rc): $(launched)"
[[ ! -s "$mark" ]] || fail "SIGTERM must skip the close-out"
grep -q '@build close-out skipped: Codex exited 42 after SIGTERM' "$TMP_ROOT/launch.err" || fail "SIGTERM must report the skipped close-out: $(launched)"
# Codex does not inherit an ignored SIGINT: the stub dies from SIGINT sent to it alone
intdir="$TMP_ROOT/int"; mkdir -p "$intdir"
launch_bg STUB_CODEX_INT_DIR="$intdir"
await_file "$intdir/pid"
kill -INT "$(cat "$intdir/pid")"
rc=0; wait "$bg_launch" || rc=$?
[[ "$rc" -eq 130 ]] || fail "SIGINT must reach Codex with its default action (got $rc): $(launched)"
write_contract '{"verification":[{"command":"false","purpose":"red","source":"test"}]}'
launch .codex/codex-mode.sh @build x
[[ "$rc" -eq 0 ]] || fail "a failing close-out keeps Codex's exit code (got $rc): $(launched)"
launched | grep -q 'verify_report=' || fail "a failing close-out still names its report: $(launched)"
write_contract "{\"verification\":[{\"command\":\"$(stub closeout)\",\"purpose\":\"stub\",\"source\":\"test\"}]}"
: > "$mark"
launch .codex/codex-mode.sh @verify x
launched_ok "@verify launch"
[[ ! -s "$mark" ]] || fail "@verify must not run the close-out"
# 27 doctor warns on roster drift without failing because of it
launch .codex/codex-mode.sh doctor
grep -q 'ok .*seat roster in AGENTS.md matches seats.json' "$TMP_ROOT/launch.out" || fail "doctor must check the seat roster: $(launched)"
grep -q 'WARN.*roster drift' "$TMP_ROOT/launch.out" && fail "fresh roster must not drift"
sed -i.bak 's/`@verify` · verification/`@verifyX` · verification/' "$target/AGENTS.md"; rm -f "$target/AGENTS.md.bak"
launch .codex/codex-mode.sh doctor
cp "$TMP_ROOT/agents.orig" "$target/AGENTS.md"
grep -q 'WARN.*roster drift.*scripts/agent-seats.sh render' "$TMP_ROOT/launch.out" || fail "doctor must warn on roster drift: $(launched)"
# (editing AGENTS.md also fails the guard's context-pack check; that is not the roster check)
grep -q 'FAIL.*roster' "$TMP_ROOT/launch.out" && fail "roster drift must be a warning, not a doctor failure: $(launched)"

# 31 context budget: the verifier counts what seats read; kit text above a gate
# fails, project content (user-owned files, USER regions) above a gate only warns
budget="$TMP_ROOT/budget"
mkdir -p "$budget"
git -C "$budget" init -q
# A fixed name: the project name is counted text, so the kit numbers stay stable.
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$budget" --workflow full \
  --project-name budget-fixture >/dev/null 2>&1
budget_run() {  # <out file> <verifier args...>; sets rc
  local out="$1"; shift
  rc=0
  (cd "$budget" && scripts/verify-ai-deps.sh "$@" </dev/null >"$out" 2>&1) || rc=$?
}
budget_field() {  # <json file> <core|on_demand> <key>
  python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["context_budget"][sys.argv[2]][sys.argv[3]])' "$@" ||
    fail "no context_budget.$2.$3 in $1"
}
pad_section() {  # <file> <exact line> <bytes>: insert filler right below that line
  python3 -B - "$@" <<'PY'
import pathlib, sys
path, heading, size = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
lines = path.read_text(encoding="utf-8").split("\n")
at = lines.index(heading) + 1
lines[at:at] = ["", ("filler " * (size // 7)).strip()]
path.write_text("\n".join(lines), encoding="utf-8")
PY
}
base_json="$TMP_ROOT/budget-base.json"
budget_run "$base_json" --json
[[ "$rc" -eq 0 ]] || fail "a fresh target must verify (rc=$rc): $(cat "$base_json")"
python3 -B - "$base_json" <<'PY' || fail "fresh target budget: $(cat "$base_json")"
import json, sys
budget = json.load(open(sys.argv[1]))["context_budget"]
for key, amber, gate in (("core", 3800, 4000), ("on_demand", 5900, 6200)):
    part = budget[key]
    assert (part["amber"], part["gate"]) == (amber, gate), part
    assert part["estimate"] == part["kit"] + part["project"] and part["project"] > 0, part
    # Ratchet on the kit's own text: a fresh target keeps it out of amber.
    assert part["kit"] <= amber and part["kit_status"] == "ok", part
    # A fresh install does not start with a warning: its project content is
    # still the kit's templates.
    assert part["status"] == "ok", part
PY
base_core="$(budget_field "$base_json" core estimate)"
base_core_kit="$(budget_field "$base_json" core kit)"
base_core_project="$(budget_field "$base_json" core project)"
base_on_demand="$(budget_field "$base_json" on_demand estimate)"
base_on_demand_kit="$(budget_field "$base_json" on_demand kit)"
# Change tiers: the tier text is paid for by trimming duplicates; the kit text
# must not grow past the 5203-token baseline it had before tiers.
[[ "$base_on_demand_kit" -le 5203 ]] || fail "on-demand kit text must be at most 5203 tokens, got $base_on_demand_kit"
# Budget by tier: small is core, large is on-demand, medium adds tier-medium.md
# (reported only; large sessions never read it).
python3 -B - "$base_json" "$budget/docs/agent-configs/tier-medium.md" <<'PY' || fail "tier budgets: $(cat "$base_json")"
import json, sys
budget = json.load(open(sys.argv[1]))["context_budget"]
raw = open(sys.argv[2], "rb").read()
words = len(raw.decode("utf-8").split())
medium_doc = int(max(len(raw) / 4, words * 1.3))
tiers = budget["tiers"]
assert tiers["small"]["estimate"] == budget["core"]["estimate"], tiers
assert tiers["large"]["estimate"] == budget["on_demand"]["estimate"], tiers
assert tiers["medium"]["estimate"] == tiers["small"]["estimate"] + medium_doc, (tiers, medium_doc)
assert (tiers["small"]["amber"], tiers["small"]["gate"]) == (3800, 4000), tiers
assert (tiers["large"]["amber"], tiers["large"]["gate"]) == (5900, 6200), tiers
assert "gate" not in tiers["medium"] and "amber" not in tiers["medium"], tiers
assert tiers["large"]["kit"] <= 5203, tiers
PY
saved_target="$target"; target="$budget"
doc_has docs/agent-configs/tier-medium.md '## Planned files' 'same_vendor' 'reviewer_model: human' \
  'CODEX_REASONING_EFFORT=high' 'tier close'
doc_has AGENTS.md 'tier-medium.md'
target="$saved_target"
budget_run "$TMP_ROOT/budget-only.json" --json --context-budget
python3 -B -c 'import json,sys; a, b = (json.load(open(p))["context_budget"] for p in sys.argv[1:]); assert a == b, (a, b)' \
  "$base_json" "$TMP_ROOT/budget-only.json" || fail "--context-budget must report the full run's numbers"
(cd "$budget" && .codex/codex-mode.sh doctor </dev/null >"$TMP_ROOT/budget-doctor.out" 2>&1) || true
for line in "core startup context estimate: $base_core tokens (gate 4000, amber above 3800)" \
  "kit core startup context estimate: $base_core_kit tokens (gate 4000, amber above 3800)" \
  "on-demand full workflow context estimate: $base_on_demand tokens (gate 6200, amber above 5900)" \
  "kit on-demand full workflow context estimate: $base_on_demand_kit tokens (gate 6200, amber above 5900)"; do
  # Kit lines must stay ok; a total may warn (project content is the user's).
  prefix=""; [[ "$line" == kit* ]] && prefix="ok    "
  grep -Fq "$prefix$line" "$TMP_ROOT/budget-doctor.out" ||
    fail "doctor must relay the verifier's line '$line': $(cat "$TMP_ROOT/budget-doctor.out")"
done
(cd "$budget" && scripts/agent-guard.sh pre-final --advisory </dev/null >/dev/null 2>&1) || true
python3 -B -c 'import json,sys; e = [json.loads(l) for l in open(sys.argv[1]) if l.strip()][-1]["token_estimate"]; assert e == {"core_startup": int(sys.argv[2]), "core_startup_kit": int(sys.argv[3])}, e' \
  "$budget/.agents/state/session-events.jsonl" "$base_core" "$base_core_kit" ||
  fail "the guard event must estimate core as the verifier does"
# (a) Project content past the core gate warns, naming the file; the verifier still passes.
brief="$budget/docs/agent-configs/project-brief.md"
cp "$brief" "$TMP_ROOT/brief.orig"
pad_section "$brief" '## Open questions' $(( (4100 - base_core) * 4 ))
budget_run "$TMP_ROOT/budget-over.out"
[[ "$rc" -eq 0 ]] ||
  fail "project content above the core gate must not fail the verifier: $(grep -E 'FAIL|context' "$TMP_ROOT/budget-over.out")"
grep -Eq 'warn  core startup context estimate: [0-9]+ tokens exceeds gate 4000; project content is yours to shorten: docs/agent-configs/project-brief.md [0-9]+' \
  "$TMP_ROOT/budget-over.out" || fail "the core warning must name project-brief.md: $(grep context "$TMP_ROOT/budget-over.out")"
grep -Fq "ok    kit core startup context estimate: $base_core_kit tokens" "$TMP_ROOT/budget-over.out" ||
  fail "the brief is not kit text: $(grep context "$TMP_ROOT/budget-over.out")"
grep -Fq 'enforced by the harness test suite' "$TMP_ROOT/budget-over.out" && fail "the verifier itself enforces the gate"
cp "$TMP_ROOT/brief.orig" "$brief"
# Between amber and the gate the total only warns.
pad_section "$brief" '## Open questions' $(( (3900 - base_core) * 4 ))
budget_run "$TMP_ROOT/budget-amber.json" --json --context-budget
python3 -B - "$TMP_ROOT/budget-amber.json" <<'PY' || fail "a core estimate in amber must warn, not fail: $(cat "$TMP_ROOT/budget-amber.json")"
import json, sys
report = json.load(open(sys.argv[1]))
assert report["context_budget"]["core"]["status"] == "amber", report
assert report["context_budget"]["core"]["kit_status"] == "ok", report
core = [c["status"] for c in report["checks"] if c["label"].startswith("core startup context estimate")]
assert core == ["warn"], core
PY
cp "$TMP_ROOT/brief.orig" "$brief"
# (b) Kit text past a gate fails the verifier.
contracts="$budget/docs/agent-configs/agent-mode-contracts.md"
cp "$contracts" "$TMP_ROOT/contracts.orig"
pad_section "$contracts" '## Planning Mode' $(( (6300 - base_on_demand_kit) * 4 ))
budget_run "$TMP_ROOT/budget-kit-over.out" --context-budget
[[ "$rc" -ne 0 ]] || fail "kit text above the on-demand gate must fail the verifier: $(cat "$TMP_ROOT/budget-kit-over.out")"
grep -Eq 'FAIL  kit on-demand full workflow context estimate: [0-9]+ tokens exceeds gate 6200' "$TMP_ROOT/budget-kit-over.out" ||
  fail "the kit gate must be a recorded error: $(cat "$TMP_ROOT/budget-kit-over.out")"
cp "$TMP_ROOT/contracts.orig" "$contracts"
# (c) Text inside a USER region is project content.
cp "$budget/AGENTS.md" "$TMP_ROOT/budget-agents.orig"
pad_section "$budget/AGENTS.md" '<!-- BEGIN USER: agents:extra -->' 2000
budget_run "$TMP_ROOT/budget-user.json" --json --context-budget
[[ "$(budget_field "$TMP_ROOT/budget-user.json" core kit)" -eq "$base_core_kit" ]] || fail "USER region text must not count as kit"
[[ $(( $(budget_field "$TMP_ROOT/budget-user.json" core project) - base_core_project )) -ge 450 ]] ||
  fail "USER region text must count as project: $(cat "$TMP_ROOT/budget-user.json")"
cp "$TMP_ROOT/budget-agents.orig" "$budget/AGENTS.md"
# (d) Detector output (stacks, modules, commands, warnings) is project content: 40
# Gradle modules raise project and leave the kit's text unchanged.
modbig="$TMP_ROOT/modbig"
mkdir -p "$modbig"
git -C "$modbig" init -q
for i in $(seq -w 1 40); do printf 'include(":feature-%s")\n' "$i"; done > "$modbig/settings.gradle.kts"
# The same name as the budget target, so only the modules differ.
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$modbig" --workflow full \
  --project-name budget-fixture >/dev/null 2>&1
grep -Fq -- '- `:feature-40`' "$modbig/AGENTS.md" || fail "the detector must list the 40 modules in AGENTS.md"
(cd "$modbig" && scripts/verify-ai-deps.sh --json --context-budget </dev/null >"$TMP_ROOT/budget-modules.json" 2>&1) ||
  fail "detected modules must never fail the verifier: $(cat "$TMP_ROOT/budget-modules.json")"
python3 -B - "$base_json" "$TMP_ROOT/budget-modules.json" <<'PY' || fail "detected modules must count as project: $(cat "$TMP_ROOT/budget-modules.json")"
import json, sys
base, big = (json.load(open(path))["context_budget"] for path in sys.argv[1:])
for key in ("core", "on_demand"):
    assert big[key]["kit"] == base[key]["kit"], (key, base[key], big[key])
    assert big[key]["project"] >= base[key]["project"] + 150, (key, base[key], big[key])
PY
# task-journal.md is not counted; the reference's State values section is.
reference="$budget/docs/agent-configs/agent-handoff-reference.md"
printf '\n%s\n' "$(printf 'journal %.0s' $(seq 1 1000))" >> "$budget/docs/agent-configs/task-journal.md"
pad_section "$reference" '## State values' 600
budget_run "$TMP_ROOT/budget-sections.json" --json --context-budget
grown=$(( $(budget_field "$TMP_ROOT/budget-sections.json" on_demand estimate) - base_on_demand ))
[[ "$grown" -ge 120 && "$grown" -le 200 ]] ||
  fail "on-demand must grow by the State values padding only (grew $grown): $(cat "$TMP_ROOT/budget-sections.json")"
[[ "$(budget_field "$TMP_ROOT/budget-sections.json" core estimate)" -eq "$base_core" ]] || fail "core must not change"
# The largest section a seat writes is counted, whichever it is.
pad_section "$reference" '### `audit-review.md`' 4000
budget_run "$TMP_ROOT/budget-largest.json" --json --context-budget
python3 -B -c 'import json,sys; s = json.load(open(sys.argv[1]))["context_budget"]["on_demand"]["reference_sections"]; assert s == ["State values", "`audit-review.md`"], s' \
  "$TMP_ROOT/budget-largest.json" || fail "the padded audit-review section must be the largest written section"
[[ $(( $(budget_field "$TMP_ROOT/budget-largest.json" on_demand estimate) - base_on_demand - grown )) -gt 600 ]] ||
  fail "the largest written section must be counted: $(cat "$TMP_ROOT/budget-largest.json")"

printf 'verification-evidence-test: ok\n'
