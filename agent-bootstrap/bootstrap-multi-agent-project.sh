#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="$(pwd -P)"
PROJECT_NAME="$(basename "$TARGET_DIR")"
PROJECT_NAME_EXPLICIT=false
STAMP="$(date +%Y%m%d-%H%M%S)"
AGENT_BOOTSTRAP_VERSION="2026.10.13.2"
AGENT_BOOTSTRAP_CHANNEL="stable"
RTK_VERSION="0.37.2"
WORKFLOW_PRESET="infra"
WORKFLOW_EXPLICIT=false
APPLY_ONLY=""
ROLLBACK_ID=""
DRY_RUN=false
BACKUP=true
FORCE=false
CANDIDATE_ON_CONFLICT=true
REFRESH_LOCK=false
ACTION="generate"
JSON_OUTPUT=false
RETIREMENT_SCOPE="local-only"
RETIREMENT_SCOPE_SET=false
STATUS_VERSION=""
LAST_WRITTEN_FILE=""
OPTIONAL_SKILLS=()
INSTALLED_SKILLS=()

BOOTSTRAP_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$BUNDLE_DIR/lib"
# shellcheck source=agent-bootstrap/lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=agent-bootstrap/lib/overlays.sh
source "$LIB_DIR/overlays.sh"
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

warn() {
  printf 'warn: %s\n' "$*" >&2
}

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
    "  --only PATH          With --apply-candidates, promote only PATH (repeatable)." \
    "  --rollback ID        Undo the generation or candidate apply recorded as upgrade ID." \
    "  --cleanup-backups    Remove harness-stamped .bak/.generated leftovers." \
    "  --status             Report installed harness state for the target." \
    "  --first-10           Print the first 10 minutes operator/onboarding path." \
    "  --next               Alias for --first-10." \
    "  --diff               Show generated-file diff for a non-destructive upgrade preview." \
    "  --upgrade-plan       Print an operator upgrade plan for the target." \
    "  --retirement-plan    Report retired harness files and proposed actions (read-only)." \
    "  --retirement-status  Report the current state of retired harness files (read-only)." \
    "  --apply-retirements  Remove exact retired harness files after verified backups." \
    "  --retirement-scope S local-only (default) or all-matching (also tracked/non-Git files)." \
    "  --status-version N   With --status --json: 1 (default) or 2 (adds the retirement report)." \
    "  --json               Machine-readable output for --status, --upgrade-plan and retirement actions." \
    "  --workflow PRESET    Optional workflow philosophy: infra or full." \
    "  --add-skill NAME     Add optional skill template to the target (mobile-optimization)." \
    "  --no-backup          Overwrite existing generated files without .bak copy." \
    "  --version            Print bootstrap version." \
    "  -h, --help           Show help."
}

retirement_usage_error() {
  echo "ERROR: $*" >&2
  usage >&2
  exit 2
}

ORIGINAL_ARGS=("$@")
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
    --only)
      APPLY_ONLY+="${2:?missing value for --only}"$'\n'
      shift 2
      ;;
    --rollback)
      ACTION="rollback"
      ROLLBACK_ID="${2:?missing value for --rollback}"
      shift 2
      ;;
    --cleanup-backups)
      ACTION="cleanup-backups"
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
    --retirement-plan|--retirement-status|--apply-retirements)
      ACTION="${1#--}"
      shift
      ;;
    --retirement-scope)
      [[ $# -ge 2 ]] || retirement_usage_error "missing value for --retirement-scope"
      case "$2" in
        local-only|all-matching) RETIREMENT_SCOPE="$2" ;;
        *) retirement_usage_error "invalid --retirement-scope: $2 (expected local-only or all-matching)" ;;
      esac
      RETIREMENT_SCOPE_SET=true
      shift 2
      ;;
    --status-version)
      [[ $# -ge 2 ]] || retirement_usage_error "missing value for --status-version"
      case "$2" in
        1|2) STATUS_VERSION="$2" ;;
        *) retirement_usage_error "invalid --status-version: $2 (expected 1 or 2)" ;;
      esac
      shift 2
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
    --add-skill)
      case "${2:?missing value for --add-skill}" in
        mobile-optimization)
          OPTIONAL_SKILLS+=("$2")
          ;;
        *)
          echo "ERROR: unsupported optional skill: $2" >&2
          usage >&2
          exit 2
          ;;
      esac
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

# HK-07: reject malformed retirement combinations in any argument order before
# dispatch or writes. Unrelated existing combinations keep last-action-wins.
validate_retirement_arguments() {
  local arg skip=false dedicated=false first="" mixed="" overrides=""
  for arg in "$@"; do
    if [[ "$skip" == true ]]; then
      skip=false
      continue
    fi
    case "$arg" in
      --project-name|--target|--only|--workflow|--add-skill|--retirement-scope|--status-version) skip=true ;;
      --rollback)
        # An action that takes a value (the upgrade id).
        skip=true
        if [[ -z "$first" ]]; then
          first="$arg"
        elif [[ "$arg" != "$first" ]]; then
          mixed="$first $arg"
        fi
        ;;
      --retirement-plan|--retirement-status|--apply-retirements|--refresh-lock|--apply-candidates|\
      --cleanup-backups|--status|--first-10|--next|--diff|--upgrade-plan)
        case "$arg" in --retirement-plan|--retirement-status|--apply-retirements) dedicated=true ;; esac
        if [[ -z "$first" ]]; then
          first="$arg"
        elif [[ "$arg" != "$first" ]]; then
          mixed="$first $arg"
        fi
        ;;
      --force|--skip-existing|--no-backup) overrides+=" $arg" ;;
    esac
  done
  if [[ "$dedicated" == true ]]; then
    [[ -z "$mixed" ]] || retirement_usage_error "retirement actions cannot be combined with other actions: $mixed"
    [[ -z "$overrides" ]] || retirement_usage_error "retirement actions reject${overrides}; backups are mandatory and preserved files cannot be forced"
    [[ -z "$APPLY_ONLY" ]] || retirement_usage_error "--only requires --apply-candidates"
  fi
  if [[ -n "$STATUS_VERSION" ]] && [[ "$ACTION" != "status" || "$JSON_OUTPUT" != "true" ]]; then
    retirement_usage_error "--status-version requires --status --json"
  fi
  if [[ "$RETIREMENT_SCOPE_SET" == true ]]; then
    case "$ACTION" in
      refresh-lock|first-10|apply-candidates|cleanup-backups)
        retirement_usage_error "--retirement-scope is not valid with --$ACTION"
        ;;
      status)
        [[ "$JSON_OUTPUT" != "true" || "$STATUS_VERSION" == "2" ]] ||
          retirement_usage_error "--retirement-scope needs --status-version 2; status v1 JSON cannot represent it"
        ;;
    esac
  fi
}

