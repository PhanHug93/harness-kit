# Harness Path B Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Part A closed loop from convention-by-doc into an actually-enforced loop — a runtime Stop-hook that runs verification at close-out, an injection-safe runner, honest pass/warn/fail telemetry, no false-greens, a wall-clock budget — plus the maintainability hardening (extension guide, mirror discovery, version coherence) that keeps the kit evolvable.

**Architecture:** Keep the kit dependency-light: Bash 3.2+ orchestration + Python 3 stdlib, no new deps. Verification execution stays inside `agent-guard.sh` (shipped to targets by wholesale `copy_bundle_file`, so no heredoc mirror). The keystone is wiring a **Claude Code Stop hook** into the generated `.claude/settings.json` (the only tool surface with a close-out hook mechanism — Gemini/Cursor/Windsurf have none, so for them the loop stays advisory and the docs must say so). The injection fix is to drop `shell=True`: run detected commands with `shell=False` after `shlex.split` — shell metacharacters then become inert literal argv tokens, so a hostile module/path name cannot inject. Telemetry moves from a single pass-path call to a `pre_final`-scoped `EXIT` trap that records every close-out outcome.

**Tech Stack:** Bash 3.2+, Python 3 stdlib (`subprocess`, `shlex`, `json`, `signal`, `os`, `time`), Git, existing `agent-bootstrap` writer/render/test harness, Claude Code hooks (`Stop`).

---

## Scope Boundary

