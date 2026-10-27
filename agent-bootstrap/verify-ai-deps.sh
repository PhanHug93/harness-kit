#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

WORKFLOW_PRESET="full"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
WARN=0
OUTPUT_JSON=false
BUDGET_ONLY=false
CHECKS=()
CONTEXT_BUDGET_JSON=""

usage() {
  printf '%s\n' "Usage: scripts/verify-ai-deps.sh [--json] [--context-budget]" \
    "  --context-budget  run only the context budget check (core startup and on-demand)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --context-budget)
      BUDGET_ONLY=true
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
  printf ']'
  if [[ -n "$CONTEXT_BUDGET_JSON" ]]; then
    printf ',"context_budget":%s' "$CONTEXT_BUDGET_JSON"
  fi
  printf '}\n'
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
    scripts/agent-*.sh|scripts/agent-tier.py|scripts/detect-agent-tech-stack.sh|scripts/install-rtk.sh|scripts/rtk|scripts/verify-ai-deps.sh)
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
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" "$key" <<'PY' 2>/dev/null || true
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

token_estimate() {  # <words> <bytes>: the larger of bytes/4 and words*1.3
  awk -v words="$1" -v chars="$2" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

estimate_tokens_for_file() {
  local path="$1"
  local words="0"
  local chars="0"
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  read -r words chars < <(LC_ALL=C wc -w -c < "$path")
  token_estimate "$words" "$chars"
}

# Project content is the user's: the user-owned files below, and in any other
# counted file the body of each <!-- BEGIN USER: ... --> region and of each
# detector-filled managed block (stacks, modules, verification commands,
# warnings). The rest, marker lines included, is kit text.
BUDGET_USER_OWNED_FILES=" docs/agent-configs/project-brief.md docs/agent-configs/project-agent-context.md "

# Prints "<kit> <project>" token estimates for one counted file.
split_file_estimate() {
  local relpath="$1"
  local path="$ROOT_DIR/$1"
  if [[ ! -f "$path" ]]; then
    printf '0 0\n'
    return 0
  fi
  if [[ "$BUDGET_USER_OWNED_FILES" == *" $relpath "* ]]; then
    printf '0 %s\n' "$(estimate_tokens_for_file "$path")"
    return 0
  fi
  LC_ALL=C awk '
    function est(b, w) { b = b / 4; w = w * 1.3; return int(b > w ? b : w) }
    /<!-- BEGIN (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 1; next }
    /<!-- END (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 0; next }
    user { pb += length($0) + 1; pw += NF; next }
    { kb += length($0) + 1; kw += NF }
    END { printf "%d %d\n", est(kb, kw), est(pb, pw) }
  ' "$path"
}

# Prints "<kit><TAB><project><TAB><heading text>" for each ## or ### section of a
# Markdown file; a section runs to the next such heading outside a code fence.
markdown_section_estimates() {
  [[ -f "$1" ]] || return 0
  LC_ALL=C awk '
    function est(b, w) { b = b / 4; w = w * 1.3; return int(b > w ? b : w) }
    function flush() { if (name != "") printf "%d\t%d\t%s\n", est(kb, kw), est(pb, pw), name }
    /^```/ { fence = !fence }
    !fence && /^###? / { flush(); name = $0; sub(/^#+ /, "", name); kb = 0; kw = 0; pb = 0; pw = 0 }
    name == "" { next }
    /<!-- BEGIN (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 1; next }
    /<!-- END (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 0; next }
    user { pb += length($0) + 1; pw += NF; next }
    { kb += length($0) + 1; kw += NF }
    END { flush() }
  ' "$1"
}

budget_status() {  # <estimate> <amber> <gate>
  if [[ "$1" -gt "$3" ]]; then
    printf 'over'
  elif [[ "$1" -gt "$2" ]]; then
    printf 'amber'
  else
    printf 'ok'
  fi
}

# Prints the largest project parts as "path N, path N" (at most three).
largest_project_parts() {
  [[ $# -gt 0 ]] || return 0
  printf '%s\n' "$@" | sort -t "$(printf '\t')" -k1,1nr | head -3 |
    awk -F '\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'
}

# The total (kit + project) only warns: project content is the user's to shorten.
# Kit text above a gate is an error.
report_budget() {  # <label> <total> <kit> <amber> <gate> <status> <kit status> [project part...]
  local label="$1" total="$2" kit="$3" amber="$4" gate="$5" status="$6" kit_status="$7" parts
  shift 7
  case "$status" in
    over)
      parts="$(largest_project_parts "$@")"
      warn "$label: $total tokens exceeds gate $gate${parts:+; project content is yours to shorten: $parts}"
      ;;
    amber) warn "$label: $total tokens (gate $gate, amber above $amber); measure after any edit to a counted file" ;;
    *) ok "$label: $total tokens (gate $gate, amber above $amber)" ;;
  esac
  case "$kit_status" in
    over) bad "kit $label: $kit tokens exceeds gate $gate" ;;
    amber) warn "kit $label: $kit tokens (gate $gate, amber above $amber); measure after any edit to a counted file" ;;
    *) ok "kit $label: $kit tokens (gate $gate, amber above $amber)" ;;
  esac
}

budget_json() {  # <total> <kit> <project> <amber> <gate> <status> <kit status>
  printf '"estimate":%s,"kit":%s,"project":%s,"amber":%s,"gate":%s,"status":"%s","kit_status":"%s"' "$@"
}

# Core startup: what every seat reads first. On demand: core plus the workflow
# docs and, from the handoff reference, its State values section and the largest
# other section (a seat reads those two, not the whole reference).
check_context_budget() {
  local reference="$ROOT_DIR/docs/agent-configs/agent-handoff-reference.md"
  local relpath kit project label tab
  local core_kit=0 core_project=0 od_kit=0 od_project=0
  local state_kit=0 state_project=0 largest_kit=0 largest_project=0 largest_name=""
  local section_kit section_project section_name sections_json=""
  local core_total od_total core_status core_kit_status od_status od_kit_status
  local core_parts=() od_parts=()
  tab="$(printf '\t')"
  for relpath in \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md; do
    read -r kit project < <(split_file_estimate "$relpath")
    label="$relpath"
    if [[ "$BUDGET_USER_OWNED_FILES" != *" $relpath "* ]]; then
      label="$relpath (USER and detected blocks)"
    fi
    case "$relpath" in
      AGENTS.md|docs/agent-configs/project-agent-context.md|docs/agent-configs/project-brief.md)
        core_kit=$((core_kit + kit))
        core_project=$((core_project + project))
        if [[ "$project" -gt 0 ]]; then
          core_parts+=("$project$tab$label")
        fi
        ;;
    esac
    od_kit=$((od_kit + kit))
    od_project=$((od_project + project))
    if [[ "$project" -gt 0 ]]; then
      od_parts+=("$project$tab$label")
    fi
  done
  while IFS="$tab" read -r section_kit section_project section_name; do
    if [[ "$section_name" == "State values" ]]; then
      state_kit="$section_kit"
      state_project="$section_project"
    elif [[ $((section_kit + section_project)) -gt $((largest_kit + largest_project)) ]]; then
      largest_kit="$section_kit"
      largest_project="$section_project"
      largest_name="$section_name"
    fi
  done < <(markdown_section_estimates "$reference")
  od_kit=$((od_kit + state_kit + largest_kit))
  od_project=$((od_project + state_project + largest_project))
  if [[ $((state_project + largest_project)) -gt 0 ]]; then
    od_parts+=("$((state_project + largest_project))${tab}docs/agent-configs/agent-handoff-reference.md (USER and detected blocks)")
  fi
  core_total=$((core_kit + core_project))
  od_total=$((od_kit + od_project))
  core_status="$(budget_status "$core_total" 3800 4000)"
  core_kit_status="$(budget_status "$core_kit" 3800 4000)"
  od_status="$(budget_status "$od_total" 5900 6200)"
  od_kit_status="$(budget_status "$od_kit" 5900 6200)"

  report_budget "core startup context estimate" "$core_total" "$core_kit" 3800 4000 \
    "$core_status" "$core_kit_status" ${core_parts[@]+"${core_parts[@]}"}
  report_budget "on-demand full workflow context estimate" "$od_total" "$od_kit" 5900 6200 \
    "$od_status" "$od_kit_status" ${od_parts[@]+"${od_parts[@]}"}

  if [[ $((state_kit + state_project)) -gt 0 ]]; then
    sections_json='"State values"'
  fi
  if [[ -n "$largest_name" ]]; then
    sections_json="${sections_json:+$sections_json,}\"$(json_escape "$largest_name")\""
  fi
  # Tiers: small reads the core files, medium adds tier-medium.md (reported
  # only, no gate), large reads what on-demand counts (never tier-medium.md).
  local med_kit med_project med_total
  read -r med_kit med_project < <(split_file_estimate docs/agent-configs/tier-medium.md)
  med_kit=$((core_kit + med_kit))
  med_project=$((core_project + med_project))
  med_total=$((med_kit + med_project))
  ok "context tiers: small $core_total, medium $med_total (reported only), large $od_total tokens"
  CONTEXT_BUDGET_JSON="{\"core\":{$(budget_json "$core_total" "$core_kit" "$core_project" 3800 4000 "$core_status" "$core_kit_status")},\"on_demand\":{$(budget_json "$od_total" "$od_kit" "$od_project" 5900 6200 "$od_status" "$od_kit_status"),\"reference_sections\":[$sections_json]},\"tiers\":{\"small\":{$(budget_json "$core_total" "$core_kit" "$core_project" 3800 4000 "$core_status" "$core_kit_status")},\"medium\":{\"estimate\":$med_total,\"kit\":$med_kit,\"project\":$med_project},\"large\":{$(budget_json "$od_total" "$od_kit" "$od_project" 5900 6200 "$od_status" "$od_kit_status")}}}"
}

finish_report() {
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    emit_json_report
  else
    printf '\nPass: %s  Warn: %s  Fail: %s\n' "$PASS" "$WARN" "$FAIL"
  fi
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
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
        ) + tuple(
            key
            for key in ("tier_rules", "risk_tokens", "risk_paths", "dependency_manifests", "dependency_locks", "test_patterns",
                        "binary_asset_extensions")
            if key in context_policy
        ),
        "context policy",
    )
    def string_list(value):
        return isinstance(value, list) and all(non_empty_string(entry) for entry in value)
    if "tier_rules" in context_policy:
        tier_rules = context_policy.get("tier_rules")
        require(isinstance(tier_rules, dict) and set(tier_rules) == {"small", "medium"}, "context policy tier_rules must be an object with small and medium")
        if isinstance(tier_rules, dict):
            for tier_name in ("small", "medium"):
                limits = tier_rules.get(tier_name)
                require(
                    isinstance(limits, dict)
                    and set(limits) == {"max_files", "max_lines"}
                    and all(isinstance(limits[key], int) and not isinstance(limits[key], bool) and limits[key] >= 0 for key in limits),
                    f"context policy tier_rules.{tier_name} must have integer max_files and max_lines",
                )
    for list_key in ("risk_tokens", "risk_paths", "dependency_manifests", "dependency_locks", "binary_asset_extensions"):
        if list_key in context_policy:
            require(string_list(context_policy.get(list_key)), f"context policy {list_key} must be an array of non-empty strings")
    if string_list(context_policy.get("binary_asset_extensions")):
        require(all(re.fullmatch(r"\.?[A-Za-z0-9][A-Za-z0-9_+-]*", entry) for entry in context_policy["binary_asset_extensions"]),
                "context policy binary_asset_extensions must hold extensions like png")
    if "test_patterns" in context_policy:
        test_patterns = context_policy.get("test_patterns")
        require(
            isinstance(test_patterns, dict) and set(test_patterns) == {"dirs", "names"} and all(string_list(value) for value in test_patterns.values()),
            "context policy test_patterns must have dirs and names arrays of non-empty strings",
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
    "agent-seats-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-seats-v1.schema.json",
    "agent-project-tech-stack-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-project-tech-stack-v1.schema.json",
    "agent-bootstrap-lock-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-lock-v1.schema.json",
    "agent-bootstrap-status-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-status-v1.schema.json",
    "agent-bootstrap-verify-report-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-verify-report-v1.schema.json",
    "agent-guard-event-v2.schema.json": "https://agent-bootstrap.local/schemas/agent-guard-event-v2.schema.json",
    "agent-guard-verification-v2.schema.json": "https://agent-bootstrap.local/schemas/agent-guard-verification-v2.schema.json",
    "harness-project-knowledge-v1.schema.json": "https://agent-bootstrap.local/schemas/harness-project-knowledge-v1.schema.json",
    "harness-kit-run-report-v1.schema.json": "https://agent-bootstrap.local/schemas/harness-kit-run-report-v1.schema.json",
    "harness-tier-v1.schema.json": "https://agent-bootstrap.local/schemas/harness-tier-v1.schema.json",
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
import re
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
        ) + tuple(key for key in ("toolchain", "risk_paths", "binary_asset_extensions") if key in doc),
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
                require_exact_keys(item, ("command", "purpose", "source") + (("scope",) if "scope" in item else ()), f"project tech-stack verification[{index}]")
                if "scope" in item:
                    require(item.get("scope") in ("fast", "full"), f"project tech-stack verification[{index}].scope must be fast or full")
                for key in ("command", "purpose", "source"):
                    require(non_empty_string(item.get(key)), f"project tech-stack verification[{index}].{key} must be a non-empty string")
    if "toolchain" in doc:
        toolchain = doc.get("toolchain")
        require(isinstance(toolchain, list) and all(non_empty_string(entry) for entry in toolchain), "project tech-stack toolchain must be an array of non-empty strings")
    if "risk_paths" in doc:
        risk_paths = doc.get("risk_paths")
        require(isinstance(risk_paths, list) and all(non_empty_string(entry) for entry in risk_paths), "project tech-stack risk_paths must be an array of non-empty strings")
    if "binary_asset_extensions" in doc:
        assets = doc.get("binary_asset_extensions")
        require(isinstance(assets, list) and all(non_empty_string(entry) for entry in assets), "project tech-stack binary_asset_extensions must be an array of non-empty strings")
        if isinstance(assets, list) and all(non_empty_string(entry) for entry in assets):
            require(all(re.fullmatch(r"\.?[A-Za-z0-9][A-Za-z0-9_+-]*", entry) for entry in assets),
                    "project tech-stack binary_asset_extensions must hold extensions like png")
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

if [[ "$BUDGET_ONLY" == "true" ]]; then
  if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
    check_context_budget
  else
    ok "workflow preset is infra-only; no context budget applies"
  fi
  finish_report
fi

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
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256 \
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

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if [[ -e "$ROOT_DIR/docs/agent-configs/seats.json" ]]; then
    if [[ -x "$ROOT_DIR/scripts/agent-seats.sh" ]] && "$ROOT_DIR/scripts/agent-seats.sh" validate >/dev/null 2>&1; then
      ok "seats.json is valid"
    else
      bad "seats.json is invalid"
    fi
  else
    warn "seats.json is missing; run scripts/agent-seats.sh init"
  fi

  if [[ -e "$ROOT_DIR/docs/agent-configs/model-profiles.json" ]]; then
    warn "inactive legacy model-profiles.json is present; seats.json is authoritative"
    if python3 -m json.tool "$ROOT_DIR/docs/agent-configs/model-profiles.json" >/dev/null 2>&1; then
      ok "inactive legacy model profile JSON parses"
    else
      warn "inactive legacy model profile JSON is malformed; seats.json is authoritative"
    fi
  fi
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
  if python3 -m json.tool "$ROOT_DIR/docs/agent-configs/context-policy.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-event-v2.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-verification-v2.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-project-knowledge-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-kit-run-report-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-tier-v1.schema.json" >/dev/null 2>&1; then
    ok "schema JSON parses"
  else
    bad "schema JSON is invalid"
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
  docs/agent-configs/tier-medium.md \
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
need_executable scripts/agent-tier.py
need_executable scripts/agent-local-only-check.sh
need_executable scripts/harness-kit.sh
need_executable scripts/detect-agent-tech-stack.sh
need_executable scripts/verify-ai-deps.sh

need_bash_syntax scripts/install-rtk.sh
need_bash_syntax scripts/rtk
need_bash_syntax scripts/agent-tech-stack-lib.sh
need_bash_syntax scripts/agent-hook.sh
need_bash_syntax scripts/agent-guard.sh
need_bash_syntax scripts/agent-local-only-check.sh
need_bash_syntax scripts/harness-kit.sh
need_bash_syntax scripts/detect-agent-tech-stack.sh
need_bash_syntax scripts/verify-ai-deps.sh
if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  need_executable scripts/agent-seats.sh
  need_bash_syntax scripts/agent-seats.sh
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

# The hook path may also start at "$CLAUDE_PROJECT_DIR", which keeps it working
# after the agent changes directory.
if grep -Eq '(\./|[$][{]?CLAUDE_PROJECT_DIR[}]?(\\")?/)scripts/agent-hook\.sh(\\")? claude-pretool' "$ROOT_DIR/.claude/settings.json"; then
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
  if codex_doctor_out="$("$ROOT_DIR/.codex/codex-mode.sh" doctor 2>&1)"; then
    ok "Codex helper doctor passes"
  else
    codex_candidate="$(find "$ROOT_DIR/.codex" -name '*.generated.*' -print 2>/dev/null | head -1)"
    if [[ -n "$codex_candidate" && ! -w "$ROOT_DIR/.codex" ]]; then
      warn "Codex helper doctor skipped: read-only .codex candidate unapplied (${codex_candidate#"$ROOT_DIR"/}); promote with write access"
    else
      # Name the doctor's first failure so the reader need not rerun it.
      codex_doctor_reason=""
      while IFS= read -r codex_doctor_line; do
        if [[ "$codex_doctor_line" == "  FAIL  "* ]]; then
          codex_doctor_reason="${codex_doctor_line#"  FAIL  "}"
          break
        fi
      done <<<"$codex_doctor_out"
      bad "Codex helper doctor failed${codex_doctor_reason:+: $codex_doctor_reason}"
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
fi

finish_report