validate_retirement_arguments ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
case "$ACTION" in
  retirement-plan|retirement-status|apply-retirements)
    retirement_mode="${ACTION#retirement-}"
    [[ "$ACTION" != "apply-retirements" ]] || retirement_mode="apply"
    retirement_args=(--target "$TARGET_DIR" --scope "$RETIREMENT_SCOPE" --bootstrap "$BOOTSTRAP_SCRIPT_PATH")
    [[ "$JSON_OUTPUT" != "true" ]] || retirement_args+=(--json)
    [[ "$DRY_RUN" != "true" ]] || retirement_args+=(--dry-run)
    exec python3 "$LIB_DIR/retirement.py" "$retirement_mode" "${retirement_args[@]}"
    ;;
esac

read_lock_value() {
  local key="$1"
  local file="${2:-$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json}"
  [[ -f "$file" ]] || return 0
  bootstrap_existing_file_is_eligible "$file" || {
    warn "omitting unsafe lock metadata read: $(bootstrap_path_diagnostic "$file")"
    return 0
  }
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

read_lock_skills() {
  local file="${1:-$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json}"
  [[ -f "$file" ]] || return 0
  bootstrap_existing_file_is_eligible "$file" || {
    warn "omitting unsafe lock skills read: $(bootstrap_path_diagnostic "$file")"
    return 0
  }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)

skills = document.get("skills", [])
if isinstance(skills, list):
    for skill in skills:
        if isinstance(skill, str):
            print(skill)
PY
    return 0
  fi
  sed -n 's/.*"skills"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$file" |
    tr ',' '\n' |
    sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p'
}

read_lock_skill_metadata_value() {
  local skill="$1"
  local key="$2"
  local file="${3:-$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json}"
  [[ -f "$file" ]] || return 0
  bootstrap_existing_file_is_eligible "$file" || {
    warn "omitting unsafe lock skill metadata read: $(bootstrap_path_diagnostic "$file")"
    return 0
  }
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$file" "$skill" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path, skill, key = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)

metadata = document.get("skill_metadata", {})
if not isinstance(metadata, dict):
    sys.exit(0)
skill_metadata = metadata.get(skill, {})
if not isinstance(skill_metadata, dict):
    sys.exit(0)
value = skill_metadata.get(key)
if isinstance(value, str):
    print(value)
PY
}

read_lock_skill_metadata_json() {
  local file="${1:-$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json}"
  [[ -f "$file" ]] || { printf '{}'; return 0; }
  bootstrap_existing_file_is_eligible "$file" || {
    warn "omitting unsafe lock skill metadata read: $(bootstrap_path_diagnostic "$file")"
    printf '{}'
    return 0
  }
  command -v python3 >/dev/null 2>&1 || { printf '{}'; return 0; }
  python3 - "$file" <<'PY' 2>/dev/null || printf '{}'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    print("{}")
    sys.exit(0)

metadata = document.get("skill_metadata", {})
if not isinstance(metadata, dict):
    metadata = {}
print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
PY
}

array_has_value() {
  local array_name="$1"
  local wanted="$2"
  local count=0
  local index=0
  local value
  eval "count=\${#${array_name}[@]}"
  while [[ "$index" -lt "$count" ]]; do
    eval "value=\${${array_name}[$index]}"
    [[ "$value" == "$wanted" ]] && return 0
    index=$((index + 1))
  done
  return 1
}

add_installed_skill() {
  local skill="$1"
  array_has_value INSTALLED_SKILLS "$skill" && return 0
  INSTALLED_SKILLS+=("$skill")
}

optional_skill_installed() {
  array_has_value INSTALLED_SKILLS "$1"
}

optional_skill_selected() {
  optional_skill_requested "$1" || optional_skill_installed "$1"
}

load_installed_optional_skills() {
  local skill
  INSTALLED_SKILLS=()
  while IFS= read -r skill; do
    [[ -n "$skill" ]] || continue
    case "$skill" in
      mobile-optimization) add_installed_skill "$skill" ;;
    esac
  done < <(read_lock_skills)
}

selected_optional_skills() {
  if optional_skill_selected mobile-optimization; then
    printf '%s\n' "mobile-optimization"
  fi
  return 0
}

selected_optional_skills_json() {
  local skill
  local first=true
  local json=""
  while IFS= read -r skill; do
    [[ -n "$skill" ]] || continue
    if [[ "$first" == "true" ]]; then
      first=false
    else
      json+=", "
    fi
    json+="\"$(json_escape "$skill")\""
  done < <(selected_optional_skills)
  printf '%s' "$json"
}

mobile_optimization_skill_source_paths() {
  cat <<'EOF'
templates/skills/mobile-optimization/SKILL.md
templates/skills/mobile-optimization/catalog.md
templates/skills/mobile-optimization/pointers/claude.command.md
templates/skills/mobile-optimization/pointers/cursor.rules.mdc
templates/skills/mobile-optimization/pointers/pointer-body.md
templates/skills/mobile-optimization/pointers/windsurf.rules.md
templates/skills/mobile-optimization/skill.manifest.json
EOF
  if detected_stack_has android_kotlin; then
    cat <<'EOF'
templates/skills/mobile-optimization/overlays/kotlin.md
templates/skills/mobile-optimization/fewshots/kotlin.md
EOF
  fi
  if detected_stack_has ios_swift; then
    cat <<'EOF'
templates/skills/mobile-optimization/overlays/swift.md
templates/skills/mobile-optimization/fewshots/swift.md
EOF
  fi
}