**Includes (the reviewed verdict's required changes):**

- Item 4 — injection-safe runner: `shell=False` + `shlex.split`, skip unparseable commands.
- Items 2,3 — `EXIT`-trap telemetry for all close-out outcomes; `gate_status` vs `verification.status` split; event schema **v2**; `error` state; the `verification.status==fail ⇒ gate_status!=pass` invariant.
- Items 5,6 — "0 commands"/all-skipped must be pass-with-warn, never green; total wall-clock budget; "budget exhausted" is not a clean green.
- Item 1 (keystone) — close-out subcommand in `agent-hook.sh` **and** a generated `.claude/settings.json` Stop-hook registration, soft-signal by default, change-gated, blocking only on real test failure; honest non-Claude scoping.
- Items 7,8,9,11 — extension guide; mirror-discovery test; version bump `2026.06.24.2` + coherence test + behavioral changelog; targeted test diagnostics only.

**Excludes (deferred to a follow-up branch):**

- Item 10 — recovery/rollback docs + orphan-overlay surfacing (low backward-compat risk; not coupled to the runtime loop).
- **Token-level detector `argv`** (constructing argv from discrete tokens at each registration site). It is *not* needed for injection safety — `shell=False`+`shlex` already neutralizes metacharacters (they become inert argv tokens). Detector-emitted `argv` derived by `shlex` at emit time would be byte-equivalent to the runner doing `shlex` itself, so it adds no safety and is omitted (YAGNI). Revisit only if a future command legitimately needs a shell.
- Budget-economy telemetry fields (`token_estimate`, persisted `files_changed`) beyond what the gate needs.
- Any test-framework refactor (the suite stays fail-fast/single-file; Task 10 adds only targeted diagnostics).
- A general shell-execution sandbox. `--run-verify` runs the project's own build/test (arbitrary code by design). The `shell=False` work is **defense-in-depth, not a security boundary** — keep all wording consistent with that.

## Branch / PR Split & Sequencing

Land in dependency order so the runner is trustworthy before the loop is switched on by default:

1. **B-runtime-safety** — Tasks 1,2,3 then 4,5 (items 4,2,3,5,6). All touch `agent-guard.sh` (the runner + event); one PR. **Carries the version bump (Task 9).**
2. **B-closed-loop-wiring** — Task 6 (item 1). Lands **last**, after the runner is trustworthy.
3. **B-maintainability** — Tasks 7,8,10 (items 7,8,11). Parallel branch, low blast radius.

(Task 9's version bump is in B-runtime-safety because that PR ships the first behavioral change. The changelog accrues a line when B-closed-loop-wiring lands.)

## Mirror Discipline (read before editing)

- `agent-guard.sh` → shipped by **wholesale copy** (`lib/writers-runtime.sh:248 copy_bundle_file`). Edits need **no** heredoc mirror, but the integration test byte-compares generated vs canonical (`need_same_file`, runtime-snapshot loop ~`scripts/test-bootstrap-multi-agent-project.sh:805`).
- `agent-hook.sh` → **heredoc-generated** in `lib/writers-runtime.sh` (`write_file "$TARGET_DIR/scripts/agent-hook.sh" <<'EOF'` ~L258). Item 1 edits MUST be mirrored there; `need_same_file` stays green.
- `.claude/settings.json` → written by `lib/writers-docs.sh` via **wholesale `write_file`** (infra ~L533, full ~L1241) — i.e. regenerated, not USER-overlay-merged. The Stop-hook edit applies to **both** writers; see Task 6 Step 5 note on the back-compat implication (user edits to settings.json are not preserved across regen — pre-existing behavior, called out so it is a conscious choice).

## File Structure

- Modify `agent-bootstrap/agent-guard.sh` — runner `shell=False`+`shlex`; budget; `gate_status`/`verification.status`; `EXIT`-trap telemetry; `error` state.
- Modify `agent-bootstrap/agent-hook.sh` — `close-out` subcommand (+ mirror `lib/writers-runtime.sh`).
- Modify `agent-bootstrap/lib/writers-docs.sh` — `.claude/settings.json` Stop-hook (infra + full); AGENTS/tool-contract honesty note.
- Create `agent-bootstrap/schemas/agent-guard-event-v2.schema.json` — telemetry event schema v2 (+ generated schema-catalog mirror + MANIFEST row).
- Create `docs/agent-configs/EXTENSION-GUIDE.md` — item 7.
- Modify `agent-bootstrap/VERSION`, `agent-bootstrap/bootstrap-multi-agent-project.sh`, `CHANGELOG.md`, `agent-bootstrap/MANIFEST.md`.
- Modify `scripts/test-bootstrap-multi-agent-project.sh` — all regressions.

---

### Task 0: Lock Branch And Confirm Current-State Facts

**Files:** none.

- [ ] **Step 1:** Run:
```bash
git branch --show-current   # expect feature/harness-path-b-hardening
git status --short          # expect empty
git rev-parse --short HEAD  # expect 8e88dbd
```

- [ ] **Step 2:** Confirm the facts this plan depends on:
```bash
grep -n 'append_pre_final_event "pass"' agent-bootstrap/agent-guard.sh   # exactly one site
grep -nE '"PreToolUse"|"Stop"' agent-bootstrap/lib/writers-docs.sh        # PreToolUse only, no Stop
grep -nE 'shell=True|shell=False' agent-bootstrap/agent-guard.sh          # shell=True today
grep -cn 'trap ' agent-bootstrap/agent-guard.sh                          # expect 0 existing traps (Task 2 relies on this)
```
If any differs, stop and reconcile this plan before coding.

---

### Task 1: Injection-Safe Runner (item 4) — branch B-runtime-safety

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-guard.sh`

**Design:** Drop `shell=True`. Run each command via `shlex.split` + `shell=False`. A hostile module name like `;rm -rf` then becomes inert literal argv tokens (the command fails; nothing executes). Commands that fail to tokenize are skipped. No detector/schema change — the safety is entirely in the runner (which ships by wholesale copy, no mirror).

- [ ] **Step 1: Write the failing injection regression test**

In `scripts/test-bootstrap-multi-agent-project.sh`, after the existing verify fixtures, add:
```bash
INJECT_DIR="$FIXTURE_DIR/verify-injection"
mkdir -p "$INJECT_DIR/scripts"
cat > "$INJECT_DIR/package.json" <<'EOF_INJECT_PKG'
{ "scripts": { "test": "bash -c 'true'" } }
EOF_INJECT_PKG
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$INJECT_DIR" --workflow full >/dev/null
(
  cd "$INJECT_DIR"
  git init -q; git config user.email t@e.invalid; git config user.name t; git add -A; git commit -qm base
  scripts/agent-guard.sh preflight >/dev/null
  # Forge a detector JSON whose command carries a shell-injection payload.
  cat > scripts/detect-agent-tech-stack.sh <<'EOF_FORGE'
#!/usr/bin/env bash
[[ "$1" == "--json" ]] && printf '%s\n' '{"schema":"agent-tech-stack-detection/v1","tech_stacks":["node_js"],"modules":[],"verification_commands":["npm test ; touch PWNED"],"warnings":[]}'
EOF_FORGE
  chmod +x scripts/detect-agent-tech-stack.sh
  PATH="$FAKE_NPM_DIR:$PATH" scripts/agent-guard.sh pre-final --run-verify --advisory >/dev/null 2>&1 || true
)
[[ ! -e "$INJECT_DIR/PWNED" ]] || fail "verification runner executed an injected command (shell=True regression)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-bootstrap-multi-agent-project.sh`
Expected: FAIL — `PWNED` created because the runner uses `shell=True`.

- [ ] **Step 3: Make the runner injection-safe (`agent-guard.sh`)**

Add `import shlex` to the runner heredoc's imports (next to `import subprocess`). Replace the `subprocess.Popen(command, ... shell=True, ...)` block (the `Popen(...)` call after `started = time.time()`, currently shell=True with `start_new_session=True`) with:
```python
    try:
        argv = shlex.split(command)
    except ValueError:
        argv = []
    if not argv:
        summary["skipped"] += 1
        results.append({"command": command, "status": "skipped", "reason": "unparseable_command"})
        print(f"agent-guard: warn: skipped unparseable verification command: {command}", file=sys.stderr)
        continue
    process = subprocess.Popen(
        argv, cwd=root, shell=False, text=True,
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )
```
Keep the existing timeout / `os.killpg` escalation path unchanged (it operates on `process`).

- [ ] **Step 4: Run focused checks**

Run:
```bash
bash -n agent-bootstrap/agent-guard.sh
scripts/test-bootstrap-multi-agent-project.sh
```
Expected: PASS; `PWNED` not created; existing verify-ok/fail/placeholder tests still pass (the `<scheme>` placeholder is still skipped by the existing regex before tokenization).

- [ ] **Step 5: Commit**
```bash
git add agent-bootstrap/agent-guard.sh scripts/test-bootstrap-multi-agent-project.sh
git commit -m "fix: run detected verification with shell=False (neutralizes shell injection)"
```

---

### Task 2: Close-Out Telemetry For All Outcomes (item 2)

**Files:** `scripts/test-bootstrap-multi-agent-project.sh`, `agent-bootstrap/agent-guard.sh`

**Design:** Replace the single pass-path `append_pre_final_event "pass"` with a `pre_final`-scoped `EXIT` trap. The trap must (1) capture `$?` on its first line; (2) only emit when `EMIT_CLOSEOUT` was armed inside `pre_final` (never for `preflight`/`check`/`pre-edit`/`doctor`); (3) be best-effort (a python error must not change the exit status); (4) write the real gate outcome, not a hardcoded `"pass"`. Task 0 Step 2 already confirmed there is no pre-existing `EXIT` trap to compose with.

- [ ] **Step 1: Write the failing fail-path telemetry test**

Add (reusing the `verify-prefinal-fail` fixture):
```bash
( cd "$VERIFY_FAIL_DIR" && PATH="$FAKE_NPM_DIR:$PATH" scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1 || true )
python3 - "$VERIFY_FAIL_DIR/.agents/state/session-events.jsonl" <<'PY'
import json, sys
last = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
assert last["event"] == "pre_final", last
assert last["gate_status"] == "fail", last
PY
```

- [ ] **Step 2: Run to verify it fails** → strict-mode verify failure aborts before any event is written.

- [ ] **Step 3: Add close-out gate state + scoped trap (`agent-guard.sh`)**

Near the state constants, add (initialized for `set -u` safety):
```bash
EMIT_CLOSEOUT=false
GATE_STATUS=fail        # pessimistic default; set to pass/warn only when reached intentionally
RUN_VERIFY_FLAG=false
```
Change `append_pre_final_event` to take the status from its first arg (no hardcoded "pass") and add the trap helper:
```bash
closeout_trap() {
  local code=$?
  [[ "$EMIT_CLOSEOUT" == "true" ]] || return 0
  [[ "$code" -ne 0 ]] && GATE_STATUS=fail
  append_pre_final_event "$GATE_STATUS" "$RUN_VERIFY_FLAG" || true
}
```

- [ ] **Step 4: Arm the trap inside `pre_final()` only**

At the top of `pre_final()` (after option parsing, before `load_policy`):
```bash
  RUN_VERIFY_FLAG="$run_verify"
  EMIT_CLOSEOUT=true
  trap closeout_trap EXIT
```
Remove the old `append_pre_final_event "pass" "$run_verify"` line. Set `GATE_STATUS=pass` immediately before the final `printf 'agent-guard: pre-final ok ...'` (Tasks 3–5 refine to `warn`).

- [ ] **Step 5: Prove the trap does not fire for other subcommands**
```bash
(
  cd "$VERIFY_OK_DIR"
  before=$(wc -l < .agents/state/session-events.jsonl 2>/dev/null || echo 0)
  for i in 1 2 3 4 5; do scripts/agent-guard.sh check >/dev/null 2>&1 || true; done
  after=$(wc -l < .agents/state/session-events.jsonl 2>/dev/null || echo 0)
  [[ "$before" == "$after" ]] || fail "non-pre-final subcommand emitted a close-out event"
)
```

- [ ] **Step 6: Run + commit** — `bash -n agent-bootstrap/agent-guard.sh && scripts/test-bootstrap-multi-agent-project.sh`; commit `feat: write close-out telemetry for all pre-final outcomes via scoped trap`.

---

### Task 3: `gate_status` vs `verification.status` Schema v2 (item 3)

**Files:** Create `agent-bootstrap/schemas/agent-guard-event-v2.schema.json`; Modify `scripts/test-bootstrap-multi-agent-project.sh`, `agent-bootstrap/agent-guard.sh`, `agent-bootstrap/MANIFEST.md`.

**Design:** `gate_status ∈ {pass,warn,fail}` (harness verdict); `verification.status ∈ {pass,fail,none,skipped,error}` (verify run; `error` = detector JSON invalid / python missing). Invariant: `verification.status=="fail" ⇒ gate_status!="pass"`. Event schema → `agent-guard-event/v2`.

- [ ] **Step 1: Write the failing invariant + advisory + error tests**
```bash
python3 - "$VERIFY_FAIL_DIR/.agents/state/session-events.jsonl" <<'PY'
import json, sys
last = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
assert last["schema"] == "agent-guard-event/v2", last
assert last["verification"]["status"] == "fail", last
assert last["gate_status"] != "pass", last          # invariant
PY
( cd "$VERIFY_FAIL_DIR" && PATH="$FAKE_NPM_DIR:$PATH" scripts/agent-guard.sh pre-final --run-verify --advisory >/dev/null 2>&1 || true )
python3 - "$VERIFY_FAIL_DIR/.agents/state/session-events.jsonl" <<'PY'
import json, sys
last = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
assert last["gate_status"] == "warn", last
assert last["verification"]["status"] == "fail", last
PY
```

- [ ] **Step 2: Run to verify it fails** (schema v1, no `verification.status`, advisory still `pass`).

- [ ] **Step 3: Compute `verification_status` in the runner AND write a report even on the error path**

In the Python runner, the early `sys.exit(2)` path (invalid detector JSON / missing `verification_commands`) currently exits **before** writing a report. Change it to write a minimal report first:
```python
def write_error_report(message):
    report_path.write_text(json.dumps({
        "schema": "agent-guard-verification/v1",
        "scope": scope, "verification_status": "error", "error": message,
        "summary": {"pass": 0, "fail": 0, "skipped": 0}, "commands": [],
    }, indent=2) + "\n", encoding="utf-8")
```
Call `write_error_report(...)` immediately before each `sys.exit(2)`. On the normal path, after building `summary`, derive status using `executed` (no undefined variable):
```python
executed = summary["pass"] + summary["fail"]
if executed == 0 and summary["skipped"]:
    verification_status = "none"
elif summary["fail"]:
    verification_status = "fail"
elif summary["pass"]:
    verification_status = "pass"
else:
    verification_status = "skipped"
report["verification_status"] = verification_status
```

- [ ] **Step 4: Set `GATE_STATUS` and emit `verification.status` (`agent-guard.sh`)**

In `run_detected_verification`, after the python call (`code` holds the exit status):
```bash
  if [[ "$code" -eq 2 ]]; then
    GATE_STATUS=$([[ "$strict" == "true" ]] && echo fail || echo warn)
    warn "verification could not run (error); gate_status=$GATE_STATUS"
    [[ "$strict" == "true" ]] && return "$code"
  elif [[ "$code" -ne 0 ]]; then
    if [[ "$strict" == "true" ]]; then GATE_STATUS=fail; return "$code"; fi
    GATE_STATUS=warn; warn "verification failed in advisory mode (gate_status=warn)"
  fi
```
In `append_pre_final_event`, read `verification_status` from `last-verify-report.json` (default `"none"` if the file is absent) into `verification.status`, stamp `"schema":"agent-guard-event/v2"`, and enforce the invariant — if `verification.status=="fail"` and the incoming gate arg is `"pass"`, coerce the emitted `gate_status` to `"warn"`. Python sketch inside the event heredoc:
```python
vstatus = "none"
if verify_path.is_file():
    try: vstatus = json.loads(verify_path.read_text(encoding="utf-8")).get("verification_status", "none")
    except Exception: vstatus = "error"
gate = os.environ["GATE_STATUS_VALUE"]
if vstatus == "fail" and gate == "pass": gate = "warn"
event = {"schema": "agent-guard-event/v2", "event": "pre_final",
         "generated_at": ..., "gate_status": gate,
         "verification": {"status": vstatus, "summary": summary, "available": verify_path.is_file()}}
```

- [ ] **Step 5: Create the v2 schema file + catalog mirror + manifest row**

Create `agent-bootstrap/schemas/agent-guard-event-v2.schema.json` (complete JSON Schema, following the style of `agent-bootstrap-verify-report-v1.schema.json`):
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "agent-guard-event-v2",
  "title": "Agent Guard close-out event",
  "type": "object",
  "required": ["schema", "event", "generated_at", "gate_status", "verification"],
  "additionalProperties": false,
  "properties": {
    "schema": { "const": "agent-guard-event/v2" },
    "event": { "const": "pre_final" },
    "generated_at": { "type": "string" },
    "gate_status": { "enum": ["pass", "warn", "fail"] },
    "verification": {
      "type": "object",
      "required": ["status", "available"],
      "properties": {
        "status": { "enum": ["pass", "fail", "none", "skipped", "error"] },
        "available": { "type": "boolean" },
        "summary": { "type": "object" },
        "report_path": { "type": "string" }
      }
    }
  }
}
```
Add the schema to the generated schema-catalog writer (mirror) and a MANIFEST row.

- [ ] **Step 6: Run + commit** — full suite PASS; commit `feat: gate_status/verification.status split, event schema v2 with error state + invariant`.

---

### Task 4: No False-Green On Zero Commands (item 5)

**Files:** `scripts/test-bootstrap-multi-agent-project.sh`, `agent-bootstrap/agent-guard.sh`

**Design:** All-skipped (0 executed) is `verification.status="none"`, gate **pass-with-warn** (Q3: `none` warns, never hard-fails — a repo with no fast commands must not be blocked). Suppress the `verification ok` print.

- [ ] **Step 1: Write the failing test** (placeholder-only fixture → all skipped):
```bash
( cd "$VERIFY_PLACEHOLDER_DIR" && scripts/agent-guard.sh pre-final --run-verify --advisory >"$TMP_DIR"/out/zero.out 2>"$TMP_DIR"/out/zero.err || true )
grep -q "verification ok" "$TMP_DIR/out/zero.out" && fail "all-skipped run printed false-green 'verification ok'"
python3 - "$VERIFY_PLACEHOLDER_DIR/.agents/state/session-events.jsonl" <<'PY'
import json, sys
last = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
assert last["verification"]["status"] == "none", last
assert last["gate_status"] == "warn", last
PY
```

- [ ] **Step 2: Run to verify it fails** (currently prints `verification ok (0 passed, N skipped)`).

- [ ] **Step 3: Implement** — replace the unconditional success print at the end of the runner:
```python
executed = summary["pass"] + summary["fail"]
if summary["fail"]:
    print(f"agent-guard: ERROR: verification failed ({summary['fail']} failed, {summary['pass']} passed, {summary['skipped']} skipped)", file=sys.stderr); sys.exit(1)
if executed == 0:
    print(f"agent-guard: warn: no runnable verification commands ({summary['skipped']} skipped); gate=pass-with-warn", file=sys.stderr); sys.exit(0)
print(f"agent-guard: verification ok ({summary['pass']} passed, {summary['skipped']} skipped)")
```
In `run_detected_verification`, when the report's `verification_status=="none"`, set `GATE_STATUS=warn`.

- [ ] **Step 4: Run + commit** — PASS; commit `fix: all-skipped verification is pass-with-warn, not false-green`.

---

### Task 5: Total Wall-Clock Budget (item 6)

**Files:** `scripts/test-bootstrap-multi-agent-project.sh`, `agent-bootstrap/agent-guard.sh`

**Design:** Add `AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS` (fast default shorter than full). Per-command timeout becomes `min(per_command, remaining_total)`. Budget exhaustion ⇒ remaining commands `skipped reason=budget_exhausted`, outcome is **not** a clean green: strict ⇒ `gate_status=fail`; advisory ⇒ `warn`.

- [ ] **Step 1: Write the failing test** (deterministic; fake-slow command + tiny budget):
```bash
BUDGET_DIR="$FIXTURE_DIR/verify-budget"; mkdir -p "$BUDGET_DIR/scripts"
cat > "$BUDGET_DIR/package.json" <<'EOF_B'
{ "scripts": { "test": "bash scripts/slow.sh", "build": "bash scripts/slow.sh" } }
EOF_B
printf '#!/usr/bin/env bash\nsleep 5\n' > "$BUDGET_DIR/scripts/slow.sh"; chmod +x "$BUDGET_DIR/scripts/slow.sh"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$BUDGET_DIR" --workflow full >/dev/null
( cd "$BUDGET_DIR" && git init -q && git config user.email t@e.invalid && git config user.name t && git add -A && git commit -qm base && scripts/agent-guard.sh preflight >/dev/null )
if ( cd "$BUDGET_DIR" && PATH="$FAKE_NPM_DIR:$PATH" AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS=1 scripts/agent-guard.sh pre-final --run-verify >/dev/null 2>&1 ); then
  fail "budget-exhausted run reported success in strict mode"
fi
python3 - "$BUDGET_DIR/.agents/state/last-verify-report.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert any(c.get("status") == "timeout" for c in doc["commands"]), ("expected a timeout", doc)
assert any(c.get("reason") == "budget_exhausted" for c in doc["commands"]), ("expected a budget_exhausted skip", doc)
PY
```

- [ ] **Step 2: Run to verify it fails** (no budget concept).

- [ ] **Step 3: Plumb the env + implement (`agent-guard.sh`)**

Bash side, near the other verify constants (~L48), add and pass it scope-dependently into the runner's env:
```bash
VERIFY_TOTAL_DEFAULT_FAST="${AGENT_GUARD_VERIFY_TOTAL_FAST_SECONDS:-300}"
VERIFY_TOTAL_DEFAULT_FULL="${AGENT_GUARD_VERIFY_TOTAL_FULL_SECONDS:-1800}"
```
In `run_detected_verification`, compute and export before invoking python:
```bash
  local total="${AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS:-}"
  if [[ -z "$total" ]]; then
    total=$([[ "$verify_scope" == "full" ]] && echo "$VERIFY_TOTAL_DEFAULT_FULL" || echo "$VERIFY_TOTAL_DEFAULT_FAST")
  fi
  VERIFY_TOTAL_TIMEOUT_SECONDS="$total" \
  # ... (alongside the existing exported VERIFY_* vars) ...
```
Python side, before the command loop:
```python
total = int(os.environ.get("VERIFY_TOTAL_TIMEOUT_SECONDS", "0"))
deadline = time.time() + total if total > 0 else None
```
Inside the loop, before launching each command:
```python
    if deadline is not None:
        remaining = int(deadline - time.time())
        if remaining <= 0:
            summary["skipped"] += 1
            results.append({"command": command, "status": "skipped", "reason": "budget_exhausted"})
            continue
        eff_timeout = max(1, min(timeout, remaining))
    else:
        eff_timeout = timeout
```
Use `eff_timeout` in the `process.wait(timeout=eff_timeout)` call. A real per-command timeout keeps the existing `status:"timeout"` (which counts as a fail). Budget-exhausted skips do not flip `summary.fail`, so in `run_detected_verification` add: if any command has `reason=="budget_exhausted"`, treat the outcome as non-green — strict ⇒ `GATE_STATUS=fail; return 1`; advisory ⇒ `GATE_STATUS=warn` (read this from the report, or have the runner exit non-zero when budget was hit and at least one command was skipped for budget).

- [ ] **Step 4: Run + commit** — PASS; commit `feat: total verification wall-clock budget; budget-exhausted is not a clean green`.

---

### Task 6: KEYSTONE — Close-Out Subcommand + Stop-Hook Registration (item 1) — branch B-closed-loop-wiring

**Files:** Modify `agent-bootstrap/agent-hook.sh` (+ mirror `lib/writers-runtime.sh`), `agent-bootstrap/lib/writers-docs.sh` (settings.json infra + full; AGENTS/tool-contract), `scripts/test-bootstrap-multi-agent-project.sh`.

**Design & Claude Stop-hook protocol (confirmed in Step 1):** A `Stop` hook reads JSON on stdin including `stop_hook_active`. **Exit code 2 blocks the stop** and feeds stderr back to the model as the reason; exit 0 allows stop; the structured alternative is stdout JSON `{"decision":"block","reason":"..."}`. Guard against infinite loops via `stop_hook_active`. Soft-signal default: run **fast advisory** verification (so unrelated strict checks — drift/memory — never abort the hook), then **block only when files changed AND the verification report has real failures**.

> **Critical correctness note (do not regress):** the hook must NOT decide "block" from the guard's *exit code* when running `--advisory` (advisory returns 0 even on verify failure). It must read `last-verify-report.json` `summary.fail`.

- [ ] **Step 1: Confirm the Stop-hook protocol** against the installed Claude Code version (`claude --help`, hooks docs). Record the confirmed contract as a comment in the writer. If it differs, adapt Steps 4–5.

- [ ] **Step 2: Write the failing wiring + enforcement tests** (drive the GENERATED artifacts, not the guard directly):
```bash
need_contains "$(cat "$TMP_DIR/.claude/settings.json")" '"Stop"' "settings.json registers Stop hook"
need_contains "$(cat "$TMP_DIR/.claude/settings.json")" 'agent-hook.sh close-out' "Stop hook calls close-out subcommand"
python3 -m json.tool "$TMP_DIR/.claude/settings.json" >/dev/null || fail "generated settings.json is not valid JSON after Stop hook"
# a failing test, driven through the generated Stop hook, must BLOCK stop (exit 2)
(
  cd "$VERIFY_FAIL_DIR"
  printf '%s' '{"stop_hook_active":false}' | PATH="$FAKE_NPM_DIR:$PATH" scripts/agent-hook.sh close-out >"$TMP_DIR"/out/closeout.out 2>"$TMP_DIR"/out/closeout.err
) && fail "close-out did not block stop (exit 2) on failing verification"
need_contains "$(cat "$TMP_DIR/out/closeout.err")" "verification" "close-out reports the failure reason to the model"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "advisory" "AGENTS notes non-Claude surfaces stay advisory"
```

- [ ] **Step 3: Run to verify it fails** (no Stop hook, no `close-out`).

- [ ] **Step 4: Add the `close-out` subcommand (`agent-hook.sh`)**

Add to the dispatch `case` (after `doctor)`):
```bash
  close-out)
    close_out
    ;;
