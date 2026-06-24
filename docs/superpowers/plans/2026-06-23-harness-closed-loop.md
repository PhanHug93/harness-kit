# Harness Closed Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the harness from policy-only guidance into a lightweight closed loop: shared tool-entrypoint contract, detector JSON output, pre-final verification execution, stack-drift detection, and machine-readable telemetry.

**Architecture:** Keep the kit dependency-light: Bash orchestration plus Python 3 from the existing hard dependency set, with no `jsonschema` or package-manager additions. Preserve the current mirror/drift contract while moving tool-facing repeated text into a single template-rendered contract block. Make the default close-out path observable through `scripts/agent-guard.sh pre-final --run-verify`, which runs the fast verification subset by default, while `--verify-scope full` opt-in runs build/full commands. Advisory mode still degrades when state is not writable or the caller explicitly uses `--advisory`.

**Tech Stack:** Bash, Python 3 stdlib, Git, existing `agent-bootstrap` writer/render/test harness.

---

## Scope Boundary

This branch includes:

- Detector JSON output so verification commands can be consumed as structured data.
- `agent-guard pre-final --run-verify` execution of runnable detector commands, with `fast` default scope and `full` opt-in scope.
- Stack drift check comparing live detector summary with the bootstrap lock.
- Lightweight JSON/JSONL guard artifacts in `.agents/state/`.
- Shared tool-entrypoint contract block rendered into Claude, Gemini, Windsurf, and Cursor surfaces.
- Template catalog sync script so `agent-bootstrap/templates` is the source of truth and the docs mirror is mechanical.

This branch excludes:

- Full secret scanner or pre-commit secret detector.
- Automatic git checkpoint/rollback per session.
- Runtime multi-agent handoff state machine.
- Bash execution sandboxing. The kit remains a file/edit guardrail and readiness harness, not a security boundary for arbitrary shell execution.

## File Structure

- Modify: `agent-bootstrap/agent-tech-stack-lib.sh`  
  Add structured JSON output helpers and expose verification commands as arrays.
- Modify: `agent-bootstrap/lib/detect.sh`  
  Keep the embedded detector library in sync with `agent-tech-stack-lib.sh`; make lock summary generation unchanged.
- Modify: `agent-bootstrap/detect-agent-tech-stack.sh`  
  Add `--json` CLI mode in the canonical runtime detector snapshot.
- Modify: `agent-bootstrap/lib/writers-runtime.sh`  
  Add `--json` to the generated detector heredoc and mirror any guard logic that is generated into target projects.
- Modify: `agent-bootstrap/agent-guard.sh`  
  Add stack drift, verification runner, verification report, and session event JSONL.
- Modify: `agent-bootstrap/lib/writers-docs.sh`  
  Render shared tool contract blocks and update generated close-out guidance to call `pre-final --run-verify`.
- Modify: `agent-bootstrap/lib/core.sh`  
  Add a tiny template renderer for bundle templates with literal token replacement.
- Create: `agent-bootstrap/templates/tool-contract/shared.md`  
  Canonical text that every tool surface must include.
- Create: `scripts/sync-template-catalog.sh`  
  Regenerate docs template mirror from `agent-bootstrap/templates`.
- Modify: `agent-bootstrap/MANIFEST.md`  
  Add new template and sync script entries.
- Modify: `README.md` and `agent-bootstrap/README.md`  
  Document the closed-loop path and non-goal boundary.
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`  
  Add regression tests for detector JSON, pre-final verification, stack drift, telemetry, and tool-contract parity.

---

### Task 1: Rename Branch And Lock The Scope

**Files:**
- No file changes.

- [ ] **Step 1: Verify the branch name**

Run:

```bash
git branch --show-current
```

Expected:

```text
feature/harness-closed-loop
```

- [ ] **Step 2: Verify the branch base**

Run:

```bash
git merge-base --is-ancestor main HEAD && git rev-parse --short main HEAD
```

Expected: exit code `0`, with `main` and `HEAD` matching if no implementation commits exist yet.

- [ ] **Step 3: Verify clean workspace before code changes**

Run:

```bash
git status --short --branch
```

Expected:

```text
## feature/harness-closed-loop
```

---

### Task 2: Add Structured Detector JSON

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-tech-stack-lib.sh`
- Modify: `agent-bootstrap/lib/detect.sh`
- Modify: `agent-bootstrap/detect-agent-tech-stack.sh`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`

- [ ] **Step 1: Write failing detector JSON tests**

In `scripts/test-bootstrap-multi-agent-project.sh`, near the existing detector summary assertions around the generated full bootstrap target, add:

```bash
detector_json="$(cd "$TMP_DIR" && scripts/detect-agent-tech-stack.sh --json)"
python3 - "$detector_json" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
assert doc["schema"] == "agent-tech-stack-detection/v1", doc
assert isinstance(doc["tech_stacks"], list), doc
assert isinstance(doc["modules"], list), doc
assert isinstance(doc["verification_commands"], list), doc
assert isinstance(doc["warnings"], list), doc
assert "./gradlew :app:testProdDebugUnitTest" in doc["verification_commands"], doc
assert "./gradlew :app:assembleProdDebug" in doc["verification_commands"], doc
PY
```

Add a canonical detector snapshot assertion near the existing root smoke checks:

```bash
canonical_detector_json="$(cd "$ROOT_DIR" && agent-bootstrap/detect-agent-tech-stack.sh --root "$FIXTURE_DIR/android-app" --json)"
python3 - "$canonical_detector_json" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
assert doc["schema"] == "agent-tech-stack-detection/v1", doc
assert "android_kotlin" in doc["tech_stacks"], doc
assert any(command.startswith("./gradlew") for command in doc["verification_commands"]), doc
PY
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL with `unknown option: --json` or missing JSON schema assertions.