optional_skill_content_hash() {
  local skill="$1"
  local relpath
  case "$skill" in
    mobile-optimization)
      {
        while IFS= read -r relpath; do
          [[ -n "$relpath" ]] || continue
          [[ -f "$BUNDLE_DIR/$relpath" ]] || fail "missing optional skill source: $relpath"
          printf 'path:%s\n' "$relpath"
          cat "$BUNDLE_DIR/$relpath"
          printf '\n'
        done < <(mobile_optimization_skill_source_paths | sort -u)
      } | hash_text
      ;;
    *)
      fail "unsupported optional skill hash: $skill"
      ;;
  esac
}

selected_optional_skill_metadata_json() {
  local skill current_hash existing_hash existing_version installed_from_version content_hash
  local first=true
  local json=""
  while IFS= read -r skill; do
    [[ -n "$skill" ]] || continue
    current_hash="$(optional_skill_content_hash "$skill")"
    existing_hash="$(read_lock_skill_metadata_value "$skill" content_hash)"
    existing_version="$(read_lock_skill_metadata_value "$skill" installed_from_version)"

    installed_from_version="$existing_version"
    content_hash="$existing_hash"
    if optional_skill_requested "$skill"; then
      if [[ -z "$existing_hash" || "$existing_hash" != "$current_hash" ]]; then
        installed_from_version="$AGENT_BOOTSTRAP_VERSION"
        content_hash="$current_hash"
      fi
    elif [[ -z "$content_hash" ]]; then
      content_hash="$current_hash"
    fi
    [[ -n "$installed_from_version" ]] || installed_from_version="$AGENT_BOOTSTRAP_VERSION"
    [[ -n "$content_hash" ]] || content_hash="$current_hash"

    if [[ "$first" == "true" ]]; then
      first=false
    else
      json+=","
    fi
    json+="\"$(json_escape "$skill")\":{\"content_hash\":\"$(json_escape "$content_hash")\",\"installed_from_version\":\"$(json_escape "$installed_from_version")\"}"
  done < <(selected_optional_skills)
  printf '{%s}' "$json"
}

selected_optional_skills_csv() {
  local skill
  local first=true
  local csv=""
  while IFS= read -r skill; do
    [[ -n "$skill" ]] || continue
    if [[ "$first" == "true" ]]; then
      first=false
    else
      csv+=","
    fi
    csv+="$skill"
  done < <(selected_optional_skills)
  printf '%s' "${csv:-none}"
}

mobile_optimization_skew_status() {
  optional_skill_installed mobile-optimization || { printf 'not-installed'; return 0; }
  local installed_hash current_hash
  installed_hash="$(read_lock_skill_metadata_value mobile-optimization content_hash)"
  [[ -n "$installed_hash" ]] || { printf 'unknown'; return 0; }
  current_hash="$(optional_skill_content_hash mobile-optimization)"
  if [[ "$installed_hash" == "$current_hash" ]]; then
    printf 'clean'
  else
    printf 'stale'
  fi
}

validate_requested_optional_skills() {
  if optional_skill_requested mobile-optimization &&
    ! detected_stack_has android_kotlin &&
    ! detected_stack_has ios_swift; then
    echo "ERROR: --add-skill mobile-optimization requires a detected android_kotlin or ios_swift stack." >&2
    if detected_stack_has flutter_dart; then
      echo "Flutter/Dart is out of scope for this skill." >&2
    fi
    echo "No files written." >&2
    exit 3
  fi
}

optional_skill_generation_args() {
  if optional_skill_selected mobile-optimization &&
    { detected_stack_has android_kotlin || detected_stack_has ios_swift; }; then
    printf '%s\n' "--add-skill"
    printf '%s\n' "mobile-optimization"
  fi
  return 0
}

optional_skill_allowlist_paths() {
  optional_skill_selected mobile-optimization || return 0
  cat <<'EOF'
.agents/skills/mobile-optimization/SKILL.md
.agents/skills/mobile-optimization/catalog.md
.agents/skills/mobile-optimization/overlays/kotlin.md
.agents/skills/mobile-optimization/overlays/swift.md
.agents/skills/mobile-optimization/fewshots/kotlin.md
.agents/skills/mobile-optimization/fewshots/swift.md
.windsurf/rules/mobile-optimization.md
.cursor/rules/mobile-optimization.mdc
.claude/commands/optimize-code.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/SKILL.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/catalog.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/fewshots/kotlin.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/fewshots/swift.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/overlays/kotlin.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/overlays/swift.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/pointers/claude.command.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/pointers/cursor.rules.mdc
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/pointers/pointer-body.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/pointers/windsurf.rules.md
docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/skill.manifest.json
EOF
}

resolve_workflow_from_lock() {
  local existing_lock="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local existing_workflow=""
  if [[ -f "$existing_lock" ]]; then
    existing_workflow="$(
      read_lock_value workflow_preset "$existing_lock"
    )"
    if [[ -n "$existing_workflow" ]]; then
      WORKFLOW_PRESET="$existing_workflow"
    fi
  fi
  return 0
}

resolve_project_name_from_lock() {
  local existing_lock="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local existing_project=""
  if [[ -f "$existing_lock" ]]; then
    existing_project="$(
      read_lock_value project_name "$existing_lock"
    )"
    if [[ -n "$existing_project" ]]; then
      PROJECT_NAME="$existing_project"
    fi
  fi
  return 0
}

if [[ "$PROJECT_NAME_EXPLICIT" == "false" ]]; then
  resolve_project_name_from_lock
fi

if [[ -n "$APPLY_ONLY" && "$ACTION" != "apply-candidates" ]]; then
  echo "ERROR: --only requires --apply-candidates" >&2
  exit 2
