#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_URL="https://github.com/PhanHug93/harness-kit.git"
DEFAULT_REF="v2026.10.13.2"

REPO_URL="${HARNESS_KIT_REPO_URL:-$DEFAULT_REPO_URL}"
REF="${HARNESS_KIT_REF:-$DEFAULT_REF}"
CACHE_DIR="${HARNESS_KIT_CACHE_DIR:-$HOME/dev/harness-kit}"
HOME_DIR="${AGENT_BOOTSTRAP_HOME:-$HOME/dev/agent-bootstrap}"
TARGET_DIR="$(pwd -P)"
DEFAULT_BRANCH_NAME="feature/upgrade-harness-kit"
BRANCH_NAME="$DEFAULT_BRANCH_NAME"
WORKFLOW=""
SOURCE_DIR=""
ALLOW_DIRTY=false
APPLY_CANDIDATES=false
DRY_RUN=false
NO_BRANCH=false
SKIP_VERIFY=false
APPLY_RETIREMENTS=false
RETIREMENT_SCOPE=""

usage() {
  cat <<'HELP'
Usage: harness-kit-one-shot-upgrade.sh [options]

Safely install a pinned harness-kit release and run a non-destructive harness
upgrade in the target project. By default this script creates an upgrade branch,
generates *.generated.* candidates for conflicts, and does NOT apply candidates.

Options:
  --repo URL             Harness-kit Git repo. Defaults to https://github.com/PhanHug93/harness-kit.git.
  --ref REF              Harness-kit ref/tag. Defaults to v2026.10.13.2.
  --cache-dir DIR        Local source clone/cache. Defaults to $HOME/dev/harness-kit.
  --source-dir DIR       Use an existing harness-kit checkout instead of cloning/fetching.
  --home DIR             Canonical harness home. Defaults to $AGENT_BOOTSTRAP_HOME or $HOME/dev/agent-bootstrap.
  --target DIR           Project to upgrade. Defaults to the current directory.
  --branch NAME          Upgrade branch to create/switch to. Defaults to feature/upgrade-harness-kit.
  --workflow PRESET      infra or full. Defaults to the installed workflow, or full
                         for projects without a harness lock.
  --allow-dirty          Continue even when the target Git worktree has uncommitted changes.
  --no-branch            Do not create or switch branches.
  --apply-candidates     Promote reviewed bootstrap *.generated.* candidates after generation.
  --apply-retirements    After generation (and candidates), remove exact retired harness
                         files with mandatory verified backups. Never implied by other flags.
  --retirement-scope S   local-only (default) or all-matching for the retirement plan/apply.
  --skip-verify          Skip generated runtime verification commands.
  --dry-run              Print the planned operations and a retirement plan from an already
                         available local source (--source-dir or a matching cache) without
                         fetching, installing, switching branches or writing.
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
    --workflow)
      WORKFLOW="${2:?missing value for --workflow}"
      case "$WORKFLOW" in
        infra|full) ;;
        *) fail "--workflow must be infra or full" ;;
      esac
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
    --apply-retirements)
      APPLY_RETIREMENTS=true
      shift
      ;;
    --retirement-scope)
      case "${2:-}" in
        local-only|all-matching) RETIREMENT_SCOPE="$2" ;;
        *) printf 'one-shot: ERROR: --retirement-scope must be local-only or all-matching\n' >&2; exit 2 ;;
      esac
      shift 2
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

if [[ "$NO_BRANCH" == true && "$BRANCH_NAME" != "$DEFAULT_BRANCH_NAME" ]]; then
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

retirement_scope_args=()
if [[ -n "$RETIREMENT_SCOPE" ]]; then
  retirement_scope_args=(--retirement-scope "$RETIREMENT_SCOPE")
fi

# Dry-run plans retirements only from an already available local source: an
# explicit --source-dir, or a cache checkout already at the requested ref. It
# never fetches, clones, checks out, installs, creates home/cache directories,
# switches branches, generates or verifies.
dry_run_source() {
  local head wanted
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -x "$SOURCE_DIR/agent-bootstrap/install-agent-bootstrap-home.sh" ]] ||
      fail "--source-dir is missing agent-bootstrap/install-agent-bootstrap-home.sh"
    printf '%s\n' "$SOURCE_DIR"
    return 0
  fi
  [[ -d "$CACHE_DIR/.git" ]] || return 1
  head="$(git -C "$CACHE_DIR" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1
  wanted="$(git -C "$CACHE_DIR" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)" || return 1
  [[ -n "$head" && "$head" == "$wanted" ]] || return 1
  printf '%s\n' "$CACHE_DIR"
}

