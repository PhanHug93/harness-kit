#!/usr/bin/env bash
# agent-bootstrap/lib/render.sh
# Sourced by bootstrap-multi-agent-project.sh. Overlay/lock/gitignore rendering.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

selected_template_overlays() {
  local stack
  for stack in "${TECH_STACKS[@]}"; do
    case "$stack" in
      android_kotlin|android_java|kotlin_gradle|java_gradle|python|python_fastapi|python_django|ios_swift|node_js|react|nextjs|vue|svelte|flutter_dart|go|rust|dotnet|php|php_laravel)
        printf '%s\n' "$stack"
        ;;
    esac
  done
}

render_stack_overlays() {
  local printed_any=false
  local stack
  for stack in "${TECH_STACKS[@]}"; do
    case "$stack" in
      android_kotlin|android_java)
        [[ "$printed_any" == "true" ]] && printf '\n'
        printed_any=true
        cat <<'EOF_OVERLAY'
### Android/Kotlin Overlay

- Prefer existing Android architecture and Gradle module boundaries.
- Verify with project-specific Gradle tasks from this context.
- Treat manifests, resources, navigation graphs, DI, R8/ProGuard, Firebase, and build variants as protected areas.
EOF_OVERLAY
        ;;
      python|python_fastapi|python_django)
        [[ "$printed_any" == "true" ]] && printf '\n'
        printed_any=true
        cat <<'EOF_OVERLAY'
### Python Overlay

- Prefer existing package/test layout before introducing new structure.
- Verify with detected test/lint commands only after confirming they exist.
- Do not apply Android/Gradle protected-path rules to Python projects.
EOF_OVERLAY
        ;;
      ios_swift)
        [[ "$printed_any" == "true" ]] && printf '\n'
        printed_any=true
        cat <<'EOF_OVERLAY'
### iOS/Swift Overlay

- Inspect `.xcodeproj`, `.xcworkspace`, `Package.swift`, `Podfile`, and scheme layout before proposing verification.
- `xcodebuild -list` is discovery only, not a build proof.
- Do not apply Android/Gradle protected-path rules to iOS projects.
EOF_OVERLAY
        ;;
      node_js|react|nextjs|vue|svelte)
        [[ "$printed_any" == "true" ]] && printf '\n'
        printed_any=true
        cat <<'EOF_OVERLAY'
### Node/Web Overlay

- Confirm whether `package.json` is production code or local tooling before applying frontend rules.
- Prefer package-manager scripts actually present in `package.json`.
- Do not assume `npm test`, `npm run lint`, or `npm run build` exists without checking scripts.
EOF_OVERLAY
        ;;
    esac
  done
  if [[ "$printed_any" != "true" ]]; then
    cat <<'EOF_OVERLAY'
### Generic Overlay

- Treat all verification commands as placeholders until project scripts are inspected.
- Ask for the smallest missing context before implementation if stack behavior is ambiguous.
- Do not import Android, iOS, Python, or Node-specific rules by default.
EOF_OVERLAY
  fi
}

