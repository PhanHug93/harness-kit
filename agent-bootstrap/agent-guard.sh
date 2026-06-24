#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
POLICY_FILE="$PROJECT_ROOT/docs/agent-configs/context-policy.json"
PROJECT_TECH_STACK_FILE="$PROJECT_ROOT/docs/superpowers/specs/project-tech-stack.json"
# Resolve a usable state directory so the guard still works when .agents is
# read-only (e.g. sandboxed runs). Order: $AGENT_STATE_DIR, .agents/state, then
# a per-project dir under TMPDIR. Falls back to advisory-only if none is usable.
agent_state_dir_usable() {
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
agent_resolve_state_dir() {
  local candidate
  for candidate in \
    "${AGENT_STATE_DIR:-}" \
    "$PROJECT_ROOT/.agents/state" \
    "${TMPDIR:-/tmp}/agent-bootstrap-state/$(printf '%s' "$PROJECT_ROOT" | cksum | tr -d ' \t')"; do
    [[ -n "$candidate" ]] || continue
    if agent_state_dir_usable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
if STATE_DIR="$(agent_resolve_state_dir)"; then
  STATE_WRITABLE=true
else
  STATE_DIR="$PROJECT_ROOT/.agents/state"
  STATE_WRITABLE=false
fi
CONTEXT_PACK="$STATE_DIR/context-pack.json"
ACK_LOG="$STATE_DIR/guard-ack.log"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
VERIFY_REPORT="$STATE_DIR/last-verify-report.json"
VERIFY_LOG_DIR="$STATE_DIR/verify-logs"
VERIFY_TIMEOUT_SECONDS="${AGENT_GUARD_VERIFY_TIMEOUT_SECONDS:-900}"
VERIFY_SCOPE_DEFAULT="${AGENT_GUARD_VERIFY_SCOPE:-fast}"
SESSION_EVENTS="$STATE_DIR/session-events.jsonl"

REQUIRED_CONTEXT=()
RECOMMENDED_CONTEXT=()
PROTECTED_PATTERNS=()
PROTECTED_REASONS=()
AGENT_INSTRUCTIONS=()

usage() {
  printf '%s\n' \
    "Usage: scripts/agent-guard.sh preflight|check|pre-edit [--advisory|--strict] [--ack TEXT] <path>|pre-final [--advisory|--strict] [--run-verify] [--verify-scope fast|full]|status|doctor" \
    "" \
    "Lite context guard for generated multi-agent harness projects."
}

fail() {
  printf 'agent-guard: ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'agent-guard: warn: %s\n' "$*" >&2
}

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    JSON_ESCAPE_VALUE="$1" python3 - <<'PY'
import json
import os

print(json.dumps(os.environ.get("JSON_ESCAPE_VALUE", ""), ensure_ascii=False)[1:-1], end="")
PY
    return
  fi
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
  else
    echo "ERROR: missing SHA-256 tool: install sha256sum, shasum, or python3" >&2
    return 1
  fi
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

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date
}

is_safe_relative_path() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" != /* ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 1
  [[ "$value" != *'//'* ]] || return 1
  [[ "$value" != */ ]] || return 1
  [[ "$value" != "." && "$value" != ./* && "$value" != */. && "$value" != */./* ]] || return 1
  [[ "$value" != ".." && "$value" != ../* && "$value" != */.. && "$value" != */../* ]] || return 1
  return 0
}

validate_policy_path() {
  local value="$1"
  local source="$2"
  is_safe_relative_path "$value" || fail "unsafe $source path: $value"
}

collapse_relative_path() {
  local value="$1"
  local old_ifs="$IFS"
  local part
  local result=""
  local -a parts=()
  IFS='/'
  read -r -a parts <<< "$value"
  IFS="$old_ifs"
  local -a output=()
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.)
        ;;
      ..)
        if [[ "${#output[@]}" -eq 0 ]]; then
          return 1
        fi
        unset 'output[${#output[@]}-1]'
        output=("${output[@]}")
        ;;
      *)
        output+=("$part")
        ;;
    esac
  done
  for part in "${output[@]}"; do
    if [[ -z "$result" ]]; then
      result="$part"
    else
      result="$result/$part"
    fi
  done
  [[ -n "$result" ]] || result="."
  printf '%s' "$result"
}

canonical_project_abspath() {
  local raw_path="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PROJECT_ROOT" "$raw_path" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
raw = pathlib.Path(sys.argv[2])
candidate = raw if raw.is_absolute() else root / raw
resolved = candidate.resolve(strict=False)
try:
    resolved.relative_to(root)
except ValueError:
    print("outside project root", file=sys.stderr)
    sys.exit(2)
print(resolved)
PY
    return $?
  fi

  local relpath="$raw_path"
  case "$raw_path" in
    "$PROJECT_ROOT")
      printf '%s' "$PROJECT_ROOT"
      return 0
      ;;
    "$PROJECT_ROOT"/*)
      relpath="${raw_path#"$PROJECT_ROOT"/}"
      ;;
    /*)
      printf 'outside project root\n' >&2
      return 2
      ;;
    ./*)
      relpath="${raw_path#./}"
      ;;
  esac
  relpath="$(collapse_relative_path "$relpath")" || {
    printf 'outside project root\n' >&2
    return 2
  }
  printf '%s/%s' "$PROJECT_ROOT" "$relpath"
}

canonical_project_relpath() {
  local raw_path="$1"
  local absolute
  absolute="$(canonical_project_abspath "$raw_path")" || fail "path outside project root: $raw_path"
  if [[ "$absolute" == "$PROJECT_ROOT" ]]; then
    printf '.'
  elif [[ "$absolute" == "$PROJECT_ROOT/"* ]]; then
    printf '%s' "${absolute#"$PROJECT_ROOT"/}"
  else
    fail "path outside project root: $raw_path"
  fi
}

default_required_context() {
  printf '%s\n' \
    "AGENTS.md" \
    "CLAUDE.md" \
    "docs/agent-configs/project-agent-context.md" \
    "docs/agent-configs/agent-bootstrap.lock.json" \
    "docs/agent-configs/context-policy.json"
}

default_recommended_context() {
  printf '%s\n' \
    "docs/agent-configs/project-brief.md" \
    "docs/superpowers/specs/project-tech-stack.json" \
    "docs/superpowers/specs/project-tech-stack.md" \
    "docs/agent-configs/project-onboarding.md"
}

default_protected_paths() {
  printf '%s\t%s\n' \
    "AGENTS.md" "agent entrypoint" \
    "CLAUDE.md" "claude entrypoint" \
    "GEMINI.md" "gemini entrypoint" \
    ".windsurfrules" "windsurf entrypoint" \
    ".github/**" "ci-release" \
    ".claude/settings.json" "claude hook config" \
    ".claude/commands/**" "claude commands" \
    ".codex/**" "codex adapter" \
    ".cursor/**" "cursor adapter" \
    ".gemini/**" "gemini adapter" \
    ".windsurf/**" "windsurf adapter" \
    ".openclaude/**" "openclaude adapter" \
    ".agents/skills/**" "agent skills" \
    "agent-bootstrap/**" "source bundle" \
    "docs/agent-configs/**" "agent context" \
    "docs/superpowers/specs/**" "durable specs" \
    "scripts/agent-*.sh" "agent runtime" \
    "scripts/verify-ai-deps.sh" "verifier" \
    "scripts/install-rtk.sh" "tool install" \
    "scripts/rtk" "git wrapper"
}

policy_schema_value() {
  if command -v python3 >/dev/null 2>&1 && [[ -f "$POLICY_FILE" ]]; then
    python3 - "$POLICY_FILE" <<'PY'
import json
import pathlib
import sys

try:
    doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    sys.exit(1)
print(doc.get("schema", ""))
PY
    return $?
  fi
  sed -n 's/.*"schema"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$POLICY_FILE" | head -n1
}

policy_values() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1 && [[ -f "$POLICY_FILE" ]]; then
    python3 - "$POLICY_FILE" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
doc = json.loads(path.read_text(encoding="utf-8"))

if key in ("required_context", "recommended_context", "agent_instructions"):
    for item in doc.get(key, []):
        if isinstance(item, str):
            print(item)
elif key == "protected_paths":
    for item in doc.get(key, []):
        if isinstance(item, dict):
            pattern = item.get("pattern")
            reason = item.get("reason", "")
            if isinstance(pattern, str):
                print(f"{pattern}\t{reason}")
PY
    return 0
  fi

  case "$key" in
    required_context) default_required_context ;;
    recommended_context) default_recommended_context ;;
    protected_paths) default_protected_paths ;;
    agent_instructions) ;;
    *) return 1 ;;
  esac
}

project_contract_values() {
  local key="$1"
  [[ -f "$PROJECT_TECH_STACK_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$PROJECT_TECH_STACK_FILE" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)

reason = "project protected path" if key == "protected_paths" else "project generated file"
for item in doc.get(key, []):
    if isinstance(item, str) and item:
        print(f"{item}\t{reason}")
PY
}

add_protected_pattern() {
  local pattern="$1"
  local reason="$2"
  local source="$3"
  validate_policy_path "$pattern" "$source"
  PROTECTED_PATTERNS+=("$pattern")
  PROTECTED_REASONS+=("$reason")
}

load_policy() {
  REQUIRED_CONTEXT=()
  RECOMMENDED_CONTEXT=()
  PROTECTED_PATTERNS=()
  PROTECTED_REASONS=()
  AGENT_INSTRUCTIONS=()

  [[ -f "$POLICY_FILE" ]] || fail "missing context policy: docs/agent-configs/context-policy.json"
  local schema
  schema="$(policy_schema_value || true)"
  [[ "$schema" == "agent-context-policy/v1" ]] ||
    fail "context policy schema must be agent-context-policy/v1"

  local item line pattern reason
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    validate_policy_path "$item" "context policy required_context"
    REQUIRED_CONTEXT+=("$item")
  done < <(policy_values required_context)

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    validate_policy_path "$item" "context policy recommended_context"
    RECOMMENDED_CONTEXT+=("$item")
  done < <(policy_values recommended_context)

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pattern="${line%%$'\t'*}"
    if [[ "$line" == *$'\t'* ]]; then
      reason="${line#*$'\t'}"
    else
      reason=""
    fi
    add_protected_pattern "$pattern" "$reason" "context policy protected_paths"
  done < <(policy_values protected_paths)

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pattern="${line%%$'\t'*}"
    reason="${line#*$'\t'}"
    add_protected_pattern "$pattern" "$reason" "project tech-stack protected_paths"
  done < <(project_contract_values protected_paths)

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pattern="${line%%$'\t'*}"
    reason="${line#*$'\t'}"
    add_protected_pattern "$pattern" "$reason" "project tech-stack generated_files"
  done < <(project_contract_values generated_files)

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    AGENT_INSTRUCTIONS+=("$item")
  done < <(policy_values agent_instructions)

  [[ ${#REQUIRED_CONTEXT[@]} -gt 0 ]] || fail "context policy required_context is empty"
  [[ ${#PROTECTED_PATTERNS[@]} -gt 0 ]] || fail "context policy protected_paths is empty"
}

pattern_matches() {
  local pattern="$1"
  local path="$2"
  local prefix
  case "$pattern" in
    */\*\*)
      prefix="${pattern%/\*\*}"
      [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
      ;;
    *'*'*|*'?'*|*'['*)
      # shellcheck disable=SC2053 # Project policy patterns intentionally use shell globs.
      [[ "$path" == $pattern ]]
      ;;
    *)
      [[ "$path" == "$pattern" ]]
      ;;
  esac
}

