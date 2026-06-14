#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="$(pwd -P)"
PROJECT_NAME="$(basename "$TARGET_DIR")"
STAMP="$(date +%Y%m%d-%H%M%S)"
AGENT_BOOTSTRAP_VERSION="2026.06.14.6"
AGENT_BOOTSTRAP_CHANNEL="stable"
RTK_VERSION="0.37.2"
WORKFLOW_PRESET="infra"
WORKFLOW_EXPLICIT=false
DRY_RUN=false
BACKUP=true
FORCE=false
CANDIDATE_ON_CONFLICT=true
REFRESH_LOCK=false
LAST_WRITTEN_FILE=""

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib"
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
    "  --workflow PRESET    Optional workflow philosophy: infra or full." \
    "  --no-backup          Overwrite existing generated files without .bak copy." \
    "  --version            Print bootstrap version." \
    "  -h, --help           Show help."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="${2:?missing value for --project-name}"
      shift 2
      ;;
    --target)
      TARGET_DIR="$(cd "${2:?missing value for --target}" && pwd -P)"
      PROJECT_NAME="$(basename "$TARGET_DIR")"
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

if [[ "$REFRESH_LOCK" == "true" && "$WORKFLOW_EXPLICIT" == "false" ]]; then
  existing_lock="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  if [[ -f "$existing_lock" ]]; then
    existing_workflow="$(
      sed -n 's/^[[:space:]]*"workflow_preset"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$existing_lock" |
        head -n1
    )"
    [[ -n "$existing_workflow" ]] && WORKFLOW_PRESET="$existing_workflow"
  fi
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

main() {
  detect_tech_stack
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
  write_agentmemory_skill
  write_rtk_tools
  write_tech_stack_lib
  write_runtime_detector
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
}

main