fi

if [[ "$WORKFLOW_EXPLICIT" == "false" ]]; then
  case "$ACTION" in
    refresh-lock|status|first-10|diff|upgrade-plan|apply-candidates|cleanup-backups) resolve_workflow_from_lock ;;
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
  bootstrap_find_pruned "$TARGET_DIR" -type f -name '*.generated.*' -print 2>/dev/null > "$candidate_list"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    base="${candidate%.generated.*}"
    rel_base="${base#"$TARGET_DIR"/}"
    if grep -Fxq "$rel_base" "$allowed_list" && ! bootstrap_user_owned_file_is_filled "$base"; then
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
  local mobile_skill_version mobile_skill_hash mobile_skill_skew
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
  mobile_skill_skew="$(mobile_optimization_skew_status)"
  if optional_skill_installed mobile-optimization; then
    mobile_skill_version="$(read_lock_skill_metadata_value mobile-optimization installed_from_version)"
    mobile_skill_hash="$(read_lock_skill_metadata_value mobile-optimization content_hash)"
  else
    mobile_skill_version="none"
    mobile_skill_hash="none"
  fi

  printf 'target=%s\n' "$TARGET_DIR"
  printf 'project=%s\n' "$PROJECT_NAME"
  printf 'schema=%s\n' "${installed_schema:-missing}"
  printf 'bundle_version=%s\n' "$AGENT_BOOTSTRAP_VERSION"
  printf 'installed_version=%s\n' "${installed_version:-missing}"
  printf 'channel=%s\n' "${installed_channel:-missing}"
  printf 'workflow_preset=%s\n' "${installed_workflow:-$WORKFLOW_PRESET}"
  printf 'installed_skills=%s\n' "$(selected_optional_skills_csv)"
  printf 'skill_mobile_optimization_installed_from_version=%s\n' "${mobile_skill_version:-missing}"
  printf 'skill_mobile_optimization_content_hash=%s\n' "${mobile_skill_hash:-missing}"
  printf 'skill_mobile_optimization_skew=%s\n' "$mobile_skill_skew"
  printf 'detector_lock_status=%s\n' "$status"
  printf 'onboarding_status=%s\n' "$onboarding_status"
  printf 'pending_generated_candidates=%s\n' "$pending_count"
  printf 'generated_file_drift=%s\n' "$generated_drift"
}

print_status() {
  local fields
  fields="$(current_status_fields)"
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    local target project schema installed version channel workflow skills skill_mobile_version skill_mobile_hash skill_mobile_skew detector onboarding pending generated_drift
    target="$(printf '%s\n' "$fields" | sed -n 's/^target=//p')"
    project="$(printf '%s\n' "$fields" | sed -n 's/^project=//p')"
    schema="$(printf '%s\n' "$fields" | sed -n 's/^schema=//p')"
    version="$(printf '%s\n' "$fields" | sed -n 's/^bundle_version=//p')"
    installed="$(printf '%s\n' "$fields" | sed -n 's/^installed_version=//p')"
    channel="$(printf '%s\n' "$fields" | sed -n 's/^channel=//p')"
    workflow="$(printf '%s\n' "$fields" | sed -n 's/^workflow_preset=//p')"
    skills="$(printf '%s\n' "$fields" | sed -n 's/^installed_skills=//p')"
    skill_mobile_version="$(printf '%s\n' "$fields" | sed -n 's/^skill_mobile_optimization_installed_from_version=//p')"
    skill_mobile_hash="$(printf '%s\n' "$fields" | sed -n 's/^skill_mobile_optimization_content_hash=//p')"
    skill_mobile_skew="$(printf '%s\n' "$fields" | sed -n 's/^skill_mobile_optimization_skew=//p')"
    detector="$(printf '%s\n' "$fields" | sed -n 's/^detector_lock_status=//p')"
    onboarding="$(printf '%s\n' "$fields" | sed -n 's/^onboarding_status=//p')"
    pending="$(printf '%s\n' "$fields" | sed -n 's/^pending_generated_candidates=//p')"
    generated_drift="$(printf '%s\n' "$fields" | sed -n 's/^generated_file_drift=//p')"
    printf '{"schema":"agent-bootstrap-status/v1","target":"%s","project":"%s","lock_schema":"%s","bundle_version":"%s","installed_version":"%s","channel":"%s","workflow_preset":"%s","installed_skills":"%s","skill_mobile_optimization_installed_from_version":"%s","skill_mobile_optimization_content_hash":"%s","skill_mobile_optimization_skew":"%s","detector_lock_status":"%s","onboarding_status":"%s","pending_generated_candidates":%s,"generated_file_drift":"%s"}\n' \
      "$(json_escape "$target")" \
      "$(json_escape "$project")" \
      "$(json_escape "$schema")" \
      "$(json_escape "$version")" \
      "$(json_escape "$installed")" \
      "$(json_escape "$channel")" \
      "$(json_escape "$workflow")" \
      "$(json_escape "$skills")" \
      "$(json_escape "$skill_mobile_version")" \
      "$(json_escape "$skill_mobile_hash")" \
      "$(json_escape "$skill_mobile_skew")" \
      "$(json_escape "$detector")" \
      "$(json_escape "$onboarding")" \
      "${pending:-0}" \
      "$(json_escape "${generated_drift:-unknown}")"
  else
    printf '%s\n' "$fields"
  fi
}

