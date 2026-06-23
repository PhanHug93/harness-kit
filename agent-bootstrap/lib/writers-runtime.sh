#!/usr/bin/env bash
# agent-bootstrap/lib/writers-runtime.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits target scripts/* runtime files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

write_rtk_tools() {
  write_file "$TARGET_DIR/scripts/install-rtk.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"
# Runtime snapshot: run from generated target projects as scripts/install-rtk.sh.
# Source/canonical bundle copies do not carry the generated docs/agent-configs tree.
PROVENANCE_FILE="${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v${RTK_VERSION}.sha256"

OS="$(uname -s)"
ARCH="$(uname -m)"
PLATFORM="${OS}-${ARCH}"

case "${PLATFORM}" in
  Darwin-arm64)
    ASSET="rtk-aarch64-apple-darwin.tar.gz"
    ;;
  Darwin-x86_64)
    ASSET="rtk-x86_64-apple-darwin.tar.gz"
    ;;
  Linux-aarch64)
    ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"
    ;;
  Linux-x86_64)
    ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"
    ;;
  *)
    echo "Unsupported platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac

if [ ! -f "${PROVENANCE_FILE}" ]; then
  echo "Missing rtk provenance manifest: ${PROVENANCE_FILE}" >&2
  exit 1
fi
SHA256="$(awk -v asset="${ASSET}" '$2 == asset { print $1 }' "${PROVENANCE_FILE}" | head -n1)"
if [ -z "${SHA256}" ]; then
  echo "No checksum for ${ASSET} in ${PROVENANCE_FILE}" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${ASSET}"
INSTALL_DIR="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}"
ARCHIVE_PATH="${INSTALL_DIR}/${ASSET}"
BIN_PATH="${INSTALL_DIR}/rtk"
LINK_PATH="${ROOT_DIR}/.tools/bin/rtk"

mkdir -p "${INSTALL_DIR}" "${ROOT_DIR}/.tools/bin"
if command -v curl >/dev/null 2>&1; then
  curl --proto '=https' --proto-redir '=https' -fL "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}"
elif command -v wget >/dev/null 2>&1; then
  wget -O "${ARCHIVE_PATH}" "${DOWNLOAD_URL}"
else
  echo "Need curl or wget to download rtk." >&2; exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
else
  echo "Need sha256sum or shasum to verify rtk." >&2; exit 1
fi
if [ "${ACTUAL_SHA256}" != "${SHA256}" ]; then
  echo "Checksum mismatch for ${ASSET}" >&2
  echo "Expected: ${SHA256}" >&2
  echo "Actual  : ${ACTUAL_SHA256}" >&2
  exit 1
fi

ARCHIVE_MEMBERS="$(tar -tzf "${ARCHIVE_PATH}")"
# Pinned rtk v0.37.2 archives contain exactly one top-level binary. When
# bumping RTK, verify upstream archive layout and update this policy if needed.
case "${ARCHIVE_MEMBERS}" in
  "rtk"|"./rtk")
    ;;
  *)
    echo "Unexpected rtk archive contents:" >&2
    printf '%s\n' "${ARCHIVE_MEMBERS}" >&2
    exit 1
    ;;
esac
tar -xzf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
chmod +x "${BIN_PATH}"
ln -sfn "../rtk/v${RTK_VERSION}/rtk" "${LINK_PATH}"

echo "Installed pinned rtk v${RTK_VERSION} at ${BIN_PATH}"
"${BIN_PATH}" --version
EOF
  make_executable "$LAST_WRITTEN_FILE"

  write_file "$TARGET_DIR/scripts/rtk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"
RTK_BIN="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}/rtk"

if [ ! -x "${RTK_BIN}" ]; then
  echo "Pinned rtk v${RTK_VERSION} not found at ${RTK_BIN}." >&2
  echo "Run: ./scripts/install-rtk.sh" >&2
  exit 1
fi

exec "${RTK_BIN}" "$@"
EOF
  make_executable "$LAST_WRITTEN_FILE"
}

write_template_catalog() {
  local template
  for template in \
    base/README.md \
    overlays/android_kotlin.md \
    overlays/generic.md \
    overlays/ios_swift.md \
    overlays/node_js.md \
    overlays/python.md \
    workflows/council/README.md \
    workflows/karpathy/README.md \
    workflows/three-mode/README.md; do
    copy_bundle_file \
      "templates/$template" \
      "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/$template"
  done
}

write_schema_model_and_provenance_catalog() {
  copy_bundle_file \
    "model-profiles/codex-model-profiles.json" \
    "$TARGET_DIR/docs/agent-configs/model-profiles.json"
  copy_bundle_file \
    "policies/agent-context-policy.json" \
    "$TARGET_DIR/docs/agent-configs/context-policy.json"
  copy_bundle_file \
    "schemas/agent-context-policy-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-model-profiles-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-project-tech-stack-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-lock-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-status-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-verify-report-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json"
  copy_bundle_file \
    "provenance/rtk-v0.37.2.sha256" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"
}