- [ ] **Step 3: Add JSON helpers to `agent-bootstrap/agent-tech-stack-lib.sh`**

After `agent_print_summary()`, add:

```bash
agent_json_escape() {
  JSON_ESCAPE_VALUE="$1" python3 - <<'PY'
import json
import os
print(json.dumps(os.environ.get("JSON_ESCAPE_VALUE", ""), ensure_ascii=False)[1:-1], end="")
PY
}

agent_print_json_array() {
  local first=true
  local item
  printf '['
  for item in "$@"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(agent_json_escape "$item")"
  done
  printf ']'
}

agent_print_json() {
  printf '{"schema":"agent-tech-stack-detection/v1"'
  printf ',"tech_stack_lib_version":"%s"' "$(agent_json_escape "$AGENT_TECH_STACK_LIB_VERSION")"
  printf ',"tech_stacks":'
  agent_print_json_array "${AGENT_TECH_STACKS[@]}"
  printf ',"modules":'
  agent_print_json_array "${AGENT_MODULES[@]}"
  printf ',"verification_commands":'
  agent_print_json_array "${AGENT_VERIFY_COMMANDS[@]}"
  printf ',"warnings":'
  agent_print_json_array "${AGENT_WARNINGS[@]}"
  printf '}\n'
}
```

- [ ] **Step 4: Mirror the helper in `agent-bootstrap/lib/detect.sh`**

Inside the `emit_tech_stack_lib()` heredoc, add the same `agent_json_escape`, `agent_print_json_array`, and `agent_print_json` functions immediately after the embedded `agent_print_summary()`.

- [ ] **Step 5: Add `--json` to the canonical detector**

In `agent-bootstrap/detect-agent-tech-stack.sh`, update usage and option parsing:

```bash
"Usage: scripts/detect-agent-tech-stack.sh [--root DIR] [--markdown|--summary|--json]"
```

Add:

```bash
    --json)
      FORMAT="json"
      shift
      ;;
```

Replace the final output switch with:

```bash
case "$FORMAT" in
  summary)
    agent_print_summary
    ;;
  json)
    agent_print_json
    ;;
  markdown)
    agent_print_markdown "$ROOT"
    ;;
esac
```

- [ ] **Step 6: Add `--json` to the generated detector heredoc**

Apply the same usage, parsing, and output switch edits inside `write_runtime_detector()` in `agent-bootstrap/lib/writers-runtime.sh`.

- [ ] **Step 7: Run focused syntax checks**

Run:

```bash
bash -n agent-bootstrap/agent-tech-stack-lib.sh
bash -n agent-bootstrap/detect-agent-tech-stack.sh
bash -n agent-bootstrap/lib/detect.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
```

Expected: all commands exit `0`.

- [ ] **Step 8: Run the failing test again**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS for detector JSON assertions. If another failing assertion appears, stop and handle the task that owns that assertion.

---

### Task 3: Add Pre-Final Verification Runner

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-guard.sh`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`

- [ ] **Step 1: Write failing tests for successful verification**

In `scripts/test-bootstrap-multi-agent-project.sh`, after the memory pre-final tests, add:

```bash
VERIFY_OK_DIR="$FIXTURE_DIR/verify-prefinal-ok"
mkdir -p "$VERIFY_OK_DIR/scripts"
cat > "$VERIFY_OK_DIR/package.json" <<'EOF_VERIFY_OK_PACKAGE'
{
  "scripts": {
    "test": "bash scripts/verify-ok.sh",
    "build": "bash scripts/verify-build.sh"
  }
}
EOF_VERIFY_OK_PACKAGE
cat > "$VERIFY_OK_DIR/scripts/verify-ok.sh" <<'EOF_VERIFY_OK_SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "verify ok"
EOF_VERIFY_OK_SCRIPT
cat > "$VERIFY_OK_DIR/scripts/verify-build.sh" <<'EOF_VERIFY_BUILD_SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "verify build"
touch .agents/state/build-ran.marker
EOF_VERIFY_BUILD_SCRIPT
chmod +x "$VERIFY_OK_DIR/scripts/verify-ok.sh"
chmod +x "$VERIFY_OK_DIR/scripts/verify-build.sh"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$VERIFY_OK_DIR" --workflow full >/dev/null
(
  cd "$VERIFY_OK_DIR"
  git init -q
  git config user.email "agent-bootstrap-test@example.invalid"
  git config user.name "Agent Bootstrap Test"
  git add -A
  git commit -qm baseline
  scripts/agent-guard.sh preflight >/dev/null
  scripts/agent-guard.sh pre-final --run-verify >"$TMP_DIR"/out/bootstrap-prefinal-verify-ok.out 2>"$TMP_DIR"/out/bootstrap-prefinal-verify-ok.err
)
need_contains "$(cat "$TMP_DIR/out/bootstrap-prefinal-verify-ok.out")" "pre-final ok" "pre-final verify ok output"
[[ -f "$VERIFY_OK_DIR/.agents/state/last-verify-report.json" ]] || fail "pre-final did not write verification report"
python3 - "$VERIFY_OK_DIR/.agents/state/last-verify-report.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["schema"] == "agent-guard-verification/v1", doc
assert doc["scope"] == "fast", doc
assert doc["summary"]["fail"] == 0, doc
assert any(item["command"] == "npm test" and item["status"] == "pass" for item in doc["commands"]), doc
assert any(item["command"] == "npm run build" and item["status"] == "skipped" and item["reason"] == "scope_fast" for item in doc["commands"]), doc
PY
[[ ! -e "$VERIFY_OK_DIR/.agents/state/build-ran.marker" ]] || fail "default pre-final --run-verify should not run full-scope build commands"
(
  cd "$VERIFY_OK_DIR"
  scripts/agent-guard.sh pre-final --run-verify --verify-scope full >"$TMP_DIR"/out/bootstrap-prefinal-verify-full.out 2>"$TMP_DIR"/out/bootstrap-prefinal-verify-full.err
)
[[ -f "$VERIFY_OK_DIR/.agents/state/build-ran.marker" ]] || fail "pre-final --verify-scope full did not run build command"
python3 - "$VERIFY_OK_DIR/.agents/state/last-verify-report.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["scope"] == "full", doc
assert doc["summary"]["fail"] == 0, doc
assert any(item["command"] == "npm run build" and item["status"] == "pass" for item in doc["commands"]), doc
PY
```

