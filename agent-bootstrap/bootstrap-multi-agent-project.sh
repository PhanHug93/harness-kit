#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="$(pwd -P)"
PROJECT_NAME="$(basename "$TARGET_DIR")"
PROJECT_NAME_EXPLICIT=false
STAMP="$(date +%Y%m%d-%H%M%S)"
AGENT_BOOTSTRAP_VERSION="2026.06.18.2"
AGENT_BOOTSTRAP_CHANNEL="stable"
RTK_VERSION="0.37.2"
WORKFLOW_PRESET="infra"
WORKFLOW_EXPLICIT=false
DRY_RUN=false
BACKUP=true
FORCE=false
CANDIDATE_ON_CONFLICT=true
REFRESH_LOCK=false
ACTION="generate"
JSON_OUTPUT=false
LAST_WRITTEN_FILE=""

BOOTSTRAP_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$BUNDLE_DIR/lib"
# shellcheck source=agent-bootstrap/lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=agent-bootstrap/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=agent-bootstrap/lib/render.sh
source "$LIB_DIR/render.sh"
# shellcheck source=agent-bootstrap/lib/writers-runtime.sh
source "$LIB_DIR/writers-runtime.sh"
# shellcheck source=agent-bootstrap/lib/writers-docs.sh
source "$LIB_DIR/writers-docs.sh"
# shellcheck source=agent-bootstrap/lib/onboarding.sh
source "$LIB_DIR/onboarding.sh"

usage() {
  printf '%s\n' \
    "Usage: bootstrap-multi-agent-project.sh [options]" \
    "" \
    "Copy this script to a project root, then run it to generate portable" \
    "multi-agent instructions for Codex and Claude." \
    "" \
    "Options:" \
    "  --project-name NAME  Override detected project name." \
    "  --target DIR         Generate files in DIR instead of current directory." \
    "  --dry-run            Print planned files without writing." \
    "  --force              Overwrite existing files; backups stay enabled unless --no-backup." \
    "  --skip-existing      Skip existing files instead of writing .generated candidates." \
    "  --refresh-lock       Refresh only docs/agent-configs/agent-bootstrap.lock.json." \
    "  --apply-candidates   Promote latest *.generated.* candidates into place." \
    "  --status             Report installed harness state for the target." \
    "  --first-10           Print the first 10 minutes operator/onboarding path." \
    "  --next               Alias for --first-10." \
    "  --diff               Show generated-file diff for a non-destructive upgrade preview." \
    "  --upgrade-plan       Print an operator upgrade plan for the target." \
    "  --json               Machine-readable output for --status." \
    "  --workflow PRESET    Optional workflow philosophy: infra or full." \
    "  --no-backup          Overwrite existing generated files without .bak copy." \
    "  --version            Print bootstrap version." \
    "  -h, --help           Show help."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="${2:?missing value for --project-name}"
      PROJECT_NAME_EXPLICIT=true
      shift 2
      ;;
    --target)
      TARGET_DIR="$(cd "${2:?missing value for --target}" && pwd -P)"
      if [[ "$PROJECT_NAME_EXPLICIT" == "false" ]]; then
        PROJECT_NAME="$(basename "$TARGET_DIR")"
      fi
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      CANDIDATE_ON_CONFLICT=false
      shift
      ;;
    --skip-existing)
      CANDIDATE_ON_CONFLICT=false
      shift
      ;;
    --refresh-lock)
      REFRESH_LOCK=true
      ACTION="refresh-lock"
      shift
      ;;
    --apply-candidates)
      ACTION="apply-candidates"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --first-10|--next)
      ACTION="first-10"
      shift
      ;;
    --diff)
      ACTION="diff"
      shift
      ;;
    --upgrade-plan)
      ACTION="upgrade-plan"
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --workflow)
      WORKFLOW_PRESET="${2:?missing value for --workflow}"
      WORKFLOW_EXPLICIT=true
      shift 2
      ;;
    --no-backup)
      BACKUP=false
      shift
      ;;
    --version)
      printf 'bootstrap-multi-agent-project %s (%s)\n' "$AGENT_BOOTSTRAP_VERSION" "$AGENT_BOOTSTRAP_CHANNEL"
      exit 0
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