write_tech_stack_lib() {
  write_file "$TARGET_DIR/scripts/agent-tech-stack-lib.sh" < <(emit_tech_stack_lib)
  make_executable "$LAST_WRITTEN_FILE"
}

write_runtime_detector() {
  write_file "$TARGET_DIR/scripts/detect-agent-tech-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FORMAT="markdown"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$SCRIPT_DIR/agent-tech-stack-lib.sh"

usage() {
  printf '%s\n' \
    "Usage: scripts/detect-agent-tech-stack.sh [--root DIR] [--markdown|--summary]" \
    "" \
    "Detect project tech stack from local file signatures and print agent-ready context."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="$(cd "${2:?missing value for --root}" && pwd -P)"
      shift 2
      ;;
    --markdown)
      FORMAT="markdown"
      shift
      ;;
    --summary)
      FORMAT="summary"
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

if [[ ! -f "$LIB" ]]; then
  echo "ERROR: missing tech-stack detection library: ${LIB#"$ROOT"/}" >&2
  exit 1
fi

# shellcheck source=scripts/agent-tech-stack-lib.sh
source "$LIB"

agent_detect_tech_stack "$ROOT"

if [[ "$FORMAT" == "summary" ]]; then
  agent_print_summary
  exit 0
fi

agent_print_markdown "$ROOT"
EOF

  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_guard() {
  copy_bundle_file "agent-guard.sh" "$TARGET_DIR/scripts/agent-guard.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_onboarding_runtime() {
  copy_bundle_file "agent-onboarding.sh" "$TARGET_DIR/scripts/agent-onboarding.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_hook() {
  write_file "$TARGET_DIR/scripts/agent-hook.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
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
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$LOCK_FILE" | head -n1
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
print(f"{tool_name}\t{file_path}")
PY
    return $?
  fi
  local tool_name file_path
  tool_name="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s\t%s\n' "$tool_name" "$file_path"
}

guard_claude_edit_tool() {
  local edit_path="$1"
  [[ -n "$edit_path" ]] || fail "Claude edit hook did not include tool_input.file_path"
  if [[ -n "${AGENT_GUARD_EDIT_ACK:-}" ]]; then
    "$AGENT_GUARD" pre-edit --strict --ack "$AGENT_GUARD_EDIT_ACK" "$edit_path"
  else
    "$AGENT_GUARD" pre-edit --strict "$edit_path"
  fi
}

claude_pretool() {
  required_executable "$DETECTOR"
  required_executable "$AGENT_GUARD"
  local hook_input=""
  local parsed=""
  local tool_name=""
  local edit_path=""
  local old_ifs
  if [[ ! -t 0 ]]; then
    hook_input="$(cat || true)"
  fi
  "$AGENT_GUARD" preflight >/dev/null
  if [[ -n "$hook_input" ]]; then
    parsed="$(parse_claude_hook_input "$hook_input" || true)"
    old_ifs="$IFS"
    IFS=$'\t'
    read -r tool_name edit_path <<< "$parsed"
    IFS="$old_ifs"
    case "$tool_name" in
      Edit|Write|MultiEdit)
        guard_claude_edit_tool "$edit_path"
        exit 0
        ;;
    esac
  fi
  verify_detector_lock warn
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

case "${1:-}" in
  claude-pretool)
    shift || true
    claude_pretool "$@"
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
  -h|--help|help|"")
    echo "Usage: scripts/agent-hook.sh claude-pretool|codex-preflight|guard-local-state|no-scan-paths|doctor"
    ;;
  *)
    fail "unknown command: $1"
    ;;
esac
EOF

  replace_placeholder "$LAST_WRITTEN_FILE" "__WORKFLOW_PRESET__" "$WORKFLOW_PRESET"
  make_executable "$LAST_WRITTEN_FILE"
}

write_verify_ai_deps() {
  write_file "$TARGET_DIR/scripts/verify-ai-deps.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
WARN=0
OUTPUT_JSON=false
CHECKS=()

usage() {
  printf '%s\n' "Usage: scripts/verify-ai-deps.sh [--json]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_JSON=true
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

record_check() {
  local status="$1"
  local label="$2"
  CHECKS+=("$status"$'\t'"$label")
  if [[ "$OUTPUT_JSON" != "true" ]]; then
    case "$status" in
      pass) printf '  ok    %s\n' "$label" ;;
      fail) printf '  FAIL  %s\n' "$label" ;;
      warn) printf '  warn  %s\n' "$label" ;;
    esac
  fi
}