compute_apply_state() {
  local ro=false eligible=false c d rel candidates detect_root="${DETECT_ROOT:-$TARGET_DIR}"
  candidates="$(bootstrap_find_pruned "$TARGET_DIR" -type f -name '*.generated.*' -print 2>/dev/null)"
  # A preview generates into staging, which holds only the candidates beside
  # harness outputs; the real tree's candidates (codegen sources, retired
  # paths, ...) count as they do in a real run.
  if [[ "$detect_root" != "$TARGET_DIR" ]]; then
    candidates+=$'\n'"$(bootstrap_find_pruned "$detect_root" -type f -name '*.generated.*' -print 2>/dev/null)"
  fi
  [[ -n "${candidates//$'\n'/}" ]] || { printf 'complete\n'; return 0; }
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    case "$c" in
      "$TARGET_DIR"/*) rel="${c#"$TARGET_DIR"/}" ;;
      *) rel="${c#"$detect_root"/}" ;;
    esac
    # Retired migration input, also excluded by candidate count/application.
    # Keep existing handling for every other candidate; an approximate second
    # allowlist can miss valid installers or future generated surfaces.
    [[ "${rel%.generated.*}" == "docs/agent-configs/model-profiles.json" ]] && continue
    eligible=true
    d="$(dirname "${c%.generated.*}")"
    [[ -w "$d" ]] || ro=true
  done <<< "$candidates"
  [[ "$eligible" == "true" ]] || { printf 'complete\n'; return 0; }
  if [[ "$ro" == "true" ]]; then
    printf 'blocked-readonly\n'
  else
    printf 'pending\n'
  fi
}

# True when the lock exists and equals its harness baseline copy.
lock_matches_baseline() {
  local lock="$1" rel base
  [[ -f "$lock" && ! -L "$lock" ]] || return 1
  rel="$(harness_baseline_relpath "$lock")" || return 1
  harness_baseline_readable "$rel" || return 1
  base="$(harness_baseline_file "$rel")"
  cmp -s "$lock" "$base"
}

write_agent_bootstrap_lock() {
  local lock_file="$TARGET_DIR/docs/agent-configs/agent-bootstrap.lock.json"
  local summary hash overlays overlay_json skills_json skill_metadata_json first saved_force saved_candidate
  local apply_state lock_generated_at existing_generated_at existing_version existing_channel existing_project existing_workflow existing_hash existing_apply_state
  local existing_skills current_skills existing_skill_metadata current_skill_metadata
  summary="$(detector_summary_for_lock)"
  hash="$(printf '%s' "$summary" | hash_text)"
  overlays="$(selected_template_overlays | sort -u)"
  skills_json="$(selected_optional_skills_json)"
  skill_metadata_json="$(selected_optional_skill_metadata_json)"
  apply_state="$(compute_apply_state)"
  overlay_json=""
  first=true
  while IFS= read -r overlay; do
    [[ -n "$overlay" ]] || continue
    if [[ "$first" == "true" ]]; then
      first=false
    else
      overlay_json+=", "
    fi
    overlay_json+="\"$(json_escape "$overlay")\""
  done <<< "$overlays"
  [[ -n "$overlay_json" ]] || overlay_json='"generic"'
  [[ -n "$skills_json" ]] || skills_json=""
  lock_generated_at="$STAMP"
  if [[ -f "$lock_file" ]]; then
    existing_generated_at="$(read_lock_value generated_at "$lock_file")"
    existing_version="$(read_lock_value version "$lock_file")"
    existing_channel="$(read_lock_value channel "$lock_file")"
    existing_project="$(read_lock_value project_name "$lock_file")"
    existing_workflow="$(read_lock_value workflow_preset "$lock_file")"
    existing_hash="$(read_lock_value detector_summary_sha256 "$lock_file")"
    existing_apply_state="$(read_lock_value apply_state "$lock_file")"
    existing_skills="$(read_lock_skills "$lock_file" | sort | tr '\n' ',')"
    current_skills="$(selected_optional_skills | sort | tr '\n' ',')"
    existing_skill_metadata="$(read_lock_skill_metadata_json "$lock_file")"
    current_skill_metadata="$skill_metadata_json"
    if [[ -n "$existing_generated_at" ]] &&
      [[ "$existing_version" == "$AGENT_BOOTSTRAP_VERSION" ]] &&
      [[ "$existing_channel" == "$AGENT_BOOTSTRAP_CHANNEL" ]] &&
      [[ "$existing_project" == "$PROJECT_NAME" ]] &&
      [[ "$existing_workflow" == "$WORKFLOW_PRESET" ]] &&
      [[ "$existing_hash" == "$hash" ]] &&
      [[ "$existing_apply_state" == "$apply_state" ]] &&
      [[ "$existing_skills" == "$current_skills" ]] &&
      [[ "$existing_skill_metadata" == "$current_skill_metadata" ]]; then
      lock_generated_at="$existing_generated_at"
    fi
  fi

  saved_force="$FORCE"
  saved_candidate="$CANDIDATE_ON_CONFLICT"
  # The lock is machine state, never user content: when it differs from its
  # baseline (or has none) it is rewritten in place (backup rules unchanged)
  # instead of becoming a candidate; an unedited lock takes the normal update
  # path. --skip-existing still skips it, and a --keep pin still wins.
  if [[ "$REFRESH_LOCK" == "true" ]] ||
    { [[ "$CANDIDATE_ON_CONFLICT" == "true" ]] && ! lock_matches_baseline "$lock_file"; }; then
    FORCE=true
    CANDIDATE_ON_CONFLICT=false
  fi
  write_file "$lock_file" <<EOF_LOCK
{
  "schema": "agent-bootstrap-lock/v1",
  "version": "$AGENT_BOOTSTRAP_VERSION",
  "channel": "$AGENT_BOOTSTRAP_CHANNEL",
  "skills": [$skills_json],
  "skill_metadata": $skill_metadata_json,
  "project_name": "$(json_escape "$PROJECT_NAME")",
  "generated_at": "$lock_generated_at",
  "apply_state": "$apply_state",
  "rtk": {
    "required": true,
    "version": "$RTK_VERSION",
    "install_command": "bash scripts/install-rtk.sh"
  },
  "templates": {
    "base": "docs/agent-configs/bootstrap-multi-agent-project/templates/base",
    "overlays": [$overlay_json],
    "workflow_preset": "$(json_escape "$WORKFLOW_PRESET")"
  },
  "detector_summary_sha256": "$hash",
  "detector_summary": "$(json_escape "$summary")"
}
EOF_LOCK
  FORCE="$saved_force"
  CANDIDATE_ON_CONFLICT="$saved_candidate"
}

# Resolves where the local-only ignore block lives. Sets IGNORE_RESOLVED
# (exclude|gitignore|none) and IGNORE_EXCLUDE_FILE. Quiet; the caller logs.
# Order: --ignore-target, then the file already holding the marker
# (.gitignore first, then .git/info/exclude), then the exclude file.
IGNORE_BLOCK_MARKER="# >>> multi-agent bootstrap local state >>>"
IGNORE_RESOLVED=""
IGNORE_EXCLUDE_FILE=""
IGNORE_NOT_GIT=false

ignore_exclude_path() {
  local path
  path="$(git -C "$TARGET_DIR" rev-parse --git-path info/exclude 2>/dev/null)" || return 1
  [[ -n "$path" ]] || return 1
  case "$path" in
    /*) ;;
    *) path="$TARGET_DIR/$path" ;;
  esac
  printf '%s\n' "$path"
}

resolve_ignore_target() {
  local want="${IGNORE_TARGET:-}" exclude_file=""
  IGNORE_NOT_GIT=false
  IGNORE_EXCLUDE_FILE=""
  exclude_file="$(ignore_exclude_path)" || exclude_file=""
  if [[ -z "$want" ]]; then
    if [[ -f "$TARGET_DIR/.gitignore" ]] && grep -Fq "$IGNORE_BLOCK_MARKER" "$TARGET_DIR/.gitignore" 2>/dev/null; then
      want=gitignore
    elif [[ -n "$exclude_file" && -f "$exclude_file" ]] && grep -Fq "$IGNORE_BLOCK_MARKER" "$exclude_file" 2>/dev/null; then
      want=exclude
    else
      want=exclude
    fi
  fi
  if [[ "$want" == "exclude" && -z "$exclude_file" ]]; then
    IGNORE_NOT_GIT=true
    want=gitignore
  fi
  IGNORE_RESOLVED="$want"
  IGNORE_EXCLUDE_FILE="$exclude_file"
}

emit_ignore_block() {
  cat <<'EOF'
# >>> multi-agent bootstrap local state >>>
# Harness-kit generated files and local harness source/cache copies stay local-only.
/harness-kit/
/.harness-kit/
/agent-bootstrap/
AGENTS.md
AGENTS.md.generated.*
CLAUDE.md
CLAUDE.md.generated.*
GEMINI.md
GEMINI.md.generated.*
.windsurfrules
.windsurfrules.generated.*
docs/agent-configs/
docs/superpowers/specs/README.md
docs/superpowers/specs/README.md.generated.*
docs/superpowers/specs/project-tech-stack.md
docs/superpowers/specs/project-tech-stack.md.generated.*
docs/superpowers/specs/project-tech-stack.json
docs/superpowers/specs/project-tech-stack.json.generated.*
# Development records are local-only: only specs of started work and plan
# journals are pushed. Draft specs and analyses stay in
# docs/superpowers/plans/<topic>/ until the work starts; plans never leave.
docs/superpowers/*
!docs/superpowers/specs/
!docs/superpowers/plans/
docs/superpowers/plans/**
!docs/superpowers/plans/*/
!docs/superpowers/plans/*/journal.md
.agents/
.claude/
.codex/
.cursor/rules/
.windsurf/rules/
scripts/agent-tech-stack-lib.sh
scripts/detect-agent-tech-stack.sh
scripts/agent-hook.sh
scripts/agent-guard.sh
scripts/agent-tier.py
scripts/agent-seats.sh
scripts/agent-onboarding.sh
scripts/agent-local-only-check.sh
scripts/verify-ai-deps.sh
scripts/install-git-hooks.sh
scripts/install-rtk.sh
scripts/rtk
scripts/harness-kit.sh
scripts/githooks/
.gitignore.generated.*
AGENTS.local.md
CLAUDE.local.md
GEMINI.local.md
docs/agent-configs/*.local.md
.agents/runtime/
.agents/state/
.agents/cache/
.codex-mode-lock
.codex/*.bak.*
.codex/.setup-*.state
.codex/.setup-*.bootstrap
.codex/environments/
.claude/settings.local.json
.claude/worktrees/
.tools/
.gemini/
.windsurf/
.openclaude/
.openclaude-profile.json
.cursor/rules-local/
.cursor/**/*.local.mdc
.superpowers/brainstorm/
*.bak.*
.DS_Store
# <<< multi-agent bootstrap local state <<<
EOF
}