read_lock_value() {
  local key="$1"
  local file="${2:-$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json}"
  [[ -f "$file" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
wanted = sys.argv[2]

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
    return 0
  fi
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n1
}

resolve_workflow_from_lock() {
  local existing_lock="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local existing_workflow=""
  if [[ -f "$existing_lock" ]]; then
    existing_workflow="$(
      read_lock_value workflow_preset "$existing_lock"
    )"
    [[ -n "$existing_workflow" ]] && WORKFLOW_PRESET="$existing_workflow"
  fi
}

resolve_project_name_from_lock() {
  local existing_lock="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local existing_project=""
  if [[ -f "$existing_lock" ]]; then
    existing_project="$(
      read_lock_value project_name "$existing_lock"
    )"
    [[ -n "$existing_project" ]] && PROJECT_NAME="$existing_project"
  fi
}

if [[ "$PROJECT_NAME_EXPLICIT" == "false" ]]; then
  resolve_project_name_from_lock
fi

if [[ "$WORKFLOW_EXPLICIT" == "false" ]]; then
  case "$ACTION" in
    refresh-lock|status|first-10|diff|upgrade-plan|apply-candidates) resolve_workflow_from_lock ;;
  esac
fi

case "$WORKFLOW_PRESET" in
  infra|full) ;;
  *)
    echo "ERROR: invalid --workflow preset: $WORKFLOW_PRESET" >&2
    usage >&2
    exit 2
    ;;
esac

TECH_STACKS=()
MODULES=()
VERIFY_COMMANDS=()
WARNINGS=()

pending_generated_candidate_count() (
  local candidate_list allowed_list candidate base rel_base count
  candidate_list="$(mktemp)"
  allowed_list="$(mktemp)"
  count=0
  trap 'rm -f "$candidate_list" "$allowed_list"' EXIT HUP INT TERM
  generated_file_allowlist > "$allowed_list"
  find "$TARGET_DIR" \
    \( -path "$TARGET_DIR/.git" -o -path "$TARGET_DIR/.tools" -o -path "$TARGET_DIR/.gradle" -o -path "$TARGET_DIR/build" \) -prune -o \
    -type f -name '*.generated.*' -print 2>/dev/null > "$candidate_list"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    base="${candidate%.generated.*}"
    rel_base="${base#"$TARGET_DIR"/}"
    if grep -Fxq "$rel_base" "$allowed_list"; then
      count=$((count + 1))
    fi
  done < "$candidate_list"
  printf '%s' "$count"
)

detector_lock_status() {
  local expected="$1"
  local actual="$2"
  if [[ -z "$expected" ]]; then
    printf 'missing'
  elif [[ "$expected" == "$actual" ]]; then
    printf 'match'
  else
    printf 'drift'
  fi
}

onboarding_status_for_target() {
  local helper="$TARGET_DIR/scripts/agent-onboarding.sh"
  local status_json status
  if [[ -x "$helper" ]]; then
    status_json="$(
      cd "$TARGET_DIR" &&
        scripts/agent-onboarding.sh status --json 2>/dev/null
    )" || {
      printf 'invalid'
      return 0
    }
    if command -v python3 >/dev/null 2>&1; then
      status="$(
        printf '%s' "$status_json" |
          python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","invalid"))' 2>/dev/null || true
      )"
    else
      status="$(printf '%s' "$status_json" | sed -n 's/^[[:space:]]*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi
    printf '%s' "${status:-invalid}"
    return 0
  fi
  if [[ -f "$TARGET_DIR/docs/agent-configs/project-onboarding.md" ]]; then
    printf 'missing'
  else
    printf 'not-installed'
  fi
}

