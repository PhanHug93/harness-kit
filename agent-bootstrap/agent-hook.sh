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
    *)
      # Claude Code only blocks on exit 2; any other guard refusal (outside the
      # project root, missing context, failed preflight) must block the edit too.
      echo "agent-hook: ERROR: edit blocked: agent-guard pre-edit exited $rc" >&2
      exit 2
      ;;
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

hook_input_field() {
  # Print a string or boolean field of the Claude hook JSON; empty otherwise.
  command -v python3 >/dev/null 2>&1 || return 0
  HOOK_INPUT="$1" python3 - "$2" <<'PY' 2>/dev/null || true
import json
import os
import sys

try:
    value = json.loads(os.environ.get("HOOK_INPUT", "") or "{}").get(sys.argv[1])
except Exception:
    value = None
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
PY
}

# Same order as agent_resolve_state_dir in scripts/agent-guard.sh, so session
# snapshots live next to the guard's reports: $AGENT_STATE_DIR, .agents/state,
# then a per-project dir under TMPDIR. Sets HOOK_STATE_DIR.
hook_state_dir_usable() {
  local d="$1" parent
  if [[ -d "$d" ]]; then
    [[ -w "$d" ]]
    return
  fi
  parent="$(dirname "$d")"
  while [[ ! -d "$parent" && "$parent" != "/" && "$parent" != "." ]]; do
    parent="$(dirname "$parent")"
  done
  [[ -w "$parent" ]]
}

resolve_hook_state_dir() {
  local candidate
  HOOK_STATE_DIR=""
  for candidate in \
    "${AGENT_STATE_DIR:-}" \
    "$PROJECT_ROOT/.agents/state" \
    "${TMPDIR:-/tmp}/agent-bootstrap-state/$(printf '%s' "$PROJECT_ROOT" | cksum | tr -d ' \t')"; do
    [[ -n "$candidate" ]] || continue
    if hook_state_dir_usable "$candidate"; then
      HOOK_STATE_DIR="$candidate"
      return 0
    fi
  done
  return 1
}

# Sets SESSION_SNAPSHOT, SESSION_TAG (first 12 hex of sha256(session_id), which
# names this session's close-out report and error log) and HOOK_STATE_DIR; fails
# for ids that are not ^[A-Za-z0-9._-]+$ or when no state dir is usable.
set_session_snapshot() {
  local session="$1" pattern='^[A-Za-z0-9._-]+$' tag_pattern='^[0-9a-f]{12}$'
  SESSION_SNAPSHOT=""
  SESSION_TAG=""
  [[ "$session" =~ $pattern ]] || return 1
  resolve_hook_state_dir || return 1
  SESSION_TAG="$(printf '%s' "$session" | hash_text 2>/dev/null)" || return 1
  SESSION_TAG="${SESSION_TAG:0:12}"
  [[ "$SESSION_TAG" =~ $tag_pattern ]] || return 1
  SESSION_SNAPSHOT="$HOOK_STATE_DIR/sessions/$session.snapshot"
}