- [ ] **Step 2: Write failing tests for failed verification**

Add:

```bash
VERIFY_FAIL_DIR="$FIXTURE_DIR/verify-prefinal-fail"
mkdir -p "$VERIFY_FAIL_DIR/scripts"
cat > "$VERIFY_FAIL_DIR/package.json" <<'EOF_VERIFY_FAIL_PACKAGE'
{
  "scripts": {
    "test": "bash scripts/verify-fail.sh"
  }
}
EOF_VERIFY_FAIL_PACKAGE
cat > "$VERIFY_FAIL_DIR/scripts/verify-fail.sh" <<'EOF_VERIFY_FAIL_SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "verify fail" >&2
exit 7
EOF_VERIFY_FAIL_SCRIPT
chmod +x "$VERIFY_FAIL_DIR/scripts/verify-fail.sh"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$VERIFY_FAIL_DIR" --workflow full >/dev/null
(
  cd "$VERIFY_FAIL_DIR"
  git init -q
  git config user.email "agent-bootstrap-test@example.invalid"
  git config user.name "Agent Bootstrap Test"
  git add -A
  git commit -qm baseline
  scripts/agent-guard.sh preflight >/dev/null
)
if (cd "$VERIFY_FAIL_DIR" && scripts/agent-guard.sh pre-final --run-verify >"$TMP_DIR"/out/bootstrap-prefinal-verify-fail.out 2>"$TMP_DIR"/out/bootstrap-prefinal-verify-fail.err); then
  fail "pre-final --run-verify passed with a failing verification command"
fi
need_contains "$(cat "$TMP_DIR/out/bootstrap-prefinal-verify-fail.err")" "verification failed" "pre-final verification failure message"
python3 - "$VERIFY_FAIL_DIR/.agents/state/last-verify-report.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["summary"]["fail"] == 1, doc
assert any(item["command"] == "npm test" and item["status"] == "fail" and item["exit_code"] == 7 for item in doc["commands"]), doc
PY
```

- [ ] **Step 3: Write failing tests for placeholder skip**

Add:

```bash
VERIFY_PLACEHOLDER_DIR="$FIXTURE_DIR/verify-prefinal-placeholder"
mkdir -p "$VERIFY_PLACEHOLDER_DIR/Demo.xcodeproj"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$VERIFY_PLACEHOLDER_DIR" --workflow full >/dev/null
(
  cd "$VERIFY_PLACEHOLDER_DIR"
  git init -q
  git config user.email "agent-bootstrap-test@example.invalid"
  git config user.name "Agent Bootstrap Test"
  git add -A
  git commit -qm baseline
  scripts/agent-guard.sh preflight >/dev/null
  scripts/agent-guard.sh pre-final --run-verify --advisory >"$TMP_DIR"/out/bootstrap-prefinal-placeholder.out 2>"$TMP_DIR"/out/bootstrap-prefinal-placeholder.err
)
need_contains "$(cat "$TMP_DIR/out/bootstrap-prefinal-placeholder.err")" "skipped verification command" "pre-final skips placeholder command"
python3 - "$VERIFY_PLACEHOLDER_DIR/.agents/state/last-verify-report.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert any("<scheme>" in item["command"] and item["status"] == "skipped" for item in doc["commands"]), doc
PY
```

- [ ] **Step 4: Run tests to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because `pre-final` does not accept `--run-verify`.

- [ ] **Step 5: Add guard constants**

Near the top of `agent-bootstrap/agent-guard.sh`, add:

```bash
VERIFY_REPORT="$STATE_DIR/last-verify-report.json"
VERIFY_LOG_DIR="$STATE_DIR/verify-logs"
VERIFY_TIMEOUT_SECONDS="${AGENT_GUARD_VERIFY_TIMEOUT_SECONDS:-900}"
VERIFY_SCOPE_DEFAULT="${AGENT_GUARD_VERIFY_SCOPE:-fast}"
```

- [ ] **Step 6: Define the placeholder/non-runnable rule (single source of truth)**

Classification of runnable vs placeholder commands lives in exactly ONE place: the
Python runner added in Step 7. Do **not** add a parallel Bash
`verification_command_is_runnable` helper — two copies of the rule (Bash + Python)
drift apart silently. The contract: a command is skipped when it is empty, contains a
`<...>` placeholder token, or starts with `Add project-specific`. Document this rule as
a comment next to the runner so the single source is discoverable.

- [ ] **Step 7: Add Python-backed verification runner**

Before `pre_final()`, add:

