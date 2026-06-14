#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_DIR="${AGENT_BOOTSTRAP_HOME:-${HOME}/dev/agent-bootstrap}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WRITE_ZSHRC=false
DRY_RUN=false
INIT_HISTORY=true
ZSHRC_PATH="${ZSHRC:-${HOME}/.zshrc}"

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
    log "backup ${dest_path#$DEST_DIR/}.bak.$STAMP"
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
agent-doctor()  { ./scripts/agent-hook.sh doctor; }
agent-refresh() { agent-init --refresh-lock; }
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

main() {
  log "canonical directory: $DEST_DIR"
  if [[ "$DRY_RUN" != true ]]; then
    mkdir -p "$DEST_DIR"
  fi

  copy_file "README.md" "README.md"
  copy_file "VERSION" "VERSION"
  copy_file "MANIFEST.md" "MANIFEST.md"
  copy_file "bootstrap-multi-agent-project.sh" "bootstrap-multi-agent-project.sh"
  copy_file "agent-tech-stack-lib.sh" "agent-tech-stack-lib.sh"
  copy_file "agent-hook.sh" "agent-hook.sh"
  copy_file "detect-agent-tech-stack.sh" "detect-agent-tech-stack.sh"
  copy_file "install-rtk.sh" "install-rtk.sh"
  copy_file "rtk" "rtk"
  copy_file "verify-ai-deps.sh" "verify-ai-deps.sh"
  copy_file "lib/core.sh" "lib/core.sh"
  copy_file "lib/detect.sh" "lib/detect.sh"
  copy_file "lib/render.sh" "lib/render.sh"
  copy_file "lib/writers-runtime.sh" "lib/writers-runtime.sh"
  copy_file "lib/writers-docs.sh" "lib/writers-docs.sh"
  copy_file "lib/onboarding.sh" "lib/onboarding.sh"
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
agent-doctor()  { ./scripts/agent-hook.sh doctor; }
agent-refresh() { agent-init --refresh-lock; }
# <<< agent-bootstrap <<<

Then run: source "$ZSHRC_PATH"
EOF_NEXT
  fi
}

main "$@"