ok() { PASS=$((PASS + 1)); record_check pass "$1"; }
bad() { FAIL=$((FAIL + 1)); record_check fail "$1"; }
warn() { WARN=$((WARN + 1)); record_check warn "$1"; }

emit_json_report() {
  local first=true
  local check status label
  printf '{"schema":"agent-bootstrap-verify-report/v1","workflow_preset":"%s","summary":{"pass":%s,"warn":%s,"fail":%s},"checks":[' \
    "$(json_escape "$WORKFLOW_PRESET")" "$PASS" "$WARN" "$FAIL"
  for check in "${CHECKS[@]}"; do
    status="${check%%$'\t'*}"
    label="${check#*$'\t'}"
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"status":"%s","label":"%s"}' "$(json_escape "$status")" "$(json_escape "$label")"
  done
  printf ']}\n'
}

need_file() {
  if [[ -f "$ROOT_DIR/$1" ]]; then
    ok "file exists: $1"
  else
    bad "missing file: $1"
  fi
}

need_executable() {
  if [[ -x "$ROOT_DIR/$1" ]]; then
    ok "executable: $1"
  else
    bad "not executable: $1"
  fi
}

need_bash_syntax() {
  if bash -n "$ROOT_DIR/$1"; then
    ok "bash syntax: $1"
  else
    bad "bash syntax failed: $1"
  fi
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
    rel_candidate="${candidate#"$ROOT_DIR"/}"
    base="${candidate%.generated.*}"
    rel_base="${base#"$ROOT_DIR"/}"
    if is_bootstrap_generated_base "$rel_base"; then
      printf '%s\n' "$rel_candidate"
      return 0
    fi
  done < <(find "$ROOT_DIR" \
    \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.tools" -o -path "$ROOT_DIR/.gradle" -o -path "$ROOT_DIR/build" \) -prune -o \
    -type f -name '*.generated.*' -print 2>/dev/null || true)
  return 1
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
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" | head -n1
}

estimate_tokens_for_file() {
  local path="$1"
  local words="0"
  local chars="0"
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  read -r words chars < <(wc -w -c < "$path")
  awk -v words="$words" -v chars="$chars" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

sum_estimated_tokens() {
  local total=0
  local token_count=0
  local relpath
  for relpath in "$@"; do
    token_count="$(estimate_tokens_for_file "$ROOT_DIR/$relpath")"
    total=$((total + token_count))
  done
  printf '%s' "$total"
}

check_context_budget() {
  local core_tokens
  local full_tokens
  core_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md)"
  full_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md \
    docs/agent-configs/task-journal.md)"

  if [[ "$core_tokens" -le 4000 ]]; then
    ok "core startup context estimate: ${core_tokens} tokens (budget 4000)"
  else
    warn "core startup context estimate: ${core_tokens} tokens exceeds budget 4000"
  fi

  if [[ "$full_tokens" -le 6500 ]]; then
    ok "on-demand full workflow context estimate: ${full_tokens} tokens (budget 6500)"
  else
    warn "on-demand full workflow context estimate: ${full_tokens} tokens exceeds budget 6500"
  fi
}

