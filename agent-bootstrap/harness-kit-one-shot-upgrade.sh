#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_URL="https://github.com/PhanHug93/harness-kit.git"
DEFAULT_REF="v2026.06.24.2"

REPO_URL="${HARNESS_KIT_REPO_URL:-$DEFAULT_REPO_URL}"
REF="${HARNESS_KIT_REF:-$DEFAULT_REF}"
CACHE_DIR="${HARNESS_KIT_CACHE_DIR:-$HOME/dev/harness-kit}"
HOME_DIR="${AGENT_BOOTSTRAP_HOME:-$HOME/dev/agent-bootstrap}"
TARGET_DIR="$(pwd -P)"
BRANCH_NAME="codex/upgrade-harness-kit"
SOURCE_DIR=""
ALLOW_DIRTY=false
APPLY_CANDIDATES=false
DRY_RUN=false
NO_BRANCH=false
SKIP_VERIFY=false

usage() {
  cat <<'HELP'
Usage: harness-kit-one-shot-upgrade.sh [options]

Safely install a pinned harness-kit release and run a non-destructive harness
upgrade in the target project. By default this script creates an upgrade branch,
generates *.generated.* candidates for conflicts, and does NOT apply candidates.

Options:
  --repo URL             Harness-kit Git repo. Defaults to https://github.com/PhanHug93/harness-kit.git.
  --ref REF              Harness-kit ref/tag. Defaults to v2026.06.24.2.
  --cache-dir DIR        Local source clone/cache. Defaults to $HOME/dev/harness-kit.
  --source-dir DIR       Use an existing harness-kit checkout instead of cloning/fetching.
  --home DIR             Canonical harness home. Defaults to $AGENT_BOOTSTRAP_HOME or $HOME/dev/agent-bootstrap.
  --target DIR           Project to upgrade. Defaults to the current directory.
  --branch NAME          Upgrade branch to create/switch to. Defaults to codex/upgrade-harness-kit.
  --allow-dirty          Continue even when the target Git worktree has uncommitted changes.
  --no-branch            Do not create or switch branches.
  --apply-candidates     Promote reviewed bootstrap *.generated.* candidates after generation.
  --skip-verify          Skip generated runtime verification commands.
  --dry-run              Print the planned source/home/target operations without writing.
  -h, --help             Show this help.
HELP
}

log() { printf 'one-shot: %s\n' "$*"; }
warn() { printf 'one-shot: WARN: %s\n' "$*" >&2; }
fail() { printf 'one-shot: ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

abs_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || fail "directory does not exist: $dir"
  (cd "$dir" && pwd -P)
}

version_from_ref() {
  case "$REF" in
    v[0-9]*.[0-9]*.[0-9]*.[0-9]*)
      printf '%s\n' "${REF#v}"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_URL="${2:?missing value for --repo}"
      shift 2
      ;;
    --ref)
      REF="${2:?missing value for --ref}"
      shift 2
      ;;
    --cache-dir)
      CACHE_DIR="${2:?missing value for --cache-dir}"
      shift 2
      ;;
    --source-dir)
      SOURCE_DIR="${2:?missing value for --source-dir}"
      shift 2
      ;;
    --home)
      HOME_DIR="${2:?missing value for --home}"
      shift 2
      ;;
    --target)
      TARGET_DIR="${2:?missing value for --target}"
      shift 2
      ;;
    --branch)
      BRANCH_NAME="${2:?missing value for --branch}"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    --no-branch)
      NO_BRANCH=true
      shift
      ;;
    --apply-candidates)
      APPLY_CANDIDATES=true
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

if [[ "$NO_BRANCH" == true && "$BRANCH_NAME" != "codex/upgrade-harness-kit" ]]; then
  fail "--branch cannot be combined with --no-branch"
fi

require_cmd git
require_cmd python3

