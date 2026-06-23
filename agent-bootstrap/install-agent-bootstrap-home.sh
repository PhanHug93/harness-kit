#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_DIR="${AGENT_BOOTSTRAP_HOME:-${HOME}/dev/agent-bootstrap}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WRITE_ZSHRC=false
DRY_RUN=false
INIT_HISTORY=true
ZSHRC_PATH="${ZSHRC:-${HOME}/.zshrc}"
SOURCE_REPO_URL=""
SOURCE_REF=""
SOURCE_COMMIT=""

usage() {
  cat <<'HELP'
Usage: scripts/install-agent-bootstrap-home.sh [options]

Export the repo's portable agent bootstrap files into a canonical solo-workflow
folder. The target folder is $AGENT_BOOTSTRAP_HOME when set, otherwise
$HOME/dev/agent-bootstrap.

Options:
  --home DIR       Canonical agent bootstrap directory.
  --write-zshrc   Install/update the managed shell functions in ~/.zshrc.
  --zshrc FILE    Shell rc file to update with --write-zshrc.
  --no-git        Do not initialize local history in the canonical directory.
  --repo URL      Source Git repository URL/path for update metadata.
  --ref REF       Source Git ref/tag for update metadata.
  --commit SHA    Source Git commit for update metadata.
  --dry-run       Print planned actions without writing.
  -h, --help      Show this help.
HELP
}

log() { printf 'agent-bootstrap-home: %s\n' "$*"; }
warn() { printf 'agent-bootstrap-home: WARN: %s\n' "$*" >&2; }
fail() { printf 'agent-bootstrap-home: ERROR: %s\n' "$*" >&2; exit 1; }

shell_quote() {
  printf '%q' "$1"
}

read_source_json_value() {
  local key="$1"
  local file="$BUNDLE_DIR/SOURCE.json"
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
if isinstance(value, str):
    print(value)
PY
}

source_root() {
  cd "$BUNDLE_DIR/.." && pwd -P
}

detect_source_repo_url() {
  if [[ -n "$SOURCE_REPO_URL" ]]; then
    printf '%s\n' "$SOURCE_REPO_URL"
    return 0
  fi
  local inherited
  inherited="$(read_source_json_value repo_url)"
  if [[ -n "$inherited" ]]; then
    printf '%s\n' "$inherited"
    return 0
  fi
  local root
  root="$(source_root)"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" config --get remote.origin.url || true
  fi
}

detect_source_ref() {
  if [[ -n "$SOURCE_REF" ]]; then
    printf '%s\n' "$SOURCE_REF"
    return 0
  fi
  local inherited
  inherited="$(read_source_json_value installed_ref)"
  if [[ -n "$inherited" ]]; then
    printf '%s\n' "$inherited"
    return 0
  fi
  local root
  root="$(source_root)"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" describe --tags --exact-match 2>/dev/null ||
      git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null ||
      true
  fi
}

detect_source_commit() {
  if [[ -n "$SOURCE_COMMIT" ]]; then
    printf '%s\n' "$SOURCE_COMMIT"
    return 0
  fi
  local inherited
  inherited="$(read_source_json_value installed_commit)"
  if [[ -n "$inherited" ]]; then
    printf '%s\n' "$inherited"
    return 0
  fi
  local root
  root="$(source_root)"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" rev-parse HEAD 2>/dev/null || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      DEST_DIR="${2:?missing value for --home}"
      shift 2
      ;;
    --write-zshrc)
      WRITE_ZSHRC=true
      shift
      ;;
    --zshrc)
      ZSHRC_PATH="${2:?missing value for --zshrc}"
      shift 2
      ;;
    --no-git)
      INIT_HISTORY=false
      shift
      ;;
    --repo)
      SOURCE_REPO_URL="${2:?missing value for --repo}"
      shift 2
      ;;
    --ref)
      SOURCE_REF="${2:?missing value for --ref}"
      shift 2
      ;;
    --commit)
      SOURCE_COMMIT="${2:?missing value for --commit}"
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

