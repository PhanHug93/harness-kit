# shellcheck shell=bash
# Migration: move the kit's local-only ignore block from the tracked .gitignore
# to .git/info/exclude, which is never committed.
#
# One source of truth: the exclude block is written by the kit generator's own
# functions (lib/render.sh: write_ignore_block_exclude, emit_ignore_block_for_exclude),
# so the content, the prefix anchoring below a repository top level and the
# idempotence rules are the same as on a fresh install. The old text in
# .gitignore is only removed (its backup is kept in the journal).
MIGRATION_ID=2026.10.20.1-ignore-block-to-exclude
MIGRATION_SINCE=2026.10.20.1
MIGRATION_KIND=decision
MIGRATION_SUMMARY="Move the local-only ignore block from .gitignore to .git/info/exclude"

_MARKER="# >>> multi-agent bootstrap local state >>>"

migration_needed() {
  [ -f "$TARGET_DIR/.gitignore" ] && [ ! -L "$TARGET_DIR/.gitignore" ] &&
    grep -Fq "$_MARKER" "$TARGET_DIR/.gitignore" &&
    git -C "$TARGET_DIR" rev-parse --git-path info/exclude >/dev/null 2>&1
}

migration_describe() {
  printf 'the local-only ignore block is in .gitignore\n'
}

migration_apply() {
  local gitignore="$TARGET_DIR/.gitignore" exclude
  [ -f "$gitignore" ] && grep -Fq "$_MARKER" "$gitignore" || return 0
  # shellcheck disable=SC1091
  . "$KIT_DIR/lib/render.sh"
  # shellcheck disable=SC2317,SC2329 # replaces render.sh's logger
  log() { :; }
  DRY_RUN=false
  IGNORE_BLOCK_MARKER="$_MARKER"
  exclude="$(ignore_exclude_path)" || return 1
  IGNORE_EXCLUDE_FILE="$exclude"
  migration_backup "$exclude"
  write_ignore_block_exclude
  grep -Fq "$_MARKER" "$exclude" || return 1
  # Only now take the block out of .gitignore, so a failure above loses nothing.
  migration_backup .gitignore
  python3 -I -B - "$gitignore" "$_MARKER" <<'PY'
import sys

path, marker = sys.argv[1], sys.argv[2]
end = "# <<< multi-agent bootstrap local state <<<"
lines = open(path, newline="").read().splitlines(keepends=True)
out, i = [], 0
while i < len(lines):
    if lines[i].rstrip("\r\n").startswith(marker):
        j = i
        while j < len(lines) and not lines[j].rstrip("\r\n").startswith(end):
            j += 1
        if j == len(lines):
            sys.exit("ERROR: .gitignore has a block start without its end marker; not changed")
        if out and out[-1].strip() == "":
            out.pop()
        i = j + 1
        continue
    out.append(lines[i])
    i += 1
with open(path, "w", newline="") as handle:
    handle.write("".join(out))
PY
  migration_backup .tools/agent-state/project-knowledge.json
  python3 -I -B "$KIT_DIR/lib/knowledge.py" --target "$TARGET_DIR" ignore-target exclude
}
