#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

WORKFLOW_PRESET="full"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RTK="$PROJECT_ROOT/scripts/rtk"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
LOCK_FILE="$PROJECT_ROOT/docs/agent-configs/agent-bootstrap.lock.json"
CODEX_HELPER="$PROJECT_ROOT/.codex/codex-mode.sh"
VERIFY_AI_DEPS="$PROJECT_ROOT/scripts/verify-ai-deps.sh"
AGENT_GUARD="$PROJECT_ROOT/scripts/agent-guard.sh"

NO_SCAN_PATHS=(
  ".claude/worktrees/"
  ".tools/"
  ".gradle/"
  ".gradle-ci/"
  ".gradle-ci-real/"
  ".gradle-codex/"
  ".gradle-local/"
  ".codex/environments/"
  ".superpowers/brainstorm/"
  ".cursor/rules-local/"
  ".gemini/"
  ".windsurf/"
  ".openclaude/"
  ".agents/runtime/"
  ".agents/state/"
  ".agents/cache/"
  "build/"
  "*/build/"
  "*/out/"
)

LOCAL_ONLY_PATHS=(
  "AGENTS.local.md"
  "CLAUDE.local.md"
  "GEMINI.local.md"
  "*.local.agents.md"
  "*.local.claude.md"
  "*.local.gemini.md"
  "docs/agent-configs/*.local.md"
  ".claude/settings.local.json"
  ".claude/*/settings.local.json"
  ".claude/worktrees/"
  ".codex-mode-lock"
  ".codex/.setup-codex-project.state"
  ".codex/.setup-codex-project.bootstrap"
  ".codex/environments/"
  ".codex/config.toml.bak.*"
  ".tools/"
  ".cursor/rules-local/"
  ".cursor/**/*.local.mdc"
  ".gemini/"
  ".windsurf/"
  ".openclaude/"
  ".openclaude-profile.json"
  ".superpowers/brainstorm/"
  ".agents/runtime/"
  ".agents/state/"
  ".agents/cache/"
)

SENSITIVE_LOCAL_PATHS=(
  "local.properties"
  "*/local.properties"
  "keystore.properties"
  "*/keystore.properties"
  ".env"
  ".env.*"
  "*/.env"
  "*/.env.*"
  "*.jks"
  "*.keystore"
  "*.pem"
  "*.p8"
  "*.key"
)

fail() {
  echo "agent-hook: ERROR: $*" >&2
  exit 1
}

required_file() {
  [[ -f "$1" ]] || fail "missing required file: ${1#"$PROJECT_ROOT"/}"
}

required_executable() {
  [[ -x "$1" ]] || fail "missing executable file: ${1#"$PROJECT_ROOT"/}"
}

rtk_available() {
  [[ -x "$RTK" ]] && "$RTK" --version >/dev/null 2>&1
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    echo "ERROR: missing SHA-256 tool: install sha256sum, shasum, or python3" >&2
    return 1
  fi
}

lock_value() {
  local key="$1"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read bootstrap lock"
  python3 - "$LOCK_FILE" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path, wanted = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)


def walk(value):
    if isinstance(value, dict):
        if wanted in value:
            found = value[wanted]
            if isinstance(found, str):
                print(found)
                return True
            if isinstance(found, bool):
                print("true" if found else "false")
                return True
            if isinstance(found, (int, float)):
                print(found)
                return True
        for child in value.values():
            if walk(child):
                return True
    elif isinstance(value, list):
        for child in value:
            if walk(child):
                return True
    return False


walk(document)
PY
}

verify_detector_lock() {
  local on_drift="${1:-fail}"
  required_file "$LOCK_FILE"
  local expected actual summary
  expected="$(lock_value detector_summary_sha256)"
  [[ -n "$expected" ]] || fail "missing detector_summary_sha256 in ${LOCK_FILE#"$PROJECT_ROOT"/}"
  summary="$("$DETECTOR" --summary)"
  actual="$(printf '%s' "$summary" | hash_text)"
  if [[ "$actual" != "$expected" ]]; then
    if [[ "$on_drift" == "warn" ]]; then
      echo "agent-hook: warn: detector summary drifted from lock. Re-run bootstrap/lock refresh intentionally before launching agents. expected=$expected actual=$actual" >&2
      return 0
    fi
    fail "detector summary drifted from lock. Re-run bootstrap/lock refresh intentionally before launching agents. expected=$expected actual=$actual"
  fi
}