write_ignore_block() {
  resolve_ignore_target
  case "$IGNORE_RESOLVED" in
    none) return 0 ;;
    exclude) write_ignore_block_exclude ;;
    *)
      [[ "$IGNORE_NOT_GIT" != "true" ]] ||
        log "warn: target is not a Git repository; writing the local-only block to .gitignore"
      write_ignore_block_gitignore
      ;;
  esac
}

# Below the repository top level, exclude patterns apply from the repo root, so
# the block is anchored under the target's prefix and its marker carries it.
emit_ignore_block_for_exclude() {
  local prefix="$1"
  if [[ -z "$prefix" ]]; then
    emit_ignore_block
    return
  fi
  emit_ignore_block | awk -v prefix="$prefix" -v marker="$IGNORE_BLOCK_MARKER" '
    /^#/ {
      if (index($0, marker) == 1 || index($0, "# <<< multi-agent bootstrap local state <<<") == 1) { print $0 " " prefix } else { print }
      next
    }
    /^[[:space:]]*$/ { print; next }
    {
      pat = $0; neg = ""
      if (substr(pat, 1, 1) == "!") { neg = "!"; pat = substr(pat, 2) }
      if (substr(pat, 1, 1) == "/") { sub(/^\//, "", pat); print neg "/" prefix pat; next }
      body = pat; sub(/\/$/, "", body)
      if (index(body, "/") > 0) { print neg "/" prefix pat } else { print neg "/" prefix "**/" pat }
    }'
}

write_ignore_block_exclude() {
  local exclude="$IGNORE_EXCLUDE_FILE" prefix marker rc=0
  prefix="$(git -C "$TARGET_DIR" rev-parse --show-prefix 2>/dev/null || true)"
  marker="$IGNORE_BLOCK_MARKER"
  [[ -z "$prefix" ]] || marker="$marker $prefix"
  if [[ -L "$exclude" ]]; then
    log "warn: refusing unsafe exclude file (symbolic link): $exclude"
    return 1
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN update $exclude"
    return 0
  fi
  if [[ -f "$exclude" ]] && grep -Fxq "$marker" "$exclude"; then
    # A newer kit adds entries: refresh the managed block in place. Lines
    # outside it are never touched, and a current block is not rewritten.
    ignore_block_sync write "$exclude" "$marker" "$(emit_ignore_block_for_exclude "$prefix")" || rc=$?
    case "$rc" in
      0) ;;
      10) log "Refreshed the local-only ignore block in $exclude" ;;
      *) log "warn: local-only ignore block in $exclude has no end marker; left unchanged" ;;
    esac
    return 0
  fi
  mkdir -p "$(dirname "$exclude")"
  local sep=""
  [[ ! -s "$exclude" ]] || [[ -z "$(tail -c 1 "$exclude")" ]] || sep=$'\n'
  { printf '%s' "$sep"; emit_ignore_block_for_exclude "$prefix"; } >> "$exclude"
}