current_status_fields() {
  local lock_file="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local installed_version installed_schema installed_channel installed_workflow expected_hash actual_summary actual_hash status pending_count generated_drift onboarding_status
  installed_version="$(read_lock_value version "$lock_file")"
  installed_schema="$(read_lock_value schema "$lock_file")"
  installed_channel="$(read_lock_value channel "$lock_file")"
  installed_workflow="$(read_lock_value workflow_preset "$lock_file")"
  expected_hash="$(read_lock_value detector_summary_sha256 "$lock_file")"
  actual_summary="$(detector_summary_for_lock)"
  actual_hash="$(printf '%s' "$actual_summary" | hash_text)"
  status="$(detector_lock_status "$expected_hash" "$actual_hash")"
  pending_count="$(pending_generated_candidate_count)"
  generated_drift="$(generated_file_drift_status)"
  onboarding_status="$(onboarding_status_for_target)"

  printf 'target=%s\n' "$TARGET_DIR"
  printf 'project=%s\n' "$PROJECT_NAME"
  printf 'schema=%s\n' "${installed_schema:-missing}"
  printf 'bundle_version=%s\n' "$AGENT_BOOTSTRAP_VERSION"
  printf 'installed_version=%s\n' "${installed_version:-missing}"
  printf 'channel=%s\n' "${installed_channel:-missing}"
  printf 'workflow_preset=%s\n' "${installed_workflow:-$WORKFLOW_PRESET}"
  printf 'detector_lock_status=%s\n' "$status"
  printf 'onboarding_status=%s\n' "$onboarding_status"
  printf 'pending_generated_candidates=%s\n' "$pending_count"
  printf 'generated_file_drift=%s\n' "$generated_drift"
}

print_status() {
  local fields
  fields="$(current_status_fields)"
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    local target project schema installed version channel workflow detector onboarding pending generated_drift
    target="$(printf '%s\n' "$fields" | sed -n 's/^target=//p')"
    project="$(printf '%s\n' "$fields" | sed -n 's/^project=//p')"
    schema="$(printf '%s\n' "$fields" | sed -n 's/^schema=//p')"
    version="$(printf '%s\n' "$fields" | sed -n 's/^bundle_version=//p')"
    installed="$(printf '%s\n' "$fields" | sed -n 's/^installed_version=//p')"
    channel="$(printf '%s\n' "$fields" | sed -n 's/^channel=//p')"
    workflow="$(printf '%s\n' "$fields" | sed -n 's/^workflow_preset=//p')"
    detector="$(printf '%s\n' "$fields" | sed -n 's/^detector_lock_status=//p')"
    onboarding="$(printf '%s\n' "$fields" | sed -n 's/^onboarding_status=//p')"
    pending="$(printf '%s\n' "$fields" | sed -n 's/^pending_generated_candidates=//p')"
    generated_drift="$(printf '%s\n' "$fields" | sed -n 's/^generated_file_drift=//p')"
    printf '{"schema":"agent-bootstrap-status/v1","target":"%s","project":"%s","lock_schema":"%s","bundle_version":"%s","installed_version":"%s","channel":"%s","workflow_preset":"%s","detector_lock_status":"%s","onboarding_status":"%s","pending_generated_candidates":%s,"generated_file_drift":"%s"}\n' \
      "$(json_escape "$target")" \
      "$(json_escape "$project")" \
      "$(json_escape "$schema")" \
      "$(json_escape "$version")" \
      "$(json_escape "$installed")" \
      "$(json_escape "$channel")" \
      "$(json_escape "$workflow")" \
      "$(json_escape "$detector")" \
      "$(json_escape "$onboarding")" \
      "${pending:-0}" \
      "$(json_escape "${generated_drift:-unknown}")"
  else
    printf '%s\n' "$fields"
  fi
}

copy_target_for_diff() {
  local dest="$1"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.git/' \
      --exclude '.tools/' \
      --exclude '.gradle/' \
      --exclude 'build/' \
      --exclude '*/build/' \
      --exclude 'node_modules/' \
      --exclude 'Pods/' \
      --exclude 'vendor/' \
      "$TARGET_DIR/" "$dest/"
    return 0
  fi

  (
    cd "$TARGET_DIR"
    find . \
      \( -path './.git' -o -path './.tools' -o -path './.gradle' -o -path './build' -o -path './node_modules' -o -path './Pods' -o -path './vendor' \) -prune -o \
      -type f -print
  ) | while IFS= read -r relpath; do
    relpath="${relpath#./}"
    mkdir -p "$dest/$(dirname "$relpath")"
    cp -p "$TARGET_DIR/$relpath" "$dest/$relpath"
  done
}