is_tracked() {
  local pathspec="$1"
  local tracked_path
  if rtk_available; then
    while IFS= read -r tracked_path; do
      [[ -n "$tracked_path" ]] || continue
      if [[ -e "$PROJECT_ROOT/$tracked_path" ]]; then
        return 0
      fi
    done < <("$RTK" git -C "$PROJECT_ROOT" ls-files -- "$pathspec")
    return 1
  fi
  if command -v git >/dev/null 2>&1 &&
    git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r tracked_path; do
      [[ -n "$tracked_path" ]] || continue
      if [[ -e "$PROJECT_ROOT/$tracked_path" ]]; then
        return 0
      fi
    done < <(git -C "$PROJECT_ROOT" ls-files -- "$pathspec")
  fi
  return 1
}

print_no_scan_paths() {
  printf '%s\n' \
    "${NO_SCAN_PATHS[@]}" \
    "${LOCAL_ONLY_PATHS[@]}" \
    "${SENSITIVE_LOCAL_PATHS[@]}" |
    awk '!seen[$0]++'
}

guard_local_state() {
  local relative
  for relative in "${LOCAL_ONLY_PATHS[@]}"; do
    if is_tracked "$relative"; then
      fail "local-only agent state is tracked: $relative"
    fi
  done
}

parse_claude_hook_input() {
  local input="$1"
  if command -v python3 >/dev/null 2>&1; then
    HOOK_INPUT="$input" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(1)

tool_name = payload.get("tool_name") or payload.get("tool")
tool_input = payload.get("tool_input") or payload.get("input") or {}
if not isinstance(tool_input, dict):
    tool_input = {}
file_path = tool_input.get("file_path") or tool_input.get("path") or ""
if not isinstance(tool_name, str):
    tool_name = ""
if not isinstance(file_path, str):
    file_path = ""
sys.stdout.buffer.write((tool_name + "\0" + file_path + "\0").encode("utf-8"))
PY
    return $?
  fi
  local tool_name file_path
  tool_name="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s\0%s\0' "$tool_name" "$file_path"
}

guard_claude_edit_tool() {
  local edit_path="$1" ask_reason="${2:-}" rc=0 classification=""
  [[ -n "$edit_path" ]] || fail "Claude edit hook did not include tool_input.file_path"
  if [[ -n "${AGENT_GUARD_EDIT_ACK:-}" ]]; then
    classification="$("$AGENT_GUARD" pre-edit --strict --use-ack-log --ack "$AGENT_GUARD_EDIT_ACK" "$edit_path")" || rc=$?
  else
    classification="$("$AGENT_GUARD" pre-edit --strict --use-ack-log "$edit_path")" || rc=$?
  fi
  # Stdout must be pure JSON when the hook asks the user; otherwise keep the
  # classification on stdout (debug log only), so denials stay two stderr lines.
  if [[ -z "$ask_reason" && -n "$classification" ]]; then
    printf '%s\n' "$classification"
  fi
  case "$rc" in
    0) return 0 ;;
    3) exit 2 ;;
    *) exit "$rc" ;;
  esac
}

claude_anchor_env() {
  # Claude Code adapter: mint the workspace envelope from host-provided hook
  # data (session_id, CLAUDE_PROJECT_DIR) only when no envelope exists. Never
  # derive it from the agent's current directory or overwrite existing values.
  local input="$1" minted
  CLAUDE_ANCHOR_MINTED=false
  [[ -z "${AGENT_WORKSPACE_CONTEXT:-}" && -z "${AGENT_HOST_SESSION_ID:-}" ]] || return 0
  [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && command -v python3 >/dev/null 2>&1 || return 0
  minted="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import base64
import json
import os
import re
import sys

try:
    payload = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(1)
session = payload.get("session_id") if isinstance(payload, dict) else None
root = os.environ.get("CLAUDE_PROJECT_DIR", "")
if (not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9._:-]+", session)
        or not os.path.isabs(root) or not os.path.isdir(root)):
    sys.exit(1)
context = dict(original_workspace=root, target_repository=root, target_source="user", session_id=session)
print(session)
print("base64:" + base64.b64encode(json.dumps(context, ensure_ascii=False).encode("utf-8")).decode("ascii"))
PY
)" || return 0
  AGENT_HOST_SESSION_ID="${minted%%$'\n'*}"
  AGENT_WORKSPACE_CONTEXT="${minted#*$'\n'}"
  export AGENT_HOST_SESSION_ID AGENT_WORKSPACE_CONTEXT
  CLAUDE_ANCHOR_MINTED=true
}

