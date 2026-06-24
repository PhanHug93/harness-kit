#!/usr/bin/env bash
# agent-bootstrap/lib/core.sh
# Sourced by bootstrap-multi-agent-project.sh. Generic utilities + workflow gating.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
#
# Shared-global contract (owned by the entrypoint, sourced into one shell; every
# lib may read these): TARGET_DIR, WORKFLOW_PRESET, DRY_RUN, BACKUP, FORCE,
# CANDIDATE_ON_CONFLICT, STAMP, LAST_WRITTEN_FILE, and the detection arrays
# TECH_STACKS, MODULES, VERIFY_COMMANDS, WARNINGS.

log() {
  printf '%s\n' "$*"
}

shell_quote() {
  printf '%q' "$1"
}

record_generated_file() {
  local path="$1"
  local relpath="$path"
  [[ -n "${AGENT_BOOTSTRAP_WRITE_LOG:-}" ]] || return 0
  case "$path" in
    "$TARGET_DIR"/*) relpath="${path#"$TARGET_DIR"/}" ;;
  esac
  printf '%s\n' "$relpath" >> "$AGENT_BOOTSTRAP_WRITE_LOG"
}

ensure_dir() {
  local dir="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN mkdir -p $dir"
    return
  fi
  mkdir -p "$dir"
}

backup_existing() {
  local path="$1"
  [[ -e "$path" && "$BACKUP" == "true" ]] || return 0
  local dir
  dir="$(dirname "$path")"
  if [[ -w "$dir" ]] && cp -p "$path" "$path.bak.$STAMP" 2>/dev/null; then
    return 0
  fi
  # Read-only target dir (e.g. sandboxed .codex/.agents): back up to a writable
  # side location instead of failing the whole run.
  local fallback="${AGENT_STATE_DIR:-$TARGET_DIR/.tools/agent-state}/backups"
  if mkdir -p "$fallback" 2>/dev/null && cp -p "$path" "$fallback/$(basename "$path").bak.$STAMP" 2>/dev/null; then
    log "backup (fallback): $fallback/$(basename "$path").bak.$STAMP"
    return 0
  fi
  log "warn: could not back up $path (read-only); proceeding"
  return 0
}

bootstrap_relpath_for() {
  local path="$1"
  case "$path" in
    "$TARGET_DIR"/*) printf '%s\n' "${path#"$TARGET_DIR"/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

is_bootstrap_user_owned_relpath() {
  local relpath="$1"
  case "$relpath" in
    docs/agent-configs/project-agent-context.md|\
    docs/agent-configs/project-brief.md|\
    docs/superpowers/specs/project-tech-stack.md|\
    docs/superpowers/specs/project-tech-stack.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_user_owned_file_is_unfilled() {
  local path="$1"
  local relpath
  [[ -f "$path" ]] || return 1
  relpath="$(bootstrap_relpath_for "$path")"
  case "$relpath" in
    docs/agent-configs/project-brief.md|docs/superpowers/specs/project-tech-stack.md)
      grep -Fq '<!-- UNFILLED -->' "$path"
      ;;
    docs/superpowers/specs/project-tech-stack.json)
      if command -v python3 >/dev/null 2>&1; then
        [[ "$(
          python3 - "$path" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(json.load(handle).get("status", ""))
except Exception:
    print("")
PY
        )" == "unfilled" ]]
      else
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"unfilled"' "$path"
      fi
      ;;
    docs/agent-configs/project-agent-context.md)
      grep -Fq '<!-- UNFILLED -->' "$path"
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_user_owned_file_is_filled() {
  local path="$1"
  local relpath
  [[ -f "$path" ]] || return 1
  relpath="$(bootstrap_relpath_for "$path")"
  is_bootstrap_user_owned_relpath "$relpath" || return 1
  ! bootstrap_user_owned_file_is_unfilled "$path"
}

write_user_owned_file() {
  local path="$1"
  if [[ -f "$path" && "$FORCE" != "true" ]] && bootstrap_user_owned_file_is_filled "$path"; then
    log "User-owned file preserved: $path"
    cat >/dev/null
    return 0
  fi
  write_file "$path"
}

write_file() {
  local path="$1"
  local final_path="$path"
  LAST_WRITTEN_FILE=""
  ensure_dir "$(dirname "$path")"
  if [[ -e "$path" && "$FORCE" != "true" ]]; then
    if [[ "$CANDIDATE_ON_CONFLICT" == "true" ]]; then
      final_path="$path.generated.$STAMP"
      ensure_dir "$(dirname "$final_path")"
      log "Existing file preserved: $path"
      log "Writing candidate: $final_path"
    else
      log "Skipping existing file: $path"
      cat >/dev/null
      return
    fi
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN write $final_path"
    cat >/dev/null
    LAST_WRITTEN_FILE="$final_path"
    return
  fi
  if [[ "$final_path" == "$path" ]]; then
    backup_existing "$path"
  fi
  # Atomic write: stage in the same dir, then rename into place so an abort
  # mid-write (e.g. --force --no-backup) cannot truncate an existing file.
  local tmp="${final_path}.tmp.$$"
  cat > "$tmp"
  mv "$tmp" "$final_path"
  LAST_WRITTEN_FILE="$final_path"
  record_generated_file "$final_path"
}

write_overlay_file() {
  local path="$1" tmp_new merged
  tmp_new="$(mktemp)"
  cat > "$tmp_new"
  if [[ -f "$path" ]]; then
    merged="${tmp_new}.merged"
    if overlay_merge "$path" "$tmp_new" > "$merged" && [[ -s "$merged" ]]; then
      mv "$merged" "$tmp_new"
    else
      rm -f "$merged"
    fi
  fi
  write_file "$path" < "$tmp_new"
  rm -f "$tmp_new"
}

copy_bundle_file() {
  local source_rel="$1"
  local target_path="$2"
  local source_path="$BUNDLE_DIR/$source_rel"
  [[ -f "$source_path" ]] || {
    echo "ERROR: missing bundle file: $source_rel" >&2
    exit 1
  }
  write_file "$target_path" < "$source_path"
}

make_executable() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN chmod +x $path"
    return
  fi
  chmod +x "$path"
}

format_bullets() {
  local item
  for item in "$@"; do
    printf -- '- %s\n' "\`$item\`"
  done
}

workflow_enabled() {
  [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]
}

replace_placeholder() {
  local path="$1"
  local placeholder="$2"
  local value="$3"
  local content
  [[ "$DRY_RUN" == "true" ]] && return 0
  [[ -f "$path" ]] || return 0
  # Pure-bash substitution (no python3 dependency). The value is a slash-free
  # preset token (full/infra) and the placeholder has no glob metacharacters, so
  # parameter expansion is safe. Generated files carry exactly one trailing
  # newline; `cat` strips it and `printf '%s\n'` restores it byte-for-byte.
  content="$(cat "$path")"
  printf '%s\n' "${content//$placeholder/$value}" > "$path"
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    echo "ERROR: missing SHA-256 tool: install sha256sum, shasum, or python3" >&2
    return 1
  fi
}

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    JSON_ESCAPE_VALUE="$1" python3 - <<'PY'
import json
import os

print(json.dumps(os.environ.get("JSON_ESCAPE_VALUE", ""), ensure_ascii=False)[1:-1], end="")
PY
    return
  fi
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

render_bundle_template() {
  local relative="$1"
  local template_path="$BUNDLE_DIR/$relative"
  [[ -f "$template_path" ]] || fail "missing bundle template: $relative"
  cat "$template_path"
}