sanitize_for_diff() {
  local relpath="$1"
  local file="$2"
  if [[ "$relpath" == "docs/agent-configs/agent-bootstrap.lock.json" ]]; then
    sed 's/"generated_at": "[^"]*"/"generated_at": "<generated_at>"/' "$file"
  else
    cat "$file"
  fi | awk -v target="$TARGET_DIR" -v temp="${DIFF_TMP_TARGET:-}" -v target_private="/private$TARGET_DIR" -v temp_private="/private${DIFF_TMP_TARGET:-}" '
    function replace_all(value, needle, replacement, out, pos) {
      if (needle == "") {
        return value
      }
      out = ""
      while ((pos = index(value, needle)) > 0) {
        out = out substr(value, 1, pos - 1) replacement
        value = substr(value, pos + length(needle))
      }
      return out value
    }
    {
      $0 = replace_all($0, target_private, "<target>")
      $0 = replace_all($0, target, "<target>")
      if (temp != "") {
        $0 = replace_all($0, temp_private, "<target>")
        $0 = replace_all($0, temp, "<target>")
      }
      gsub(/on [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]/, "on <generated_at>")
      print
    }
  '
}

print_generated_diff() (
  local tmp_root tmp_target write_log relpath diff_found old_sanitized new_sanitized
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
  tmp_target="$tmp_root/target"
  DIFF_TMP_TARGET="$tmp_target"
  write_log="$tmp_root/generated-files.txt"
  diff_found=false
  copy_target_for_diff "$tmp_target"
  : > "$write_log"

  AGENT_BOOTSTRAP_WRITE_LOG="$write_log" \
    "$BOOTSTRAP_SCRIPT_PATH" --target "$tmp_target" --project-name "$PROJECT_NAME" --workflow "$WORKFLOW_PRESET" --force --no-backup \
    >"$tmp_root/generate.out"

  sort -u "$write_log" | while IFS= read -r relpath; do
    [[ -n "$relpath" ]] || continue
    old_sanitized="$tmp_root/old.$$"
    new_sanitized="$tmp_root/new.$$"
    if [[ -f "$TARGET_DIR/$relpath" ]]; then
      sanitize_for_diff "$relpath" "$TARGET_DIR/$relpath" > "$old_sanitized"
    else
      : > "$old_sanitized"
    fi
    sanitize_for_diff "$relpath" "$tmp_target/$relpath" > "$new_sanitized"
    if ! cmp -s "$old_sanitized" "$new_sanitized"; then
      printf '%s\n' "--- $relpath"
      printf '%s\n' "+++ $relpath (generated)"
      diff -u "$old_sanitized" "$new_sanitized" | sed '1,2d' || true
      printf '\n'
      printf 'diff\n' >> "$tmp_root/diff-found"
    fi
    rm -f "$old_sanitized" "$new_sanitized"
  done

  if [[ -f "$tmp_root/diff-found" ]]; then
    diff_found=true
  fi
  if [[ "$diff_found" != "true" ]]; then
    printf 'No generated-file differences.\n'
  fi
)

generated_file_drift_status() {
  local diff_output
  diff_output="$(print_generated_diff)"
  if [[ "$diff_output" == "No generated-file differences." ]]; then
    printf 'clean'
  else
    printf 'stale'
  fi
}

generated_file_allowlist() (
  local tmp_root tmp_target write_log
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
  tmp_target="$tmp_root/target"
  write_log="$tmp_root/generated-files.txt"
  copy_target_for_diff "$tmp_target"
  : > "$write_log"

  AGENT_BOOTSTRAP_WRITE_LOG="$write_log" \
    "$BOOTSTRAP_SCRIPT_PATH" --target "$tmp_target" --project-name "$PROJECT_NAME" --workflow "$WORKFLOW_PRESET" --force --no-backup \
    >"$tmp_root/generate.out"

  sort -u "$write_log"
)