workspace_ask_reason() {
  # Print a reason only when Claude Code should ask the user: a cross-repository
  # mismatch. Worktree mismatches and unattested sessions stay advisory.
  local report
  report="$("$AGENT_GUARD" workspace-check 2>/dev/null)" && return 0
  REPORT="$report" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    doc = json.loads(os.environ.get("REPORT", "").strip().splitlines()[-1])
except Exception:
    raise SystemExit(0)
if doc.get("status") == "mismatch" and doc.get("mismatch_kind") == "repository":
    print("Workspace-repository guard: " + str(doc.get("reason")) + "; context="
          + json.dumps(doc.get("context"), ensure_ascii=False)
          + "; confirm the target repository with the user before writing.")
PY
}

claude_ask() {
  ASK_REASON="$1" python3 - <<'PY'
import json
import os

print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                         "permissionDecisionReason": os.environ["ASK_REASON"]}},
                 ensure_ascii=False))
PY
}

claude_session_start() {
  # SessionStart hook: anchor the session, persist the envelope for later Bash
  # tool commands through CLAUDE_ENV_FILE, and report the status to Claude.
  # Never blocks the session.
  local input="" report
  if [[ ! -t 0 ]]; then
    input="$(cat || true)"
  fi
  claude_anchor_env "$input"
  if [[ "$CLAUDE_ANCHOR_MINTED" == "true" && -n "${CLAUDE_ENV_FILE:-}" ]]; then
    printf 'export AGENT_HOST_SESSION_ID=%s\nexport AGENT_WORKSPACE_CONTEXT=%s\n' \
      "$AGENT_HOST_SESSION_ID" "$AGENT_WORKSPACE_CONTEXT" >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  report="$("$AGENT_GUARD" workspace-check 2>/dev/null || true)"
  REPORT="$report" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    doc = json.loads(os.environ.get("REPORT", "").strip().splitlines()[-1])
except Exception:
    doc = {"status": "unknown"}
status = str(doc.get("status", "unknown"))
line = "Workspace-repository guard (advisory): " + status
if status == "verified":
    line += "; target " + str(doc.get("target_repository"))
elif status == "mismatch":
    line += " (" + str(doc.get("mismatch_kind")) + "): " + str(doc.get("reason")) \
        + "; confirm the target repository with the user before writing"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": line}},
                 ensure_ascii=False))
PY
  exit 0
}

claude_pretool() {
  required_executable "$DETECTOR"
  required_executable "$AGENT_GUARD"
  local hook_input=""
  local tool_name=""
  local edit_path=""
  local ask_reason=""
  if [[ ! -t 0 ]]; then
    hook_input="$(cat || true)"
  fi
  claude_anchor_env "$hook_input"
  "$AGENT_GUARD" preflight >/dev/null
  ask_reason="$(workspace_ask_reason)"
  if [[ -n "$hook_input" ]]; then
    tool_name=""
    edit_path=""
    exec 3< <(parse_claude_hook_input "$hook_input" || true)
    IFS= read -r -d '' tool_name <&3 || true
    IFS= read -r -d '' edit_path <&3 || true
    exec 3<&-
    case "$tool_name" in
      Edit|Write|MultiEdit)
        guard_claude_edit_tool "$edit_path" "$ask_reason"
        [[ -z "$ask_reason" ]] || claude_ask "$ask_reason"
        exit 0
        ;;
    esac
  fi
  verify_detector_lock warn
  if [[ -n "$ask_reason" ]]; then
    claude_ask "$ask_reason"
    exit 0
  fi
  cd "$PROJECT_ROOT"
  if rtk_available; then
    exec "$RTK" hook claude
  fi
  echo "agent-hook: warn: pinned rtk binary is not installed; skipping rtk Claude hook. Run: bash scripts/install-rtk.sh" >&2
  exit 0
}

