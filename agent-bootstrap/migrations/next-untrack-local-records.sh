# shellcheck shell=bash
# Migration: stop tracking local-only harness files that are in the Git index.
MIGRATION_ID=next-untrack-local-records
MIGRATION_SINCE=next
MIGRATION_KIND=decision
MIGRATION_SUMMARY="Untrack local-only harness files (index only; the files stay on disk)"

# Tracked local-only paths, one per line. Prefers the project's own checker; an
# older copy without --list falls back to the kit's.
_tracked_local_only() {
  local checker="$TARGET_DIR/scripts/agent-local-only-check.sh"
  if [ -f "$checker" ] && AGENT_BOOTSTRAP_ROOT="$TARGET_DIR" bash "$checker" --list 2>/dev/null; then
    return 0
  fi
  AGENT_BOOTSTRAP_ROOT="$TARGET_DIR" bash "$KIT_DIR/agent-local-only-check.sh" --list
}

# Errors are failures (exit 2), never "nothing tracked".
migration_needed() {
  local list
  list="$(_tracked_local_only)" || return 2
  [ -n "$list" ]
}

migration_describe() {
  local list count first
  list="$(_tracked_local_only)" || return 1
  count="$(printf '%s\n' "$list" | grep -c . || true)"
  first="$(printf '%s\n' "$list" | head -n 10 | paste -sd, - | sed 's/,/, /g')"
  printf '%s tracked local-only files: %s\n' "$count" "$first"
}

migration_apply() {
  local paths
  paths="$(mktemp "${TMPDIR:-/tmp}/untrack-paths.XXXXXX")"
  _tracked_local_only >"$paths" || { rm -f "$paths"; return 1; }
  [ -s "$paths" ] || { rm -f "$paths"; return 0; }
  migration_backup "$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir)/index"
  tr '\n' '\0' <"$paths" | xargs -0 git --literal-pathspecs -C "$TARGET_DIR" rm --cached -q --
  rm -f "$paths"
}