validate_json_contracts() {
  python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
errors = []


def load_json(relpath):
    path = root / relpath
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{relpath}: {exc}")
        return None


def require(condition, message):
    if not condition:
        errors.append(message)


def require_exact_keys(value, expected, name):
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    actual = set(value.keys())
    expected_set = set(expected)
    extra = sorted(actual - expected_set)
    missing = sorted(expected_set - actual)
    if extra:
        errors.append(f"{name} has unexpected keys: {', '.join(extra)}")
    if missing:
        errors.append(f"{name} is missing keys: {', '.join(missing)}")


def non_empty_string(value):
    return isinstance(value, str) and value != ""


def safe_relative_path(value):
    if not non_empty_string(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


lock = load_json("docs/agent-configs/agent-bootstrap.lock.json") or {}
profiles_doc = load_json("docs/agent-configs/model-profiles.json") or {}
context_policy = load_json("docs/agent-configs/context-policy.json") or {}

if isinstance(lock, dict):
    require(lock.get("schema") == "agent-bootstrap-lock/v1", "lock.schema must be agent-bootstrap-lock/v1")
    for key in ("version", "channel", "project_name", "generated_at", "detector_summary_sha256", "detector_summary"):
        require(non_empty_string(lock.get(key)), f"lock.{key} must be a non-empty string")
    rtk = lock.get("rtk")
    require(isinstance(rtk, dict), "lock.rtk must be an object")
    if isinstance(rtk, dict):
        require(rtk.get("required") is True, "lock.rtk.required must be true")
        require(non_empty_string(rtk.get("version")), "lock.rtk.version must be a non-empty string")
        require(non_empty_string(rtk.get("install_command")), "lock.rtk.install_command must be a non-empty string")
    templates = lock.get("templates")
    require(isinstance(templates, dict), "lock.templates must be an object")
    if isinstance(templates, dict):
        require(non_empty_string(templates.get("base")), "lock.templates.base must be a non-empty string")
        require(templates.get("workflow_preset") in ("infra", "full"), "lock.templates.workflow_preset must be infra or full")
        overlays = templates.get("overlays")
        require(isinstance(overlays, list) and all(non_empty_string(item) for item in overlays), "lock.templates.overlays must be a non-empty string array")
else:
    require(False, "lock must be a JSON object")

if isinstance(profiles_doc, dict):
    require(profiles_doc.get("schema") == "agent-model-profiles/v1", "model profiles schema must be agent-model-profiles/v1")
    default_profile = profiles_doc.get("default_profile")
    profiles = profiles_doc.get("profiles")
    require(non_empty_string(default_profile), "model profiles default_profile must be a non-empty string")
    require(isinstance(profiles, dict) and bool(profiles), "model profiles profiles must be a non-empty object")
    if isinstance(profiles, dict):
        require(default_profile in profiles, "model profiles default_profile must reference an existing profile")
        required_profile_keys = (
            "reasoning_effort",
            "planning_model",
            "coding_model",
            "reviewing_model",
            "planning_fallback_model",
            "coding_fallback_model",
            "reviewing_fallback_model",
        )
        for name, profile in profiles.items():
            require(non_empty_string(name), "model profile names must be non-empty strings")
            require(isinstance(profile, dict), f"model profile {name} must be an object")
            if isinstance(profile, dict):
                for key in required_profile_keys:
                    require(non_empty_string(profile.get(key)), f"model profile {name}.{key} must be a non-empty string")
else:
    require(False, "model profiles must be a JSON object")

if isinstance(context_policy, dict):
    require_exact_keys(
        context_policy,
        (
            "schema",
            "version",
            "mode",
            "purpose",
            "required_context",
            "recommended_context",
            "protected_paths",
            "change_protocol",
            "agent_instructions",
        ),
        "context policy",
    )
    require(context_policy.get("schema") == "agent-context-policy/v1", "context policy schema must be agent-context-policy/v1")
    require(non_empty_string(context_policy.get("version")), "context policy version must be a non-empty string")
    require(context_policy.get("mode") == "lite", "context policy mode must be lite")
    required_context = context_policy.get("required_context")
    require(isinstance(required_context, list) and all(non_empty_string(item) for item in required_context), "context policy required_context must be a non-empty string array")
    if isinstance(required_context, list):
        for index, item in enumerate(required_context):
            require(safe_relative_path(item), f"context policy required_context[{index}] must be a safe project-relative path")
    recommended_context = context_policy.get("recommended_context")
    require(isinstance(recommended_context, list) and all(non_empty_string(item) for item in recommended_context), "context policy recommended_context must be a string array")
    if isinstance(recommended_context, list):
        for index, item in enumerate(recommended_context):
            require(safe_relative_path(item), f"context policy recommended_context[{index}] must be a safe project-relative path")
    protected_paths = context_policy.get("protected_paths")
    require(isinstance(protected_paths, list) and bool(protected_paths), "context policy protected_paths must be a non-empty array")
    if isinstance(protected_paths, list):
        for index, item in enumerate(protected_paths):
            require(isinstance(item, dict), f"context policy protected_paths[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("pattern", "reason"), f"context policy protected_paths[{index}]")
                require(non_empty_string(item.get("pattern")), f"context policy protected_paths[{index}].pattern must be a non-empty string")
                require(safe_relative_path(item.get("pattern")), f"context policy protected_paths[{index}].pattern must be a safe project-relative path")
                require(non_empty_string(item.get("reason")), f"context policy protected_paths[{index}].reason must be a non-empty string")
    change_protocol = context_policy.get("change_protocol")
    require(isinstance(change_protocol, dict), "context policy change_protocol must be an object")
    if isinstance(change_protocol, dict):
        require_exact_keys(change_protocol, ("preflight", "pre_edit", "pre_final", "rollback"), "context policy change_protocol")
        for key in ("preflight", "pre_edit", "pre_final", "rollback"):
            require(non_empty_string(change_protocol.get(key)), f"context policy change_protocol.{key} must be a non-empty string")
    agent_instructions = context_policy.get("agent_instructions")
    require(isinstance(agent_instructions, list) and all(non_empty_string(item) for item in agent_instructions), "context policy agent_instructions must be a non-empty string array")
else:
    require(False, "context policy must be a JSON object")

schema_dir = "docs/agent-configs/bootstrap-multi-agent-project/schemas"
expected_schema_ids = {
    "agent-context-policy-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-context-policy-v1.schema.json",
    "agent-model-profiles-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-model-profiles-v1.schema.json",
    "agent-project-tech-stack-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-project-tech-stack-v1.schema.json",
    "agent-bootstrap-lock-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-lock-v1.schema.json",
    "agent-bootstrap-status-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-status-v1.schema.json",
    "agent-bootstrap-verify-report-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-verify-report-v1.schema.json",
}
for filename, schema_id in expected_schema_ids.items():
    schema = load_json(f"{schema_dir}/{filename}") or {}
    require(isinstance(schema, dict), f"{filename} must be a JSON object")
    if isinstance(schema, dict):
        require(schema.get("$id") == schema_id, f"{filename} has unexpected $id")
        require(schema.get("type") == "object", f"{filename} must describe an object")

provenance_path = root / "docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"
entries = {}
try:
    for line_no, raw_line in enumerate(provenance_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        require(len(parts) == 2, f"rtk provenance line {line_no} must contain '<sha256> <asset>'")
        if len(parts) == 2:
            digest, asset = parts
            require(re.fullmatch(r"[0-9a-f]{64}", digest) is not None, f"rtk provenance digest for {asset} must be lowercase sha256")
            entries[asset] = digest
except Exception as exc:
    errors.append(f"rtk provenance manifest cannot be read: {exc}")

required_assets = (
    "rtk-aarch64-apple-darwin.tar.gz",
    "rtk-x86_64-apple-darwin.tar.gz",
    "rtk-aarch64-unknown-linux-gnu.tar.gz",
    "rtk-x86_64-unknown-linux-musl.tar.gz",
)
for asset in required_assets:
    require(asset in entries, f"rtk provenance missing asset {asset}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
}

validate_project_tech_stack_contract() {
  python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "docs/superpowers/specs/project-tech-stack.json"
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def non_empty_string(value):
    return isinstance(value, str) and value != ""


def safe_relative_path(value):
    if not non_empty_string(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


def require_exact_keys(value, expected, name):
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    actual = set(value.keys())
    expected_set = set(expected)
    extra = sorted(actual - expected_set)
    missing = sorted(expected_set - actual)
    if extra:
        errors.append(f"{name} has unexpected keys: {', '.join(extra)}")
    if missing:
        errors.append(f"{name} is missing keys: {', '.join(missing)}")


try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"project-tech-stack.json: {exc}", file=sys.stderr)
    sys.exit(1)

require(isinstance(doc, dict), "project tech-stack contract must be an object")
if isinstance(doc, dict):
    require_exact_keys(
        doc,
        (
            "schema",
            "status",
            "last_verified",
            "stacks",
            "modules",
            "architecture_boundaries",
            "generated_files",
            "protected_paths",
            "verification",
            "conventions",
            "source_evidence",
            "open_questions",
        ),
        "project tech-stack contract",
    )
    require(doc.get("schema") == "agent-project-tech-stack/v1", "project tech-stack schema must be agent-project-tech-stack/v1")
    require(doc.get("status") in ("unfilled", "partial", "filled"), "project tech-stack status must be unfilled, partial, or filled")
    last_verified = doc.get("last_verified")
    require(isinstance(last_verified, dict), "project tech-stack last_verified must be an object")
    if isinstance(last_verified, dict):
        require_exact_keys(last_verified, ("commit", "date"), "project tech-stack last_verified")
        require(isinstance(last_verified.get("commit"), str), "project tech-stack last_verified.commit must be a string")
        require(isinstance(last_verified.get("date"), str), "project tech-stack last_verified.date must be a string")
    for key in (
        "stacks",
        "modules",
        "architecture_boundaries",
        "generated_files",
        "protected_paths",
        "conventions",
        "open_questions",
    ):
        require(isinstance(doc.get(key), list) and all(isinstance(item, str) for item in doc.get(key, [])), f"project tech-stack {key} must be a string array")
    for key in ("generated_files", "protected_paths"):
        values = doc.get(key)
        if isinstance(values, list):
            for index, item in enumerate(values):
                require(safe_relative_path(item), f"project tech-stack {key}[{index}] must be a safe project-relative path")
    verification = doc.get("verification")
    require(isinstance(verification, list), "project tech-stack verification must be an array")
    if isinstance(verification, list):
        for index, item in enumerate(verification):
            require(isinstance(item, dict), f"project tech-stack verification[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("command", "purpose", "source"), f"project tech-stack verification[{index}]")
                for key in ("command", "purpose", "source"):
                    require(non_empty_string(item.get(key)), f"project tech-stack verification[{index}].{key} must be a non-empty string")
    evidence = doc.get("source_evidence")
    require(isinstance(evidence, list), "project tech-stack source_evidence must be an array")
    if isinstance(evidence, list):
        for index, item in enumerate(evidence):
            require(isinstance(item, dict), f"project tech-stack source_evidence[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("path", "claim"), f"project tech-stack source_evidence[{index}]")
                evidence_path = item.get("path")
                require(non_empty_string(evidence_path), f"project tech-stack source_evidence[{index}].path must be a non-empty string")
                if non_empty_string(evidence_path):
                    require(safe_relative_path(evidence_path), f"project tech-stack source_evidence[{index}].path must be a safe project-relative path")
                    if safe_relative_path(evidence_path):
                        require((root / evidence_path).is_file(), f"project tech-stack source_evidence[{index}].path must reference an existing file")
                require(non_empty_string(item.get("claim")), f"project tech-stack source_evidence[{index}].claim must be a non-empty string")
    if doc.get("status") == "filled":
        require(non_empty_string(last_verified.get("commit") if isinstance(last_verified, dict) else None), "filled project tech-stack requires last_verified.commit")
        require(non_empty_string(last_verified.get("date") if isinstance(last_verified, dict) else None), "filled project tech-stack requires last_verified.date")
        require(bool(doc.get("source_evidence")), "filled project tech-stack requires source_evidence")
        require(bool(doc.get("verification")), "filled project tech-stack requires verification")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
}

if [[ "$OUTPUT_JSON" != "true" ]]; then
  echo "Verifying generated agent infrastructure..."
fi

for path in \
  AGENTS.md \
  CLAUDE.md \
  docs/agent-configs/agent-bootstrap.lock.json \
  docs/agent-configs/project-agent-context.md \
  docs/agent-configs/context-policy.json \
  docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/android_kotlin.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/python.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/ios_swift.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/node_js.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/generic.md \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256 \
  docs/agent-configs/model-profiles.json \
  .claude/settings.json \
  .claude/README.md \
  .agents/skills/agentmemory-mcp/SKILL.md \
  .agents/skills/agentmemory-mcp/agents/openai.yaml; do
  need_file "$path"
done

lock_schema="$(lock_value schema)"
if [[ "$lock_schema" == "agent-bootstrap-lock/v1" ]]; then
  ok "bootstrap lock schema is agent-bootstrap-lock/v1"
else
  bad "bootstrap lock schema is not agent-bootstrap-lock/v1"
fi

lock_workflow="$(lock_value workflow_preset)"
case "$lock_workflow" in
  infra|full) ok "bootstrap lock workflow preset is valid: $lock_workflow" ;;
  *) bad "bootstrap lock workflow preset is invalid: ${lock_workflow:-missing}" ;;
esac

if grep -Fq '"schema": "agent-model-profiles/v1"' "$ROOT_DIR/docs/agent-configs/model-profiles.json"; then
  ok "model profile schema is agent-model-profiles/v1"
else
  bad "model profile schema is not agent-model-profiles/v1"
fi

if grep -Eq '"schema"[[:space:]]*:[[:space:]]*"agent-context-policy/v1"' "$ROOT_DIR/docs/agent-configs/context-policy.json"; then
  ok "agent context policy schema is agent-context-policy/v1"
else
  bad "agent context policy schema is not agent-context-policy/v1"
fi

if grep -Fq 'rtk-aarch64-apple-darwin.tar.gz' "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"; then
  ok "rtk provenance manifest exists"
else
  bad "rtk provenance manifest is missing expected assets"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$ROOT_DIR/docs/agent-configs/model-profiles.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/context-policy.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json" >/dev/null 2>&1; then
    ok "schema/model profile JSON parses"
  else
    bad "schema/model profile JSON is invalid"
  fi
  if validate_json_contracts >/dev/null; then
    ok "bootstrap JSON contracts validate"
  else
    bad "bootstrap JSON contracts failed validation"
  fi
else
  warn "python3 not found; skipped schema/model JSON validation"
  warn "python3 not found; skipped bootstrap JSON contract validation"
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  for path in \
  docs/agent-configs/agent-mode-contracts.md \
  docs/agent-configs/agent-handoff-schema.md \
  docs/agent-configs/karpathy-llm-coding-agent-config.md \
  docs/agent-configs/llm-council-agent-workflow.md \
  docs/agent-configs/task-journal.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/karpathy/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/council/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md \
  docs/agent-configs/first-10-minutes.md \
  docs/agent-configs/project-onboarding.md \
  docs/agent-configs/project-brief.md \
  .codex/config.toml \
  .codex/codex-mode.sh \
  .codex/README.md \
  .agents/skills/doubt-driven/SKILL.md \
  .claude/commands/planning.md \
  .claude/commands/planning-full-flow.md \
  .claude/commands/coding.md \
  .claude/commands/coding-full-flow.md \
  .claude/commands/reviewing.md \
  .claude/commands/reviewing-full-flow.md \
  .claude/commands/project-onboarding.md \
  .claude/commands/codex/setup.md \
  .claude/commands/codex/rescue.md \
  .claude/commands/codex/status.md \
  .claude/commands/doctor.md \
  docs/superpowers/specs/README.md \
  docs/superpowers/specs/project-tech-stack.md \
  docs/superpowers/specs/project-tech-stack.json \
  docs/superpowers/plans/README.md; do
    need_file "$path"
  done
  if command -v python3 >/dev/null 2>&1; then
    if validate_project_tech_stack_contract >/dev/null; then
      ok "project tech-stack contract validates"
    else
      bad "project tech-stack contract failed validation"
    fi
  else
    warn "python3 not found; skipped project tech-stack contract validation"
  fi
  if [[ -f "$ROOT_DIR/docs/agent-configs/project-brief.md" ]] &&
    grep -Fq '<!-- UNFILLED -->' "$ROOT_DIR/docs/agent-configs/project-brief.md"; then
    warn "project brief is unfilled; run project onboarding before substantive work"
  else
    ok "project brief is filled or not required"
  fi
  if [[ -x "$ROOT_DIR/scripts/agent-onboarding.sh" ]]; then
    onboarding_status_json="$("$ROOT_DIR/scripts/agent-onboarding.sh" status --json 2>/dev/null || true)"
    if printf '%s' "$onboarding_status_json" | python3 -m json.tool >/dev/null 2>&1; then
      onboarding_status="$(
        printf '%s' "$onboarding_status_json" |
          python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","invalid"))'
      )"
      case "$onboarding_status" in
        filled) ok "onboarding contract is filled" ;;
        partial) warn "onboarding contract is partial; run scripts/agent-onboarding.sh next" ;;
        unfilled) warn "onboarding contract is unfilled; run scripts/agent-onboarding.sh next" ;;
        *) bad "onboarding contract status is invalid: $onboarding_status" ;;
      esac
    else
      bad "onboarding contract status JSON is invalid"
    fi
  else
    bad "missing executable onboarding helper: scripts/agent-onboarding.sh"
  fi
  check_context_budget