```
Update the usage string to include `close-out`. Add the function (above the `case`; `PROJECT_ROOT` is already defined in this script):
```bash
close_out() {
  # Claude Code Stop hook (soft-signal). Run fast verification ADVISORY so
  # unrelated strict checks (drift/memory) never abort it, then block stop
  # (exit 2) only when files changed AND the report shows real failures.
  # Enforcement is Claude-only; other surfaces stay advisory (see AGENTS.md).
  local input; input="$(cat 2>/dev/null || true)"
  case "$input" in *'"stop_hook_active":true'*) exit 0 ;; esac          # loop guard
  [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]] || exit 0   # clean tree: nothing to verify
  "$PROJECT_ROOT/scripts/agent-guard.sh" pre-final --run-verify --verify-scope fast --advisory \
    >/dev/null 2>"$PROJECT_ROOT/.agents/state/closeout.err" || true
  local report="$PROJECT_ROOT/.agents/state/last-verify-report.json" failed=0
  if [[ -f "$report" ]]; then
    failed="$(python3 - "$report" <<'PY'
import json, sys
try: doc = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: print(0); sys.exit(0)
print(int(doc.get("summary", {}).get("fail", 0)))
PY
)"
  fi
  if [[ "${failed:-0}" -gt 0 ]]; then
    echo "agent-guard: close-out fast verification failed (${failed} failed); review .agents/state/last-verify-report.json before completing." >&2
    exit 2          # block stop; stderr is fed back to the model
  fi
  exit 0
}
```
> Change-gate limitation (document in the function comment): `git status --porcelain` skips a fully-clean tree; a session that *committed* its work then stops will not re-verify via the hook — run `scripts/agent-guard.sh pre-final --run-verify` explicitly. This is an accepted soft-signal trade-off, not a correctness bug.

- [ ] **Step 5: Register the Stop hook in `.claude/settings.json` (both writers)**

In `lib/writers-docs.sh`, in BOTH settings.json heredocs (infra ~L533, full ~L1241), add a `"Stop"` sibling after the `"PreToolUse"` array (mind the trailing comma after the PreToolUse `]`):
```json
    "Stop": [
      { "hooks": [ { "type": "command", "command": "./scripts/agent-hook.sh close-out" } ] }
    ]