```bash
run_detected_verification() {
  local strict="$1"
  local verify_scope="$2"
  if [[ "$STATE_WRITABLE" != "true" ]]; then
    warn "state dir not writable; skipping verification execution (advisory)"
    return 0
  fi
  [[ -x "$DETECTOR" ]] || { warn "missing detector; skipping verification execution"; return 0; }
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to run detected verification"
  mkdir -p "$VERIFY_LOG_DIR"
  local detector_json
  detector_json="$("$DETECTOR" --json 2>/dev/null || true)"
  DETECTOR_JSON="$detector_json" \
  VERIFY_REPORT="$VERIFY_REPORT" \
  VERIFY_LOG_DIR="$VERIFY_LOG_DIR" \
  VERIFY_TIMEOUT_SECONDS="$VERIFY_TIMEOUT_SECONDS" \
  VERIFY_SCOPE="$verify_scope" \
  PROJECT_ROOT="$PROJECT_ROOT" \
  python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(os.environ["PROJECT_ROOT"])
report_path = pathlib.Path(os.environ["VERIFY_REPORT"])
log_dir = pathlib.Path(os.environ["VERIFY_LOG_DIR"])
timeout = int(os.environ["VERIFY_TIMEOUT_SECONDS"])
scope = os.environ["VERIFY_SCOPE"]
try:
    detection = json.loads(os.environ.get("DETECTOR_JSON") or "{}")
except Exception as exc:
    print(f"agent-guard: ERROR: detector JSON is invalid: {exc}", file=sys.stderr)
    sys.exit(2)

commands = detection.get("verification_commands")
if not isinstance(commands, list):
    print("agent-guard: ERROR: detector JSON has no verification_commands array", file=sys.stderr)
    sys.exit(2)

log_dir.mkdir(parents=True, exist_ok=True)
results = []
summary = {"pass": 0, "fail": 0, "skipped": 0}


def command_class(command):
    lowered = command.lower()
    if (
        " assemble" in lowered
        or ":assemble" in lowered
        or " npm run build" in f" {lowered}"
        or lowered.endswith(" build")
        or " flutter build" in f" {lowered}"
        or "xcodebuild" in lowered
        or " compile" in lowered
        or ":compile" in lowered
    ):
        return "full"
    return "fast"

for index, command in enumerate(commands, 1):
    if (
        not isinstance(command, str)
        or not command
        or ("<" in command and ">" in command)
        or command.startswith("Add project-specific")
    ):
        summary["skipped"] += 1
        results.append({"command": command, "status": "skipped", "reason": "placeholder_or_non_runnable"})
        print(f"agent-guard: warn: skipped verification command: {command}", file=sys.stderr)
        continue
    klass = command_class(command)
    if scope == "fast" and klass == "full":
        summary["skipped"] += 1
        results.append({"command": command, "status": "skipped", "reason": "scope_fast", "class": klass})
        print(f"agent-guard: warn: skipped full-scope verification command: {command}", file=sys.stderr)
        continue
    started = time.time()
    log_path = log_dir / f"verify-{int(started)}-{index}.log"
    with log_path.open("w", encoding="utf-8") as log:
        log.write(f"$ {command}\n")
        try:
            completed = subprocess.run(command, cwd=root, shell=True, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            exit_code = completed.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            exit_code = 124
            timed_out = True
            log.write(f"\nTIMEOUT after {timeout}s\n")
    duration_ms = int((time.time() - started) * 1000)
    if exit_code == 0:
        summary["pass"] += 1
        status = "pass"
    else:
        summary["fail"] += 1
        status = "timeout" if timed_out else "fail"
    results.append({
        "command": command,
        "class": klass,
        "status": status,
        "exit_code": exit_code,
        "duration_ms": duration_ms,
        "log_path": str(log_path.relative_to(root)),
    })

report = {
    "schema": "agent-guard-verification/v1",
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "scope": scope,
    "summary": summary,
    "commands": results,
}
report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
if summary["fail"]:
    print(f"agent-guard: ERROR: verification failed ({summary['fail']} failed, {summary['pass']} passed, {summary['skipped']} skipped)", file=sys.stderr)
    sys.exit(1)
print(f"agent-guard: verification ok ({summary['pass']} passed, {summary['skipped']} skipped)")
PY
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    if [[ "$strict" == "true" ]]; then
      return "$code"
    fi
    warn "verification failed in advisory mode"
  fi
}
```

- [ ] **Step 8: Wire `--run-verify` into `pre_final()`**

In `pre_final()`, add a local:

```bash
local run_verify=false
local verify_scope="$VERIFY_SCOPE_DEFAULT"
```

Add option parsing:

```bash
      --run-verify)
        run_verify=true
        shift
        ;;
      --verify-scope)
        verify_scope="${2:-}"
        case "$verify_scope" in
          fast|full) ;;
          *) fail "--verify-scope must be fast or full" ;;
        esac
        shift 2
        ;;
```

After `validate_memory_closeout "$strict" "$first_protected_change"`, add:

```bash
  if [[ "$run_verify" == "true" ]]; then
    run_detected_verification "$strict" "$verify_scope"
  fi
```

- [ ] **Step 9: Mirror guard changes into `agent-bootstrap/lib/writers-runtime.sh`**

Update the generated `scripts/agent-guard.sh` heredoc with the same constants, helper, runner, `--run-verify` / `--verify-scope` parsing, and call site.

- [ ] **Step 10: Run focused tests**

Run:

```bash
bash -n agent-bootstrap/agent-guard.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through pre-final verification tests.

---

### Task 4: Add Stack Drift Check To Pre-Final

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-guard.sh`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`

- [ ] **Step 1: Write failing stack drift tests**

Add after the verification runner tests:

```bash
STACK_DRIFT_DIR="$FIXTURE_DIR/stack-drift-prefinal"
mkdir -p "$STACK_DRIFT_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$STACK_DRIFT_DIR" --workflow full >/dev/null
(
  cd "$STACK_DRIFT_DIR"
  git init -q
  git config user.email "agent-bootstrap-test@example.invalid"
  git config user.name "Agent Bootstrap Test"
  git add -A
  git commit -qm baseline
  scripts/agent-guard.sh preflight >/dev/null
)