else
  ok "workflow preset is infra-only; workflow philosophy files are opt-in"
fi

need_file scripts/install-rtk.sh
need_executable scripts/install-rtk.sh
need_executable scripts/rtk
need_file scripts/agent-tech-stack-lib.sh
need_executable scripts/agent-tech-stack-lib.sh
need_executable scripts/agent-hook.sh
need_executable scripts/agent-guard.sh
need_executable scripts/detect-agent-tech-stack.sh
need_executable scripts/verify-ai-deps.sh

need_bash_syntax scripts/install-rtk.sh
need_bash_syntax scripts/rtk
need_bash_syntax scripts/agent-tech-stack-lib.sh
need_bash_syntax scripts/agent-hook.sh
need_bash_syntax scripts/agent-guard.sh
need_bash_syntax scripts/detect-agent-tech-stack.sh
need_bash_syntax scripts/verify-ai-deps.sh
if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  need_executable scripts/agent-onboarding.sh
  need_bash_syntax scripts/agent-onboarding.sh
  need_bash_syntax .codex/codex-mode.sh
fi

if "$ROOT_DIR/scripts/rtk" --version 2>/dev/null | grep -Fq '0.37.2'; then
  ok "rtk wrapper resolves pinned version 0.37.2"
else
  warn "rtk pinned binary is not installed; run: bash scripts/install-rtk.sh before using rtk-specific hooks"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$ROOT_DIR/.claude/settings.json" >/dev/null 2>&1; then
    ok "Claude settings JSON is valid"
  else
    bad "Claude settings JSON is invalid"
  fi