case "$DEST_DIR" in
  /*) ;;
  *) DEST_DIR="$(pwd -P)/$DEST_DIR" ;;
esac

copy_file() {
  local src="$1"
  local dest_name="$2"
  local src_path="$BUNDLE_DIR/$src"
  local dest_path="$DEST_DIR/$dest_name"

  [[ -f "$src_path" ]] || fail "missing source file: $src"

  if [[ "$DRY_RUN" == true ]]; then
    log "would copy $src -> $dest_path"
    return 0
  fi

  mkdir -p "$(dirname "$dest_path")"
  if [[ -f "$dest_path" ]] && ! cmp -s "$src_path" "$dest_path"; then
    cp -p "$dest_path" "$dest_path.bak.$STAMP"
    log "backup ${dest_path#"$DEST_DIR"/}.bak.$STAMP"
  fi
  cp -p "$src_path" "$dest_path"
  log "copied $dest_name"
}

write_shell_functions() {
  local tmp
  local export_path
  export_path="$(shell_quote "$DEST_DIR")"
  tmp="$(mktemp)"

  if [[ "$DRY_RUN" == true ]]; then
    log "would update $ZSHRC_PATH with managed agent-bootstrap functions"
    rm -f "$tmp"
    return 0
  fi

  mkdir -p "$(dirname "$ZSHRC_PATH")"
  if [[ -f "$ZSHRC_PATH" ]]; then
    awk '
      $0 == "# >>> agent-bootstrap >>>" { skip = 1; next }
      $0 == "# <<< agent-bootstrap <<<" { skip = 0; next }
      skip != 1 { print }
    ' "$ZSHRC_PATH" > "$tmp"
    cp -p "$ZSHRC_PATH" "$ZSHRC_PATH.bak.$STAMP"
  else
    : > "$tmp"
  fi

  cat >> "$tmp" <<EOF_ZSHRC

# >>> agent-bootstrap >>>
export AGENT_BOOTSTRAP_HOME=$export_path
agent-init()    { bash "\$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target "\$PWD" "\$@"; }
agent-next()    { agent-init --first-10; }
agent-doctor()  { ./scripts/agent-hook.sh doctor; }
agent-refresh() { agent-init --refresh-lock; }
agent-update()  { bash "\$AGENT_BOOTSTRAP_HOME/agent-bootstrap-update.sh" --home "\$AGENT_BOOTSTRAP_HOME" "\$@"; }
agent-upgrade() { agent-update --target "\$PWD" --plan "\$@"; }
# <<< agent-bootstrap <<<
EOF_ZSHRC

  mv "$tmp" "$ZSHRC_PATH"
  log "updated $ZSHRC_PATH"
}

init_history() {
  if [[ "$INIT_HISTORY" != true ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "would initialize local history in $DEST_DIR"
    return 0
  fi
  if [[ -d "$DEST_DIR/.git" ]]; then
    log "history already initialized"
    return 0
  fi
  if [[ -x "$BUNDLE_DIR/rtk" ]] && "$BUNDLE_DIR/rtk" --version >/dev/null 2>&1; then
    "$BUNDLE_DIR/rtk" git -C "$DEST_DIR" init >/dev/null
    log "initialized local history via rtk"
  else
    warn "rtk is unavailable; skipped local history init. Run scripts/install-rtk.sh, then rerun without --no-git."
  fi
}

write_source_metadata() {
  local repo_url ref commit version metadata_file
  metadata_file="$DEST_DIR/SOURCE.json"
  repo_url="$(detect_source_repo_url)"
  ref="$(detect_source_ref)"
  commit="$(detect_source_commit)"
  version="$(sed -n '1p' "$BUNDLE_DIR/VERSION")"

  if [[ "$DRY_RUN" == true ]]; then
    log "would write SOURCE.json"
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    warn "python3 is unavailable; skipped SOURCE.json metadata"
    return 0
  }

  python3 - "$metadata_file" "$repo_url" "$ref" "$commit" "$version" "$STAMP" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = {
    "schema": "agent-bootstrap-source/v1",
    "repo_url": sys.argv[2],
    "installed_ref": sys.argv[3],
    "installed_commit": sys.argv[4],
    "installed_version": sys.argv[5],
    "updated_at": sys.argv[6],
}
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  log "wrote SOURCE.json"
}

main() {
  log "canonical directory: $DEST_DIR"
  if [[ "$DRY_RUN" != true ]]; then
    mkdir -p "$DEST_DIR"
  fi

  copy_file "README.md" "README.md"
  copy_file "VERSION" "VERSION"
  copy_file "MANIFEST.md" "MANIFEST.md"
  copy_file "bootstrap-multi-agent-project.sh" "bootstrap-multi-agent-project.sh"
  copy_file "harness-kit-one-shot-upgrade.sh" "harness-kit-one-shot-upgrade.sh"
  copy_file "agent-bootstrap-update.sh" "agent-bootstrap-update.sh"
  copy_file "agent-tech-stack-lib.sh" "agent-tech-stack-lib.sh"
  copy_file "agent-hook.sh" "agent-hook.sh"
  copy_file "agent-guard.sh" "agent-guard.sh"
  copy_file "agent-onboarding.sh" "agent-onboarding.sh"
  copy_file "detect-agent-tech-stack.sh" "detect-agent-tech-stack.sh"
  copy_file "install-rtk.sh" "install-rtk.sh"
  copy_file "rtk" "rtk"
  copy_file "verify-ai-deps.sh" "verify-ai-deps.sh"
  copy_file "model-profiles/codex-model-profiles.json" "model-profiles/codex-model-profiles.json"
  copy_file "policies/agent-context-policy.json" "policies/agent-context-policy.json"
  copy_file "provenance/rtk-v0.37.2.sha256" "provenance/rtk-v0.37.2.sha256"
  copy_file "schemas/agent-context-policy-v1.schema.json" "schemas/agent-context-policy-v1.schema.json"
  copy_file "schemas/agent-model-profiles-v1.schema.json" "schemas/agent-model-profiles-v1.schema.json"
  copy_file "schemas/agent-project-tech-stack-v1.schema.json" "schemas/agent-project-tech-stack-v1.schema.json"
  copy_file "schemas/agent-bootstrap-lock-v1.schema.json" "schemas/agent-bootstrap-lock-v1.schema.json"
  copy_file "schemas/agent-bootstrap-status-v1.schema.json" "schemas/agent-bootstrap-status-v1.schema.json"
  copy_file "schemas/agent-bootstrap-verify-report-v1.schema.json" "schemas/agent-bootstrap-verify-report-v1.schema.json"
  copy_file "templates/base/README.md" "templates/base/README.md"
  copy_file "templates/overlays/android_kotlin.md" "templates/overlays/android_kotlin.md"
  copy_file "templates/overlays/generic.md" "templates/overlays/generic.md"
  copy_file "templates/overlays/ios_swift.md" "templates/overlays/ios_swift.md"
  copy_file "templates/overlays/node_js.md" "templates/overlays/node_js.md"
  copy_file "templates/overlays/python.md" "templates/overlays/python.md"
  copy_file "templates/workflows/council/README.md" "templates/workflows/council/README.md"
  copy_file "templates/workflows/karpathy/README.md" "templates/workflows/karpathy/README.md"
  copy_file "templates/workflows/three-mode/README.md" "templates/workflows/three-mode/README.md"
  copy_file "lib/core.sh" "lib/core.sh"
  copy_file "lib/detect.sh" "lib/detect.sh"
  copy_file "lib/render.sh" "lib/render.sh"
  copy_file "lib/writers-runtime.sh" "lib/writers-runtime.sh"
  copy_file "lib/writers-docs.sh" "lib/writers-docs.sh"
  copy_file "lib/onboarding.sh" "lib/onboarding.sh"
  copy_file "lib/overlays.sh" "lib/overlays.sh"
  write_source_metadata
  init_history

  if [[ "$WRITE_ZSHRC" == true ]]; then
    write_shell_functions
  else
    local export_path
    export_path="$(shell_quote "$DEST_DIR")"
    cat <<EOF_NEXT

Add this managed block manually, or rerun with --write-zshrc:

# >>> agent-bootstrap >>>
export AGENT_BOOTSTRAP_HOME=$export_path
agent-init()    { bash "\$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target "\$PWD" "\$@"; }
agent-next()    { agent-init --first-10; }
agent-doctor()  { ./scripts/agent-hook.sh doctor; }
agent-refresh() { agent-init --refresh-lock; }
agent-update()  { bash "\$AGENT_BOOTSTRAP_HOME/agent-bootstrap-update.sh" --home "\$AGENT_BOOTSTRAP_HOME" "\$@"; }
agent-upgrade() { agent-update --target "\$PWD" --plan "\$@"; }
# <<< agent-bootstrap <<<

Then run: source "$ZSHRC_PATH"
EOF_NEXT
  fi
}

main "$@"