snapshot_required_path() {
  case "$1" in
    docs|docs/agent-configs|docs/agent-configs/*|docs/superpowers|docs/superpowers/specs|\
    docs/superpowers/specs/project-brief.md|\
    docs/superpowers/specs/project-tech-stack.md|docs/superpowers/specs/project-tech-stack.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

snapshot_resolved_path() {
  AGENT_SNAPSHOT_PATH="$1" python3 - <<'PY'
import os
print(os.path.realpath(os.environ["AGENT_SNAPSHOT_PATH"]))
PY
}

copy_snapshot_regular_children() {
  local source="$1"
  local dest="$2"
  local relpath="$3"
  local resolved child child_rel
  bootstrap_existing_directory_is_eligible "$source" || return 1
  resolved="$(snapshot_resolved_path "$source")"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_rel="$relpath/$(basename "$child")"
    snapshot_path_is_personal "$child_rel" && continue
    if ! bootstrap_existing_file_is_eligible "$child"; then
      snapshot_required_path "$child_rel" && return 1
      continue
    fi
    mkdir -p "$dest/$(dirname "$child_rel")"
    cp -p "$child" "$dest/$child_rel"
  done < <(find "$resolved" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null)
}

copy_snapshot_directory_link_contents() {
  local source="$1"
  local dest="$2"
  local relpath="$3"
  local resolved nested nested_source
  case "$relpath" in
    docs/agent-configs|docs/superpowers/specs)
      copy_snapshot_regular_children "$source" "$dest" "$relpath"
      ;;
    docs|docs/superpowers)
      bootstrap_existing_directory_is_eligible "$source" || return 1
      resolved="$(snapshot_resolved_path "$source")"
      if [[ "$relpath" == "docs" ]]; then
        for nested in agent-configs superpowers/specs; do
          nested_source="$resolved/$nested"
          if [[ -d "$nested_source" ]]; then
            copy_snapshot_regular_children "$nested_source" "$dest" "$relpath/$nested" || return 1
          elif [[ -e "$nested_source" || -L "$nested_source" ]]; then
            return 1
          fi
        done
      else
        nested_source="$resolved/specs"
        if [[ -d "$nested_source" ]]; then
          copy_snapshot_regular_children "$nested_source" "$dest" "$relpath/specs"
        elif [[ -e "$nested_source" || -L "$nested_source" ]]; then
          return 1
        fi
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

# Copies the listed (NUL-separated) relpaths from the target into a snapshot in
# one process; a cp per file dominated large trees.
snapshot_copy_files() {
  AGENT_SNAPSHOT_SOURCE="$TARGET_DIR" AGENT_SNAPSHOT_DEST="$1" python3 -c '
import os, shutil, sys
source, dest = os.environ["AGENT_SNAPSHOT_SOURCE"], os.environ["AGENT_SNAPSHOT_DEST"]
for raw in sys.stdin.buffer.read().split(b"\0"):
    if raw:
        rel = os.fsdecode(raw)
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(source, rel), target)
'
}

# Personal or secret files that generation never reads are never copied into
# a snapshot under $TMPDIR, where other sessions of the same user could read
# them (and a killed run would leave them behind).
snapshot_path_is_personal() {
  case "${1##*/}" in
    *.local|*.local.*|*.p12|*.pfx|*.mobileprovision|*.provisionprofile|*.xcconfig|\
    google-services.json|GoogleService-Info.plist|.netrc|.npmrc|.pypirc)
      return 0
      ;;
  esac
  return 1
}

copy_target_for_diff() {
  local dest="$1"
  local relpath source target required=false copy_list status=0
  mkdir -p "$dest"
  copy_list="$(mktemp "${TMPDIR:-/tmp}/agent-snapshot.XXXXXX")"

  (cd "$TARGET_DIR" && bootstrap_find_pruned . -type d -print0) | (cd "$dest" && xargs -0 mkdir -p .)

  while IFS= read -r -d '' relpath; do
    relpath="${relpath#./}"
    [[ -n "$relpath" ]] || continue
    snapshot_path_is_personal "$relpath" && continue
    source="$TARGET_DIR/$relpath"
    target="$dest/$relpath"
    if [[ -L "$source" && -d "$source" ]]; then
      if bootstrap_existing_directory_is_eligible "$source"; then
        mkdir -p "$target"
        if ! copy_snapshot_directory_link_contents "$source" "$dest" "$relpath"; then
          required=true
        fi
      else
        printf 'warn: omitted unsafe directory link from preview: %s\n' "$(bootstrap_path_diagnostic "$source")" >&2
        snapshot_required_path "$relpath" && required=true
      fi
    elif bootstrap_existing_file_is_eligible "$source"; then
      printf '%s\0' "$relpath" >&3
    else
      printf 'warn: omitted unsafe preview entry: %s\n' "$(bootstrap_path_diagnostic "$source")" >&2
      snapshot_required_path "$relpath" && required=true
    fi
  done 3>"$copy_list" < <(cd "$TARGET_DIR" && bootstrap_find_pruned . \( -type f -o -type l \) -print0)

  snapshot_copy_files "$dest" < "$copy_list" || status=1
  rm -f "$copy_list"
  [[ "$status" -eq 0 ]] || return 1

  if [[ "$required" == "true" ]]; then
    printf 'ERROR: required preview configuration was unsafe or unavailable\n' >&2
    return 1
  fi
}