protected_reason_for_path() {
  local path="$1"
  local index=0
  while [[ "$index" -lt "${#PROTECTED_PATTERNS[@]}" ]]; do
    if pattern_matches "${PROTECTED_PATTERNS[$index]}" "$path"; then
      printf '%s\t%s' "${PROTECTED_PATTERNS[$index]}" "${PROTECTED_REASONS[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

changed_protected_paths() {
  command -v git >/dev/null 2>&1 || return 0
  git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local relpath match pattern reason
  while IFS= read -r relpath; do
    [[ -n "$relpath" ]] || continue
    case "$relpath" in
      .agents/*|.tools/*) continue ;;
    esac
    if match="$(protected_reason_for_path "$relpath")"; then
      pattern="${match%%$'\t'*}"
      if [[ "$match" == *$'\t'* ]]; then
        reason="${match#*$'\t'}"
      else
        reason=""
      fi
      printf '%s\t%s\t%s\n' "$relpath" "$pattern" "$reason"
    fi
  done < <(git -C "$PROJECT_ROOT" diff --name-only HEAD -- 2>/dev/null || true)
}

latest_journal_closeout() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$PROJECT_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
journals = sorted(
    root.glob("docs/superpowers/plans/*/journal.md"),
    key=lambda path: path.stat().st_mtime if path.exists() else 0,
    reverse=True,
)

if not journals:
    print("state\tnone")
    return_code = 0
    raise SystemExit(return_code)

def emit(key, value):
    print(f"{key}\t{str(value).replace(chr(9), ' ')}")

path = journals[0]
text = path.read_text(encoding="utf-8", errors="replace")
entries = []
current = []
for line in text.splitlines():
    if line.startswith("## "):
        if current:
            entries.append(current)
        current = [line]
    elif current:
        current.append(line)
if current:
    entries.append(current)

closeout = None
for entry in entries:
    fields = {}
    for line in entry:
        stripped = line.strip()
        if not stripped.startswith("- ") or ":" not in stripped:
            continue
        key, value = stripped[2:].split(":", 1)
        fields[key.strip()] = value.strip()
    if fields.get("status") in {"decided", "done"}:
        closeout = fields

emit("journal", path.relative_to(root))
if closeout is None:
    emit("state", "no-closeout")
    raise SystemExit(0)

emit("state", "closeout")
for key in ("status", "memory", "save_decision", "evidence", "recall_verified"):
    emit(key, closeout.get(key, ""))
PY
}