apply_generated_candidates() (
  local candidate_list applied_list allowed_list candidate base rel_candidate rel_base applied_any
  candidate_list="$(mktemp)"
  applied_list="$(mktemp)"
  allowed_list="$(mktemp)"
  applied_any=false
  trap 'rm -f "$candidate_list" "$applied_list" "$allowed_list"' EXIT HUP INT TERM
  generated_file_allowlist > "$allowed_list"
  find "$TARGET_DIR" \
    \( -path "$TARGET_DIR/.git" -o -path "$TARGET_DIR/.tools" -o -path "$TARGET_DIR/.gradle" -o -path "$TARGET_DIR/build" \) -prune -o \
    -type f -name '*.generated.*' -print 2>/dev/null |
    sort -r > "$candidate_list"

  if [[ ! -s "$candidate_list" ]]; then
    rm -f "$candidate_list" "$applied_list"
    printf 'No generated candidates to apply.\n'
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    base="${candidate%.generated.*}"
    rel_candidate="${candidate#"$TARGET_DIR"/}"
    rel_base="${base#"$TARGET_DIR"/}"
    if ! grep -Fxq "$rel_base" "$allowed_list"; then
      continue
    fi
    applied_any=true
    if grep -Fxq "$base" "$applied_list"; then
      if [[ "$DRY_RUN" == "true" ]]; then
        printf 'DRY-RUN remove older generated candidate %s\n' "$rel_candidate"
      else
        rm -f "$candidate"
        printf 'Removed older generated candidate %s\n' "$rel_candidate"
      fi
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      printf 'DRY-RUN apply generated candidate %s -> %s\n' "$rel_candidate" "$rel_base"
    else
      backup_existing "$base"
      mkdir -p "$(dirname "$base")"
      mv "$candidate" "$base"
      printf 'Applied generated candidate %s -> %s\n' "$rel_candidate" "$rel_base"
    fi
    printf '%s\n' "$base" >> "$applied_list"
  done < "$candidate_list"

  if [[ "$applied_any" != "true" ]]; then
    printf 'No generated candidates to apply.\n'
  fi
)

print_upgrade_plan() {
  local status_fields
  status_fields="$(current_status_fields)"
  printf 'Upgrade plan\n'
  printf '%s\n' "$status_fields"
  printf '\n'
  printf 'Preview generated-file changes:\n'
  printf '  bash %s --target %s --workflow %s --diff\n' "$BOOTSTRAP_SCRIPT_PATH" "$(shell_quote "$TARGET_DIR")" "$WORKFLOW_PRESET"
  printf 'Apply non-destructively (writes *.generated.* candidates for conflicts):\n'
  printf '  bash %s --target %s --workflow %s\n' "$BOOTSTRAP_SCRIPT_PATH" "$(shell_quote "$TARGET_DIR")" "$WORKFLOW_PRESET"
  printf 'Promote reviewed generated candidates into place:\n'
  printf '  bash %s --target %s --apply-candidates\n' "$BOOTSTRAP_SCRIPT_PATH" "$(shell_quote "$TARGET_DIR")"
  printf 'Validate target after review/apply:\n'
  printf '  scripts/verify-ai-deps.sh\n'
}