change_map() {
  # change_map write|same <snapshot>: the change map starts with "HEAD\t<commit
  # or none>" (so a commit counts as a change), then one sorted line per path
  # that `git status` reports (untracked included, ignored and the hook state
  # dir excluded) as "<path>\t<sha256|deleted|unreadable>"; backslash, tab, CR
  # and newline in paths are escaped. The digest covers the content and the
  # executable bit (a link: its target; a submodule or nested repository: its
  # HEAD and status). `write` replaces the snapshot atomically; `same` exits 0
  # only when the snapshot equals the current map, stopping at the first
  # difference (1 differs, 2 map unavailable).
  python3 - "$PROJECT_ROOT" "$1" "$2" "$HOOK_STATE_DIR" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys

root, mode, snapshot, state_dir = (os.fsencode(sys.argv[1]), sys.argv[2], sys.argv[3],
                                   os.fsencode(sys.argv[4]))


def git(args, cwd):
    return subprocess.run(["git", "--no-optional-locks", "-C", cwd] + args, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True, timeout=120).stdout


try:
    top = os.path.realpath(git(["rev-parse", "--show-toplevel"], root).rstrip(b"\n"))
    raw = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
except Exception:
    sys.exit(2)
try:
    head = git(["rev-parse", "--verify", "-q", "HEAD"], root).strip() or b"none"
except Exception:
    head = b"none"
# Paths under the hook state dir (AGENT_STATE_DIR inside the tree) never count.
skip = os.path.relpath(os.path.realpath(state_dir), top) if state_dir else b".."
skip = None if skip == b"." or skip.startswith(b"..") else skip + b"/"
fields = raw.split(b"\0")
paths = set()
index = 0
while index < len(fields):
    entry = fields[index]
    index += 1
    if len(entry) < 4:
        continue
    found = [entry[3:]]
    if b"R" in entry[:2] or b"C" in entry[:2]:
        # Rename/copy: the source path follows as its own field.
        if index < len(fields) and fields[index]:
            found.append(fields[index])
        index += 1
    paths.update(p for p in found if not (skip and (p + b"/").startswith(skip)))


def digest(rel):
    path = os.path.join(top, rel.rstrip(b"/"))
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return b"deleted"
    except OSError:
        return b"unreadable"
    sha = hashlib.sha256()
    try:
        if stat.S_ISLNK(info.st_mode):
            sha.update(b"link\0" + os.readlink(path))
        elif stat.S_ISDIR(info.st_mode):
            sha.update(b"repo\0")
            # Only a directory with its own .git (a submodule or nested repo)
            # is probed; a plain directory must not hash the parent's status.
            if os.path.lexists(os.path.join(path, b".git")):
                for args in (["rev-parse", "HEAD"], ["status", "--porcelain", "-z"]):
                    try:
                        sha.update(git(args, path) + b"\0")
                    except Exception:
                        sha.update(b"?\0")
            else:
                sha.update(b"dir\0")
        else:
            sha.update(b"file\0x\0" if info.st_mode & 0o111 else b"file\0-\0")
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    sha.update(chunk)
    except OSError:
        return b"unreadable"
    return sha.hexdigest().encode()


def escape(rel):
    return (rel.replace(b"\\", b"\\\\").replace(b"\t", b"\\t")
            .replace(b"\r", b"\\r").replace(b"\n", b"\\n"))


rows = sorted((escape(p), p) for p in paths)
header = b"HEAD\t" + head + b"\n"
if mode == "same":
    try:
        with open(snapshot, "rb") as handle:
            lines = handle.read().split(b"\n")
    except OSError:
        sys.exit(1)
    if lines[0] + b"\n" != header or lines[-1] != b"" or len(lines) - 2 != len(rows):
        sys.exit(1)
    saved = {}
    for line in lines[1:-1]:
        name, sep, value = line.rpartition(b"\t")
        if not sep:
            sys.exit(1)
        saved[name] = value
    if set(saved) != set(name for name, _ in rows):
        sys.exit(1)
    for name, path in rows:
        if digest(path) != saved[name]:
            sys.exit(1)
    sys.exit(0)
content = header + b"".join(name + b"\t" + digest(path) + b"\n" for name, path in rows)
os.makedirs(os.path.dirname(snapshot), exist_ok=True)
temp = "{}.tmp.{}".format(snapshot, os.getpid())
try:
    with open(temp, "wb") as handle:
        handle.write(content)
    os.replace(temp, snapshot)
finally:
    if os.path.lexists(temp):
        os.unlink(temp)
PY
}

write_session_snapshot() {
  # Record which paths are already changed when the session starts, so the Stop
  # hook verifies only this session's changes. An existing snapshot is kept:
  # SessionStart also fires on resume and compact for the same session id.
  local session snapshot
  command -v python3 >/dev/null 2>&1 || {
    echo "agent-hook: warn: python3 is unavailable; no session snapshot, close-out will be skipped" >&2
    return 0
  }
  session="$(hook_input_field "$1" session_id)"
  if ! set_session_snapshot "$session"; then
    echo "agent-hook: warn: no usable session_id or state dir; no session snapshot, close-out will be skipped" >&2
    return 0
  fi
  snapshot="$SESSION_SNAPSHOT"
  [[ ! -f "$snapshot" ]] || return 0
  # Snapshots and close-out reports/logs of finished sessions are pruned after 30 days.
  find "$HOOK_STATE_DIR/sessions" -type f \( -name '*.snapshot' -o -name '*.snapshot.tmp.*' \) \
    -mtime +30 -exec rm -f {} + 2>/dev/null || true
  find "$HOOK_STATE_DIR" -maxdepth 1 -type f \( -name 'closeout-*-verify.json' -o -name 'closeout-*.err' \) \
    -mtime +30 -exec rm -f {} + 2>/dev/null || true
  change_map write "$snapshot" ||
    echo "agent-hook: warn: could not record the session snapshot; close-out will be skipped" >&2
  return 0
}

