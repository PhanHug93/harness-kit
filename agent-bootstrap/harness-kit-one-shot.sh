#!/usr/bin/env bash
# Harness Kit one-shot entry: fetch a kit release into the project, then hand
# over to that version's orchestrator. Install, reinstall and update are one command.
set -euo pipefail

DEFAULT_REF="v2026.10.13.2"
REPO_URL="${HARNESS_KIT_REPO_URL:-https://github.com/PhanHug93/harness-kit.git}"
TO="${DEFAULT_REF#v}"
SOURCE_DIR=""
TARGET=""
PASS=()

usage() {
  cat <<USAGE
Usage: harness-kit-one-shot.sh [--to VERSION|latest] [--target DIR] [--source-dir DIR] [--repo URL] [kit options]

Fetches the kit release into <project>/.harness-kit/v<version>/ and runs its
orchestrator. Other options are passed through unchanged.
  --to VERSION|latest  Kit version to install or update to. Defaults to v2026.10.13.2.
  --target DIR         Project directory (a Git work tree). Defaults to the current directory.
  --source-dir DIR     Local harness-kit checkout (or a dir with agent-bootstrap/); no network.
  --repo URL           Kit Git repo. Defaults to https://github.com/PhanHug93/harness-kit.git.
  -h, --help           Show this help.
USAGE
}
die() { echo "ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to|--ref) [ "$#" -ge 2 ] || die "$1 needs a value"; TO="$2"; shift 2 ;;
    --source-dir) [ "$#" -ge 2 ] || die "--source-dir needs a value"; SOURCE_DIR="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || die "--repo needs a value"; REPO_URL="$2"; shift 2 ;;
    --target) [ "$#" -ge 2 ] || die "--target needs a value"; TARGET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done

if [ -n "$SOURCE_DIR" ]; then
  [ -d "$SOURCE_DIR" ] || die "--source-dir is not a directory: $SOURCE_DIR"
  SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
  [ -f "$SOURCE_DIR/agent-bootstrap/VERSION" ] || die "no agent-bootstrap/VERSION under $SOURCE_DIR"
fi
if [ "$TO" = "latest" ]; then
  if [ -n "$SOURCE_DIR" ]; then
    TO="$(sed -n '1p' "$SOURCE_DIR/agent-bootstrap/VERSION" | tr -d '[:space:]')"
  else
    TO="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | sed -n 's#.*refs/tags/v\([0-9][0-9.]*\)$#\1#p' \
      | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)"
    [ -n "$TO" ] || die "could not find any v* release tag at $REPO_URL"
  fi
fi
TO="${TO#v}"
case "$TO" in
  [0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]*) ;;
  *) die "version must look like YYYY.MM.DD.N, got: $TO" ;;
esac

[ -n "$TARGET" ] || TARGET="$(pwd -P)"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd -P)"
[ "$(git -C "$TARGET" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ] \
  || die "target is not inside a Git work tree: $TARGET (run 'git init' first)"

# Keep the kit's own directories out of git status before writing anything.
prefix="$(git -C "$TARGET" rev-parse --show-prefix)"
exclude="$(git -C "$TARGET" rev-parse --git-path info/exclude)"
case "$exclude" in /*) ;; *) exclude="$TARGET/$exclude" ;; esac
mkdir -p "$(dirname "$exclude")"
touch "$exclude"
for entry in "/${prefix}.harness-kit/" "/${prefix}.tools/"; do
  grep -qxF -- "$entry" "$exclude" || printf '%s\n' "$entry" >> "$exclude"
done

KIT_ROOT="$TARGET/.harness-kit"
[ ! -L "$KIT_ROOT" ] || die "$KIT_ROOT is a symlink; remove it and retry"
mkdir -p "$KIT_ROOT"
VDIR="$KIT_ROOT/v$TO"
[ ! -L "$VDIR" ] || die "$VDIR is a symlink; remove it and retry"
DEST="$VDIR/agent-bootstrap"

if [ -e "$VDIR" ]; then
  have="$(sed -n '1p' "$DEST/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  [ "$have" = "$TO" ] || die "$VDIR exists but is not a valid kit $TO copy; remove it (rm -rf '$VDIR') and retry"
else
  TMP="$(mktemp -d "$KIT_ROOT/.fetch-XXXXXX")"
  created_vdir=0
  cleanup() {
    rm -rf "$TMP"
    [ "$created_vdir" = 1 ] && [ ! -e "$DEST" ] && rm -rf "$VDIR"
    return 0
  }
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  mkdir -p "$TMP/src"
  if [ -n "$SOURCE_DIR" ]; then
    mkdir -p "$TMP/src/agent-bootstrap"
    cp -R "$SOURCE_DIR/agent-bootstrap/." "$TMP/src/agent-bootstrap/"
  else
    git clone -q --depth 1 --branch "v$TO" "$REPO_URL" "$TMP/src" >/dev/null 2>&1 \
      || die "could not fetch v$TO from $REPO_URL"
  fi
  got="$(sed -n '1p' "$TMP/src/agent-bootstrap/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  [ "$got" = "$TO" ] || die "fetched kit reports version '${got:-none}', expected $TO"
  mkdir -p "$VDIR"; created_vdir=1
  mv "$TMP/src/agent-bootstrap" "$DEST"
  created_vdir=0
  rm -rf "$TMP"
  trap - EXIT INT TERM
fi

RUN="$DEST/harness-kit-run.sh"
[ -f "$RUN" ] || die "kit $TO predates the one-shot runner (no harness-kit-run.sh); use --to with a newer version"
exec bash "$RUN" --target "$TARGET" --kit-version "$TO" ${PASS[@]+"${PASS[@]}"}
