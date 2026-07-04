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
  local ro=false c d candidates
  candidates="$(find "$TARGET_DIR" \( -path "$TARGET_DIR/.git" -o -path "$TARGET_DIR/.tools" \) -prune -o -type f -name '*.generated.*' -print 2>/dev/null)"
  [[ -n "$candidates" ]] || { printf 'complete\n'; return 0; }
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    d="$(dirname "${c%.generated.*}")"
    [[ -w "$d" ]] || ro=true
  done <<< "$candidates"
  if [[ "$ro" == "true" ]]; then
    printf 'blocked-readonly\n'
  else
    printf 'pending\n'
  fi
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
  if [[ "$REFRESH_LOCK" == "true" ]]; then
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

append_gitignore_block() {
  local gitignore="$TARGET_DIR/.gitignore"
  local marker="# >>> multi-agent bootstrap local state >>>"
  local existed=false

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN update $gitignore"
    return
  fi

  [[ -f "$gitignore" ]] && existed=true
  [[ -f "$gitignore" ]] || touch "$gitignore"
  if grep -Fq "$marker" "$gitignore"; then
    return
  fi

  if [[ "$existed" == "true" && "$FORCE" != "true" && "$CANDIDATE_ON_CONFLICT" != "true" ]]; then
    log "Skipping existing file: $gitignore"
    return
  fi

  [[ "$existed" == "true" ]] && backup_existing "$gitignore"
  cat >> "$gitignore" <<'EOF'

# >>> multi-agent bootstrap local state >>>
AGENTS.local.md
CLAUDE.local.md
GEMINI.local.md
docs/agent-configs/*.local.md
.agents/*
!.agents/skills/
!.agents/skills/**
.agents/skills/**/*.bak.*
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
  record_generated_file "$gitignore"
}