```
> Back-compat note (document): `.claude/settings.json` is written via wholesale `write_file`, so the Stop hook lands only when a target is (re-)bootstrapped, and any user edits to settings.json are not preserved across regen — this is pre-existing behavior, called out so the Stop-hook addition is a conscious choice, not a surprise.

- [ ] **Step 6: Mirror `agent-hook.sh` into `lib/writers-runtime.sh`** — apply the identical `close_out` function + dispatch + usage into the generated `agent-hook.sh` heredoc so `need_same_file` stays green.

- [ ] **Step 7: Add the honesty note** — in both AGENTS.md writers + `templates/tool-contract/shared.md`: "Close-out verification auto-runs as a Claude Code Stop hook; Gemini/Cursor/Windsurf have no equivalent close-out hook, so for those surfaces the loop is advisory — run `scripts/agent-guard.sh pre-final --run-verify` manually." Re-run `scripts/sync-template-catalog.sh`.

- [ ] **Step 8: Run + commit**
```bash
bash -n agent-bootstrap/agent-hook.sh agent-bootstrap/lib/writers-docs.sh agent-bootstrap/lib/writers-runtime.sh
scripts/sync-template-catalog.sh --check
scripts/test-bootstrap-multi-agent-project.sh
```
Expected: PASS incl. the decisive wiring/enforcement tests + `need_same_file`. Commit `feat: wire close-out verification as a Claude Code Stop hook (soft-signal, change-gated)`.

---

### Task 7: Extension Guide (item 7) — branch B-maintainability

**Files:** Create `docs/agent-configs/EXTENSION-GUIDE.md`, Modify `agent-bootstrap/MANIFEST.md`, `scripts/test-bootstrap-multi-agent-project.sh`.

- [ ] **Step 1: Failing presence/coverage test**
```bash
guide="$ROOT_DIR/docs/agent-configs/EXTENSION-GUIDE.md"
need_contains "$(cat "$guide")" "Add a detected stack" "extension guide covers adding a stack"
need_contains "$(cat "$guide")" "agent-tech-stack-lib.sh" "guide names the detector file"
need_contains "$(cat "$guide")" "lib/detect.sh" "guide names the detector heredoc mirror"
need_contains "$(cat "$guide")" "need_same_file" "guide names the mirror guard"
```
- [ ] **Step 2: Run → FAIL (file absent).**
- [ ] **Step 3: Write the guide** — three "to add X, edit these files" maps (a detected stack; a tool surface; a guard check), each naming the canonical file, its heredoc mirror, the MANIFEST row, and the guarding test. No placeholders — name exact files.
- [ ] **Step 4: Run + commit** `docs: add extension guide mapping change-sites for stacks/surfaces/guards`.

---

### Task 8: Mirror-Discovery Test (item 8)

**Files:** `agent-bootstrap` generated runtime script headers (marker), `scripts/test-bootstrap-multi-agent-project.sh`

**Design:** Make the runtime-snapshot mirror set discovery-based, not hand-listed. Add the discovery marker FIRST, then the test.

- [ ] **Step 1: Add a discovery marker** to each generated runtime script header (canonical bundle file AND its heredoc source where applicable): a comment line `# AGENT_BOOTSTRAP_GENERATED` near the top of `agent-hook.sh`, `detect-agent-tech-stack.sh`, `agent-guard.sh`, `agent-tech-stack-lib.sh`, `verify-ai-deps.sh`, `install-rtk.sh`, `rtk`. Keep canonical and heredoc byte-identical.