# ignore_block_sync check|write FILE BEGIN BLOCK: compares the managed block
# starting at the line BEGIN (through BLOCK's own last line) with BLOCK.
# Exit 0 current, 10 stale (rewritten in place by write; every line outside
# the block kept byte for byte), 2 no such block, 3 no end marker (untouched).
ignore_block_sync() {
  python3 -I -B - "$@" <<'PY'
import os
import sys
import tempfile

mode, path, begin, block = sys.argv[1:5]
want = block.split("\n")
end = want[-1]
with open(path, encoding="utf-8", errors="surrogateescape", newline="") as handle:
    lines = handle.read().splitlines(keepends=True)
plain = [line.rstrip("\r\n") for line in lines]
if begin not in plain:
    sys.exit(2)
start = plain.index(begin)
if end not in plain[start + 1:]:
    sys.exit(3)
stop = plain.index(end, start + 1)
if plain[start:stop + 1] == want:
    sys.exit(0)
if mode == "write":
    text = "".join(lines[:start]) + "".join(line + "\n" for line in want) + "".join(lines[stop + 1:])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".ignore-block.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as handle:
            handle.write(text)
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
sys.exit(10)
PY
}

# .gitignore is tracked, so a stale block there is refreshed in place only on
# an explicit --ignore-target gitignore --force (with its backup), never by a
# preview's staged run. Otherwise the current block also goes to the
# repository's exclude file, so new kit files stay ignored without a tracked
# change; the ignore-block-to-exclude migration then removes the old block.
refresh_gitignore_block() {
  local gitignore="$1" block rc=0
  block="$(emit_ignore_block)"
  ignore_block_sync check "$gitignore" "$IGNORE_BLOCK_MARKER" "$block" || rc=$?
  [[ "$rc" -eq 10 ]] || return 0
  if [[ "${IGNORE_TARGET:-}" == "gitignore" && "${FORCE:-}" == "true" &&
    -z "${AGENT_BOOTSTRAP_WRITE_LOG:-}${AGENT_BOOTSTRAP_PLAN_LOG:-}" ]]; then
    backup_existing "$gitignore" || return 1
    rc=0
    ignore_block_sync write "$gitignore" "$IGNORE_BLOCK_MARKER" "$block" || rc=$?
    [[ "$rc" -eq 10 ]] || return 1
    log "Refreshed the local-only ignore block in $gitignore"
    record_generated_file "$gitignore"
    return 0
  fi
  if [[ -n "$IGNORE_EXCLUDE_FILE" ]]; then
    log "warn: .gitignore holds an older local-only block; the current block goes to $IGNORE_EXCLUDE_FILE (move it there with the ignore-block-to-exclude migration, or refresh .gitignore with --ignore-target gitignore --force)"
    write_ignore_block_exclude || true
  else
    log "warn: .gitignore holds an older local-only block; refresh it with --ignore-target gitignore --force"
  fi
}

