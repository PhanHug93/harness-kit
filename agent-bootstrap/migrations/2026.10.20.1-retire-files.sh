# shellcheck shell=bash
# Migration: remove retired harness-kit files (HK-07 inventory) with the
# generator's own verified backups.
MIGRATION_ID=2026.10.20.1-retire-files
MIGRATION_SINCE=2026.10.20.1
MIGRATION_KIND=decision
MIGRATION_SUMMARY="Remove retired harness-kit files (backups are kept)"

# Number of retired files the plan would remove; fails when the plan cannot
# be read (an error is never "nothing to retire").
_retire_count() {
  local json
  json="$(bash "$KIT_DIR/bootstrap-multi-agent-project.sh" --target "$TARGET_DIR" --retirement-plan --json 2>/dev/null)" ||
    return 1
  printf '%s' "$json" | python3 -I -B -c '
import json, sys
try:
    entries = json.load(sys.stdin)["entries"]
except (ValueError, KeyError, TypeError):
    sys.exit(1)
print(sum(1 for item in entries if isinstance(item, dict) and item.get("action") == "retire"))'
}

migration_needed() {
  local count
  count="$(_retire_count)" || return 2
  [ "$count" -gt 0 ]
}

migration_describe() {
  local count
  count="$(_retire_count)" || return 1
  printf '%s retired kit files can be removed\n' "$count"
}

migration_apply() {
  local rc=0
  bash "$KIT_DIR/bootstrap-multi-agent-project.sh" --target "$TARGET_DIR" --apply-retirements || rc=$?
  # Exit 3: every exact retired file was removed; modified or out-of-scope
  # ones were preserved (reported by the engine), which is not a failure.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]
}