- [ ] **Step 2: Write the discovery test** — symmetric failure semantics (fail on a missing generated file, not skip):
```bash
while IFS= read -r snap; do
  base="${snap#"$BOOTSTRAP_BUNDLE"/}"
  if [[ ! -f "$TMP_DIR/scripts/$base" ]]; then
    fail "discovered runtime snapshot $base was not generated into the target"
  fi
  need_same_file "$snap" "$TMP_DIR/scripts/$base" "discovered snapshot $base"
done < <(grep -lE '^# AGENT_BOOTSTRAP_GENERATED' "$BOOTSTRAP_BUNDLE"/*.sh "$BOOTSTRAP_BUNDLE"/rtk 2>/dev/null | sort)
# every templates/ file must have a docs mirror (and vice versa already covered by sync --check)
while IFS= read -r t; do
  rel="${t#"$BOOTSTRAP_BUNDLE"/templates/}"
  [[ -f "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/$rel" ]] || fail "template $rel has no docs mirror"
done < <(find "$BOOTSTRAP_BUNDLE/templates" -type f -not -name '*.bak.*' -not -name '*.generated.*' | sort)
```
- [ ] **Step 3: Run → expect PASS** (markers from Step 1 make the discovery set exact). If a snapshot lacks a marker, add it.
- [ ] **Step 4: Commit** `test: discover mirror snapshots/templates instead of hand-maintained list`.

