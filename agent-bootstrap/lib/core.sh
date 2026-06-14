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
  if [[ -e "$path" && "$BACKUP" == "true" ]]; then
    cp -p "$path" "$path.bak.$STAMP"
  fi
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
    printf -- '- `%s`\n' "$item"
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
  else
    cksum | awk '{print $1}'
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}