TARGET_DIR="$(abs_dir "$TARGET_DIR")"
HOME_DIR="${HOME_DIR/#\~/$HOME}"
CACHE_DIR="${CACHE_DIR/#\~/$HOME}"
if [[ -n "$SOURCE_DIR" ]]; then
  SOURCE_DIR="$(abs_dir "$SOURCE_DIR")"
fi

log "harness-kit one-shot upgrade"
log "repo=$REPO_URL"
log "ref=$REF"
log "target=$TARGET_DIR"
log "home=$HOME_DIR"

if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN would install/update harness home and generate target candidates"
  exit 0
fi

git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "target is not inside a Git worktree: $TARGET_DIR"
TARGET_DIR="$(git -C "$TARGET_DIR" rev-parse --show-toplevel)"
log "target_git_root=$TARGET_DIR"

if [[ "$ALLOW_DIRTY" != true ]] && [[ -n "$(git -C "$TARGET_DIR" status --porcelain)" ]]; then
  git -C "$TARGET_DIR" status --short >&2
  fail "target worktree has uncommitted changes; commit/stash them or rerun with --allow-dirty"
fi

resolve_source() {
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -x "$SOURCE_DIR/agent-bootstrap/install-agent-bootstrap-home.sh" ]] ||
      fail "--source-dir is missing agent-bootstrap/install-agent-bootstrap-home.sh"
    printf '%s\n' "$SOURCE_DIR"
    return 0
  fi

  if [[ -e "$CACHE_DIR" && ! -d "$CACHE_DIR/.git" ]]; then
    fail "cache path exists but is not a Git checkout: $CACHE_DIR"
  fi

  if [[ -d "$CACHE_DIR/.git" ]]; then
    log "updating source cache: $CACHE_DIR" >&2
    git -C "$CACHE_DIR" fetch --tags "$REPO_URL"
  else
    log "cloning source cache: $CACHE_DIR" >&2
    mkdir -p "$(dirname "$CACHE_DIR")"
    git clone "$REPO_URL" "$CACHE_DIR"
    git -C "$CACHE_DIR" fetch --tags "$REPO_URL"
  fi

  git -C "$CACHE_DIR" -c advice.detachedHead=false checkout --quiet "$REF^{}"
  printf '%s\n' "$CACHE_DIR"
}

SOURCE_DIR="$(resolve_source)"
version="$(sed -n '1p' "$SOURCE_DIR/agent-bootstrap/VERSION" 2>/dev/null || true)"
expected_version="$(version_from_ref)"
if [[ -n "$expected_version" && "$version" != "$expected_version" ]]; then
  fail "source VERSION '$version' does not match requested ref '$REF' ($expected_version)"
fi
[[ -n "$version" ]] || fail "source VERSION is missing"
source_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
log "source=$SOURCE_DIR"
log "version=$version"
if [[ -n "$source_commit" ]]; then
  log "source_commit=$source_commit"
fi

install_cmd=(
  "$SOURCE_DIR/agent-bootstrap/install-agent-bootstrap-home.sh"
  --home "$HOME_DIR"
  --repo "$REPO_URL"
  --ref "$REF"
  --no-git
)
if [[ -n "$source_commit" ]]; then
  install_cmd+=(--commit "$source_commit")
fi
AGENT_BOOTSTRAP_HOME="$HOME_DIR" "${install_cmd[@]}"

bootstrap="$HOME_DIR/bootstrap-multi-agent-project.sh"
[[ -x "$bootstrap" ]] || fail "installed home is missing bootstrap entrypoint: $bootstrap"

if [[ "$NO_BRANCH" != true ]]; then
  current_branch="$(git -C "$TARGET_DIR" branch --show-current || true)"
  if [[ "$current_branch" != "$BRANCH_NAME" ]]; then
    if git -C "$TARGET_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
      log "switching to existing upgrade branch: $BRANCH_NAME"
      git -C "$TARGET_DIR" switch "$BRANCH_NAME"
    else
      log "creating upgrade branch: $BRANCH_NAME"
      git -C "$TARGET_DIR" switch -c "$BRANCH_NAME"
    fi
  else
    log "already on upgrade branch: $BRANCH_NAME"
  fi