codex_preflight() {
  local check_only=false
  if [[ "${1:-}" == "--check-only" ]]; then
    check_only=true
    shift
  fi
  if [[ "$check_only" != "true" ]]; then
    "$AGENT_GUARD" workspace-check >/dev/null || true
  fi
  local mode="${1:-unknown}"
  local flow="${2:-unknown}"
  required_file "$PROJECT_ROOT/AGENTS.md"
  required_file "$PROJECT_ROOT/CLAUDE.md"
  required_file "$PROJECT_ROOT/docs/agent-configs/project-agent-context.md"
  if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
    required_file "$PROJECT_ROOT/docs/agent-configs/agent-mode-contracts.md"
    required_file "$PROJECT_ROOT/docs/agent-configs/agent-handoff-schema.md"
    required_file "$PROJECT_ROOT/.codex/config.toml"
  fi
  required_executable "$DETECTOR"
  required_executable "$AGENT_GUARD"
  guard_local_state
  if [[ "$check_only" == "true" ]]; then
    "$AGENT_GUARD" check >/dev/null
  else
    "$AGENT_GUARD" preflight >/dev/null
  fi
  verify_detector_lock
  echo "agent-hook: codex preflight ok (mode=$mode flow=$flow)" >&2
}

doctor() {
  if [[ -x "$CODEX_HELPER" ]]; then
    "$CODEX_HELPER" doctor
  fi
  if [[ -x "$VERIFY_AI_DEPS" ]]; then
    "$VERIFY_AI_DEPS"
  else
    codex_preflight doctor standard
  fi
}

close_out() {
  # Claude Code Stop hook. Run fast verification in advisory mode so unrelated
  # strict checks do not abort the hook, then block Stop (exit 2) only when this
  # session has file changes and the verification report contains real failures.
  # Gemini/Cursor/Windsurf have no equivalent close-out hook, so those surfaces
  # stay advisory and should call agent-guard pre-final manually.
  local input stop_active=false report failed=0 err_file
  input="$(cat 2>/dev/null || true)"
  claude_anchor_env "$input"
  if command -v python3 >/dev/null 2>&1; then
    stop_active="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null || printf 'false\n'
import json
import os

try:
    payload = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    payload = {}
print("true" if payload.get("stop_hook_active") is True else "false")
PY
)"
  fi
  [[ "$stop_active" == "true" ]] && exit 0
  if command -v git >/dev/null 2>&1 &&
    [[ -z "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]]; then
    exit 0
  fi
  err_file="$PROJECT_ROOT/.agents/state/closeout.err"
  mkdir -p "$(dirname "$err_file")" 2>/dev/null || err_file="${TMPDIR:-/tmp}/agent-bootstrap-closeout.err"
  "$AGENT_GUARD" pre-final --run-verify --verify-scope fast --advisory >/dev/null 2>"$err_file" || true
  report="$PROJECT_ROOT/.agents/state/last-verify-report.json"
  if [[ -f "$report" ]] && command -v python3 >/dev/null 2>&1; then
    failed="$(python3 - "$report" <<'PY' 2>/dev/null || printf '0\n'
import json
import sys

try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit(0)
print(int(doc.get("summary", {}).get("fail", 0)))
PY
)"
  fi
  if [[ "${failed:-0}" -gt 0 ]]; then
    printf 'agent-guard: close-out fast verification failed (%s failed); review .agents/state/last-verify-report.json before completing.\n' "$failed" >&2
    exit 2
  fi
  exit 0
}

case "${1:-}" in
  claude-pretool)
    shift || true
    claude_pretool "$@"
    ;;
  claude-session-start)
    claude_session_start
    ;;
  codex-preflight)
    shift || true
    codex_preflight "$@"
    ;;
  guard-local-state)
    guard_local_state
    ;;
  no-scan-paths)
    print_no_scan_paths
    ;;
  doctor)
    doctor
    ;;
  close-out)
    close_out
    ;;
  -h|--help|help|"")
    echo "Usage: scripts/agent-hook.sh claude-pretool|claude-session-start|codex-preflight|guard-local-state|no-scan-paths|doctor|close-out"
    ;;
  *)
    fail "unknown command: $1"
    ;;
esac