if [[ "$DRY_RUN" == true ]]; then
  git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "target is not inside a Git worktree: $TARGET_DIR"
  plan_target="$(git -C "$TARGET_DIR" rev-parse --show-toplevel)"
  log "target_git_root=$plan_target"
  plan_source="$(dry_run_source)" || plan_source=""
  plan_bundle="$plan_source/agent-bootstrap"
  if [[ -z "$plan_source" || ! -f "$plan_bundle/bootstrap-multi-agent-project.sh" ||
    ! -f "$plan_bundle/lib/retirement.py" || ! -f "$plan_bundle/policies/retired-artifacts-v1.json" ]]; then
    warn "retirement plan is unavailable: no validated local harness source for $REF that supports retirement plans; dry-run never fetches"
    warn "rerun with a local checkout of $REF: bash harness-kit-one-shot-upgrade.sh --dry-run --source-dir /path/to/harness-kit --target $(printf '%q' "$plan_target")"
    exit 1
  fi
  version="$(sed -n '1p' "$plan_bundle/VERSION" 2>/dev/null || true)"
  expected_version="$(version_from_ref)"
  if [[ -n "$expected_version" && "$version" != "$expected_version" ]]; then
    fail "source VERSION '$version' does not match requested ref '$REF' ($expected_version)"
  fi
  [[ -n "$version" ]] || fail "source VERSION is missing"
  log "source=$plan_source"
  log "version=$version"
  log "source_commit=$(git -C "$plan_source" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  log "retirement_policy_sha256=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$plan_bundle/policies/retired-artifacts-v1.json")"
  plan_action=(--retirement-plan)
  if [[ "$APPLY_RETIREMENTS" == true ]]; then
    plan_action=(--apply-retirements --dry-run)
  fi
  bash "$plan_bundle/bootstrap-multi-agent-project.sh" --target "$plan_target" "${plan_action[@]}" \
    ${retirement_scope_args[@]+"${retirement_scope_args[@]}"} ||
    fail "retirement plan reported an inspection error; nothing was written"
  log "DRY-RUN would install/update harness home and generate target candidates"
  if [[ "$APPLY_RETIREMENTS" == true ]]; then
    log "DRY-RUN would then apply the retirement plan above with mandatory backups"
  fi
  exit 0
fi

git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "target is not inside a Git worktree: $TARGET_DIR"
TARGET_DIR="$(git -C "$TARGET_DIR" rev-parse --show-toplevel)"
log "target_git_root=$TARGET_DIR"

installed_workflow() {
  # Lock content is read only when it resolves inside the target.
  python3 - "$TARGET_DIR" <<'PY' 2>/dev/null || true
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lock = root / "docs/agent-configs/agent-bootstrap.lock.json"
try:
    lock.resolve().relative_to(root)
    if not lock.is_file():
        sys.exit(0)
    doc = json.loads(lock.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
value = (doc.get("templates") or {}).get("workflow_preset") or doc.get("workflow_preset") or ""
print(value if value in ("infra", "full") else "")
PY
}

if [[ -n "$WORKFLOW" ]]; then
  log "workflow=$WORKFLOW (requested)"
else
  WORKFLOW="$(installed_workflow)"
  if [[ -n "$WORKFLOW" ]]; then
    log "workflow=$WORKFLOW (installed)"
  else
    WORKFLOW="full"
    log "workflow=full (no harness lock found)"
  fi
fi

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

run_bootstrap "status before generation" --status ${retirement_scope_args[@]+"${retirement_scope_args[@]}"}
run_bootstrap "upgrade plan" --upgrade-plan ${retirement_scope_args[@]+"${retirement_scope_args[@]}"}
if ! run_bootstrap "generated diff preview" --diff ${retirement_scope_args[@]+"${retirement_scope_args[@]}"}; then
  warn "generated diff preview failed; continuing because preview is informational"
fi
run_bootstrap "generating $WORKFLOW workflow candidates" --workflow "$WORKFLOW" \
  ${retirement_scope_args[@]+"${retirement_scope_args[@]}"}

if [[ "$APPLY_CANDIDATES" == true ]]; then
  run_bootstrap "applying reviewed generated candidates" --apply-candidates
else
  log "safe default: candidates were not auto-applied"
fi

# Retirement runs only on explicit request, after generation and candidates;
# the bootstrap rebuilds the plan at this apply boundary.
retirement_rc=0
if [[ "$APPLY_RETIREMENTS" == true ]]; then
  log "applying explicit retirements (fresh plan, mandatory verified backups)"
  bash "$bootstrap" --target "$TARGET_DIR" --apply-retirements \
    ${retirement_scope_args[@]+"${retirement_scope_args[@]}"} || retirement_rc=$?
  case "$retirement_rc" in
    0) ;;
    3) warn "retirement preserved modified, unsafe or out-of-scope files; review the report above" ;;
    *)
      warn "retirement apply failed (exit $retirement_rc); the partial outcome is reported above and backups are retained"
      fail "stopped before verification and status; earlier generation changes are not rolled back"
      ;;
  esac
else
  log "safe default: retired harness files were not removed"
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
4. Retired harness files listed in the retirement plan stay until you run:
   bash "$bootstrap" --target "$TARGET_DIR" --apply-retirements
5. Commit from the upgrade branch only after project tests/verifiers pass.
EOF

if [[ "$retirement_rc" -eq 3 ]]; then
  exit 3
fi