# Hardening: pin the cross-file summary-format coupling. The lock hashes
# detector_summary_for_lock() (lib/detect.sh); the drift check hashes
# `detect-agent-tech-stack.sh --summary` (agent_print_summary in
# agent-tech-stack-lib.sh). Both currently emit byte-identical format, but they
# live in different files with no test pinning that invariant. Without this, a
# one-sided edit would silently turn the new hard-fail into a false-positive
# detector drift on every pre-final.
# (a) A fresh, unmodified target must NOT report drift (advisory so unrelated
#     strict checks cannot mask the assertion; we only assert on the drift line).
(cd "$STACK_DRIFT_DIR" && scripts/agent-guard.sh pre-final --advisory >"$TMP_DIR"/out/bootstrap-stack-nodrift.out 2>"$TMP_DIR"/out/bootstrap-stack-nodrift.err) || true
if grep -q "detector summary drifted" "$TMP_DIR"/out/bootstrap-stack-nodrift.err; then
  fail "fresh unmodified target wrongly reported detector drift"
fi
# (b) The detector --summary the guard hashes must byte-match the summary the
#     lock hashed (this directly pins the detect.sh <-> agent-tech-stack-lib.sh format).
python3 - "$STACK_DRIFT_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
lock = json.loads((root / "docs/agent-configs/agent-bootstrap.lock.json").read_text(encoding="utf-8"))
live = subprocess.run(
    ["scripts/detect-agent-tech-stack.sh", "--summary"],
    cwd=root,
    text=True,
    capture_output=True,
).stdout
assert live.strip() == str(lock["detector_summary"]).strip(), (live, lock["detector_summary"])
PY

cat > "$STACK_DRIFT_DIR/package.json" <<'EOF_STACK_DRIFT_PACKAGE'
{
  "scripts": {
    "test": "bash -c 'true'"
  }
}
EOF_STACK_DRIFT_PACKAGE
if (cd "$STACK_DRIFT_DIR" && scripts/agent-guard.sh pre-final >"$TMP_DIR"/out/bootstrap-stack-drift.out 2>"$TMP_DIR"/out/bootstrap-stack-drift.err); then
  fail "pre-final accepted detector stack drift"
fi
need_contains "$(cat "$TMP_DIR/out/bootstrap-stack-drift.err")" "detector summary drifted" "pre-final stack drift error"
```

Add advisory degradation:

```bash
(cd "$STACK_DRIFT_DIR" && scripts/agent-guard.sh pre-final --advisory >"$TMP_DIR"/out/bootstrap-stack-drift-advisory.out 2>"$TMP_DIR"/out/bootstrap-stack-drift-advisory.err)
need_contains "$(cat "$TMP_DIR/out/bootstrap-stack-drift-advisory.err")" "detector summary drifted" "pre-final advisory stack drift warning"
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because `pre-final` does not compare the live detector summary with the lock.

- [ ] **Step 3: Add lock value reader if missing**

If `agent-bootstrap/agent-guard.sh` has no generic lock value helper, add before `pre_final()`:

```bash
lock_value() {
  local key="$1"
  local file="$PROJECT_ROOT/docs/agent-configs/agent-bootstrap.lock.json"
  [[ -f "$file" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path, key = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
value = doc.get(key)
print(value if isinstance(value, str) else "")
PY
    return 0
  fi
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n1
}
```

- [ ] **Step 4: Add detector drift check**

Add before `pre_final()`:

```bash
check_detector_summary_drift() {
  local strict="$1"
  [[ -x "$DETECTOR" ]] || { warn "missing detector; skipping stack drift check"; return 0; }
  local expected actual summary
  expected="$(lock_value detector_summary_sha256)"
  [[ -n "$expected" ]] || { warn "missing detector_summary_sha256 in bootstrap lock"; return 0; }
  summary="$("$DETECTOR" --summary 2>/dev/null || true)"
  actual="$(printf '%s' "$summary" | hash_text)"
  if [[ "$expected" != "$actual" ]]; then
    if [[ "$strict" == "true" ]]; then
      fail "detector summary drifted from bootstrap lock; run scripts/detect-agent-tech-stack.sh --markdown and refresh with bash scripts/bootstrap-multi-agent-project.sh --refresh-lock"
    fi
    warn "detector summary drifted from bootstrap lock; refresh intentionally before completion"
  fi
}
```

- [ ] **Step 5: Call drift check in `pre_final()`**

After `check_context_pack_freshness`, add:

```bash
  check_detector_summary_drift "$strict"
```

- [ ] **Step 6: Mirror guard changes into generated runtime**

Apply the same helper and call site inside `agent-bootstrap/lib/writers-runtime.sh`.

- [ ] **Step 7: Run focused tests**

Run:

```bash
bash -n agent-bootstrap/agent-guard.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through stack drift tests.

---

### Task 5: Add Session Telemetry JSONL

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-guard.sh`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`

- [ ] **Step 1: Write failing telemetry tests**

Add after successful pre-final verification assertions:

```bash
[[ -f "$VERIFY_OK_DIR/.agents/state/session-events.jsonl" ]] || fail "pre-final did not write session telemetry JSONL"
python3 - "$VERIFY_OK_DIR/.agents/state/session-events.jsonl" <<'PY'
import json
import sys

lines = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert lines, "no telemetry lines"
last = lines[-1]
assert last["schema"] == "agent-guard-event/v1", last
assert last["event"] == "pre_final", last
assert last["verification"]["summary"]["fail"] == 0, last
PY
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because `session-events.jsonl` is missing.

- [ ] **Step 3: Add telemetry constant**

Near other guard state constants:

```bash
SESSION_EVENTS="$STATE_DIR/session-events.jsonl"
```

- [ ] **Step 4: Add telemetry append helper**

Before `pre_final()`, add:

```bash
append_pre_final_event() {
  local status="$1"
  [[ "$STATE_WRITABLE" == "true" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  SESSION_EVENTS="$SESSION_EVENTS" VERIFY_REPORT="$VERIFY_REPORT" STATUS_VALUE="$status" python3 - <<'PY'
import json
import os
import pathlib
import time

events_path = pathlib.Path(os.environ["SESSION_EVENTS"])
verify_path = pathlib.Path(os.environ["VERIFY_REPORT"])
verification = {"summary": {"pass": 0, "fail": 0, "skipped": 0}, "available": False}
if verify_path.is_file():
    try:
        doc = json.loads(verify_path.read_text(encoding="utf-8"))
        verification = {"summary": doc.get("summary", {}), "available": True, "report_path": str(verify_path)}
    except Exception as exc:
        verification = {"available": False, "error": str(exc)}

event = {
    "schema": "agent-guard-event/v1",
    "event": "pre_final",
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": os.environ["STATUS_VALUE"],
    "verification": verification,
}
events_path.parent.mkdir(parents=True, exist_ok=True)
with events_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}
```

- [ ] **Step 5: Call telemetry at pre-final exit points**

In `pre_final()`, add:

```bash
  append_pre_final_event "pass"
```

immediately before the final `printf 'agent-guard: pre-final ok ...'`.

Do not try to append on every `fail` path in this branch; failing command reports are already written to `last-verify-report.json`.

- [ ] **Step 6: Mirror guard changes into generated runtime**

Apply the same constant/helper/call site in `agent-bootstrap/lib/writers-runtime.sh`.

- [ ] **Step 7: Run focused tests**

Run:

```bash
bash -n agent-bootstrap/agent-guard.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through telemetry tests.

---

### Task 6: Add Shared Tool-Entrypoint Contract

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/lib/core.sh`
- Modify: `agent-bootstrap/lib/writers-docs.sh`
- Create: `agent-bootstrap/templates/tool-contract/shared.md`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`
- Modify: `agent-bootstrap/MANIFEST.md`

- [ ] **Step 1: Write failing parity tests**

In `scripts/test-bootstrap-multi-agent-project.sh`, after generated file existence checks for `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, and Cursor rules, add:

```bash
extract_tool_contract() {
  local file="$1"
  sed -n '/BEGIN MANAGED: multi-agent-bootstrap:tool-contract/,/END MANAGED: multi-agent-bootstrap:tool-contract/p' "$file"
}

claude_contract="$(extract_tool_contract "$TMP_DIR/CLAUDE.md")"
gemini_contract="$(extract_tool_contract "$TMP_DIR/GEMINI.md")"
windsurf_contract="$(extract_tool_contract "$TMP_DIR/.windsurfrules")"
cursor_contract="$(extract_tool_contract "$TMP_DIR/.cursor/rules/agent-conventions.mdc")"
[[ -n "$claude_contract" ]] || fail "CLAUDE.md missing managed tool contract"
[[ "$claude_contract" == "$gemini_contract" ]] || fail "GEMINI.md tool contract drifted from CLAUDE.md"
[[ "$claude_contract" == "$windsurf_contract" ]] || fail "Windsurf tool contract drifted from CLAUDE.md"
[[ "$claude_contract" == "$cursor_contract" ]] || fail "Cursor tool contract drifted from CLAUDE.md"
need_contains "$claude_contract" "scripts/agent-guard.sh pre-final --run-verify" "tool contract close-out command"
```

Add the same extraction block for the infra-only generated target already produced by the test as `ROOT_DIRECT_DIR`:

```bash
infra_claude_contract="$(extract_tool_contract "$ROOT_DIRECT_DIR/CLAUDE.md")"
infra_gemini_contract="$(extract_tool_contract "$ROOT_DIRECT_DIR/GEMINI.md")"
infra_windsurf_contract="$(extract_tool_contract "$ROOT_DIRECT_DIR/.windsurfrules")"
infra_cursor_contract="$(extract_tool_contract "$ROOT_DIRECT_DIR/.cursor/rules/agent-conventions.mdc")"
[[ -n "$infra_claude_contract" ]] || fail "infra CLAUDE.md missing managed tool contract"
[[ "$infra_claude_contract" == "$infra_gemini_contract" ]] || fail "infra GEMINI.md tool contract drifted from CLAUDE.md"
[[ "$infra_claude_contract" == "$infra_windsurf_contract" ]] || fail "infra Windsurf tool contract drifted from CLAUDE.md"
[[ "$infra_claude_contract" == "$infra_cursor_contract" ]] || fail "infra Cursor tool contract drifted from CLAUDE.md"
need_contains "$infra_claude_contract" "scripts/agent-guard.sh pre-final --run-verify" "infra tool contract close-out command"
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because generated tool surfaces do not contain a shared managed contract block.

- [ ] **Step 3: Create shared tool contract template**

Create `agent-bootstrap/templates/tool-contract/shared.md`:

````markdown
<!-- BEGIN MANAGED: multi-agent-bootstrap:tool-contract -->
Read `AGENTS.md` first. Load `docs/agent-configs/project-agent-context.md`, the filled project brief when available, and detector output before substantive work.

At the start of substantive work, run:

```bash
scripts/agent-guard.sh preflight
scripts/detect-agent-tech-stack.sh --markdown
```

Before claiming completion, run:

```bash
scripts/agent-guard.sh pre-final --run-verify
```

Use `--verify-scope full` for release, high-risk, or final PR readiness. Use `scripts/agent-hook.sh no-scan-paths` before broad search. This harness guards files, context freshness, verification, and generated candidates; it is not a security boundary for arbitrary Bash commands.
<!-- END MANAGED: multi-agent-bootstrap:tool-contract -->
````

- [ ] **Step 4: Add template renderer**

In `agent-bootstrap/lib/core.sh`, after `json_escape()`, add:

```bash
render_bundle_template() {
  local relative="$1"
  local template_path="$BUNDLE_DIR/$relative"
  [[ -f "$template_path" ]] || fail "missing bundle template: $relative"
  cat "$template_path"
}
```

This branch only needs literal templates. Do not add a general substitution language until a caller actually needs tokens.

- [ ] **Step 5: Render shared contract in tool writers**

In `agent-bootstrap/lib/writers-docs.sh`, add:

```bash
tool_contract_block() {
  render_bundle_template "templates/tool-contract/shared.md"
}
```

Update `write_infra_tool_entrypoints()` and `write_tool_entrypoints()` so every generated tool surface includes `$(tool_contract_block)` exactly once:

```bash
  local contract
  contract="$(tool_contract_block)"