write_ignore_block_gitignore() {
  local gitignore="$TARGET_DIR/.gitignore"
  local marker="$IGNORE_BLOCK_MARKER"
  local existed=false

  if bootstrap_entry_exists "$gitignore"; then
    if ! bootstrap_existing_file_is_eligible "$gitignore"; then
      log "warn: refusing unsafe .gitignore entry: $(bootstrap_path_diagnostic "$gitignore")"
      return 1
    fi
  else
    bootstrap_write_parent_is_eligible "$gitignore" || {
      log "warn: refusing unsafe .gitignore parent: $(bootstrap_path_diagnostic "$(dirname "$gitignore")")"
      return 1
    }
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN update $gitignore"
    if [[ ! -f "$gitignore" ]] || ! grep -Fq "$marker" "$gitignore"; then
      record_generated_file "$gitignore"
    fi
    return
  fi

  [[ -f "$gitignore" ]] && existed=true
  [[ -f "$gitignore" ]] || touch "$gitignore"
  if grep -Fq "$marker" "$gitignore"; then
    refresh_gitignore_block "$gitignore"
    return
  fi

  if [[ "$existed" == "true" && "$FORCE" != "true" && "$CANDIDATE_ON_CONFLICT" != "true" ]]; then
    log "Skipping existing file: $gitignore"
    return
  fi

  [[ "$existed" == "true" ]] && backup_existing "$gitignore"
  { printf '\n'; emit_ignore_block; } >> "$gitignore"
  record_generated_file "$gitignore"
}
