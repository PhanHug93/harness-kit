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

bootstrap_path_is_within_root() {
  local path="$1"
  AGENT_POLICY_ROOT="$TARGET_DIR" AGENT_POLICY_PATH="$path" python3 - <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(os.environ["AGENT_POLICY_ROOT"]).resolve(strict=True)
path = pathlib.Path(os.environ["AGENT_POLICY_PATH"])
if not path.is_absolute():
    path = pathlib.Path.cwd() / path
try:
    # `Path.resolve()` follows links, so it cannot be the lexical pass: an
    # excluded link such as `.git/linked-package.json -> safe/package.json`
    # would lose its excluded component before policy checks run.  Normalize
    # the absolute spelling first, then resolve the same path separately.
    lexical = pathlib.Path(os.path.abspath(os.path.normpath(os.fspath(path))))
except (OSError, RuntimeError):
    sys.exit(1)
try:
    lexical.relative_to(root)
    resolved = pathlib.Path(os.path.realpath(str(path))).resolve(strict=False)
    resolved.relative_to(root)
except (OSError, RuntimeError, ValueError):
    sys.exit(1)
parts = pathlib.PurePath(lexical.relative_to(root)).parts
resolved_parts = pathlib.PurePath(resolved.relative_to(root)).parts
excluded = {".git", ".tools", ".idea", ".next", "node_modules", "Pods", "vendor", "build", "dist", "out", "local.properties", "keystore.properties"}
def excluded_path(items):
    return any(
        part in excluded or part.startswith(".gradle") or part.startswith(".env") or
        part.endswith((".jks", ".keystore", ".pem", ".p8", ".key")) or
        (part == ".agents" and idx + 1 < len(items) and items[idx + 1] in {"runtime", "state", "cache"})
        for idx, part in enumerate(items)
    )
if excluded_path(parts) or excluded_path(resolved_parts):
    sys.exit(1)
sys.exit(0)
PY
}

bootstrap_entry_exists() {
  [[ -e "$1" || -L "$1" ]]
}

bootstrap_existing_file_is_eligible() {
  local path="$1"
  bootstrap_entry_exists "$path" || return 1
  [[ -f "$path" ]] || return 1
  bootstrap_path_is_within_root "$path" || return 1
  [[ -r "$path" ]] || return 1
}

bootstrap_existing_directory_is_eligible() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  bootstrap_path_is_within_root "$path"
}

bootstrap_write_parent_is_eligible() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  bootstrap_path_is_within_root "$parent"
}

bootstrap_path_diagnostic() {
  AGENT_DIAGNOSTIC_PATH="$1" python3 - <<'PY'
import os

value = os.environ["AGENT_DIAGNOSTIC_PATH"]
out = []
for char in value:
    code = ord(char)
    if char == "\\":
        out.append("\\\\")
    elif char == "\n":
        out.append("\\n")
    elif char == "\r":
        out.append("\\r")
    elif char == "\t":
        out.append("\\t")
    elif code < 0x20 or 0x7f <= code <= 0x9f:
        out.append(f"\\u{code:04x}")
    else:
        out.append(char)
print("".join(out), end="")
PY
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
  if bootstrap_entry_exists "$dir"; then
    if [[ ! -d "$dir" ]] || ! bootstrap_existing_directory_is_eligible "$dir"; then
      log "warn: refusing unsafe directory path: $(bootstrap_path_diagnostic "$dir")"
      return 1
    fi
  else
    bootstrap_write_parent_is_eligible "$dir" || {
      log "warn: refusing unsafe directory parent: $(bootstrap_path_diagnostic "$dir")"
      return 1
    }
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN mkdir -p $dir"
    return
  fi
  mkdir -p "$dir" || {
    log "warn: could not create directory: $(bootstrap_path_diagnostic "$dir")"
    return 1
  }
}

backup_existing() {
  local path="$1"
  bootstrap_entry_exists "$path" || return 0
  [[ "$BACKUP" == "true" ]] || return 0
  if [[ -L "$path" ]]; then
    bootstrap_write_parent_is_eligible "$path" || {
      log "warn: refusing unsafe symlink backup parent: $(bootstrap_path_diagnostic "$path")"
      return 1
    }
  else
    bootstrap_existing_file_is_eligible "$path" || {
      log "warn: refusing to read unsafe backup source: $(bootstrap_path_diagnostic "$path")"
      return 1
    }
  fi
  local dir
  dir="$(dirname "$path")"
  if [[ -w "$dir" ]] && cp -Pp "$path" "$path.bak.$STAMP" 2>/dev/null; then
    return 0
  fi
  # Read-only target dir (e.g. sandboxed .codex/.agents): back up to a writable
  # side location instead of failing the whole run.
  local fallback="${AGENT_STATE_DIR:-$TARGET_DIR/.tools/agent-state}/backups"
  if mkdir -p "$fallback" 2>/dev/null && cp -Pp "$path" "$fallback/$(basename "$path").bak.$STAMP" 2>/dev/null; then
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
  bootstrap_existing_file_is_eligible "$path" || return 1
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
  if bootstrap_entry_exists "$path" && ! bootstrap_existing_file_is_eligible "$path"; then
    if is_bootstrap_user_owned_relpath "$(bootstrap_relpath_for "$path")"; then
      log "warn: preserving unsafe user-owned file: $(bootstrap_path_diagnostic "$path")"
      harness_plan_log preserved "$path"
      cat >/dev/null
      return 0
    fi
  fi
  if bootstrap_existing_file_is_eligible "$path" && [[ "$FORCE" != "true" ]] && bootstrap_user_owned_file_is_filled "$path"; then
    log "User-owned file preserved: $path"
    harness_plan_log preserved "$path"
    cat >/dev/null
    return 0
  fi
  write_file "$path"
}

