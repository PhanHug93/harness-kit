#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOME_DIR="${AGENT_BOOTSTRAP_HOME:-$SCRIPT_DIR}"
REPO_URL=""
TARGET_DIR=""
ACTION="check"
JSON_OUTPUT=false
DRY_RUN=false
SELF_UPDATE_TMP_ROOT=""

usage() {
  cat <<'HELP'
Usage: agent-bootstrap-update.sh [options]

Check for newer harness releases in Git, refresh the canonical harness home,
and delegate project-local upgrade planning/application to the bootstrap
generator.

Options:
  --home DIR       Canonical harness home. Defaults to $AGENT_BOOTSTRAP_HOME or this script's directory.
  --repo URL       Git repository URL/path that publishes vYYYY.MM.DD.N tags.
  --check          Print upstream update status. This is the default action.
  --self-update    Refresh the canonical home from the latest remote release tag.
  --target DIR     Target project for --plan or --apply.
  --plan           Print update status and the target upgrade plan.
  --apply          Generate target changes non-destructively using the current home bundle.
  --json           Machine-readable output for --check.
  --dry-run        Print planned self-update without writing.
  -h, --help       Show this help.
HELP
}

fail() {
  printf 'agent-bootstrap-update: ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup_self_update_tmp() {
  if [[ -n "${SELF_UPDATE_TMP_ROOT:-}" ]]; then
    rm -rf "$SELF_UPDATE_TMP_ROOT"
  fi
}

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
  else
    sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
}

read_json_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
key = sys.argv[2]

try:
    doc = json.loads(open(path, "r", encoding="utf-8").read())
except Exception:
    sys.exit(0)

value = doc.get(key, "")
if isinstance(value, (str, int, float)):
    print(value)
elif isinstance(value, bool):
    print("true" if value else "false")
PY
}

current_version() {
  sed -n '1p' "$HOME_DIR/VERSION" 2>/dev/null || printf 'missing\n'
}

resolve_repo_url() {
  if [[ -n "$REPO_URL" ]]; then
    printf '%s\n' "$REPO_URL"
    return 0
  fi
  local metadata_repo
  metadata_repo="$(read_json_value "$HOME_DIR/SOURCE.json" repo_url)"
  if [[ -n "$metadata_repo" ]]; then
    printf '%s\n' "$metadata_repo"
    return 0
  fi
  if git -C "$HOME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$HOME_DIR" config --get remote.origin.url || true
    return 0
  fi
}

latest_remote_release() {
  local repo="$1"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for update checks"
  python3 - "$repo" <<'PY'
import re
import subprocess
import sys

repo = sys.argv[1]

try:
    out = subprocess.check_output(
        ["git", "ls-remote", "--tags", repo, "v*"],
        stderr=subprocess.PIPE,
        text=True,
    )
except subprocess.CalledProcessError as exc:
    sys.stderr.write(exc.stderr)
    sys.exit(exc.returncode)

records = {}
for line in out.splitlines():
    parts = line.split()
    if len(parts) != 2:
        continue
    sha, ref = parts
    peeled = ref.endswith("^{}")
    if peeled:
        ref = ref[:-3]
    tag = ref.rsplit("/", 1)[-1]
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\.(\d+)", tag)
    if not match:
        continue
    version = ".".join(match.groups())
    key = tuple(int(part) for part in match.groups())
    record = records.setdefault(tag, {"key": key, "version": version, "tag": tag, "tag_sha": "", "commit_sha": ""})
    if peeled:
        record["commit_sha"] = sha
    else:
        record["tag_sha"] = sha

if not records:
    sys.exit(3)

best = max(records.values(), key=lambda item: item["key"])
version = best["version"]
tag = best["tag"]
sha = best["commit_sha"] or best["tag_sha"]
print(f"{version}\t{tag}\t{sha}")
PY
}

version_is_newer() {
  local candidate="$1"
  local current="$2"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$candidate" "$current" <<'PY'
import re
import sys

def parts(value):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return (-1,)
    return tuple(int(part) for part in match.groups())

sys.exit(0 if parts(sys.argv[1]) > parts(sys.argv[2]) else 1)
PY
}

update_status_fields() {
  local repo current latest_data latest_version latest_tag latest_commit update_available
  repo="$(resolve_repo_url)"
  [[ -n "$repo" ]] || fail "missing repo URL; pass --repo or install from a Git-backed source"
  current="$(current_version)"
  latest_data="$(latest_remote_release "$repo")" || fail "could not resolve latest release tag from $repo"
  IFS=$'\t' read -r latest_version latest_tag latest_commit <<< "$latest_data"
  update_available=false
  if version_is_newer "$latest_version" "$current"; then
    update_available=true
  fi

  printf 'home=%s\n' "$HOME_DIR"
  printf 'repo=%s\n' "$repo"
  printf 'current_version=%s\n' "$current"
  printf 'latest_version=%s\n' "$latest_version"
  printf 'latest_tag=%s\n' "$latest_tag"
  printf 'latest_commit=%s\n' "$latest_commit"
  printf 'update_available=%s\n' "$update_available"
}