fi

run_bootstrap() {
  local label="$1"
  shift
  log "$label"
  bash "$bootstrap" --target "$TARGET_DIR" "$@"
}

run_bootstrap "status before generation" --status
run_bootstrap "upgrade plan" --upgrade-plan
if ! run_bootstrap "generated diff preview" --diff; then
  warn "generated diff preview failed; continuing because preview is informational"
fi
run_bootstrap "generating full workflow candidates" --workflow full

if [[ "$APPLY_CANDIDATES" == true ]]; then
  run_bootstrap "applying reviewed generated candidates" --apply-candidates
else
  log "safe default: candidates were not auto-applied"
fi

if [[ "$SKIP_VERIFY" != true ]]; then
  if [[ -f "$TARGET_DIR/scripts/install-rtk.sh" ]]; then
    log "verify: bash scripts/install-rtk.sh"
    (cd "$TARGET_DIR" && bash scripts/install-rtk.sh)
  fi
  if [[ -x "$TARGET_DIR/scripts/agent-hook.sh" ]]; then
    log "verify: scripts/agent-hook.sh doctor"
    (cd "$TARGET_DIR" && scripts/agent-hook.sh doctor)
  fi
  if [[ -x "$TARGET_DIR/scripts/agent-guard.sh" ]]; then
    log "verify: scripts/agent-guard.sh preflight"
    (cd "$TARGET_DIR" && scripts/agent-guard.sh preflight)
  fi
  if [[ -x "$TARGET_DIR/scripts/agent-onboarding.sh" ]]; then
    log "verify: scripts/agent-onboarding.sh next"
    (cd "$TARGET_DIR" && scripts/agent-onboarding.sh next)
  fi
else
  log "verification skipped by --skip-verify"
fi

run_bootstrap "status after generation" --status --json

log "generated candidates:"
candidate_list="$(find "$TARGET_DIR" -path "$TARGET_DIR/.git" -prune -o -name '*.generated.*' -print | sort)"
if [[ -n "$candidate_list" ]]; then
  printf '%s\n' "$candidate_list"
else
  log "none"
fi

# Retrofit hint: overlay-enabled files that predate USER markers (no
# <!-- BEGIN USER --> region) but now have a candidate likely hold hand-merged
# custom content. Tell the operator to wrap it so it survives future upgrades.
overlay_retrofit=""
for overlay_file in AGENTS.md .codex/README.md docs/agent-configs/agent-mode-contracts.md; do
  [[ -f "$TARGET_DIR/$overlay_file" ]] || continue
  found_overlay_candidate=false
  for candidate_path in "$TARGET_DIR/$overlay_file".generated.*; do
    if [[ -e "$candidate_path" ]]; then
      found_overlay_candidate=true
      break
    fi
  done
  [[ "$found_overlay_candidate" == "true" ]] || continue
  if grep -Fq '<!-- BEGIN USER:' "$TARGET_DIR/$overlay_file"; then
    continue
  fi
  overlay_retrofit="$overlay_retrofit $overlay_file"
done
if [[ -n "$overlay_retrofit" ]]; then
  log "retrofit: wrap custom sections with <!-- BEGIN USER: <key> --> ... <!-- END USER: <key> --> before applying so they survive future upgrades:$overlay_retrofit"
fi

cat <<EOF

Next steps
1. Review generated candidates before applying them:
   find "$TARGET_DIR" -name '*.generated.*' -print
2. Merge repo-specific overlays manually where needed.
3. When reviewed, run:
   bash "$bootstrap" --target "$TARGET_DIR" --apply-candidates
4. Commit from the upgrade branch only after project tests/verifiers pass.
EOF