memory_gate_fail() {
  local strict="$1"
  shift
  if [[ "$strict" == "true" && "$STATE_WRITABLE" == "true" ]]; then
    fail "$*"
  fi
  warn "$*"
}

validate_memory_closeout() {
  local strict="$1"
  local changed_file="$2"
  local high_risk=false
  [[ -n "$changed_file" ]] && high_risk=true

  local summary
  summary="$(latest_journal_closeout || true)"
  local journal_state="" journal_path="" status="" memory="" save_decision="" evidence="" recall_verified=""
  local key value
  while IFS=$'\t' read -r key value; do
    case "$key" in
      state) journal_state="$value" ;;
      journal) journal_path="$value" ;;
      status) status="$value" ;;
      memory) memory="$value" ;;
      save_decision) save_decision="$value" ;;
      evidence) evidence="$value" ;;
      recall_verified) recall_verified="$value" ;;
    esac
  done <<< "$summary"

  case "$journal_state" in
    none)
      warn "no task journal found; memory close-out was not validated"
      return 0
      ;;
    no-closeout)
      warn "latest task journal has no decided/done entry; memory close-out was not validated${journal_path:+ ($journal_path)}"
      return 0
      ;;
    closeout)
      ;;
    *)
      warn "could not inspect task journal; memory close-out was not validated"
      return 0
      ;;
  esac

  if [[ -z "$memory" ]]; then
    memory_gate_fail "$strict" "task journal decided/done entry missing memory:${journal_path:+ $journal_path}"
  fi

  if [[ "$high_risk" == "true" ]]; then
    case "$recall_verified" in
      yes|n/a|acked-deferred)
        ;;
      "")
        memory_gate_fail "$strict" "protected-path diff requires recall_verified: yes|n/a|acked-deferred before pre-final${changed_file:+ (changed: $changed_file)}"
        ;;
      deferred:*)
        memory_gate_fail "$strict" "protected-path diff cannot use recall_verified: deferred; use yes, n/a, or acked-deferred${changed_file:+ (changed: $changed_file)}"
        ;;
      *)
        memory_gate_fail "$strict" "protected-path diff has invalid recall_verified value '$recall_verified'; use yes, n/a, or acked-deferred${changed_file:+ (changed: $changed_file)}"
        ;;
    esac
  fi

  if [[ -z "$save_decision" ]]; then
    warn "task journal decided/done entry missing save_decision:${journal_path:+ $journal_path}"
  fi
  if [[ "$save_decision" == "saved" && ( -z "$evidence" || "$evidence" == "none" ) ]]; then
    warn "task journal save_decision=saved should include evidence"
  fi
  case "$memory" in
    ""|none|n/a) ;;
    *)
      if [[ -z "$evidence" || "$evidence" == "none" ]]; then
        warn "task journal memory id should include evidence"
      fi
      ;;
  esac
}