else
  warn "python3 not found; skipped Claude settings JSON validation"
fi

if grep -Fq './scripts/agent-hook.sh claude-pretool' "$ROOT_DIR/.claude/settings.json"; then
  ok "Claude PreToolUse uses shared agent hook"
else
  bad "Claude PreToolUse does not use shared agent hook"
fi

if grep -Fq '"matcher": "Edit|Write|MultiEdit"' "$ROOT_DIR/.claude/settings.json"; then
  ok "Claude PreToolUse guards edit/write tools"
else
  bad "Claude PreToolUse does not guard edit/write tools"
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if grep -Fq 'codex-preflight' "$ROOT_DIR/.codex/codex-mode.sh"; then
    ok "Codex helper calls shared hook preflight"
  else
    bad "Codex helper does not call shared hook preflight"
  fi
else
  ok "Codex mode helper not installed for infra-only workflow"
fi

if "$ROOT_DIR/scripts/detect-agent-tech-stack.sh" --summary >/dev/null 2>&1; then
  ok "runtime detector runs"
else
  bad "runtime detector failed"
fi

detector_summary="$("$ROOT_DIR/scripts/detect-agent-tech-stack.sh" --summary 2>/dev/null || true)"
if [[ "$detector_summary" == *"modules="* ]]; then
  ok "runtime detector reports modules"