write_file() {
  local path="$1"
  local final_path="$path"
  local input_tmp tmp merged_tmp baseline_rel upgrade_action plan_action
  LAST_WRITTEN_FILE=""
  bootstrap_write_parent_is_eligible "$path" || {
    fail "refusing write outside eligible project parent: $(bootstrap_path_diagnostic "$(dirname "$path")")"
  }
  ensure_dir "$(dirname "$path")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN write $final_path"
    cat >/dev/null
    LAST_WRITTEN_FILE="$final_path"
    return
  fi
  input_tmp="$(mktemp)"
  merged_tmp="$input_tmp.merged"
  cat > "$input_tmp"
  harness_fill_workflow_placeholder "$input_tmp"
  baseline_rel="$(harness_baseline_relpath "$path")" || baseline_rel=""
  if bootstrap_existing_file_is_eligible "$path" && cmp -s "$input_tmp" "$path"; then
    log "Existing file up to date: $path"
    harness_plan_log unchanged "$path"
    harness_baseline_record "$baseline_rel" "$input_tmp"
    rm -f "$input_tmp"
    LAST_WRITTEN_FILE="$path"
    record_generated_file "$path"
    return
  fi
  upgrade_action="create"
  plan_action="create"
  if bootstrap_entry_exists "$path"; then
    upgrade_action="update"
    plan_action="overwrite"
  fi
  if bootstrap_entry_exists "$path" && ! bootstrap_existing_file_is_eligible "$path" && [[ "$FORCE" != "true" ]]; then
    upgrade_action="candidate"
    plan_action="unsafe"
    if [[ "$CANDIDATE_ON_CONFLICT" == "true" ]]; then
      final_path="$path.generated.$STAMP"
      bootstrap_write_parent_is_eligible "$final_path" || fail "refusing unsafe candidate parent: $(bootstrap_path_diagnostic "$(dirname "$final_path")")"
      ensure_dir "$(dirname "$final_path")"
      log "Existing unsafe file preserved: $path"
      log "Writing candidate: $final_path"
    else
      log "Skipping unsafe existing file: $path"
      rm -f "$input_tmp"
      return 0
    fi
  elif bootstrap_existing_file_is_eligible "$path" && [[ "$FORCE" != "true" ]]; then
    upgrade_action="candidate"
    if [[ "$CANDIDATE_ON_CONFLICT" == "true" ]]; then
      upgrade_action="$(harness_upgrade_decision "$path" "$baseline_rel" "$input_tmp" "$merged_tmp")"
    fi
    plan_action="$upgrade_action"
    case "$upgrade_action" in
      update) log "Updated unmodified file: $path" ;;
      merge) log "Merged kit changes into local edits: $path" ;;
      kept)
        log "Kept local edits (kit output unchanged): $path"
        harness_plan_log kept "$path"
        rm -f "$input_tmp" "$merged_tmp"
        LAST_WRITTEN_FILE="$path"
        record_generated_file "$path"
        return
        ;;
    esac
    if [[ "$upgrade_action" != "candidate" ]]; then
      :
    elif [[ "$CANDIDATE_ON_CONFLICT" == "true" ]]; then
      plan_action="conflict"
      final_path="$path.generated.$STAMP"
      ensure_dir "$(dirname "$final_path")"
      log "Existing file preserved: $path"
      log "Writing candidate: $final_path"
    else
      log "Skipping existing file: $path"
      rm -f "$input_tmp"
      return
    fi
  fi
  if [[ "$final_path" == "$path" ]]; then
    backup_existing "$path" || {
      rm -f "$input_tmp" "$merged_tmp"
      return 1
    }
  fi
  harness_plan_log "$plan_action" "$path"
  if [[ "$path" == "$TARGET_DIR"/* ]]; then
    case "$upgrade_action" in
      candidate) harness_journal_add candidate "${final_path#"$TARGET_DIR"/}" ;;
      create) harness_journal_add create "${path#"$TARGET_DIR"/}" ;;
      *) harness_journal_add "$upgrade_action" "${path#"$TARGET_DIR"/}" "$path" ;;
    esac
  fi
  # Atomic write: stage in the same dir, then rename into place so an abort
  # mid-write (e.g. --force --no-backup) cannot truncate an existing file.
  tmp="${final_path}.tmp.$$"
  if [[ "$upgrade_action" == "merge" ]]; then
    cat "$merged_tmp" > "$tmp"
  else
    cat "$input_tmp" > "$tmp"
  fi
  if [[ "$upgrade_action" != "candidate" ]]; then
    harness_baseline_record "$baseline_rel" "$input_tmp"
  fi
  rm -f "$input_tmp" "$merged_tmp"
  mv "$tmp" "$final_path"
  LAST_WRITTEN_FILE="$final_path"
  record_generated_file "$final_path"
}

write_overlay_file() {
  local path="$1" tmp_new merged
  tmp_new="$(mktemp)"
  cat > "$tmp_new"
  if bootstrap_existing_file_is_eligible "$path"; then
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
  local content base
  [[ "$DRY_RUN" == "true" ]] && return 0
  bootstrap_existing_file_is_eligible "$path" || {
    bootstrap_entry_exists "$path" && log "warn: refusing unsafe placeholder read: $(bootstrap_path_diagnostic "$path")"
    return 0
  }
  # Pure-bash substitution (no python3 dependency). The value is a slash-free
  # preset token (full/infra) and the placeholder has no glob metacharacters, so
  # parameter expansion is safe. Generated files carry exactly one trailing
  # newline; `cat` strips it and `printf '%s\n'` restores it byte-for-byte.
  content="$(cat "$path")"
  printf '%s\n' "${content//$placeholder/$value}" > "$path"
  case "$path" in
    *.generated.*)
      base="${path%.generated.*}"
      if bootstrap_existing_file_is_eligible "$base" && cmp -s "$path" "$base"; then
        rm -f "$path"
        LAST_WRITTEN_FILE="$base"
        log "Generated candidate matched existing file after placeholder replacement: $base"
      fi
      ;;
  esac
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

# Harness baseline: the last kit output of every generated file, kept local-only
# under .tools/ so an upgrade can tell kit changes from local edits. The content
# policy excludes .tools/, so harness state paths get their own link check.
HARNESS_BASELINE_DIR=".tools/agent-state/harness-baseline"
HARNESS_JOURNAL_KEEP=10

harness_state_path_is_safe() {
  # Pure bash: called for every generated file, so no python round trip.
  local path="$1" rel current part
  local -a parts
  case "$path" in
    "$TARGET_DIR"/*) rel="${path#"$TARGET_DIR"/}" ;;
    *) return 1 ;;
  esac
  case "/$rel/" in
    */../*|*/./*) return 1 ;;
  esac
  IFS=/ read -r -a parts <<<"$rel"
  [[ ${#parts[@]} -gt 0 ]] || return 1
  current="$TARGET_DIR"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ -L "$current" ]] && return 1
    [[ -e "$current" ]] || break
  done
  return 0
}

harness_baseline_relpath() {
  local path="$1" relpath
  case "$path" in
    "$TARGET_DIR"/*) relpath="${path#"$TARGET_DIR"/}" ;;
    *) return 1 ;;
  esac
  case "$relpath" in
    *.generated.*|.tools/*) return 1 ;;
  esac
  is_bootstrap_user_owned_relpath "$relpath" && return 1
  printf '%s\n' "$relpath"
}

harness_baseline_file() {
  printf '%s/%s/files/%s\n' "$TARGET_DIR" "$HARNESS_BASELINE_DIR" "$1"
}

harness_baseline_readable() {
  local file
  file="$(harness_baseline_file "$1")"
  [[ -f "$file" && ! -L "$file" ]] && harness_state_path_is_safe "$file"
}

harness_state_copy() {
  local source="$1" dest="$2"
  [[ "$DRY_RUN" == "true" ]] && return 0
  harness_state_path_is_safe "$dest" || {
    log "warn: refusing unsafe harness state path: $dest"
    return 1
  }
  mkdir -p "$(dirname "$dest")" && cp -p "$source" "$dest.tmp.$$" && mv "$dest.tmp.$$" "$dest"
}

harness_baseline_record() {
  [[ -n "$1" ]] || return 0
  harness_state_copy "$2" "$(harness_baseline_file "$1")" || true
}

harness_plan_log() {
  [[ -n "${AGENT_BOOTSTRAP_PLAN_LOG:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "${2#"$TARGET_DIR"/}" >> "$AGENT_BOOTSTRAP_PLAN_LOG"
}

harness_fill_workflow_placeholder() {
  # Resolve the preset placeholder before comparing, so an unchanged hook is up
  # to date instead of a candidate that replace_placeholder later discards.
  local file="$1" content
  grep -q '__WORKFLOW_PRESET__' "$file" 2>/dev/null || return 0
  content="$(cat "$file")"
  printf '%s\n' "${content//__WORKFLOW_PRESET__/$WORKFLOW_PRESET}" > "$file"
}

harness_upgrade_decision() {
  # Prints update (no local edits), kept (kit output unchanged), merge (clean
  # three-way merge in $4) or candidate (conflict, or no usable baseline).
  local path="$1" relpath="$2" new="$3" merged="$4" base
  if [[ -z "$relpath" ]] || ! harness_baseline_readable "$relpath"; then
    printf 'candidate\n'
    return 0
  fi
  base="$(harness_baseline_file "$relpath")"
  if cmp -s "$path" "$base"; then
    printf 'update\n'
  elif [[ "$relpath" == *.json ]]; then
    # Structured (often machine-owned) files are never merged or kept line by
    # line: an edited one gets a candidate, as before baselines.
    printf 'candidate\n'
  elif cmp -s "$new" "$base"; then
    printf 'kept\n'
  elif command -v git >/dev/null 2>&1 &&
    git merge-file -p -L local -L previous-kit -L new-kit "$path" "$base" "$new" >"$merged" 2>/dev/null; then
    printf 'merge\n'
  else
    printf 'candidate\n'
  fi
}

harness_journal_dir() {
  printf '%s/%s/upgrades/%s\n' "$TARGET_DIR" "$HARNESS_BASELINE_DIR" "$STAMP"
}

harness_journal_add() {
  # action relpath [pre-image]: record one change of this run for --rollback.
  local action="$1" relpath="$2" pre="${3:-}" dir
  [[ "$DRY_RUN" == "true" ]] && return 0
  dir="$(harness_journal_dir)"
  if [[ -f "$dir/entries.tsv" ]] && cut -f2 "$dir/entries.tsv" | grep -Fxq -- "$relpath"; then
    return 0
  fi
  if [[ -n "$pre" ]]; then
    harness_state_copy "$pre" "$dir/pre/$relpath" || return 0
  fi
  if [[ "$action" != "candidate" ]] && harness_baseline_readable "$relpath"; then
    harness_state_copy "$(harness_baseline_file "$relpath")" "$dir/base-pre/$relpath" || return 0
  fi
  harness_state_path_is_safe "$dir/entries.tsv" || return 0
  mkdir -p "$dir"
  printf '%s\t%s\n' "$action" "$relpath" >> "$dir/entries.tsv"
}

harness_journal_finalize() {
  # Seal this run's journal with post-change hashes: --rollback only undoes
  # files that still match them. Older journals beyond the newest
  # HARNESS_JOURNAL_KEEP are pruned.
  local dir
  [[ "$DRY_RUN" == "true" ]] && return 0
  dir="$(harness_journal_dir)"
  [[ -f "$dir/entries.tsv" && ! -L "$dir/entries.tsv" ]] || return 0
  harness_state_path_is_safe "$dir/entries.tsv" || return 0
  python3 - "$TARGET_DIR" "$dir" "$AGENT_BOOTSTRAP_VERSION" "$WORKFLOW_PRESET" "$HARNESS_JOURNAL_KEEP" <<'PY' || return 0
import hashlib
import json
import os
import shutil
import sys

root, jdir, version, workflow, keep = sys.argv[1:6]
rows = []
with open(os.path.join(jdir, "entries.tsv"), encoding="utf-8") as handle:
    for line in handle:
        action, rel = line.rstrip("\n").split("\t", 1)
        path = os.path.join(root, rel)
        post = "-"
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as data:
                post = hashlib.sha256(data.read()).hexdigest()
        rows.append(f"{action}\t{rel}\t{post}\n")
with open(os.path.join(jdir, "journal.tsv"), "a", encoding="utf-8") as handle:
    handle.writelines(rows)
os.remove(os.path.join(jdir, "entries.tsv"))
meta = os.path.join(jdir, "meta.json")
if not os.path.exists(meta):
    with open(meta, "w", encoding="utf-8") as handle:
        json.dump({"id": os.path.basename(jdir), "kit_version": version, "workflow_preset": workflow}, handle)
        handle.write("\n")
upgrades = os.path.dirname(jdir)
ids = sorted(name for name in os.listdir(upgrades)
             if os.path.isdir(os.path.join(upgrades, name)) and not os.path.islink(os.path.join(upgrades, name)))
for name in ids[: max(0, len(ids) - int(keep))]:
    shutil.rmtree(os.path.join(upgrades, name), ignore_errors=True)
PY
  log "Upgrade id: $STAMP (undo with --rollback $STAMP)"
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