is_bootstrap_generated_base() {
  local relpath="$1"
  case "$relpath" in
    AGENTS.md|CLAUDE.md|GEMINI.md|.windsurfrules|.gitignore)
      return 0
      ;;
    .cursor/rules/agent-conventions.mdc)
      return 0
      ;;
    .claude/README.md|.claude/settings.json|.claude/commands/*)
      return 0
      ;;
    .codex/*)
      return 0
      ;;
    .agents/skills/*)
      return 0
      ;;
    docs/agent-configs/*)
      return 0
      ;;
    docs/superpowers/specs/*|docs/superpowers/plans/*)
      return 0
      ;;
    scripts/agent-*.sh|scripts/detect-agent-tech-stack.sh|scripts/install-rtk.sh|scripts/rtk|scripts/verify-ai-deps.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pending_bootstrap_generated_candidate() {
  local candidate rel_candidate base rel_base
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    rel_candidate="${candidate#"$PROJECT_ROOT"/}"
    base="${candidate%.generated.*}"
    rel_base="${base#"$PROJECT_ROOT"/}"
    if is_bootstrap_generated_base "$rel_base"; then
      printf '%s\n' "$rel_candidate"
      return 0
    fi
  done < <(find "$PROJECT_ROOT" \
    \( -path "$PROJECT_ROOT/.git" -o -path "$PROJECT_ROOT/.tools" -o -path "$PROJECT_ROOT/.gradle" -o -path "$PROJECT_ROOT/build" \) -prune -o \
    -type f -name '*.generated.*' -print 2>/dev/null || true)
  return 1
}

append_ack_log() {
  local relpath="$1"
  local pattern="$2"
  local reason="$3"
  local ack="$4"
  if [[ "$STATE_WRITABLE" != "true" ]]; then
    warn "state dir not writable; skipping ack log"
    return 0
  fi
  mkdir -p "$(dirname "$ACK_LOG")"
  printf '%s\tpath=%s\tpattern=%s\treason=%s\tack=%s\n' \
    "$(utc_now)" \
    "$relpath" \
    "$pattern" \
    "$reason" \
    "$ack" >> "$ACK_LOG"
}

required_context_json() {
  local first=true
  local relpath rel_canonical path status digest
  printf '['
  for relpath in "${REQUIRED_CONTEXT[@]}"; do
    rel_canonical="$(canonical_project_relpath "$relpath")"
    path="$PROJECT_ROOT/$rel_canonical"
    if [[ -f "$path" ]]; then
      status="present"
      digest="$(hash_file "$path")"
    else
      status="missing"
      digest=""
    fi
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"path":"%s","status":"%s","sha256":"%s"}' \
      "$(json_escape "$rel_canonical")" \
      "$(json_escape "$status")" \
      "$(json_escape "$digest")"
  done
  printf ']'
}

protected_paths_json() {
  local first=true
  local index=0
  printf '['
  while [[ "$index" -lt "${#PROTECTED_PATTERNS[@]}" ]]; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"pattern":"%s","reason":"%s"}' \
      "$(json_escape "${PROTECTED_PATTERNS[$index]}")" \
      "$(json_escape "${PROTECTED_REASONS[$index]}")"
    index=$((index + 1))
  done
  printf ']'
}

agent_instructions_sha256() {
  local instruction
  for instruction in "${AGENT_INSTRUCTIONS[@]}"; do
    printf '%s\n' "$instruction"
  done | hash_text
}

detector_summary_json() {
  local summary=""
  if [[ -x "$DETECTOR" ]]; then
    summary="$("$DETECTOR" --summary 2>/dev/null || true)"
  fi
  printf '"%s"' "$(json_escape "$summary")"
}

ensure_required_context() {
  local missing=0
  local relpath rel_canonical path
  for relpath in "${REQUIRED_CONTEXT[@]}"; do
    rel_canonical="$(canonical_project_relpath "$relpath")"
    path="$PROJECT_ROOT/$rel_canonical"
    if [[ ! -f "$path" ]]; then
      warn "missing required context: $rel_canonical"
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -gt 0 ]]; then
    fail "required context is incomplete"
  fi
}

write_context_pack() {
  if [[ "$STATE_WRITABLE" != "true" ]]; then
    warn "state dir not writable ($STATE_DIR); guard advisory-only, skipping context pack"
    return 0
  fi
  local policy_hash
  policy_hash="$(hash_file "$POLICY_FILE")"
  mkdir -p "$(dirname "$CONTEXT_PACK")"
  {
    printf '{"schema":"agent-context-pack/v1"'
    printf ',"generated_at":"%s"' "$(json_escape "$(utc_now)")"
    printf ',"policy_path":"docs/agent-configs/context-policy.json"'
    printf ',"policy_sha256":"%s"' "$(json_escape "$policy_hash")"
    printf ',"agent_instructions_sha256":"%s"' "$(json_escape "$(agent_instructions_sha256)")"
    printf ',"required_context":'
    required_context_json
    printf ',"protected_paths":'
    protected_paths_json
    printf ',"detector_summary":'
    detector_summary_json
    printf '}\n'
  } > "$CONTEXT_PACK"
}

check_context_pack_freshness() {
  if [[ "$STATE_WRITABLE" != "true" ]]; then
    warn "state dir not writable; skipping context-pack freshness check (advisory)"
    return 0
  fi
  [[ -f "$CONTEXT_PACK" ]] || fail "missing context pack; run scripts/agent-guard.sh preflight"
  command -v python3 >/dev/null 2>&1 ||
    fail "python3 is required to verify context-pack freshness"
  local current_policy_hash
  current_policy_hash="$(hash_file "$POLICY_FILE")"
  python3 - "$PROJECT_ROOT" "$CONTEXT_PACK" "$current_policy_hash" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
pack_path = pathlib.Path(sys.argv[2])
current_policy_hash = sys.argv[3]
errors = []


def safe_relative(value):
    if not isinstance(value, str) or not value:
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


try:
    pack = json.loads(pack_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"stale context pack: cannot read context pack: {exc}", file=sys.stderr)
    sys.exit(1)

if pack.get("schema") != "agent-context-pack/v1":
    errors.append("stale context pack: schema is not agent-context-pack/v1")
if pack.get("policy_sha256") != current_policy_hash:
    errors.append("stale context pack: context-policy.json changed")

entries = pack.get("required_context")
if not isinstance(entries, list):
    errors.append("stale context pack: required_context is missing")
    entries = []

for entry in entries:
    if not isinstance(entry, dict):
        errors.append("stale context pack: required_context entry is not an object")
        continue
    rel = entry.get("path")
    if not safe_relative(rel):
        errors.append(f"stale context pack: unsafe required context path {rel!r}")
        continue
    candidate = (root / rel).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError:
        errors.append(f"stale context pack: required context escapes project root: {rel}")
        continue
    if candidate.is_file():
        status = "present"
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
    else:
        status = "missing"
        digest = ""
    if status != entry.get("status") or digest != entry.get("sha256"):
        errors.append(f"stale required context: {rel}")

if errors:
    for error in errors:
        print(f"agent-guard: ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

preflight() {
  load_policy
  ensure_required_context
  write_context_pack
  printf 'agent-guard: preflight ok (context_pack=.agents/state/context-pack.json)\n'
}

check_guard() {
  load_policy
  ensure_required_context
  if [[ -f "$CONTEXT_PACK" ]]; then
    check_context_pack_freshness
  fi
  printf 'agent-guard: check ok\n'
}

pre_edit() {
  local strict=true
  local ack=""
  local raw_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        strict=true
        shift
        ;;
      --advisory)
        strict=false
        shift
        ;;
      --ack)
        ack="${2:-}"
        [[ -n "$ack" ]] || fail "--ack requires text"
        shift 2
        ;;
      --)
        shift
        raw_path="${1:-}"
        shift || true
        ;;
      -*)
        fail "unknown pre-edit option: $1"
        ;;
      *)
        if [[ -n "$raw_path" ]]; then
          fail "pre-edit accepts exactly one path"
        fi
        raw_path="$1"
        shift
        ;;
    esac
  done
  [[ -n "$raw_path" ]] || fail "pre-edit requires a path"
  load_policy
  ensure_required_context
  local relpath match pattern reason
  relpath="$(canonical_project_relpath "$raw_path")"
  if match="$(protected_reason_for_path "$relpath")"; then
    pattern="${match%%$'\t'*}"
    if [[ "$match" == *$'\t'* ]]; then
      reason="${match#*$'\t'}"
    else
      reason=""
    fi
    printf 'path=%s protected_path=true pattern=%s reason=%s\n' \
      "$(json_escape "$relpath")" \
      "$(json_escape "$pattern")" \
      "$(json_escape "$reason")"
    if [[ "$strict" == "true" && -z "$ack" ]]; then
      fail "protected path requires ack; rerun with: scripts/agent-guard.sh pre-edit --ack <reason> $relpath"
    fi
    if [[ "$strict" == "true" && -n "$ack" ]]; then
      append_ack_log "$relpath" "$pattern" "$reason" "$ack"
    fi
  else
    printf 'path=%s protected_path=false\n' "$(json_escape "$relpath")"
  fi
}

context_pack_policy_hash() {
  if command -v python3 >/dev/null 2>&1 && [[ -f "$CONTEXT_PACK" ]]; then
    python3 - "$CONTEXT_PACK" <<'PY'
import json
import pathlib
import sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(doc.get("policy_sha256", ""))
PY
    return 0
  fi
  sed -n 's/.*"policy_sha256":"\([^"]*\)".*/\1/p' "$CONTEXT_PACK" | head -n1
}