sanitize_for_diff() {
  local relpath="$1"
  local file="$2"
  if [[ "$file" == "$TARGET_DIR"/* ]] && bootstrap_entry_exists "$file" && ! bootstrap_existing_file_is_eligible "$file"; then
    printf 'warn: omitted unsafe old content from diff: %s\n' "$(bootstrap_path_diagnostic "$file")" >&2
    return 0
  fi
  if [[ "$relpath" == "docs/agent-configs/agent-bootstrap.lock.json" ]]; then
    sed -e 's/"generated_at": "[^"]*"/"generated_at": "<generated_at>"/' \
        -e 's/"apply_state": "[^"]*"/"apply_state": "<apply_state>"/' "$file"
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
  local tmp_root tmp_target write_log relpath diff_found old_sanitized new_sanitized arg old_unsafe
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
  tmp_target="$tmp_root/target"
  DIFF_TMP_TARGET="$tmp_target"
  write_log="$tmp_root/generated-files.txt"
  diff_found=false
  copy_target_for_diff "$tmp_target"
  : > "$write_log"

  set -- "$BOOTSTRAP_SCRIPT_PATH" --target "$tmp_target" --project-name "$PROJECT_NAME" --workflow "$WORKFLOW_PRESET" --force --no-backup
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    set -- "$@" "$arg"
  done < <(optional_skill_generation_args)
  AGENT_BOOTSTRAP_WRITE_LOG="$write_log" \
    "$@" \
    >"$tmp_root/generate.out"

  sort -u "$write_log" | while IFS= read -r relpath; do
    [[ -n "$relpath" ]] || continue
    if bootstrap_user_owned_file_is_filled "$TARGET_DIR/$relpath"; then
      continue
    fi
    old_sanitized="$tmp_root/old.$$"
    new_sanitized="$tmp_root/new.$$"
    old_unsafe=false
    if bootstrap_entry_exists "$TARGET_DIR/$relpath" && ! bootstrap_existing_file_is_eligible "$TARGET_DIR/$relpath"; then
      old_unsafe=true
    fi
    if [[ "$old_unsafe" == "true" ]] && is_bootstrap_user_owned_relpath "$relpath"; then
      printf 'warn: preserving unsafe user-owned file in diff: %s\n' "$(bootstrap_path_diagnostic "$TARGET_DIR/$relpath")" >&2
      continue
    fi
    if [[ "$old_unsafe" != "true" && -f "$TARGET_DIR/$relpath" ]]; then
      sanitize_for_diff "$relpath" "$TARGET_DIR/$relpath" > "$old_sanitized"
    else
      : > "$old_sanitized"
    fi
    sanitize_for_diff "$relpath" "$tmp_target/$relpath" > "$new_sanitized"
    if [[ "$old_unsafe" == "true" ]] || ! cmp -s "$old_sanitized" "$new_sanitized"; then
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
  if ! diff_output="$(print_generated_diff)"; then
    # Status is a read-only health report.  An unsafe required snapshot is
    # still drift from the installed state, while --diff must retain the
    # refusal and diagnostic from print_generated_diff itself.
    printf 'stale'
    return 0
  fi
  if [[ "$diff_output" == "No generated-file differences." ]]; then
    printf 'clean'
  else
    printf 'stale'
  fi
}

generated_file_allowlist() (
  local tmp_root tmp_target write_log arg
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
  tmp_target="$tmp_root/target"
  write_log="$tmp_root/generated-files.txt"
  copy_target_for_diff "$tmp_target"
  : > "$write_log"

  set -- "$BOOTSTRAP_SCRIPT_PATH" --target "$tmp_target" --project-name "$PROJECT_NAME" --workflow "$WORKFLOW_PRESET" --force --no-backup
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    set -- "$@" "$arg"
  done < <(optional_skill_generation_args)
  AGENT_BOOTSTRAP_WRITE_LOG="$write_log" \
    "$@" \
    >"$tmp_root/generate.out"

  {
    cat "$write_log"
    optional_skill_allowlist_paths
  } | sort -u | exclude_retired_artifact_paths
)

# HK-07: retired paths never enter the promotion/cleanup allowlist, so an old
# candidate can never restore retired CI. Fails closed without the inventory.
exclude_retired_artifact_paths() {
  local retired
  if ! retired="$(python3 "$LIB_DIR/retirement.py" paths)" || [[ -z "$retired" ]]; then
    echo "ERROR: retired artifact inventory is unavailable" >&2
    return 1
  fi
  grep -Fvx -f <(printf '%s\n' "$retired") || true
}

# HK-07: append the read-only retirement plan to ordinary actions. It never
# applies a retirement and returns 1 only for an inspection/enumeration error.
# Internal preview/allowlist generations (AGENT_BOOTSTRAP_WRITE_LOG) skip it.
print_retirement_section() {
  [[ -z "${AGENT_BOOTSTRAP_WRITE_LOG:-}" ]] || return 0
  printf '\n'
  python3 "$LIB_DIR/retirement.py" section --target "$TARGET_DIR" --scope "$RETIREMENT_SCOPE" \
    --context "$1" --bootstrap "$BOOTSTRAP_SCRIPT_PATH"
}

apply_generated_candidates() (
  local candidate_list applied_list allowed_list candidate base rel_candidate rel_base applied_any skipped target_parent
  candidate_list="$(mktemp)"
  applied_list="$(mktemp)"
  allowed_list="$(mktemp)"
  applied_any=false
  skipped=0
  trap 'rm -f "$candidate_list" "$applied_list" "$allowed_list"' EXIT HUP INT TERM
  generated_file_allowlist > "$allowed_list"
  bootstrap_find_pruned "$TARGET_DIR" -type f -name '*.generated.*' -print 2>/dev/null |
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
    if [[ -n "$APPLY_ONLY" ]] && ! printf '%s' "$APPLY_ONLY" | grep -Fxq "$rel_base"; then
      continue
    fi
    if bootstrap_user_owned_file_is_filled "$base"; then
      printf 'Skipped user-owned generated candidate %s -> %s\n' "$rel_candidate" "$rel_base"
      continue
    fi
    target_parent="$(dirname "$base")"
    bootstrap_write_parent_is_eligible "$base" || {
      printf 'ERROR: refusing candidate promotion outside eligible parent: %s\n' "$(bootstrap_path_diagnostic "$target_parent")" >&2
      skipped=$((skipped + 1))
      continue
    }
    if [[ ! -w "$target_parent" ]]; then
      printf '  skipped (read-only): %s -> %s\n' "$rel_candidate" "$rel_base"
      skipped=$((skipped + 1))
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
      backup_existing "$base" || {
        printf 'ERROR: refusing unsafe candidate promotion: %s\n' "$(bootstrap_path_diagnostic "$base")" >&2
        skipped=$((skipped + 1))
        continue
      }
      if bootstrap_existing_file_is_eligible "$base"; then
        harness_journal_add apply "$rel_base" "$base"
      else
        harness_journal_add create "$rel_base"
      fi
      mkdir -p "$(dirname "$base")"
      mv "$candidate" "$base"
      harness_baseline_record "$(harness_baseline_relpath "$base" || true)" "$base"
      printf 'Applied generated candidate %s -> %s\n' "$rel_candidate" "$rel_base"
    fi
    printf '%s\n' "$base" >> "$applied_list"
  done < "$candidate_list"

  if [[ "$applied_any" != "true" && "$skipped" -eq 0 ]]; then
    printf 'No generated candidates to apply.\n'
  fi
  while IFS= read -r rel_base; do
    [[ -n "$rel_base" ]] || continue
    grep -Fxq "$TARGET_DIR/$rel_base" "$applied_list" || printf 'No generated candidate applied for %s\n' "$rel_base"
  done <<<"$APPLY_ONLY"
  harness_journal_finalize
  if [[ "$skipped" -gt 0 ]]; then
    printf 'Skipped %s candidate(s) in read-only directories; promote with write access.\n' "$skipped"
  fi
)

cleanup_backups() {
  local removed=0 f allowed_list relpath base rel_base should_remove
  allowed_list="$(mktemp)"
  generated_file_allowlist > "$allowed_list"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    relpath="${f#"$TARGET_DIR"/}"
    should_remove=false
    case "$relpath" in
      *.generated.*)
        [[ "$relpath" =~ \.generated\.[0-9]{8}-[0-9]{6}$ ]] || continue
        base="${f%.generated.*}"
        rel_base="${base#"$TARGET_DIR"/}"
        grep -Fxq "$rel_base" "$allowed_list" && should_remove=true
        ;;
      *.bak.*)
        [[ "$relpath" =~ \.bak\.[0-9]{8}-[0-9]{6}$ ]] || continue
        base="${f%.bak.*}"
        rel_base="${base#"$TARGET_DIR"/}"
        grep -Fxq "$rel_base" "$allowed_list" && should_remove=true
        ;;
    esac
    [[ "$should_remove" == "true" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      printf 'DRY-RUN remove %s\n' "$relpath"
      removed=$((removed + 1))
    else
      if rm -f "$f"; then
        printf 'Removed %s\n' "$relpath"
        removed=$((removed + 1))
      else
        printf 'warn: could not remove %s\n' "$relpath" >&2
      fi
    fi
  done < <(bootstrap_find_pruned "$TARGET_DIR" -type f \( -name '*.bak.*' -o -name '*.generated.*' \) -print 2>/dev/null)
  if [[ "$removed" -eq 0 ]]; then
    printf 'No harness-stamped .bak.* or .generated.* leftovers to clean.\n'
  else
    printf 'Cleaned %s harness leftover file(s).\n' "$removed"
  fi
  rm -f "$allowed_list"
}

print_upgrade_plan_json() (
  # Classify every generated file by replaying generation on a temporary copy
  # of the target (with its harness baseline); nothing in the target changes.
  local tmp_root tmp_target plan_log arg baseline relpath
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM
  tmp_target="$tmp_root/target"
  plan_log="$tmp_root/plan.tsv"
  copy_target_for_diff "$tmp_target" || return 1
  baseline="$TARGET_DIR/$HARNESS_BASELINE_DIR/files"
  if [[ -d "$baseline" ]] && harness_state_path_is_safe "$baseline"; then
    while IFS= read -r relpath; do
      relpath="${relpath#./}"
      if [[ -f "$baseline/$relpath" && ! -L "$baseline/$relpath" ]] && harness_state_path_is_safe "$baseline/$relpath"; then
        mkdir -p "$tmp_target/$HARNESS_BASELINE_DIR/files/$(dirname "$relpath")"
        cp -p "$baseline/$relpath" "$tmp_target/$HARNESS_BASELINE_DIR/files/$relpath"
      fi
    done < <(cd "$baseline" && find . -type f -print)
  fi
  : > "$plan_log"
  set -- "$BOOTSTRAP_SCRIPT_PATH" --target "$tmp_target" --project-name "$PROJECT_NAME" --workflow "$WORKFLOW_PRESET" --no-backup
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    set -- "$@" "$arg"
  done < <(optional_skill_generation_args)
  if ! AGENT_BOOTSTRAP_PLAN_LOG="$plan_log" "$@" >"$tmp_root/generate.out" 2>&1; then
    cat "$tmp_root/generate.out" >&2
    return 1
  fi
  python3 - "$TARGET_DIR" "$plan_log" "$AGENT_BOOTSTRAP_VERSION" "$(read_lock_value version)" "$WORKFLOW_PRESET" \
    "$([[ -d "$baseline" ]] && printf present || printf missing)" <<'PY'
import collections
import json
import os
import sys

target, plan_log, bundle, installed, workflow, baseline = sys.argv[1:7]
actions = {}
with open(plan_log, encoding="utf-8") as handle:
    for line in handle:
        action, rel = line.rstrip("\n").split("\t", 1)
        if rel.startswith(".tools/") or ".generated." in rel:
            continue
        actions.setdefault(rel, action)
files = []
for rel in sorted(actions):
    action = actions[rel]
    real = os.path.join(target, rel)
    if action == "create" and (os.path.lexists(real)):
        action = "unsafe"
    files.append({"path": rel, "action": action})
print(json.dumps({
    "schema": "agent-bootstrap-upgrade-plan/v1",
    "target": target,
    "bundle_version": bundle,
    "installed_version": installed,
    "workflow_preset": workflow,
    "baseline": baseline,
    "counts": dict(sorted(collections.Counter(item["action"] for item in files).items())),
    "files": files,
}, indent=2))
PY
)

rollback_upgrade() {
  local id="$1" upgrades jdir
  upgrades="$TARGET_DIR/$HARNESS_BASELINE_DIR/upgrades"
  jdir="$upgrades/$id"
  if [[ ! "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || [[ ! -f "$jdir/journal.tsv" ]] || ! harness_state_path_is_safe "$jdir/journal.tsv"; then
    printf 'ERROR: no upgrade journal for %s\n' "$id" >&2
    if [[ -d "$upgrades" ]] && harness_state_path_is_safe "$upgrades"; then
      printf 'Available upgrade ids: %s\n' "$(cd "$upgrades" && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | sed 's|^\./||' | sort | tr '\n' ' ')" >&2
    fi
    return 1
  fi
  if [[ -e "$jdir/rolled-back" ]]; then
    printf 'ERROR: upgrade %s was already rolled back\n' "$id" >&2
    return 1
  fi
  python3 - "$TARGET_DIR" "$jdir" "$TARGET_DIR/$HARNESS_BASELINE_DIR/files" "$id" <<'PY'
import hashlib
import os
import shutil
import sys

root, jdir, baseline, upgrade_id = sys.argv[1:5]
root = os.path.abspath(root)


def safe(path):
    """Inside the root with no linked component below it."""
    path = os.path.abspath(path)
    if os.path.commonpath([root, path]) != root:
        return False
    current = root
    for part in os.path.relpath(path, root).split(os.sep):
        current = os.path.join(current, part)
        if os.path.islink(current):
            return False
    return True


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


restored = kept = 0
with open(os.path.join(jdir, "journal.tsv"), encoding="utf-8") as handle:
    rows = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
for action, rel, post in reversed(rows):
    path = os.path.join(root, rel)
    if not safe(path) or (os.path.lexists(path) and not os.path.isfile(path)):
        print(f"kept {rel}: not a safe regular file")
        kept += 1
        continue
    present = os.path.exists(path)
    if action in ("create", "candidate") and not present:
        print(f"already absent {rel}")
        restored += 1
    elif (digest(path) if present else "-") != post:
        print(f"kept {rel}: changed after the upgrade")
        kept += 1
        continue
    elif action in ("create", "candidate"):
        os.remove(path)
        print(f"removed {rel}")
        restored += 1
    else:
        pre = os.path.join(jdir, "pre", rel)
        if not os.path.isfile(pre) or os.path.islink(pre):
            print(f"kept {rel}: no saved copy")
            kept += 1
            continue
        staged = f"{path}.rollback.{os.getpid()}"
        shutil.copy2(pre, staged)
        os.replace(staged, path)
        print(f"restored {rel}")
        restored += 1
    if action == "candidate":
        continue
    previous = os.path.join(jdir, "base-pre", rel)
    current = os.path.join(baseline, rel)
    if not safe(current):
        continue
    if os.path.isfile(previous) and not os.path.islink(previous):
        os.makedirs(os.path.dirname(current), exist_ok=True)
        shutil.copy2(previous, current)
    elif os.path.isfile(current):
        os.remove(current)
with open(os.path.join(jdir, "rolled-back"), "w", encoding="utf-8") as handle:
    handle.write(f"restored={restored} kept={kept}\n")
print(f"Rollback {upgrade_id}: {restored} restored, {kept} kept")
sys.exit(3 if kept else 0)
PY
}

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
  printf 'Per-file plan (update, merge, conflict, kept) as JSON:\n'
  printf '  bash %s --target %s --upgrade-plan --json\n' "$BOOTSTRAP_SCRIPT_PATH" "$(shell_quote "$TARGET_DIR")"
  printf 'Undo an upgrade by the id it printed:\n'
  printf '  bash %s --target %s --rollback <upgrade-id>\n' "$BOOTSTRAP_SCRIPT_PATH" "$(shell_quote "$TARGET_DIR")"
  if optional_skill_installed mobile-optimization; then
    printf '\n'
    printf 'Optional skills installed from lock:\n'
    printf '  mobile-optimization: installed; default update preserves content and pointer, use --add-skill mobile-optimization to upgrade reviewed skill files.\n'
  fi
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
  load_installed_optional_skills
  validate_requested_optional_skills
  case "$ACTION" in
    status)
      if [[ "$JSON_OUTPUT" == "true" && "$STATUS_VERSION" == "2" ]]; then
        local status_json
        status_json="$(print_status)"
        printf '%s\n' "$status_json" |
          python3 "$LIB_DIR/retirement.py" status-v2 --target "$TARGET_DIR" --scope "$RETIREMENT_SCOPE" || exit $?
        exit 0
      fi
      print_status
      # Status JSON v1 stays byte-for-byte unchanged and retirement-blind.
      [[ "$JSON_OUTPUT" == "true" ]] || print_retirement_section status || exit $?
      exit 0
      ;;
    first-10)
      print_first_10
      exit 0
      ;;
    diff)
      print_generated_diff
      print_retirement_section diff || exit $?
      exit 0
      ;;
    upgrade-plan)
      if [[ "$JSON_OUTPUT" == "true" ]]; then
        print_upgrade_plan_json
        exit $?
      fi
      print_upgrade_plan
      print_retirement_section upgrade-plan || exit $?
      exit 0
      ;;
    rollback)
      rollback_upgrade "$ROLLBACK_ID"
      exit $?
      ;;
    apply-candidates)
      apply_generated_candidates
      print_retirement_section apply-candidates || exit $?
      exit 0
      ;;
    cleanup-backups)
      cleanup_backups
      print_retirement_section cleanup-backups || exit $?
      exit 0
      ;;
  esac

  log "Target: $TARGET_DIR"
  log "Project: $PROJECT_NAME"
  log "Detected stacks: ${TECH_STACKS[*]}"
  log "Detected modules: ${MODULES[*]}"

  if [[ "$REFRESH_LOCK" == "true" ]]; then
    write_agent_bootstrap_lock
    harness_journal_finalize
    log "Refreshed docs/agent-configs/agent-bootstrap.lock.json."
    exit 0
  fi

  if workflow_enabled; then
    write_agent_seats
    seed_agent_seats
    write_agent_docs
  else
    write_infra_agent_docs
  fi
  write_agent_bootstrap_lock
  write_template_catalog
  write_skill_mobile_optimization
  write_recovery_runbook
  write_schema_model_and_provenance_catalog
  write_portable_enforcement
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
    write_task_journal_doc
    write_tool_entrypoints
    write_codex_files
  else
    write_infra_tool_entrypoints
  fi
  append_gitignore_block
  harness_journal_finalize

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
  print_retirement_section generate || exit $?
}

main