print_update_status() {
  local fields home repo current latest latest_tag latest_commit update_available
  fields="$(update_status_fields)"
  if [[ "$JSON_OUTPUT" == true ]]; then
    home="$(printf '%s\n' "$fields" | sed -n 's/^home=//p')"
    repo="$(printf '%s\n' "$fields" | sed -n 's/^repo=//p')"
    current="$(printf '%s\n' "$fields" | sed -n 's/^current_version=//p')"
    latest="$(printf '%s\n' "$fields" | sed -n 's/^latest_version=//p')"
    latest_tag="$(printf '%s\n' "$fields" | sed -n 's/^latest_tag=//p')"
    latest_commit="$(printf '%s\n' "$fields" | sed -n 's/^latest_commit=//p')"
    update_available="$(printf '%s\n' "$fields" | sed -n 's/^update_available=//p')"
    printf '{"schema":"agent-bootstrap-update-status/v1","home":"%s","repo":"%s","current_version":"%s","latest_version":"%s","latest_tag":"%s","latest_commit":"%s","update_available":%s}\n' \
      "$(printf '%s' "$home" | json_escape)" \
      "$(printf '%s' "$repo" | json_escape)" \
      "$(printf '%s' "$current" | json_escape)" \
      "$(printf '%s' "$latest" | json_escape)" \
      "$(printf '%s' "$latest_tag" | json_escape)" \
      "$(printf '%s' "$latest_commit" | json_escape)" \
      "$update_available"
  else
    printf 'Update status\n'
    printf '%s\n' "$fields"
  fi
}

self_update() {
  local fields repo current_version latest_version latest_tag latest_commit update_available tmp_root clone_dir cloned_version cloned_commit installer
  fields="$(update_status_fields)"
  repo="$(printf '%s\n' "$fields" | sed -n 's/^repo=//p')"
  current_version="$(printf '%s\n' "$fields" | sed -n 's/^current_version=//p')"
  latest_version="$(printf '%s\n' "$fields" | sed -n 's/^latest_version=//p')"
  latest_tag="$(printf '%s\n' "$fields" | sed -n 's/^latest_tag=//p')"
  latest_commit="$(printf '%s\n' "$fields" | sed -n 's/^latest_commit=//p')"
  update_available="$(printf '%s\n' "$fields" | sed -n 's/^update_available=//p')"

  if [[ "$update_available" != true ]]; then
    printf 'Canonical home is already at or ahead of latest remote release: current=%s latest=%s (%s)\n' \
      "$current_version" "$latest_version" "$latest_tag"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf 'DRY-RUN would update %s from %s (%s)\n' "$HOME_DIR" "$repo" "$latest_tag"
    return 0
  fi

  tmp_root="$(mktemp -d)"
  SELF_UPDATE_TMP_ROOT="$tmp_root"
  trap cleanup_self_update_tmp EXIT HUP INT TERM
  clone_dir="$tmp_root/repo"
  git -c advice.detachedHead=false clone --quiet "$repo" "$clone_dir"
  git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$latest_tag^{}"

  cloned_version="$(sed -n '1p' "$clone_dir/agent-bootstrap/VERSION" 2>/dev/null || true)"
  [[ "$cloned_version" == "$latest_version" ]] ||
    fail "cloned VERSION '$cloned_version' does not match latest version '$latest_version'"
  cloned_commit="$(git -C "$clone_dir" rev-parse HEAD)"
  [[ "$cloned_commit" == "$latest_commit" ]] ||
    fail "cloned commit '$cloned_commit' does not match resolved latest commit '$latest_commit'"

  installer="$clone_dir/agent-bootstrap/install-agent-bootstrap-home.sh"
  [[ -x "$installer" ]] || fail "cloned release is missing executable home installer"

  AGENT_BOOTSTRAP_HOME="$HOME_DIR" "$installer" \
    --repo "$repo" \
    --ref "$latest_tag" \
    --commit "$cloned_commit" \
    --no-git
}

target_workflow() {
  local lock_file="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local workflow
  workflow="$(read_json_value "$lock_file" workflow_preset)"
  case "$workflow" in
    infra|full) printf '%s\n' "$workflow" ;;
    *) printf 'infra\n' ;;
  esac
}

plan_target() {
  [[ -n "$TARGET_DIR" ]] || fail "--plan requires --target DIR"
  print_update_status
  printf '\n'
  bash "$HOME_DIR/bootstrap-multi-agent-project.sh" --target "$TARGET_DIR" --upgrade-plan
}

apply_target() {
  local workflow
  [[ -n "$TARGET_DIR" ]] || fail "--apply requires --target DIR"
  print_update_status
  printf '\n'
  workflow="$(target_workflow)"
  bash "$HOME_DIR/bootstrap-multi-agent-project.sh" --target "$TARGET_DIR" --workflow "$workflow"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      HOME_DIR="$(cd "${2:?missing value for --home}" && pwd -P)"
      shift 2
      ;;
    --repo)
      REPO_URL="${2:?missing value for --repo}"
      shift 2
      ;;
    --check)
      ACTION="check"
      shift
      ;;
    --self-update)
      ACTION="self-update"
      shift
      ;;
    --target)
      TARGET_DIR="$(cd "${2:?missing value for --target}" && pwd -P)"
      shift 2
      ;;
    --plan)
      ACTION="plan"
      shift
      ;;
    --apply)
      ACTION="apply"
      shift
      ;;
    --json)
      JSON_OUTPUT=true
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

case "$ACTION" in
  check) print_update_status ;;
  self-update) self_update ;;
  plan) plan_target ;;
  apply) apply_target ;;
  *) fail "unknown action: $ACTION" ;;
esac