print_first_10() {
  local lock_file="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local onboarding_status rtk_state guard_state
  onboarding_status="$(onboarding_status_for_target)"
  rtk_state="missing"
  guard_state="missing"
  if [[ -x "$TARGET_DIR/scripts/rtk" ]] &&
    (cd "$TARGET_DIR" && scripts/rtk --version >/dev/null 2>&1); then
    rtk_state="installed"
  fi
  if [[ -x "$TARGET_DIR/scripts/agent-guard.sh" ]]; then
    guard_state="installed"
  fi

  printf 'First 10 Minutes\n'
  printf 'target=%s\n' "$TARGET_DIR"
  printf 'workflow_preset=%s\n' "$WORKFLOW_PRESET"
  printf 'rtk=%s\n' "$rtk_state"
  printf 'agent_guard=%s\n' "$guard_state"
  printf 'onboarding_status=%s\n' "$onboarding_status"
  printf '\n'

  if [[ ! -f "$lock_file" ]]; then
    printf '1. Generate the full harness into this project:\n'
    printf '   bash %s --target %s --workflow full\n' \
      "$(shell_quote "$BOOTSTRAP_SCRIPT_PATH")" "$(shell_quote "$TARGET_DIR")"
    printf '2. Re-run this guide:\n'
    printf '   bash %s --target %s --first-10\n' \
      "$(shell_quote "$BOOTSTRAP_SCRIPT_PATH")" "$(shell_quote "$TARGET_DIR")"
    return 0
  fi

  printf '1. Install the pinned runtime wrapper when missing:\n'
  printf '   bash scripts/install-rtk.sh\n'
  printf '2. Validate generated agent infrastructure:\n'
  printf '   scripts/agent-hook.sh doctor\n'
  printf '3. Refresh the local context pack for this checkout:\n'
  printf '   scripts/agent-guard.sh preflight\n'
  printf '4. Fill or verify the onboarding contract:\n'
  printf '   scripts/agent-onboarding.sh next\n'
  printf '   scripts/agent-onboarding.sh check\n'
  printf '5. Final harness verification:\n'
  printf '   scripts/verify-ai-deps.sh\n'

  if [[ -x "$TARGET_DIR/scripts/agent-onboarding.sh" ]]; then
    printf '\nCurrent onboarding next actions:\n'
    (cd "$TARGET_DIR" && scripts/agent-onboarding.sh next) || true
  elif [[ "$WORKFLOW_PRESET" != "full" ]]; then
    printf '\nOnboarding helper is generated by --workflow full. Current workflow: %s\n' "$WORKFLOW_PRESET"
  else
    printf '\nOnboarding helper is missing; regenerate or apply reviewed generated candidates.\n'
  fi
}

main() {
  detect_tech_stack
  case "$ACTION" in
    status)
      print_status
      exit 0
      ;;
    first-10)
      print_first_10
      exit 0
      ;;
    diff)
      print_generated_diff
      exit 0
      ;;
    upgrade-plan)
      print_upgrade_plan
      exit 0
      ;;
    apply-candidates)
      apply_generated_candidates
      exit 0
      ;;
  esac

  log "Target: $TARGET_DIR"
  log "Project: $PROJECT_NAME"
  log "Detected stacks: ${TECH_STACKS[*]}"
  log "Detected modules: ${MODULES[*]}"

  if [[ "$REFRESH_LOCK" == "true" ]]; then
    write_agent_bootstrap_lock
    log "Refreshed docs/agent-configs/agent-bootstrap.lock.json."
    exit 0
  fi

  if workflow_enabled; then
    write_agent_docs
  else
    write_infra_agent_docs
  fi
  write_agent_bootstrap_lock
  write_template_catalog
  write_schema_model_and_provenance_catalog
  write_agentmemory_skill
  write_rtk_tools
  write_tech_stack_lib
  write_runtime_detector
  write_agent_guard
  if workflow_enabled; then
    write_agent_onboarding_runtime
  fi
  write_agent_hook
  write_verify_ai_deps
  if workflow_enabled; then
    write_doubt_driven_skill
    write_project_onboarding
    write_tool_entrypoints
    write_codex_files
  else
    write_infra_tool_entrypoints
  fi
  append_gitignore_block

  log "Generated multi-agent files."
  if [[ "$BACKUP" == "true" ]]; then
    log "Backups for overwritten or appended existing files use suffix: .bak.$STAMP"
  fi
  log "Next: review docs/agent-configs/project-agent-context.md and adjust project-specific rules."
  if workflow_enabled; then
    log "First 10 Minutes: run scripts/agent-onboarding.sh next, then fill the onboarding contract before substantive work."
  else
    log "Full onboarding helpers are available with: --workflow full"
  fi
}

main