---

### Task 9: Version Bump + Coherence Test (item 9) — lands in B-runtime-safety

**Files:** `agent-bootstrap/VERSION`, `agent-bootstrap/bootstrap-multi-agent-project.sh`, `CHANGELOG.md`, `agent-bootstrap/MANIFEST.md`, `scripts/test-bootstrap-multi-agent-project.sh`.

- [ ] **Step 1: Failing coherence test**
```bash
v="$(sed -n '1p' "$BOOTSTRAP_BUNDLE/VERSION")"
[[ "$v" == "2026.06.24.2" ]] || fail "VERSION not bumped"
need_contains "$("$BOOTSTRAP_BUNDLE/bootstrap-multi-agent-project.sh" --version)" "$v" "entrypoint --version matches VERSION"
need_contains "$(cat "$ROOT_DIR/CHANGELOG.md")" "$v" "changelog has the version"
need_contains "$(cat "$ROOT_DIR/CHANGELOG.md")" "behavioral" "changelog marks behavioral change"
need_contains "$(cat "$BOOTSTRAP_BUNDLE/MANIFEST.md")" "$v" "manifest version"
grep -Fq 'agent-guard-event/v2' "$BOOTSTRAP_BUNDLE/agent-guard.sh" || fail "event schema not bumped to v2"
```
- [ ] **Step 2: Run → FAIL (still .1).**
- [ ] **Step 3: Bump** `VERSION`→`2026.06.24.2`, `AGENT_BOOTSTRAP_VERSION`, MANIFEST version; add a CHANGELOG entry explicitly marked **behavioral** (event schema v2; runner now `shell=False`; default close-out Stop hook on Claude). `AGENT_TECH_STACK_LIB_VERSION` is **unchanged** (detector output is not modified by this plan).
- [ ] **Step 4: Run + commit** `release: 2026.06.24.2 — path B hardening (behavioral)`.