else
  bad "runtime detector summary does not report modules"
fi

expected_detector_hash="$(lock_value detector_summary_sha256)"
actual_detector_hash="$(printf '%s' "$detector_summary" | hash_text)"
if [[ -n "$expected_detector_hash" && "$expected_detector_hash" == "$actual_detector_hash" ]]; then
  ok "runtime detector summary matches bootstrap lock"
else
  bad "runtime detector summary drifted from bootstrap lock"
fi

if "$ROOT_DIR/scripts/agent-hook.sh" guard-local-state >/dev/null 2>&1; then
  ok "local-only agent state is not tracked"
else
  bad "local-only agent state guard failed"
fi

no_scan_paths="$("$ROOT_DIR/scripts/agent-hook.sh" no-scan-paths 2>/dev/null || true)"
if printf '%s\n' "$no_scan_paths" | grep -Fq '.claude/worktrees/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.tools/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.gemini/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.windsurf/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.openclaude/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq 'AGENTS.local.md' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq 'local.properties' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '*.jks'; then
  ok "no-scan guard exposes local/sensitive paths"
else
  bad "no-scan guard paths are incomplete"
fi

if "$ROOT_DIR/scripts/agent-hook.sh" codex-preflight --check-only planning standard >/dev/null 2>&1; then
  ok "shared agent hook codex preflight passes"