lock_value() {
  local key="$1"
  local file="$PROJECT_ROOT/docs/agent-configs/agent-bootstrap.lock.json"
  [[ -f "$file" ]] || return 0
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read bootstrap lock"
  python3 - "$file" "$key" <<'PY' 2>/dev/null || true
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

append_pre_final_event() {
  local status="$1"
  local verification_ran="${2:-false}"
  [[ "$STATE_WRITABLE" == "true" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  SESSION_EVENTS="$SESSION_EVENTS" VERIFY_REPORT="$VERIFY_REPORT" STATUS_VALUE="$status" VERIFICATION_RAN="$verification_ran" python3 - <<'PY'
import json
import os
import pathlib
import time

events_path = pathlib.Path(os.environ["SESSION_EVENTS"])
verify_path = pathlib.Path(os.environ["VERIFY_REPORT"])
ran = os.environ.get("VERIFICATION_RAN") == "true"
verification = {"ran": ran, "available": False}
if ran and verify_path.is_file():
    try:
        doc = json.loads(verify_path.read_text(encoding="utf-8"))
        verification = {"ran": True, "summary": doc.get("summary", {}), "available": True, "report_path": str(verify_path)}
    except Exception as exc:
        verification = {"ran": True, "available": False, "error": str(exc)}

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

# Runnable vs placeholder/full-scope classification is centralized in the Python
# runner below (single source of truth): a command is skipped when it is empty,
# contains a token-shaped placeholder such as `<scheme>`, or starts with
# "Add project-specific"; full-class build commands are skipped under the
# default `fast` scope.
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
  local detector_json code=0
  detector_json="$("$DETECTOR" --json 2>/dev/null || true)"
  DETECTOR_JSON="$detector_json" \
  VERIFY_REPORT="$VERIFY_REPORT" \
  VERIFY_LOG_DIR="$VERIFY_LOG_DIR" \
  VERIFY_TIMEOUT_SECONDS="$VERIFY_TIMEOUT_SECONDS" \
  VERIFY_SCOPE="$verify_scope" \
  PROJECT_ROOT="$PROJECT_ROOT" \
  python3 - <<'PY' || code=$?
import json
import os
import pathlib
import re
import signal
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
placeholder_token = re.compile(r"<[A-Za-z0-9_.:-]+>")


def path_for_report(path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


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
        or placeholder_token.search(command)
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
        process = subprocess.Popen(
            command,
            cwd=root,
            shell=True,
            text=True,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            exit_code = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            exit_code = 124
            timed_out = True
            log.write(f"\nTIMEOUT after {timeout}s\n")
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
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
        "log_path": path_for_report(log_path),
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
  if [[ "$code" -ne 0 ]]; then
    if [[ "$strict" == "true" ]]; then
      return "$code"
    fi
    warn "verification failed in advisory mode"
  fi
}

pre_final() {
  local strict=true
  local run_verify=false
  local verify_scope="$VERIFY_SCOPE_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        strict=true
        shift
        ;;
      --advisory)
        strict=false
        shift
        ;;
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
      -*)
        fail "unknown pre-final option: $1"
        ;;
      *)
        fail "pre-final does not accept path arguments"
        ;;
    esac
  done
  load_policy
  check_context_pack_freshness
  check_detector_summary_drift "$strict"
  local pending_candidate
  pending_candidate="$(pending_bootstrap_generated_candidate || true)"
  if [[ -n "$pending_candidate" ]]; then
    warn "pending generated candidate requires review: $pending_candidate"
  fi
  local protected_changes first_protected_change
  protected_changes="$(changed_protected_paths || true)"
  first_protected_change="$(printf '%s\n' "$protected_changes" | sed -n '1{s/\t/ /g;p;}')"
  if [[ -n "$protected_changes" ]]; then
    warn "protected-path changes require memory recall verification before completion"
  fi
  validate_memory_closeout "$strict" "$first_protected_change"
  if [[ "$run_verify" == "true" ]]; then
    run_detected_verification "$strict" "$verify_scope"
  fi
  append_pre_final_event "pass" "$run_verify"
  printf 'agent-guard: pre-final ok (context_pack=.agents/state/context-pack.json)\n'
}

status() {
  load_policy
  printf 'policy=docs/agent-configs/context-policy.json\n'
  printf 'policy_sha256=%s\n' "$(hash_file "$POLICY_FILE")"
  if [[ -f "$CONTEXT_PACK" ]]; then
    printf 'context_pack=.agents/state/context-pack.json\n'
    printf 'context_pack_policy_sha256=%s\n' "$(context_pack_policy_hash)"
  else
    printf 'context_pack=missing\n'
  fi
  printf 'required_context_count=%s\n' "${#REQUIRED_CONTEXT[@]}"
  printf 'protected_path_count=%s\n' "${#PROTECTED_PATTERNS[@]}"
}

case "${1:-}" in
  preflight)
    shift || true
    preflight "$@"
    ;;
  check)
    shift || true
    check_guard "$@"
    ;;
  pre-edit)
    shift || true
    pre_edit "$@"
    ;;
  pre-final)
    shift || true
    pre_final "$@"
    ;;
  status)
    shift || true
    status "$@"
    ;;
  doctor)
    shift || true
    check_guard "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    fail "unknown command: $1"
    ;;
esac