---

### Task 10: Targeted Test Diagnostics (item 11) — branch B-maintainability

**Files:** `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1:** Add a small `note() { printf 'bootstrap-test: --- %s\n' "$*" >&2; }` helper and call it before each major Task-1..6 verify block, so the next fail-fast failure reports which block it died in (no framework refactor).
- [ ] **Step 2:** Run the suite, confirm labels appear, commit `test: add section diagnostics to bootstrap suite (no framework change)`.

> Item 10 (recovery/rollback docs + orphan surfacing) is intentionally deferred to a follow-up branch (see Scope Boundary).

---

### Task 11: Full Verification

**Files:** all changed.

- [ ] **Step 1: Syntax** — `bash -n` on every changed `*.sh`.
- [ ] **Step 2: Mirror + suites (single-threaded)**:
```bash
scripts/sync-template-catalog.sh --check
scripts/test-bootstrap-multi-agent-project.sh
scripts/test-onboarding-fixtures.sh
scripts/test-one-shot-upgrade.sh
git diff --check
```
Expected: all exit 0.
- [ ] **Step 3: Back-compat probe** — confirm a target generated from `.1` still passes `scripts/agent-hook.sh doctor` after re-bootstrap, and that the new runner handles a legacy detector JSON (no behavioral assumptions about `argv`, since Task 1 added none).
- [ ] **Step 4: Squash per PR** per the Branch/PR split; one commit per PR; no Co-Authored-By trailer.

---

## Self-Review Notes

- **Keystone (C1) is two-part and now blocks correctly.** Task 6 ships BOTH the `close-out` subcommand AND the generated `.claude/settings.json` Stop hook, tested via the generated artifacts. The hook runs verification *advisory* but decides block/allow by reading `last-verify-report.json` `summary.fail` and `exit 2` — it does NOT rely on the advisory exit code (which is always 0). Without Step 5 + the Step 2 enforcement test, the loop stays convention-by-doc.
- **Injection is killed by `shell=False`+`shlex`** (metacharacters become inert argv tokens). Detector-emitted `argv` is intentionally NOT added — derived via `shlex` it would be redundant; token-level argv is deferred (YAGNI). The change is defense-in-depth, not a security boundary.
- **No silent false-green.** Task 4 (0-commands → `none`/warn) and Task 5 (budget exhausted → fail/warn) both avoid a clean green; the `verification.status==fail ⇒ gate_status!=pass` invariant (Task 3) and the `error` state are regression-tested, including the runner writing a report on the `exit(2)` error path.
- **Telemetry covers failures.** The `EXIT` trap is armed only inside `pre_final` (`EMIT_CLOSEOUT`), captures `$?` first, is best-effort, and Task 0/Task 2 confirm there is no pre-existing trap to clobber; Step 5 proves it does not fire for other subcommands.
- **Mirror discipline.** Item 1 (hook) touches a heredoc-mirrored file and ends with `need_same_file` green; Task 8 makes the snapshot mirror set discovery-based (symmetric fail-on-missing). `agent-guard.sh` (Tasks 1–5) ships by wholesale copy — no heredoc mirror, but the snapshot byte-compare still guards it.
- **Back-compat.** No detector contract change (Task 1 is runner-only); event schema bumps to v2 with the version stamped; `.claude/settings.json` is wholesale-written so the Stop hook arrives on re-bootstrap (and user edits to it are not preserved — documented in Task 6 Step 5); Task 11 Step 3 probes a `.1` target.
- **Deferred (documented):** item 10; token-level detector argv; budget-economy telemetry fields; any test-framework refactor.