else
  bad "shared agent hook codex preflight failed"
fi

if "$ROOT_DIR/scripts/agent-guard.sh" check >/dev/null 2>&1; then
  ok "agent guard check passes"
else
  bad "agent guard check failed"
fi

pending_candidate="$(pending_bootstrap_generated_candidate || true)"
if [[ -n "$pending_candidate" ]]; then
  warn "pending generated candidate requires review: $pending_candidate"
else
  ok "no pending generated candidates"
fi

lock_version="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" 2>/dev/null | head -1)"
if [[ -n "$lock_version" ]]; then
  stale_version_refs=""
  for version_file in README.md docs/superpowers/specs/project-tech-stack.json docs/agent-configs/project-brief.md; do
    [[ -f "$ROOT_DIR/$version_file" ]] || continue
    while IFS= read -r found_version; do
      [[ -n "$found_version" && "$found_version" != "$lock_version" ]] &&
        stale_version_refs="$stale_version_refs $version_file:$found_version"
    done < <(grep -oE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+' "$ROOT_DIR/$version_file" 2>/dev/null | sort -u)
  done
  if [[ -n "$stale_version_refs" ]]; then
    warn "stale harness version references (lock is $lock_version):$stale_version_refs"
  else
    ok "harness version references match lock ($lock_version)"
  fi
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if "$ROOT_DIR/.codex/codex-mode.sh" doctor >/dev/null 2>&1; then
    ok "Codex helper doctor passes"
  else
    codex_candidate="$(find "$ROOT_DIR/.codex" -name '*.generated.*' -print 2>/dev/null | head -1)"
    if [[ -n "$codex_candidate" && ! -w "$ROOT_DIR/.codex" ]]; then
      warn "Codex helper doctor skipped: read-only .codex candidate unapplied (${codex_candidate#"$ROOT_DIR"/}); promote with write access"
    else
      bad "Codex helper doctor failed"
    fi
  fi
else
  ok "Codex helper doctor skipped for infra-only workflow"
fi

if [[ -x "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" ]]; then
  if [[ "${AGENT_BOOTSTRAP_SKIP_SMOKE:-}" == "1" ]]; then
    warn "portable bootstrap integration smoke test skipped to avoid recursion"
  elif [[ ! -t 0 ]]; then
    warn "portable bootstrap integration smoke test skipped in non-interactive shell"
  elif ! command -v timeout >/dev/null 2>&1; then
    warn "portable bootstrap integration smoke test skipped because timeout is unavailable"
  elif AGENT_BOOTSTRAP_SKIP_SMOKE=1 timeout 120 "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" </dev/null >/dev/null 2>&1; then
    ok "portable bootstrap integration smoke test passes"
  else
    bad "portable bootstrap integration smoke test failed"
  fi
else
  warn "portable bootstrap integration smoke test missing"
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
  emit_json_report
else
  printf '\nPass: %s  Warn: %s  Fail: %s\n' "$PASS" "$WARN" "$FAIL"
fi
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
EOF

  replace_placeholder "$LAST_WRITTEN_FILE" "__WORKFLOW_PRESET__" "$WORKFLOW_PRESET"
  make_executable "$LAST_WRITTEN_FILE"
}