claude_session_start() {
  # SessionStart hook: anchor the session, persist the envelope for later Bash
  # tool commands through CLAUDE_ENV_FILE, report the status to Claude, then
  # record the session's change snapshot for close-out (after the JSON, so the
  # report is not held behind hashing). Never blocks the session.
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
                 ensure_ascii=False), flush=True)
PY
  write_session_snapshot "$input" || true
  exit 0
}

claude_pretool() {
  required_executable "$DETECTOR"
  # Internal errors must not lock all edits: without python3 or the guard the
  # policy cannot be evaluated, so warn and allow.
  if ! command -v "${AGENT_HOOK_PYTHON:-python3}" >/dev/null 2>&1 || [[ ! -x "$AGENT_GUARD" ]]; then
    echo "agent-hook: warn: python3 or scripts/agent-guard.sh is unavailable; skipping the edit guard" >&2
    exit 0
  fi
  local hook_input=""
  local tool_name=""
  local edit_path=""
  local ask_reason=""
  if [[ ! -t 0 ]]; then
    hook_input="$(cat || true)"
  fi
  claude_anchor_env "$hook_input"
  local preflight_rc=0
  "$AGENT_GUARD" preflight >/dev/null || preflight_rc=$?
  if [[ "$preflight_rc" -ne 0 && -z "$hook_input" ]]; then
    exit "$preflight_rc"
  fi
  ask_reason="$(workspace_ask_reason)"
  if [[ -n "$hook_input" ]]; then
    tool_name=""
    edit_path=""
    exec 3< <(parse_claude_hook_input "$hook_input" || true)
    IFS= read -r -d '' tool_name <&3 || true
    IFS= read -r -d '' edit_path <&3 || true
    exec 3<&-
    if [[ "$preflight_rc" -ne 0 ]]; then
      case "$tool_name" in
        Edit|Write|MultiEdit)
          echo "agent-hook: ERROR: edit blocked: agent-guard preflight exited $preflight_rc" >&2
          exit 2
          ;;
      esac
      exit "$preflight_rc"
    fi
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
  # Claude Code Stop hook. Verify only when the paths changed since this
  # session's snapshot (written at SessionStart, advanced after each
  # non-blocking close-out), so a seat is not blocked by another seat's edits and
  # an unchanged turn costs nothing. Fast verification runs in advisory mode,
  # within 300 s (the Stop hook timeout is 360 s), into this session's own report
  # (closeout-<tag>-verify.json, never last-verify-report.json); Stop is blocked
  # (exit 2) on missing evidence or any fail/error/timeout, and kept blocked
  # until the change verifies. Unverified only warns, and so does a change above
  # its declared tier: tier checks recommend, never block.
  # Gemini/Cursor/Windsurf have no equivalent close-out hook, so those surfaces
  # stay advisory and should call agent-guard pre-final manually.
  local input session snapshot out report verdict tier_note err_file budget declared measured reasons seats which digits='^[0-9]{1,3}$'
  local notes
  input="$(cat 2>/dev/null || true)"
  claude_anchor_env "$input"
  [[ "$(hook_input_field "$input" stop_hook_active)" == "true" ]] && exit 0
  session="$(hook_input_field "$input" session_id)"
  if ! command -v python3 >/dev/null 2>&1 || ! set_session_snapshot "$session" ||
    [[ ! -f "$SESSION_SNAPSHOT" ]]; then
    echo "agent-hook: close-out skipped (no session snapshot); run scripts/agent-guard.sh pre-final --run-verify" >&2
    exit 0
  fi
  snapshot="$SESSION_SNAPSHOT"
  change_map same "$snapshot" && exit 0
  err_file="$HOOK_STATE_DIR/closeout-$SESSION_TAG.err"
  # The total budget overrides the fast default in the guard; cap it at 300 s.
  budget="${AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS:-${AGENT_GUARD_VERIFY_TOTAL_FAST_SECONDS:-300}}"
  if [[ ! "$budget" =~ $digits ]] || ((10#$budget == 0 || 10#$budget > 300)); then
    budget=300
  fi
  out="$(AGENT_GUARD_VERIFY_REPORT_NAME="closeout-$SESSION_TAG-verify.json" \
    AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS="$((10#$budget))" \
    "$AGENT_GUARD" pre-final --run-verify --verify-scope fast --advisory 2>"$err_file" || true)"
  report="$(printf '%s\n' "$out" | sed -n 's/^agent-guard: verify_report=//p' | tail -n 1)"
  verdict="$(python3 - "$report" <<'PY' 2>/dev/null || printf 'missing\n'
import json
import sys

try:
    doc = json.load(open(sys.argv[1], encoding="utf-8")) if sys.argv[1] else None
except Exception:
    doc = None
if not isinstance(doc, dict) or not isinstance(doc.get("results", []), list):
    print("missing")
    raise SystemExit(0)
status = doc.get("status")
counts = {}
for item in doc.get("results", []):
    if isinstance(item, dict) and item.get("status") in ("fail", "error", "timeout"):
        counts[item["status"]] = counts.get(item["status"], 0) + 1
# Two lines: the verification verdict, then the tier note ("-" for none).
if counts or status in ("fail", "error"):
    detail = ", ".join("{} {}".format(n, s) for s, n in sorted(counts.items()))
    print("block {}{}".format(status, " (" + detail + ")" if detail else ""))
    print("-")
elif status in ("pass", "unverified"):
    print(status)
    tier = doc.get("tier")
    if isinstance(tier, dict) and tier.get("status") == "exceeded":
        # Raised after coding with reviews missing, and not above the tier.
        ranks = ("small", "medium", "large")
        missing = [seat for seat in ("@gate", "@verify", "@audit") if seat in (tier.get("missing_reviews") or [])]
        over = (tier.get("measured") in ranks and tier.get("allowed") in ranks
                and ranks.index(tier["measured"]) > ranks.index(tier["allowed"]))
        if missing and not over:
            print("reviews " + (missing[0] if len(missing) == 1 else ", ".join(missing[:-1]) + " and " + missing[-1]))
        else:
            reasons = "; ".join(" ".join(str(r).split()) for r in (tier.get("reasons") or [])[:3])
            if tier.get("partial") is True:
                cause = " ".join(str(tier.get("partial_reason") or "unknown cause").split())
                reasons = (reasons + ". " if reasons else "") + "The measure is partial ({}), so the count may be off".format(cause)
            print("tier {} {} {}".format(tier.get("declared"), tier.get("measured"), reasons).rstrip())
    else:
        print("-")
else:
    print("missing")
    print("-")
PY
)"
  tier_note="$(sed -n 2p <<<"$verdict")"
  verdict="$(sed -n 1p <<<"$verdict")"
  # Warnings: on stderr, and as systemMessage JSON on stdout, the only way
  # Claude Code shows a hook's message to the user when the hook exits 0.
  notes=()
  case "$verdict" in
    pass) ;;
    unverified)
      notes+=("warn: close-out verification unverified (no verification command ran); fill verification[] in docs/superpowers/specs/project-tech-stack.json; report $report")
      ;;
    "block "*)
      printf 'agent-hook: close-out fast verification %s for changes in this session; review %s before completing.\n' \
        "${verdict#block }" "$report" >&2
      grep '^agent-guard: verify\[' "$err_file" 2>/dev/null | head -n 5 >&2 || true
      exit 2
      ;;
    *)
      printf 'agent-hook: close-out verification report missing or unreadable (%s); see %s and run scripts/agent-guard.sh pre-final --run-verify before completing.\n' \
        "${report:-no verify_report line}" "$err_file" >&2
      exit 2
      ;;
  esac
  case "$tier_note" in
    "tier "*)
      # Not a block: tier checks recommend.
      read -r _ declared measured reasons <<<"$tier_note"
      notes+=("warn: this change is above its tier ($declared -> $measured). Decide before pushing: raise the tier or split the change.${reasons:+ Reasons: $reasons.}")
      ;;
    "reviews "*)
      # Not a block: the coding session must end so the review seats can run.
      # Pre-final keeps the warning until they pass.
      seats="${tier_note#reviews }"
      which="that seat"
      [[ "$seats" != *" and "* ]] || which="those seats"
      notes+=("the tier was raised after coding, so $seats should review it (run $which, or review it yourself) before this counts as done.")
      ;;
  esac
  if [[ ${#notes[@]} -gt 0 ]]; then
    printf 'agent-hook: %s\n' "${notes[@]}" >&2
    python3 -c 'import json, sys; print(json.dumps({"systemMessage": " ".join("agent-hook: " + note for note in sys.argv[1:])}))' \
      "${notes[@]}" || true
  fi
  change_map write "$snapshot" ||
    echo "agent-hook: warn: could not advance the session snapshot; the next close-out re-verifies" >&2
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