```

Use `$contract` inside `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, and `.cursor/rules/agent-conventions.mdc`. Keep Claude-specific command lists outside the managed block.

- [ ] **Step 6: Add template to catalog writer**

In `write_template_catalog()` in `agent-bootstrap/lib/writers-runtime.sh`, add:

```bash
    tool-contract/shared.md \
```

to the copied template list.

- [ ] **Step 7: Add manifest row**

In `agent-bootstrap/MANIFEST.md`, add:

```markdown
| `templates/tool-contract/shared.md` | Shared managed contract rendered into tool-specific entrypoint files. | Must match generated `docs/agent-configs/bootstrap-multi-agent-project/templates/tool-contract/shared.md`. |
```

- [ ] **Step 8: Run tests**

Run:

```bash
bash -n agent-bootstrap/lib/core.sh
bash -n agent-bootstrap/lib/writers-docs.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through tool-contract parity checks.

---

### Task 7: Make Template Catalog Mirror Mechanical

**Files:**
- Create: `scripts/sync-template-catalog.sh`
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/MANIFEST.md`

- [ ] **Step 1: Write failing mirror-sync test**

In `scripts/test-bootstrap-multi-agent-project.sh`, near existing template drift checks, add:

```bash
(cd "$ROOT_DIR" && scripts/sync-template-catalog.sh --check) \
  || fail "template catalog mirror drifted from agent-bootstrap/templates; run scripts/sync-template-catalog.sh"
```

Expected behavior after implementation: exits `0` when `docs/agent-configs/bootstrap-multi-agent-project/templates` matches `agent-bootstrap/templates`, exits non-zero with a clear message when drift exists.

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because `scripts/sync-template-catalog.sh` does not exist.

- [ ] **Step 3: Create sync script**

Create `scripts/sync-template-catalog.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_DIR="$ROOT_DIR/agent-bootstrap/templates"
MIRROR_DIR="$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates"
MODE="sync"

usage() {
  printf '%s\n' \
    "Usage: scripts/sync-template-catalog.sh [--check]" \
    "" \
    "Sync docs template catalog mirror from agent-bootstrap/templates."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "check" ]]; then
  diff -qr "$SOURCE_DIR" "$MIRROR_DIR"
  exit 0
fi

mkdir -p "$MIRROR_DIR"
find "$MIRROR_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$SOURCE_DIR"/. "$MIRROR_DIR"/
```

- [ ] **Step 4: Make executable**

Run:

```bash
chmod +x scripts/sync-template-catalog.sh
```

- [ ] **Step 5: Sync the docs mirror**

Run:

```bash
scripts/sync-template-catalog.sh
scripts/sync-template-catalog.sh --check
```

Expected: `--check` exits `0` with no diff output.

- [ ] **Step 6: Update manifest**

Add a row to `agent-bootstrap/MANIFEST.md`:

```markdown
| `scripts/sync-template-catalog.sh` | Maintainer utility that regenerates the docs template mirror from `agent-bootstrap/templates`. | `--check` must pass in the bootstrap integration test. |
```

- [ ] **Step 7: Run tests**

Run:

```bash
bash -n scripts/sync-template-catalog.sh
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through template mirror sync checks.

---

### Task 8: Update Generated Guidance And Docs

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh`
- Modify: `README.md`
- Modify: `agent-bootstrap/README.md`
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/README.md`
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing content assertions**

In `scripts/test-bootstrap-multi-agent-project.sh`, add:

```bash
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "scripts/agent-guard.sh pre-final --run-verify" "AGENTS close-out verify command"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/task-journal.md")" "verification report" "task journal verification evidence guidance"
need_contains "$(cat "$ROOT_DIR/README.md")" "pre-final --run-verify" "root README closed-loop guidance"
need_contains "$(cat "$ROOT_DIR/agent-bootstrap/README.md")" "pre-final --run-verify" "bundle README closed-loop guidance"
need_contains "$(cat "$ROOT_DIR/README.md")" "not a security boundary for arbitrary Bash" "root README shell boundary"
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL on missing updated guidance.

- [ ] **Step 3: Update generated AGENTS guidance**

In both infra and full `AGENTS.md` writers in `agent-bootstrap/lib/writers-docs.sh`, replace plain close-out guidance:

```text
Run `scripts/agent-guard.sh pre-final` before claiming completion.
```

with:

```text
Run `scripts/agent-guard.sh pre-final --run-verify` before claiming ordinary completion; this runs the fast verification subset. For release, high-risk, or final PR readiness, run `scripts/agent-guard.sh pre-final --run-verify --verify-scope full`. If a detected command is a placeholder or requires unavailable local services, record the skip reason in the task journal and rerun with `--advisory` only when the user or CI environment explicitly requires advisory mode.
```

- [ ] **Step 4: Update task journal evidence guidance**

In the generated `docs/agent-configs/task-journal.md` heredoc, add to close-out guidance:

```markdown
- verification: path to `.agents/state/last-verify-report.json`, or `n/a` with a short reason when verification is delegated to CI or blocked by local environment.
```

- [ ] **Step 5: Update READMEs**

In `README.md`, `agent-bootstrap/README.md`, and `docs/agent-configs/bootstrap-multi-agent-project/README.md`, add a short section:

````markdown
### Closed-loop pre-final

The detector emits verification candidates as structured JSON. The standard local close-out path is:

```bash
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
```

`pre-final --run-verify` runs concrete fast detector commands and skips placeholders such as `xcodebuild ... <scheme>` with a warning. Use `--verify-scope full` to include build/full commands. Results are written to `.agents/state/last-verify-report.json` and a compact event is appended to `.agents/state/session-events.jsonl`.

Agent Guard is a file/context/verification guardrail. It is not a security boundary for arbitrary Bash commands.
````

- [ ] **Step 6: Run docs tests**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS through content assertions.

---

### Task 9: Full Verification And Squash

**Files:**
- All changed files.

- [ ] **Step 1: Run syntax checks**

Run:

```bash
bash -n agent-bootstrap/bootstrap-multi-agent-project.sh
bash -n agent-bootstrap/agent-guard.sh
bash -n agent-bootstrap/agent-tech-stack-lib.sh
bash -n agent-bootstrap/detect-agent-tech-stack.sh
bash -n agent-bootstrap/lib/core.sh
bash -n agent-bootstrap/lib/detect.sh
bash -n agent-bootstrap/lib/render.sh
bash -n agent-bootstrap/lib/writers-docs.sh
bash -n agent-bootstrap/lib/writers-runtime.sh
bash -n scripts/sync-template-catalog.sh
```

Expected: all exit `0`.

- [ ] **Step 2: Run integration tests**

Run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
scripts/test-one-shot-upgrade.sh
```

Expected: both exit `0`.

- [ ] **Step 3: Run diff hygiene**

Run:

```bash
git diff --check
git status --short --branch
```

Expected: `git diff --check` exits `0`; status shows only intended changed files.

- [ ] **Step 4: Review generated runtime drift**

Run:

```bash
scripts/sync-template-catalog.sh --check
scripts/test-bootstrap-multi-agent-project.sh
```

Expected: both exit `0`, confirming template mirror and generated target contracts are aligned.

- [ ] **Step 5: Create one branch commit**

Run:

```bash
git add agent-bootstrap docs README.md scripts
git commit -m "feat: close harness verification loop"
```

Expected: one commit on `feature/harness-closed-loop`.

- [ ] **Step 6: Confirm one-branch-one-commit**

Run:

```bash
git rev-list --count main..HEAD
git log --oneline main..HEAD
```

Expected:

```text
1
```

and a single commit:

```text
<sha> feat: close harness verification loop
```

If more than one commit exists, squash with:

```bash
git reset --soft main
git commit -m "feat: close harness verification loop"
```

---

## Self-Review Notes

- The plan covers the approved combined scope: source-of-truth/parity, detector structured output, pre-final verification, stack drift, telemetry, and docs.
- The plan intentionally excludes full secret scanning, automatic rollback checkpoints, handoff-state runtime, and shell sandboxing to keep the branch reviewable.
- No external Python dependencies are introduced.
- The plan preserves existing non-destructive generated candidate behavior and advisory degradation under unwritable state.
- `pre-final --run-verify` runs the fast subset by default; build/full commands are skipped with reason `scope_fast`. `--verify-scope full` is the explicit release/high-risk path. Each executed command is bounded by `VERIFY_TIMEOUT_SECONDS=900`.
- Session telemetry is intentionally pass-only in v1: failing-command detail is captured in `last-verify-report.json`, and fail-trend JSONL is deferred.

---

## Revision Notes (R1 — folded in from review, before re-review)

These changes were applied to the plan after the first review pass. Anchors named
below were verified to exist in the current tree (`feature/harness-closed-loop`, based
on `main`, which already contains the upgrade-ergonomics + memory-discipline work, so
`validate_memory_closeout`, `hash_text`, `detector_summary_for_lock`,
`write_template_catalog`, and the `pre_final()` option-parse structure are all present).

1. **Task 4 — pin the summary-format coupling (was the only real correctness risk).**
   Added two assertions in Step 1: (a) a fresh target must not emit the `detector summary
   drifted` line, and (b) `detect-agent-tech-stack.sh --summary` must byte-match the lock's
   `detector_summary`. Rationale: the lock hashes `detector_summary_for_lock()`
   (`lib/detect.sh`) while the drift check hashes `--summary` (`agent_print_summary` in
   `agent-tech-stack-lib.sh`); they are byte-identical today but in different files with no
   test pinning the invariant — a one-sided edit would turn the new hard-fail into a
   false-positive on every pre-final.
2. **Task 3 Step 6 — single source for the placeholder rule.** Removed the duplicate Bash
   `verification_command_is_runnable` helper; classification now lives only in the Python
   runner (Step 7) to avoid two rules drifting apart.
3. **Task 3 Step 7 — parenthesized the placeholder filter** so correctness no longer depends
   on Python `and`/`or` precedence.
4. **Task 7 Step 1 — wrapped the mirror `--check` assertion with `|| fail`** and a clear
   message, consistent with the suite style.
5. **Self-Review — documented two intentional trade-offs:** `--run-verify` now runs the
   fast subset by default with explicit `--verify-scope full` for release/high-risk work,
   and telemetry is pass-only in v1.

Decision: `--run-verify` distinguishes `fast` and `full` scopes. The default close-out
path must stay cheap enough that agents actually run it; full build coverage remains
available through `--verify-scope full` and CI.
