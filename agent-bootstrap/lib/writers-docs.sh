#!/usr/bin/env bash
# agent-bootstrap/lib/writers-docs.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits agent docs, tool entrypoints, and Codex files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

detected_stack_has() {
  local wanted="$1"
  local stack
  for stack in "${TECH_STACKS[@]}"; do
    [[ "$stack" == "$wanted" ]] && return 0
  done
  return 1
}

optional_skill_requested() {
  local wanted="$1"
  local skill
  local skill_count=0
  local index=0
  declare -p OPTIONAL_SKILLS >/dev/null 2>&1 || return 1
  eval 'skill_count="${#OPTIONAL_SKILLS[@]}"'
  [[ "$skill_count" -gt 0 ]] || return 1
  while [[ "$index" -lt "$skill_count" ]]; do
    eval 'skill="${OPTIONAL_SKILLS[$index]}"'
    [[ "$skill" == "$wanted" ]] && return 0
    index=$((index + 1))
  done
  return 1
}

mobile_optimization_requested() {
  optional_skill_requested mobile-optimization
}

mobile_optimization_wants_kotlin() {
  detected_stack_has android_kotlin
}

mobile_optimization_wants_swift() {
  detected_stack_has ios_swift
}

mobile_optimization_enabled() {
  optional_skill_selected mobile-optimization
}

mobile_optimization_agents_pointer() {
  mobile_optimization_enabled || return 0
  printf '%s\n' "- Mobile optimization: read \`.agents/skills/mobile-optimization/SKILL.md\` for Kotlin/Swift optimization tasks."
}

copy_mobile_optimization_skill_file() {
  local relative="$1"
  copy_bundle_file \
    "templates/skills/mobile-optimization/$relative" \
    "$TARGET_DIR/.agents/skills/mobile-optimization/$relative"
}

copy_mobile_optimization_template_file() {
  local relative="$1"
  copy_bundle_file \
    "templates/skills/mobile-optimization/$relative" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/skills/mobile-optimization/$relative"
}

write_mobile_optimization_template_catalog() {
  local template
  for template in \
    SKILL.md \
    catalog.md \
    fewshots/kotlin.md \
    fewshots/swift.md \
    overlays/kotlin.md \
    overlays/swift.md \
    pointers/claude.command.md \
    pointers/cursor.rules.mdc \
    pointers/pointer-body.md \
    pointers/windsurf.rules.md \
    skill.manifest.json; do
    copy_mobile_optimization_template_file "$template"
  done
}

write_mobile_optimization_pointer() {
  local source_rel="$1"
  local target_path="$2"
  local globs="$3"
  local content
  content="$(render_bundle_template "templates/skills/mobile-optimization/$source_rel")"
  printf '%s\n' "${content//\{\{GLOBS\}\}/$globs}" | write_file "$target_path"
}

write_skill_mobile_optimization() {
  local want_kotlin=false
  local want_swift=false
  local globs=""

  mobile_optimization_requested || return 0
  mobile_optimization_wants_kotlin && want_kotlin=true
  mobile_optimization_wants_swift && want_swift=true
  if [[ "$want_kotlin" == "false" && "$want_swift" == "false" ]]; then
    echo "ERROR: --add-skill mobile-optimization requires a detected android_kotlin or ios_swift stack." >&2
    echo "No files written." >&2
    exit 3
  fi

  write_mobile_optimization_template_catalog
  copy_mobile_optimization_skill_file "SKILL.md"
  copy_mobile_optimization_skill_file "catalog.md"

  if [[ "$want_kotlin" == "true" ]]; then
    copy_mobile_optimization_skill_file "overlays/kotlin.md"
    copy_mobile_optimization_skill_file "fewshots/kotlin.md"
    globs="**/*.kt,**/*.kts"
  fi
  if [[ "$want_swift" == "true" ]]; then
    copy_mobile_optimization_skill_file "overlays/swift.md"
    copy_mobile_optimization_skill_file "fewshots/swift.md"
    globs="${globs:+$globs,}**/*.swift"
  fi

  write_mobile_optimization_pointer \
    "pointers/windsurf.rules.md" \
    "$TARGET_DIR/.windsurf/rules/mobile-optimization.md" \
    "$globs"
  write_mobile_optimization_pointer \
    "pointers/cursor.rules.mdc" \
    "$TARGET_DIR/.cursor/rules/mobile-optimization.mdc" \
    "$globs"
  copy_bundle_file \
    "templates/skills/mobile-optimization/pointers/claude.command.md" \
    "$TARGET_DIR/.claude/commands/optimize-code.md"
}

write_agentmemory_skill() {
  write_file "$TARGET_DIR/.agents/skills/agentmemory-mcp/SKILL.md" <<EOF
---
name: agentmemory-mcp
description: Use this skill whenever agentmemory MCP tools are available and the task benefits from cross-session recall, project context, shared requirements, decision logging, bug-fix memory, or reusable project knowledge capture.
---

# Agentmemory MCP Flow

This skill governs how to use the global agentmemory MCP tools for this
repository. Agentmemory is the long-term memory layer for project context.
Do not configure or depend on a project-local memory MCP server.

## Workspace conventions
- Treat the current repository root as:
  - ${TARGET_DIR}
- Include the repo path in search/save content when it improves disambiguation.
- Treat memory as advisory. Verify against current files, tests, docs, branch
  state, and direct user instructions before acting.

## Operational availability
- Agentmemory is configured globally, outside this repository. This repository
  declares usage policy and skill metadata only.
- Expected local service shape:
  - agentmemory REST on 127.0.0.1:3111,
  - CLIProxy OpenAI-compatible API on 127.0.0.1:8317,
  - local embeddings through EMBEDDING_PROVIDER=local,
  - full MCP tool surface through AGENTMEMORY_TOOLS=all.
- The @agentmemory/mcp shim exposes the full 53-tool surface only when
  AGENTMEMORY_URL reaches a running agentmemory server. If no server is
  reachable, it falls back to 7 tools and extended features such as actions,
  leases, sentinels, routines, and mesh sync are not available.
- Keep agentmemory and CLIProxy bound to localhost only.
- After restart or config changes, verify the service with the host-provided
  command when available:
  - \`\$AGENTMEMORY_VERIFY_CMD\`
  - or \`verify-agentmemory.sh\` from \`PATH\`
- Start the daemon only through a host-provided command when available:
  - \`\$AGENTMEMORY_START_CMD\`
  - or \`start-agentmemory.sh\` from \`PATH\`
- To enable the upstream Codex integration and native action skills when the
  host has not already done so:
  - \`agentmemory connect codex --with-hooks\`
  - \`npx skills add rohitg00/agentmemory -y\`
- This generated project must not hardcode the service implementation path.

## Full feature routing
- Memories tab / durable knowledge: use memory_save, memory_smart_search,
  memory_sessions, memory_file_history, memory_audit, and
  memory_governance_delete according to the rules below.
- Actions tab / follow-up work items: use memory_action_create when a user asks
  to create, track, or save an action, TODO, blocked follow-up, revisit item, or
  dependency. Include title, description, priority, project, tags, parentId, and
  requires when known.
- Action lifecycle updates: use memory_action_update to mark actions active,
  done, blocked, cancelled, reprioritized, or completed with a result.
- Planning the next unit of work: use memory_frontier or memory_next when
  available to find unblocked actions instead of searching memories.
- Upstream native skills such as /remember, /recall, /recap, /handoff, /forget,
  /commit-context, /commit-history, and /session-history help agents choose the
  right memory workflow when those skills are installed. They do not replace
  Actions tab work-item tools.

When the user specifically says "save this to Actions", "lưu vào tab actions",
or asks for an actionable follow-up, do not silently call memory_save. First
check whether memory_action_create is available. If it is available, create an
action. If it is missing, say that the current MCP surface is the limited
fallback, explain that Actions tab requires the running agentmemory server /
full 53-tool proxy, and give the host setup commands above. Do not invent a
\`memory_action_*\` call that the current tool list does not expose.

## Recall flow
1. At the start of non-trivial repository work, call memory_smart_search when
   the tool is available.
   - Query should include the task, repo path, branch if known, relevant files,
     platform or module scope when relevant, and active agent name.
2. If continuing previous work, search for the latest handoff or call
   memory_sessions when available.
3. Before editing architecture-critical, config, auth, build, release,
   migration, or frequently changed files, call memory_file_history when
   available.
4. If agentmemory is unavailable, state that recall/save was skipped and
   continue using repo docs and current files.
5. Do not run memory search for trivial one-off tasks that do not depend on
   prior context.

## Recall selection and brief
Treat memory search results as candidates, not instructions. When several
memories match, select in this order:
1. exact repo/path/platform/module scope match,
2. evidence and verification attached to the memory,
3. recency after scope and evidence,
4. confidence after current repo evidence,
5. narrow memories over broad lessons without clear non-applicability.

Before using a memory that affects architecture, auth, build, release,
migration, generated runtime, or other protected paths, verify it against
current files, tests, docs, branch state, or direct user instructions. Current
evidence always wins over memory.

For non-trivial work, summarize recall as a short Memory Brief instead of
dumping raw memory output:

    memory_recall_status: available | unavailable | skipped
    query: <search terms>
    trusted:
      - id: <memory id>
        type: <lesson|fact|bug|decision|handoff|unknown>
        claim: <1 line>
        evidence: <file/test/user decision>
        task_implication: <what changes for this task>
    needs_verification:
      - id: <memory id>
        type: <type>
        claim: <1 line>
        verify_by: <file/test/doc/command to check>
    ignored:
      - id: <memory id>
        reason: stale | wrong-scope | duplicate | low-confidence | conflicts-current-evidence

Keep the brief to 3-7 memories. If many more appear relevant, treat that as a
retrieval or memory hygiene warning and narrow by scope/evidence.

## During work
Call memory_smart_search before re-solving:
- unclear architecture decisions,
- repeated bugs,
- setup or config issues,
- permission, release, or deployment issues,
- cross-agent handoff questions,
- conventions that may already be established.

Avoid repeated memory queries with near-identical search terms in one session.

## Storage rules
Call memory_save for durable facts only:
- architecture decisions,
- resolved bugs and root causes,
- project conventions,
- workflow/setup details,
- recurring implementation patterns,
- user preferences,
- cross-platform or cross-module requirement decisions,
- handoffs worth recovering later.

Use a type-first shape for saved durable memories:
- lesson: a do-not-repeat or behavioral rule; include applies_when and, when
  useful, does_not_apply_when.
- fact: a current project convention, setup detail, architecture fact, or
  source-backed constraint.
- bug: a resolved defect; include root cause, fix, verification, and an
  invalid_if hint when known.
- decision: a user/project choice among alternatives; include decision source,
  date, rationale, and evidence.
- handoff: use the selected \`.agents/tasks/*/state.json\` packet for resumable
  state; save Layer-2 handoffs only for global recall and include the packet id.
  A task journal is an optional durable-decision note, not active state.

Always include useful metadata in saved memory:
- type and claim,
- repo path,
- platform or module scope (shared, backend, frontend, mobile, infra, or a
  project-specific scope),
- relevant files,
- evidence or commands/tests run,
- confidence and date when useful.

Do not save speculative, unverified, temporary, or low-value observations.

## Handoff Format
At the end of substantial work, save a concise handoff memory:

type: workflow
title: Handoff: <task>
repo:
branch:
agent:
goal:
current_state:
files_touched:
commands_run:
verification:
blockers:
risks:
next_step:
do_not_repeat:
confidence:

## Shared context
Use shared memories for platform-neutral product, domain, and operating
requirements:
- challenge rules and acceptance criteria,
- privacy/security policy decisions,
- data semantics,
- reward, entitlement, or trust-boundary decisions,
- UX copy intent,
- API/backend contracts,
- QA evidence and release gates.

Use platform-specific memories for implementation details:
- platform files/modules/tasks and APIs,
- platform-specific verification commands,
- platform-only edge cases.

When saving a shared requirement, prefer this shape:

platform_scope=shared
requirement=<product/domain contract>
scope_implication=<scope-specific implementation note or none yet>
evidence=<source docs/tests/user decision>

## Guardrails
- Never save secrets, API keys, bearer tokens, cookies, private credentials,
  raw auth config, private keys, health payload dumps, or sensitive personal
  data.
- Do not store raw generated logs or large code dumps. Summarize the durable
  fact and cite files/commands instead.
- If memory conflicts with current files, tests, docs, or user instructions,
  prefer current evidence and save a corrective memory when the old memory is
  materially wrong.
- If a memory is wrong, unsafe, or should be removed, use
  memory_governance_delete when available.

## Coordination and maintenance
- If only a limited MCP tool set is available, do not treat agentmemory as a
  distributed lock, mutex, or reliable coordination bus. Use it as shared memory
  and a handoff layer only.
- Use coordination tools such as leases, signals, audits, governance, or mesh
  sync only when the corresponding MCP tools are available and their tool
  descriptions match the task.
- Use memory_consolidate only after substantial work or when explicitly asked.
- Use memory_reflect occasionally for higher-level project insights, not in
  every session.
EOF

  write_file "$TARGET_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" <<'EOF'
policy:
  allow_implicit_invocation: true

interface:
  display_name: "Agentmemory MCP"
  short_description: "Project memory recall, save, and cross-platform context"

dependencies:
  tools:
    - type: "mcp"
      value: "agentmemory"
      description: "Global agentmemory MCP server"
EOF
}

project_agent_context_generated_at() {
  local context_file="$TARGET_DIR/docs/agent-configs/project-agent-context.md"
  local existing_stamp=""
  if [[ -f "$context_file" ]]; then
    existing_stamp="$(
      sed -n "s/^Generated by \`bootstrap-multi-agent-project.sh\` on \([0-9][0-9]*-[0-9][0-9]*\)\.\$/\1/p" "$context_file" |
        head -n1
    )"
  fi
  printf '%s' "${existing_stamp:-$STAMP}"
}

write_doubt_driven_skill() {
  write_file "$TARGET_DIR/.agents/skills/doubt-driven/SKILL.md" <<'EOF'
---
name: doubt-driven
description: Use before finalizing any non-trivial decision (branching logic, module/contract boundaries, schema/migration, security/privacy claims, irreversible operations). Subjects the decision to a fresh-context adversarial review before it stands.
---

# Doubt-Driven Decision Review

Confidence and correctness are decoupled. This skill forces a non-trivial
decision through an adversarial review BEFORE it stands, while course-correction
is still cheap.

## When to use
Only for non-trivial decisions: branching logic, module/contract boundaries,
data/schema/migration choices, security or privacy claims, or irreversible
operations. Do NOT apply to trivial edits, copy changes, or mechanical work —
if you doubt every keystroke, you ship nothing.

## Procedure (bounded to 3 cycles)
1. CLAIM — state the decision in one sentence.
2. EXTRACT — hand the artifact (code/proposal) and its contract to a fresh
   reviewer WITHOUT your reasoning. If you hand over conclusions, you get back
   validation of your conclusions.
3. DOUBT — the reviewer's prompt is: "Find what is wrong with this artifact.
   Assume the author is overconfident." Not a validation request.
4. RECONCILE — re-read the artifact yourself against each finding. Classify by
   precedence: contract-misread > actionable > trade-off > noise. Do not
   rubber-stamp the reviewer.
5. STOP — resolve substantive findings or revise the decision. Unresolved
   substantive findings after 3 cycles mean the artifact is not ready.

## Notes
- The reviewer lacks your context — disagreement is information, not a verdict.
- In multi-agent setups the fresh reviewer can be a separate agent/model; offer
  cross-model review rather than silently skipping it.
- Do NOT add this skill to a persona's `skills:` frontmatter (avoid
  orchestration auto-application).

Adapted from addyosmani/agent-skills (MIT).
EOF
}

write_infra_agent_docs() {
  local stack_bullets
  local module_bullets
  local verify_bullets
  local warning_bullets
  local stack_overlay_content
  local mobile_skill_read_on_demand_bullet
  local context_generated_at
  stack_bullets="$(format_bullets "${TECH_STACKS[@]}")"
  module_bullets="$(format_bullets "${MODULES[@]}")"
  verify_bullets="$(format_bullets "${VERIFY_COMMANDS[@]}")"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    warning_bullets="$(format_bullets "${WARNINGS[@]}")"
  else
    warning_bullets="- None"
  fi
  stack_overlay_content="$(render_stack_overlays)"
  mobile_skill_read_on_demand_bullet="$(mobile_optimization_agents_pointer)"
  context_generated_at="$(project_agent_context_generated_at)"

  write_file "$TARGET_DIR/AGENTS.md" <<EOF
# Agent Infrastructure - $PROJECT_NAME

This repository has only the portable multi-agent infrastructure installed.
Workflow philosophy is opt-in. Re-run bootstrap with \`--workflow full\` if the
project wants the Karpathy/council/three-mode contracts.

## Mandatory Infrastructure

- Runtime stack detector: \`scripts/detect-agent-tech-stack.sh\`.
- Shared detector library: \`scripts/agent-tech-stack-lib.sh\`.
- Binding lock: \`docs/agent-configs/agent-bootstrap.lock.json\`.
- Shared hook: \`scripts/agent-hook.sh\`.
- Context guard: \`scripts/agent-guard.sh\` with policy
  \`docs/agent-configs/context-policy.json\`.
- rtk wrapper: \`./scripts/rtk git ...\`.
- Agentmemory skill: \`.agents/skills/agentmemory-mcp/SKILL.md\`.

At the start of substantive work, run:

\`\`\`bash
scripts/agent-guard.sh preflight
scripts/detect-agent-tech-stack.sh --markdown
\`\`\`

Before claiming ordinary completion:

\`\`\`bash
scripts/agent-guard.sh pre-final --run-verify
\`\`\`

This runs the fast verification subset. For release, high-risk, or final PR
readiness, review the detected verification commands first, then run
\`scripts/agent-guard.sh pre-final --run-verify --verify-scope full\`.
Claude Code auto-runs fast close-out verification through a Stop hook when the
tree has changes; Gemini, Cursor, and Windsurf do not expose an equivalent
close-out hook here, so their loop remains advisory and agents must run the
pre-final command manually.
Optional git gate: \`scripts/install-git-hooks.sh\`.

If the detector output changes intentionally, refresh the lock:

\`\`\`bash
bash scripts/bootstrap-multi-agent-project.sh --refresh-lock
\`\`\`

## Agentmemory Usage

Agentmemory is the long-term memory layer for project context when the global
MCP tools are available. The bootstrap installs
\`.agents/skills/agentmemory-mcp/SKILL.md\` automatically; agents should use
that skill for recall/save rules.
$mobile_skill_read_on_demand_bullet

## Detected Project Stack

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-stack -->
$stack_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-stack -->

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

## Verification Candidates

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

## Detection Warnings

<!-- BEGIN MANAGED: multi-agent-bootstrap:detection-warnings -->
$warning_bullets
<!-- END MANAGED: multi-agent-bootstrap:detection-warnings -->

## Git Workflow

All shell git commands must go through:

\`\`\`bash
./scripts/rtk git ...
\`\`\`

If \`./scripts/rtk\` is missing or cannot resolve the pinned rtk binary, run:

\`\`\`bash
bash scripts/install-rtk.sh
\`\`\`

- Override host defaults: \`feature/<slug>\` (features), \`bugfix/<slug>\` (fixes); no \`codex/\` or agent/AI names.
- Never force-push main/dev/develop, even with --force-with-lease or APIs.
- One feature per branch. User must name PR/MR target; else ask, no PR/integration.
  No target push/fast-forward or PR bypass. Merge needs separate explicit approval.
- Prefer one commit from base. Before/when >2, ask keep/squash/split;
  stop commit/push/rewrite. Never auto-squash/amend/reset/rebase.
- Create/push tags only with action approval and a user-named source branch;
  verify commit. No inference from release/HEAD/default/PR target.
  No tag moves or implied branch updates.
- Other force/rewrite actions need explicit approval.
- Conventional Commits; no agent names/trailers.

Default planning/coding/reviewing posture is project-local full-flow. Do not
revert unrelated user work.
EOF

  write_user_owned_file "$TARGET_DIR/docs/agent-configs/project-agent-context.md" <<EOF
# Project Agent Context - $PROJECT_NAME

Generated by \`bootstrap-multi-agent-project.sh\` on $context_generated_at.
Portable agent config version: \`$AGENT_BOOTSTRAP_VERSION\`.
Workflow preset: \`$WORKFLOW_PRESET\`.
Binding lock: \`docs/agent-configs/agent-bootstrap.lock.json\`.

## Detected Tech Stack

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-stack -->
$stack_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-stack -->

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

## Verification Commands

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

## Detection Warnings

<!-- BEGIN MANAGED: multi-agent-bootstrap:detection-warnings -->
$warning_bullets
<!-- END MANAGED: multi-agent-bootstrap:detection-warnings -->

## Stack-Specific Overlay

<!-- BEGIN MANAGED: multi-agent-bootstrap:stack-overlay -->
$stack_overlay_content
<!-- END MANAGED: multi-agent-bootstrap:stack-overlay -->

## Agent Safety Bridge

- If the project needs formal cross-agent handoff, rerun bootstrap with
  \`--workflow full\` to install \`docs/agent-configs/agent-handoff-schema.md\`.
- Before protected edits, run \`scripts/agent-guard.sh pre-edit <path>\`; use
  \`--ack <reason>\` and log it. Claude Code denies unacked edits
  (exit 2); per-path reuse: \`AGENT_GUARD_ACK_TTL_SECONDS\` (1-hour default).
- Run \`scripts/agent-hook.sh no-scan-paths\` before broad search and avoid
  local-only/tool-cache/generated/sensitive paths unless explicitly requested.

## Project-Specific Rules To Fill In

- Protected files and directories:
- Generated files that must not be edited manually:
- Security, privacy, compliance, or credential rules:
- Architecture boundaries:
- Test strategy:
- Release or deployment constraints:
EOF
}

tool_contract_block() {
  render_bundle_template "templates/tool-contract/shared.md"
}

tool_surface_write() {
  local path="$1"
  {
    cat
    printf '\n'
    tool_contract_block
  } | write_file "$path"
}

write_infra_tool_entrypoints() {
  tool_surface_write "$TARGET_DIR/CLAUDE.md" <<'EOF'
# Claude Instructions

Read `AGENTS.md` first. This project has portable agent infrastructure only;
Karpathy/council/three-mode workflow contracts are not installed unless
bootstrap is run with `--workflow full`.

At the start of substantive work, run:

```bash
scripts/agent-guard.sh preflight
scripts/detect-agent-tech-stack.sh --markdown
```

Use `./scripts/rtk git ...` for all shell git commands.
EOF

  tool_surface_write "$TARGET_DIR/GEMINI.md" <<'EOF'
# Gemini Instructions

Read `AGENTS.md` first. Durable project-specific stack context lives in
`docs/agent-configs/project-agent-context.md`.
EOF

  tool_surface_write "$TARGET_DIR/.windsurfrules" <<'EOF'
Read `AGENTS.md` first. Durable project-specific stack context lives in
`docs/agent-configs/project-agent-context.md`.
EOF

  tool_surface_write "$TARGET_DIR/.cursor/rules/agent-conventions.mdc" <<'EOF'
---
description: Shared agent infrastructure
alwaysApply: true
---

Read `AGENTS.md` first. Durable project-specific stack context lives in
`docs/agent-configs/project-agent-context.md`.
EOF

  write_file "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
	      {
	        "matcher": "Bash",
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh claude-pretool" }
	        ]
	      },
	      {
	        "matcher": "Edit|Write|MultiEdit",
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh claude-pretool" }
	        ]
	      }
	    ],
    "Stop": [
	      {
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh close-out" }
	        ]
	      }
	    ]
	  }
}
EOF

  write_file "$TARGET_DIR/.claude/README.md" <<'EOF'
# Claude Agent Infrastructure

This project has shared Claude Bash and edit/write hooks installed:

```bash
./scripts/agent-hook.sh claude-pretool
```

The hook validates the detector lock, guards protected Edit/Write/MultiEdit
paths, and delegates shell git handling to rtk. It is not a security boundary
for arbitrary Bash commands.
Workflow command docs are opt-in; run bootstrap with `--workflow full` if the
project wants planning/coding/reviewing command contracts.
EOF
}

write_agent_docs() {
  local stack_bullets
  local module_bullets
  local verify_bullets
  local warning_bullets
  local stack_overlay_content
  local mobile_skill_read_on_demand_bullet
  local context_generated_at
  local seat_roster_block
  stack_bullets="$(format_bullets "${TECH_STACKS[@]}")"
  module_bullets="$(format_bullets "${MODULES[@]}")"
  verify_bullets="$(format_bullets "${VERIFY_COMMANDS[@]}")"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    warning_bullets="$(format_bullets "${WARNINGS[@]}")"
  else
    warning_bullets="- None"
  fi
  stack_overlay_content="$(render_stack_overlays)"
  mobile_skill_read_on_demand_bullet="$(mobile_optimization_agents_pointer)"
  context_generated_at="$(project_agent_context_generated_at)"
  if ! seat_roster_block="$(seats_program roster-block 2>/dev/null)"; then
    seat_roster_block=$'<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\n- roster unavailable: docs/agent-configs/seats.json is missing or invalid; run scripts/agent-seats.sh wizard (or reset), then scripts/agent-seats.sh render\n<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->'
  fi

  write_overlay_file "$TARGET_DIR/AGENTS.md" <<EOF
# Agent Conventions - $PROJECT_NAME

Project rules:
\`docs/agent-configs/\`.

## Startup Context Budget

Always read at startup:

- This file.
- \`docs/agent-configs/project-agent-context.md\`.
- \`docs/agent-configs/project-brief.md\`; if \`<!-- UNFILLED -->\`, run
  \`docs/agent-configs/project-onboarding.md\` before substantive work.
- Available preflight and stack-detector output (commands below).

Read on demand:

- \`docs/agent-configs/agent-mode-contracts.md\` to select/switch modes.
- \`docs/agent-configs/agent-handoff-schema.md\` for ownership changes.
- \`.agents/tasks/<task-id>/\`: selected local collaboration packet.
- \`docs/agent-configs/karpathy-llm-coding-agent-config.md\` before substantial
  edits or production-risk refactors.
- \`docs/agent-configs/llm-council-agent-workflow.md\` for councils/high-risk
  architecture/security/release tradeoffs.
- \`.agents/skills/\` only for task-matching skill descriptions.
$mobile_skill_read_on_demand_bullet

Keep core startup context under roughly 4k estimated tokens.
\`scripts/verify-ai-deps.sh\` and \`.codex/codex-mode.sh doctor\` report the
estimate, which excludes tool-specific wrappers (\`CLAUDE.md\`, \`GEMINI.md\`).

At the start of substantive work, run \`scripts/agent-guard.sh preflight\` and
\`scripts/detect-agent-tech-stack.sh --markdown\`. Before claiming ordinary
completion, run \`scripts/agent-guard.sh pre-final --run-verify\`.

For release/high-risk/final PR readiness, review detected commands and replace
the fast check with \`scripts/agent-guard.sh pre-final --run-verify --verify-scope full\`.
Record placeholder or unavailable-service reasons in the handoff/final summary;
use \`--advisory\` only when the user or CI requires it. Optional git gate:
\`scripts/install-git-hooks.sh\`.

Keep detection logic in \`scripts/agent-tech-stack-lib.sh\`; the lock
\`docs/agent-configs/agent-bootstrap.lock.json\` binds detector output. After
stack/module changes, refresh it with
\`bash scripts/bootstrap-multi-agent-project.sh --refresh-lock\`.

If detection is unavailable, infer from build/config files and state uncertainty.

## Agentmemory Usage

Use \`.agents/skills/agentmemory-mcp/SKILL.md\` for long-term recall/save;
memory is advisory and must be verified against current files. Use
\`.agents/skills/doubt-driven/SKILL.md\` for a fresh-context adversarial check.

## Collaboration

Use the mode contract for roles, transitions, gates and review limits;
the handoff schema for packet formats. No concurrent same-file edits.

## Local State And No-Scan Guard

Do not scan/read/grep/diff/summarize/print local-only state, tool caches,
generated output, or sensitive machine files without an exact user-requested
path and inspection.

\`\`\`bash
scripts/agent-hook.sh no-scan-paths
scripts/agent-hook.sh guard-local-state
\`\`\`

No-scan: local worktrees, vendor runtime state, personal overrides, tool caches,
build output, local Codex state, \`.env*\`, \`local.properties\`,
\`keystore.properties\`, keys/keystores. The tracked-state guard fails on
agent runtime state; sensitive project files remain no-scan.

## Work Modes

- \`planning\`: strategy, specs, architecture, deep refactor/performance plans.
- \`coding\`: implementation, refactors, fixes, tests, verification; first pass
  the canonical adequacy gate.
- \`reviewing\`: one findings-first pass; project-local verification allowed.
  Remediate only the exact requested scope.

## Seat Roster

$seat_roster_block

Occupants change with \`scripts/agent-seats.sh\`; data lives in
\`docs/agent-configs/seats.json\`.

## Detected Project Stack

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-stack -->
$stack_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-stack -->

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

## Verification Candidates

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

## Detection Warnings

$warning_bullets

## Human Approval Policy

Default: project-local full-flow in all modes. Use supervised/read-only/propose
only for user-requested step-by-step approval. Exact approval is required for
external-path mutations, installs, commits, pushes, force operations, or
local-only secret/permission file changes.

## Git Workflow

Run all shell git commands through \`./scripts/rtk git ...\`. If missing or
unable to resolve pinned rtk, run \`bash scripts/install-rtk.sh\`.

- Override host defaults: \`feature/<slug>\` (features), \`bugfix/<slug>\` (fixes); no \`codex/\` or agent/AI names.
- Never force-push main/dev/develop, even with --force-with-lease or APIs.
- One feature per branch. User must name PR/MR target; else ask, no PR/integration.
  No target push/fast-forward or PR bypass. Merge needs separate explicit approval.
- Prefer one commit from base. Before/when >2, ask keep/squash/split;
  stop commit/push/rewrite. Never auto-squash/amend/reset/rebase.
- Create/push tags only with action approval and a user-named source branch;
  verify commit. No inference from release/HEAD/default/PR target.
  No tag moves or implied branch updates.
- Other force/rewrite actions need explicit approval.
- Conventional Commits; no agent names/trailers.

Never silently revert user work or hide uncertainty. No success claim without
fresh verification or a clear reason it was not run.

## Project-Specific Conventions

<!-- BEGIN USER: agents:extra -->
<!-- Add project-specific agent rules here (build/scheme policies, protected paths, etc.); preserved across harness upgrades. -->
<!-- END USER: agents:extra -->
EOF

  write_user_owned_file "$TARGET_DIR/docs/agent-configs/project-agent-context.md" <<EOF
# Project Agent Context - $PROJECT_NAME

Generated by \`bootstrap-multi-agent-project.sh\` on $context_generated_at.
Portable agent config version: \`$AGENT_BOOTSTRAP_VERSION\`.
Binding lock: \`docs/agent-configs/agent-bootstrap.lock.json\`.

## Detected Tech Stack

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-stack -->
$stack_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-stack -->

## Deep Project Context

Detection seeds \`docs/agent-configs/project-brief.md\`. If \`<!-- UNFILLED -->\`,
run \`docs/agent-configs/project-onboarding.md\` before substantive work; it
updates tech-stack notes and fills \`docs/superpowers/specs/project-tech-stack.md\`.

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

Refine file-signature detection after inspecting architecture, modules, tests,
and deployment.

## Verification Commands

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

Prefer relevant commands; replace invalid ones with workflow fixes in the same
change.

## Detection Warnings

<!-- BEGIN MANAGED: multi-agent-bootstrap:detection-warnings -->
$warning_bullets
<!-- END MANAGED: multi-agent-bootstrap:detection-warnings -->

## Stack-Specific Overlay

<!-- BEGIN MANAGED: multi-agent-bootstrap:stack-overlay -->
$stack_overlay_content
<!-- END MANAGED: multi-agent-bootstrap:stack-overlay -->

## Agent Safety Bridge

- Transfers between agents/phases follow
  \`docs/agent-configs/agent-handoff-schema.md\`.
- Before protected edits, run \`scripts/agent-guard.sh pre-edit <path>\` with
  \`--ack <reason>\`; Claude Code denies unacked edits (exit 2), and
  \`AGENT_GUARD_ACK_TTL_SECONDS\` controls per-path reuse (1-hour default).
- Before broad search, run \`scripts/agent-hook.sh no-scan-paths\`; avoid
  local-only, tool-cache, generated, and sensitive paths unless requested.

## Project-Specific Rules To Fill In

Record protected paths, generated files, security/privacy/credential rules,
architecture boundaries, test strategy, release constraints, and project-specific
tech-stack overrides and commands.

Use agentmemory if available; otherwise read this context, detector output and
nearby build/config files. State uncertainty.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/agent-handoff-schema.md" <<'EOF'
# Agent Handoff Schema

Seat, transition, and gate policy lives only in
`docs/agent-configs/agent-mode-contracts.md`.

## Select a packet

Packets at `.agents/tasks/<task-id>/` are ignored, ephemeral; ownership and
append-only behavior are conventions, not access controls.

`.agents/tasks/ACTIVE` is a cache; each task's `state.json` is authoritative.
On resume, select exactly one open task if it is the only one; repair stale
`ACTIVE`. Multiple open tasks require the user to choose. Never select the
newest task automatically. Report malformed state; do not infer it.

## Canonical artifact set

1. `state.json`
2. `task.md`
3. `codex-review.md`
4. `implementation.md`
5. `claude-review.md`
6. `user-decision.md`

Only `state.json` and `task.md` are created initially. Other evidence is allowed
when linked from `task.md`; do not add a machine-readable attachment registry.

## State contract

Initial state:

```json
{
  "protocol_version": "claude-codex-collaboration/v1",
  "task_id": "checkout-timeout-fix",
  "status": "open",
  "phase": "analysis",
  "seat": "@spec",
  "owner": "claude",
  "requested_action": "prepare spec for @gate",
  "base_commit": null,
  "source_task": null,
  "blocks": [],
  "revision_rounds": 0,
  "spec_sufficiency": {
    "verdict": "not_reviewed",
    "sufficient_for_coding_model": "not_reviewed"
  },
  "escalation_reason": null,
  "verification": {
    "runner": "none",
    "status": "not_run",
    "reason": null,
    "report": null
  },
  "updated_at": "2026-08-10T09:00:00Z"
}
```

Allowed values:

- `status`: `open | awaiting_user | closed`
- `phase`: `analysis | technical_review | implementation | verification | cross_review | resolution | closed`
- `owner`: `claude | codex | user | agent`
- `spec_sufficiency.verdict`: `not_reviewed | sufficient | partially_sufficient | insufficient`
- `spec_sufficiency.sufficient_for_coding_model`: `not_reviewed | yes | no`
- `verification.runner`: `none | claude | codex | agent`
- `verification.status`: `not_run | pass | fail | blocked`

`seat` is a protocol tag. When absent, derive it from `phase`: `analysis` →
`@spec`, `technical_review` → `@gate`, `implementation` → `@build`,
`verification` → `@verify`, `cross_review` → `@audit`, `resolution` → `@owner`.
Packets without `seat` remain valid. `owner` names the occupant host class;
nonstandard hosts use `owner: agent` and `occupant: {"host": "<host>"}`;
`verification.runner: agent` records `runner_host: <host>`.

Packet mapping examples (partial states):

```json
{"phase": "technical_review", "seat": "@gate", "owner": "codex"}
{"phase": "analysis", "seat": "@spec", "owner": "codex"}
{"phase": "technical_review", "seat": "@gate", "owner": "claude"}
{"phase": "technical_review", "seat": "@gate", "owner": "agent", "occupant": {"host": "gemini"}}
{"phase": "verification", "seat": "@verify", "owner": "agent", "occupant": {"host": "cursor"}, "verification": {"runner": "agent", "runner_host": "cursor"}}
```

`requested_action` names the next action. Capture `base_commit` on first entry
into implementation for full-diff review; `revision_rounds` starts at zero and
increments on return. Verification records runner, result, reason, and report.

### Task relations

`source_task` is `null`, a task id, or `<task-id>#<finding-id>`; it records why
the task exists while details, evidence, and scope remain in `task.md`. The
task-id portion must name an existing packet when it is available. Missing
`source_task` is equivalent to `null`.

`blocks` is a unique list of task ids that cannot continue while this packet is
active. Missing `blocks` is equivalent to `[]`. A closed packet's `blocks` edges
are inactive; no edit to the blocked packet is required. Closing a child returns an outcome to evaluate; closure alone neither proves
the source finding resolved nor advances the blocked task.

Existing `claude-codex-collaboration/v1` packets remain valid. No protocol-version
bump, bulk migration, or reverse relationship write is required. Missing
referenced packets do not invalidate the current packet; agents record uncertainty
and continue.

1. Continue the current task when the root cause and implementation scope are
   unchanged.
2. Open a child task only for a distinct finding with independently closable
   scope. Record the split rationale in `task.md`. Review retries remain in the
   same packet.
3. For one exact `source_task` value, at most one active child may block the
   same target.
4. A task cannot source from or block itself.
5. Active blocking edges must be acyclic.
6. A review retry alone never creates a child task; attempts stay in the same
   packet.

Relations are authoring conventions. The packet writer avoids self-reference,
duplicate active children, and cycles; the reviewer checks them. No guard, hook,
or runtime reads `source_task` or `blocks` in this phase.

## Artifact contracts

### `task.md`

`task.md` starts with:

```markdown
## Request (verbatim)

> <original request with secrets redacted>
```

Record objective, acceptance criteria, scope/non-goals, evidence, constraints,
interfaces, edge cases, migration/security/privacy impact, verification,
assumptions, and implementation boundaries. When `@gate` returns `task.md` to
analysis, append `## Specification revision <n>` and preserve `## Request (verbatim)`
and prior history.

Before marking the task `closed`, append one concise section to `task.md`:

```markdown
## Outcome

- Summary: <change or finding>
- Evidence: <test/report/review path>
- Effect on source: <source task decision/action>
```

The fields are prose, not enums, and do not drive an automatic transition. If
an outcome should survive packet loss, manually mirror its Summary, Evidence,
and Effect on source into the optional task journal described in
`docs/agent-configs/task-journal.md`. Mirroring is optional, not a closure gate.

### `codex-review.md`

Exactly two top-level sections with numbered attempts:

```markdown
## Pre-coding technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
spec_sufficiency: sufficient | partially_sufficient | insufficient
sufficient_for_coding_model: yes | no
blocking_gaps: none | <concise list>

## Final technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
fresh_session_attestation: yes | no
reviewed_base_commit: <commit>
verdict: pass | changes_required | blocked
```

Review history is append-only and immutable within each top-level section.
The first final review adds the `## Final technical review` heading.
On resumed specification review, insert the next numbered pre-coding `### Attempt <n>` immediately before Final; preserve prior attempts.
State sufficiency matches the latest pre-coding attempt.
`fresh_session_attestation` is procedural-only and is not proof of session, model, account, or host independence.

### `implementation.md`

Append `## Implementation attempt <n>` with model/source, route, scope, files,
verification, deviations, risks, blockers, and adequacy downgrade. A `@gate`
coding escalation records `policy_exception=gate_coding`,
`authorization=user_session`, and the reason; readers accept legacy `sol_coding`
for one release. Its policy meaning is in
`docs/agent-configs/agent-mode-contracts.md`.

### `claude-review.md`

Append one findings-first `## Cross-review attempt <n>`; its checklist and
procedural declarations live in
`docs/agent-configs/agent-mode-contracts.md`.

### `user-decision.md`

When required, append dated action, scope, authorization, and alternatives.

Prior attempts remain immutable by convention; repeats append the next numbered
attempt.

Exclude secrets, permission state and large logs; use paths and summaries.
EOF

  write_overlay_file "$TARGET_DIR/docs/agent-configs/agent-mode-contracts.md" <<'EOF'
# Agent Mode Contracts

Canonical seat tags, transitions, and gates for host files/launchers.

Common rules:
- Refresh stack context via `scripts/detect-agent-tech-stack.sh --markdown`
  when available; respect `scripts/agent-hook.sh no-scan-paths`.
- Packets: `.agents/tasks/<task-id>/`; state/artifact formats:
  `docs/agent-configs/agent-handoff-schema.md`.
- One phase owner writes at a time. Ownership is a coordination
  convention, not an authorization or security boundary.
- Project-local full-flow requires exact user approval for external paths,
  installs, commits, pushes, force operations, and local-only secret/permission changes.

## Claude–Codex Collaboration Protocol

### Constrained transitions

- `analysis` · `@spec` -> `technical_review`
- `technical_review` · `@gate` -> `analysis` | `implementation` | `resolution`
- `implementation` · `@build` -> `verification` | `resolution`
- `verification` · `@verify` -> `implementation` | `cross_review` | `resolution`
- `cross_review` · `@audit` -> `implementation` | `resolution`
- `resolution` · `@owner` -> `closed` | user-selected prior phase

`awaiting_user` is valid only with `resolution` · `@owner`. `closed` is valid only with phase `closed`.
Other active combinations use `open` and the listed owner. Claude implementation
requires an explicit user decision in the packet.

### Gates and authority

- `@gate` owns the blocking adequacy verdict for requirements, interfaces, edge
  cases, tests, migrations, security/privacy, and implementation boundaries.
- `@build` may downgrade `yes` for a spec gap found during implementation,
  but may never upgrade `no`; missing/inconsistent `@gate` verdicts block coding.
- After two unsuccessful remediation returns, ask the user whether another bounded pass is worth its cost. The user may authorize another pass in the same task. Do not create a child task or a new lifecycle state solely because the checkpoint was reached.
- Record verification runner, status, reason, and real report. Unavailable/skipped
  execution cannot pass. Only the executing host may declare a pass; other
  reports are testimony pending fresh confirmation.
- An equivalence or invariance guard names the production boundary its fixture
  crosses, declares its mutation in the packet before the test is written, and
  must fail when the fixture transform is replaced with identity.
- `@audit`'s one findings-first cross-review covers state/review consistency,
  `base_commit`, verification, any gate-coding decision and reason, and
  approved scope. Required procedural declarations: `fresh_session_attestation`, actual author model, actual reviewer model, and model source for each.
  Check author/reviewer model and session declarations for contradictions.
- Gate coding is an escalation: the user must open a new session for the
  `@gate` occupant to code. `policy_exception=gate_coding` plus
  `authorization=user_session` is an
  audit-only procedural declaration and cannot provide file-based authorization.
- The user is the final authority for closure, bounded revision, prior-phase
  return, implementation, or a gate-coding policy exception. Readers accept
  `sol_coding` as a legacy read alias for one release.

## Planning Mode

Analyze request/evidence/constraints/risks/verification. Preserve packet history.
Council is on-demand for high-risk/disputed work.

## Coding Mode

`@build` needs the latest `@gate` approval. Prefer focused root-cause patches,
tests, and fresh verification; otherwise move to resolution.

## Reviewing Mode

Ordinary review: one findings-first, evidence-backed pass. Remediate only the
exact requested scope.
The `Severity trigger` finding obligation is defined by the reviewing launcher.

## Project-Specific Mode Overrides

<!-- BEGIN USER: mode-contracts:overrides -->
<!-- Add project-specific mode rules/overrides here; preserved across harness upgrades. -->
<!-- END USER: mode-contracts:overrides -->
EOF

  write_file "$TARGET_DIR/docs/agent-configs/karpathy-llm-coding-agent-config.md" <<'EOF'
# LLM Coding Workflow

Natural language is a control plane, not engineering understanding. Preserve
user work. Production changes require this procedure.

## Procedure

1. Before edits, read relevant files, nearby tests, project rules, and current
   diffs. State what you read.
2. State explicit assumptions and risks before editing.
3. Make one small coherent patch; no unrelated refactors.
4. Verify with tests or a justified substitute; review the final diff.
5. Hand off with `docs/agent-configs/agent-handoff-schema.md` when ownership
   changes. No success claim without evidence.

Optional durable task-decision journal:
`docs/agent-configs/task-journal.md`.

## Stop conditions

- Identify the root cause or stop; never prompt-code until symptoms disappear.
  Record unknowns in the handoff.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/llm-council-agent-workflow.md" <<'EOF'
# Hybrid Council Workflow

Council advises one patch executor on user-requested high-risk/disputed
architecture, migration, data loss, security/privacy, billing, release,
performance, concurrency or unclear root causes.

Planner/BA: scope; Dev Lead: architecture; QC: regressions; Tester: evidence;
Chair: synthesis.

The coordinator chairs. Override only with evidence, user instruction, or a
safer stop; preserve high-impact minority objections.

Ordinary review is one findings-first pass under
`docs/agent-configs/agent-mode-contracts.md`; council is optional.

Before non-trivial verdicts, optionally apply `doubt-driven`
(`.agents/skills/doubt-driven/SKILL.md`).

## Procedure

1. State the question and council rationale.
2. Each role gives its position, file:line evidence, and confidence.
3. Cross-review assumptions and missing evidence.
4. Chair synthesizes approach, rejected alternatives, minority objections,
   executor, verification commands, and stop-conditions.
5. Return the verdict using `docs/agent-configs/agent-handoff-schema.md` when
   ownership changes.

## Stop conditions

- Stop and ask the user if repo evidence cannot support a verifiable position.
- Escalate credible P0/P1 security, privacy, data-loss, billing, release, or
  compliance risk even when the majority disagrees.
EOF

}

write_task_journal_doc() {
  write_file "$TARGET_DIR/docs/agent-configs/task-journal.md" <<'EOF'
# Task Journal (Optional working memory)

Optional journals preserve decisions in Git; they never select active tasks. `.agents/tasks/*/state.json` is authoritative; see
`docs/agent-configs/agent-handoff-schema.md`.

Create `docs/superpowers/plans/<topic>/journal.md` with dated entries to survive
packet loss/compaction. Bootstrap never creates per-task journals.

Manually mirror `task.md` Summary, Evidence, and Effect on source into a dated
entry when useful. Mirroring is optional, not a closure gate.

## Optional fields

- `memory`: saved durable-memory id, `none`, or `n/a`.
- `save_decision`: `saved`, `journal-only`, `rejected`, or `n/a`.
- `evidence`: supporting file, test, command, or user-decision summary.
- `recall_verified`: `yes`, `n/a`, or `acked-deferred` when relevant.
- `verification`: real verification report path, or `n/a` with a reason.

Keep prior decisions; exclude secrets, credentials, permission state and large logs.
EOF
}

write_tool_entrypoints() {
  tool_surface_write "$TARGET_DIR/CLAUDE.md" <<'EOF'
# Claude Instructions

## Claude–Codex collaboration

Claude's two default responsibilities are:

- analysis/specification
- independent cross-review

Follow the canonical roles and gates in
`docs/agent-configs/agent-mode-contracts.md`, follow the packet format in
`docs/agent-configs/agent-handoff-schema.md`, and use `.agents/tasks/` for the
active Claude–Codex handoff.
Claude occupies `@spec` and `@audit` by default (see roster).

## First run

If `docs/agent-configs/project-brief.md` still carries the `<!-- UNFILLED -->`
marker, run project onboarding (`docs/agent-configs/project-onboarding.md`;
Claude: `/project-onboarding`) BEFORE substantive work, so you have full project
context and source-backed project-specific tech-stack/spec notes.

Read `AGENTS.md` first. For startup, load
`docs/agent-configs/project-agent-context.md`, the filled project brief when
available, and detector output. Read on demand:

- `docs/agent-configs/agent-mode-contracts.md` when selecting or switching
  planning/coding/reviewing mode
- `docs/agent-configs/agent-handoff-schema.md` when handing work to another
  agent
- `.agents/tasks/<task-id>/` for the selected local collaboration packet
- `docs/agent-configs/karpathy-llm-coding-agent-config.md` before substantive
  code edits or production-risk refactors
- `docs/agent-configs/llm-council-agent-workflow.md` only for council or
  high-risk review work
- `docs/agent-configs/task-journal.md` only for optional durable-decision notes

Use `.claude/commands/` as mode entrypoints when the host supports project
commands:

- `/planning`, `/coding`, and `/reviewing` for the corresponding canonical mode
- `/planning-full-flow`, `/coding-full-flow`, `/reviewing-full-flow` as
  legacy explicit aliases
- `/codex:setup`, `/codex:rescue`, `/codex:status` for Codex readiness and
  schema-compliant handoffs
- `/doctor`

Model selection is controlled by the Claude host; these files enforce behavior,
not account-level model availability.

At the start of substantive work, run `scripts/detect-agent-tech-stack.sh --markdown`
when available and use its output with `docs/agent-configs/project-agent-context.md`.
Use `scripts/agent-hook.sh no-scan-paths` before broad search.
EOF

  tool_surface_write "$TARGET_DIR/GEMINI.md" <<'EOF'
# Gemini Instructions

## First run

If `docs/agent-configs/project-brief.md` still carries the `<!-- UNFILLED -->`
marker, run project onboarding (`docs/agent-configs/project-onboarding.md`)
BEFORE substantive work, so you have full project context and source-backed
project-specific tech-stack/spec notes.

Read `AGENTS.md` first. This file is only a tool-specific pointer. Startup
context is `project-agent-context.md`, the filled project brief when available,
and detector output. Read heavier workflow docs only on demand.
EOF

  tool_surface_write "$TARGET_DIR/.windsurfrules" <<'EOF'
Read `AGENTS.md` first. This file is only a pointer. Use project context and
brief at startup; read heavier workflow docs on demand.
EOF

  tool_surface_write "$TARGET_DIR/.cursor/rules/agent-conventions.mdc" <<'EOF'
---
description: Shared agent conventions
alwaysApply: true
---

Read `AGENTS.md` first. Use project context and brief at startup; read heavier
workflow docs under `docs/agent-configs/` only on demand. Do not duplicate
durable rules in Cursor-specific files.
EOF

  write_file "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
	      {
	        "matcher": "Bash",
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh claude-pretool" }
	        ]
	      },
	      {
	        "matcher": "Edit|Write|MultiEdit",
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh claude-pretool" }
	        ]
	      }
	    ],
    "Stop": [
	      {
	        "hooks": [
	          { "type": "command", "command": "./scripts/agent-hook.sh close-out" }
	        ]
	      }
	    ]
	  }
}
EOF

  write_file "$TARGET_DIR/.claude/README.md" <<'EOF'
# Claude Agent Workflow

## Cowork Folder Instructions

Open the generated project folder in Cowork and copy the text between these
markers into Folder Instructions once:

<!-- BEGIN COWORK FOLDER INSTRUCTIONS -->
Read the target `CLAUDE.md` first.
Follow the canonical role and handoff docs named there.
Claude occupies `@spec` and `@audit` by default (see roster).
Use `.agents/tasks/` for active Claude–Codex handoff.
Do not assume Claude Code hooks run in Cowork.
If Bash is unavailable, continue analysis and cross-review, and record verification as blocked or delegated with a reason.
<!-- END COWORK FOLDER INSTRUCTIONS -->

Use Claude Code custom commands when available:

```text
/planning <task>
/coding <task>
/reviewing <target>
/planning-full-flow <task>
/coding-full-flow <task>
/reviewing-full-flow <target>
/codex:setup [--doctor]
/codex:rescue <task>
/codex:status [--doctor]
/doctor
```

`/planning`, `/coding`, and `/reviewing` are thin entrypoints to the canonical
mode and handoff contracts below.

Read `AGENTS.md` first. Durable mode behavior lives in
`docs/agent-configs/agent-mode-contracts.md`; repo-specific stack context lives
in `docs/agent-configs/project-agent-context.md`. Handoffs use
`docs/agent-configs/agent-handoff-schema.md`; local task packets live under
`.agents/tasks/<task-id>/`.

Claude model selection is host-controlled. Keep the same mode contract if the
selected model is unavailable.

In Claude Code, the shared hook denies protected Edit/Write/MultiEdit paths with
exit 2 unless \`pre-edit --ack <reason> <path>\` exists for that path, and
delegates shell git handling to pinned rtk. It is not a security boundary for Bash.
EOF

  write_file "$TARGET_DIR/.claude/commands/planning.md" <<'EOF'
# Planning Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Planning Mode.
Use `docs/agent-configs/agent-handoff-schema.md` for the selected packet under
`.agents/tasks/<task-id>/`.

Operate project-local full-flow by default. Add `--supervised`, `--read-only`,
or `--propose` only when the user wants step-by-step approval.
Run `scripts/detect-agent-tech-stack.sh --markdown` when available. Use
requirement exploration and council checkpoints only when appropriate. End with
a concrete plan, assumptions, risks, verification, stop conditions, and a
Codex-ready handoff using `docs/agent-configs/agent-handoff-schema.md` when
follow-up coding/review is expected. Respect
`scripts/agent-hook.sh no-scan-paths` before broad search.
EOF

  write_file "$TARGET_DIR/.claude/commands/coding.md" <<'EOF'
# Coding Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Coding Mode.
Use `docs/agent-configs/agent-handoff-schema.md` for the selected packet under
`.agents/tasks/<task-id>/`.
Claude occupies `@spec` and `@audit` by default (see roster).

Default Claude behavior is handoff, not direct implementation. Execute only
after an explicit user decision and a blocking `@gate` adequacy verdict permit
Claude implementation; unavailability alone does not change ownership. If
selected, implement scoped changes, verify, and inspect the final diff. Respect
`scripts/agent-hook.sh no-scan-paths`.
EOF

  write_file "$TARGET_DIR/.claude/commands/planning-full-flow.md" <<'EOF'
# Planning Full-Flow Mode

Legacy alias for default `/planning` full-flow. Apply
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md` to the selected packet under
`.agents/tasks/<task-id>/`. This alias grants bounded project-local planning
for the current user task. Run
`scripts/detect-agent-tech-stack.sh --markdown` when available. Do not mutate
outside the project root, do not edit local-only permission state, and do not
run mutating git commands without exact approval.
EOF

  write_file "$TARGET_DIR/.claude/commands/coding-full-flow.md" <<'EOF'
# Coding Full-Flow Mode

Legacy alias for `/coding`. Apply `docs/agent-configs/agent-mode-contracts.md`
and `docs/agent-configs/agent-handoff-schema.md` to the selected packet under
`.agents/tasks/<task-id>/`. This alias does not change canonical ownership or
gates; it grants bounded project-local implementation, tests, and verification
only when the packet permits execution.
EOF

  write_file "$TARGET_DIR/.claude/commands/reviewing.md" <<'EOF'
# Reviewing Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Reviewing Mode.
Use `docs/agent-configs/agent-handoff-schema.md` for the selected packet under
`.agents/tasks/<task-id>/`.

Follow the canonical owner and review gates for the selected packet. Report one
findings-first pass ordered by severity.
EOF

  write_file "$TARGET_DIR/.claude/commands/council.md" <<'EOF'
---
description: Run the on-demand hybrid council methodology.
---

# Council

Follow `docs/agent-configs/llm-council-agent-workflow.md`. Council is advisory
until verified; the Chair preserves minority objections and one executor owns any
patch.
EOF

  write_file "$TARGET_DIR/.claude/commands/karpathy.md" <<'EOF'
---
description: Apply the context-first Karpathy coding discipline.
---

# Karpathy

Follow `docs/agent-configs/karpathy-llm-coding-agent-config.md`: context first,
small coherent patches, explicit assumptions/risks, evidence before success
claims.
EOF

  write_file "$TARGET_DIR/.claude/commands/reviewing-full-flow.md" <<'EOF'
# Reviewing Full-Flow Mode

Legacy alias for `/reviewing`. Apply
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md` to the selected packet under
`.agents/tasks/<task-id>/`. This alias does not change canonical ownership or
gates. Do not remediate unless fixes or an exact patch scope were requested.
EOF

  write_file "$TARGET_DIR/.claude/commands/codex/setup.md" <<'EOF'
---
description: Validate Codex readiness and prepare launch instructions.
argument-hint: [--doctor|--status] <optional Codex setup task>
---

# Codex Setup Bridge

Claude occupies `@spec` and `@audit` by default (see roster); Codex launches
use the selected `@spec`, `@gate`, `@build`, `@verify`, or `@audit` seat.

Read `AGENTS.md`, `CLAUDE.md`, `docs/agent-configs/agent-mode-contracts.md`,
`docs/agent-configs/agent-handoff-schema.md`, and
`docs/agent-configs/project-agent-context.md`. Use the selected packet under
`.agents/tasks/<task-id>/`.

Run:

```bash
.codex/codex-mode.sh status
scripts/agent-hook.sh no-scan-paths
```

If `--doctor` is present, also run:

```bash
.codex/codex-mode.sh doctor
scripts/verify-ai-deps.sh
```

Return current Codex readiness, any gaps, and an exact Codex launch command.
EOF

  write_file "$TARGET_DIR/.claude/commands/codex/rescue.md" <<'EOF'
---
description: Convert current Claude context into a Codex-ready rescue handoff.
argument-hint: [@spec|@gate|@build|@verify|@audit|planning|coding|reviewing] <stalled task or rescue target>
---

# Codex Rescue Handoff

Claude occupies `@spec` and `@audit` by default (see roster). Choose the
Codex seat tag that matches the packet phase.

Default to handoff, not direct implementation. Read
`docs/agent-configs/agent-mode-contracts.md`,
`docs/agent-configs/agent-handoff-schema.md`, and
`docs/agent-configs/project-agent-context.md`, then use the selected packet under
`.agents/tasks/<task-id>/`. Run
`scripts/detect-agent-tech-stack.sh --markdown` when available and
`scripts/agent-hook.sh no-scan-paths` before broad search.

Return one launch command and one schema-compliant handoff:

```bash
.codex/codex-mode.sh <@spec|@gate|@build|@verify|@audit|planning|coding|reviewing> "<handoff prompt>"
```

Include target files, repo-state caveats, constraints, non-goals, acceptance
criteria, verification commands, risks, open questions, next action, and stop
conditions.
EOF

  write_file "$TARGET_DIR/.claude/commands/codex/status.md" <<'EOF'
---
description: Report Codex mode, health, and no-scan guard status.
argument-hint: [--doctor] <optional status question>
---

# Codex Status

Claude occupies `@spec` and `@audit` by default (see roster). Status reports
the locked seat and its effective catalog model/effort.

Read `docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`. Use the selected packet under
`.agents/tasks/<task-id>/`.

Run:

```bash
.codex/codex-mode.sh status
scripts/agent-hook.sh no-scan-paths
```

If `--doctor` is present, also run:

```bash
.codex/codex-mode.sh doctor
scripts/verify-ai-deps.sh
```

Return mode, flow, health, no-scan guard summary, and any action needed before
handing work to Codex.
EOF

  write_file "$TARGET_DIR/.claude/commands/doctor.md" <<'EOF'
# Claude Agent Doctor

Run:

```bash
scripts/detect-agent-tech-stack.sh --markdown
.codex/codex-mode.sh doctor
scripts/verify-ai-deps.sh
```

Report pass/fail/warnings. Do not edit files unless the user explicitly asks
for remediation after seeing the doctor result.
EOF
}

write_codex_files() {
  write_file "$TARGET_DIR/.codex/config.toml" <<'EOF'
approval_policy = "never"
sandbox_mode = "workspace-write"
approvals_reviewer = "user"
allow_login_shell = false
web_search = "disabled"

[shell_environment_policy]
inherit = "none"
include_only = ["PATH", "HOME", "PWD", "SHELL", "CODEX_HARNESS_SESSION"]
ignore_default_excludes = false

[apps._default]
destructive_enabled = false
open_world_enabled = false
default_tools_approval_mode = "prompt"
EOF

  write_overlay_file "$TARGET_DIR/.codex/README.md" <<'EOF'
# Codex Mode Helper

Use `.codex/codex-mode.sh` instead of raw `codex` when this project needs the
standard three-mode workflow.

Commands:

```bash
.codex/codex-mode.sh @spec
.codex/codex-mode.sh @gate
.codex/codex-mode.sh @build
.codex/codex-mode.sh @verify
.codex/codex-mode.sh @audit
.codex/codex-mode.sh planning
.codex/codex-mode.sh planning --supervised
.codex/codex-mode.sh coding
.codex/codex-mode.sh coding --supervised
.codex/codex-mode.sh reviewing
.codex/codex-mode.sh reviewing --supervised
.codex/codex-mode.sh status
.codex/codex-mode.sh doctor
scripts/agent-hook.sh guard-local-state
scripts/agent-hook.sh no-scan-paths
scripts/verify-ai-deps.sh
```

Runtime stack detection lives in `scripts/agent-tech-stack-lib.sh`; the
detector is only a wrapper.

Seat occupants and model defaults live in `docs/agent-configs/seats.json`;
inspect them with `scripts/agent-seats.sh show` and validate with
`scripts/agent-seats.sh validate`. `CODEX_MODEL_PROFILE=<profile>` is ignored
with a warning for one release. All modes default to project-local full-flow. Use
`--supervised`, `--read-only`, `--propose`, or `--standard` only when the user
wants to observe and approve actions.
Reviewing is findings-first; it may run project-local verification, but applies
remediation edits only when the request asks for fixes or an exact patch scope.

Canonical collaboration:
- Roles and transitions use `docs/agent-configs/agent-mode-contracts.md`.
- Handoffs use `docs/agent-configs/agent-handoff-schema.md` with the selected
  local packet under `.agents/tasks/<task-id>/`.
- Agents respect `scripts/agent-hook.sh no-scan-paths` before broad search.

If Codex reports `Selected model is at capacity. Please try a different model.`,
use a controlled one-shot fallback instead of editing generated files:

```bash
CODEX_USE_FALLBACK=1 .codex/codex-mode.sh planning
CODEX_USE_FALLBACK=1 .codex/codex-mode.sh coding
CODEX_USE_FALLBACK=1 .codex/codex-mode.sh reviewing
```

Fallback defaults come from the selected seat in `docs/agent-configs/seats.json`.
Override per launch when capacity or rollout needs a one-shot change:

```bash
CODEX_MODEL_OVERRIDE=gpt-5.6-terra .codex/codex-mode.sh planning
CODEX_REASONING_EFFORT=high CODEX_USE_FALLBACK=1 .codex/codex-mode.sh coding
```

## Project Notes

<!-- BEGIN USER: codex-readme:notes -->
<!-- Add project-specific Codex notes here (e.g. Git hygiene); preserved across harness upgrades. -->
<!-- END USER: codex-readme:notes -->
EOF

  write_file "$TARGET_DIR/.codex/codex-mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MODE_FILE="$PROJECT_ROOT/.codex-mode-lock"
AGENT_HOOK="$PROJECT_ROOT/scripts/agent-hook.sh"
AGENT_GUARD="$PROJECT_ROOT/scripts/agent-guard.sh"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
VERIFY_AI_DEPS="$PROJECT_ROOT/scripts/verify-ai-deps.sh"
SEATS_SCRIPT="$PROJECT_ROOT/scripts/agent-seats.sh"
SEATS_FILE="$PROJECT_ROOT/docs/agent-configs/seats.json"
LEGACY_PROFILES="$PROJECT_ROOT/docs/agent-configs/model-profiles.json"
AGENTS_MD="$PROJECT_ROOT/AGENTS.md"

DEFAULT_MODE="planning"
DEFAULT_FLOW="full_flow"
STANDARD_APPROVAL="on-request"
FULL_FLOW_APPROVAL="never"

TEMP_FILES=()
NEW_TEMP=""
SEAT_DATA=()
MODEL_DATA=()
DATA_LINES=()
EFFECTIVE_MODEL=""
EFFECTIVE_EFFORT=""
MODEL_SOURCE=""
LOCKED_SEAT=""
LOCKED_TAG=""
LOCKED_PHASE=""
LOCKED_HOST=""
CONFLICT="0"

cleanup() {
  local path
  if [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
    for path in "${TEMP_FILES[@]}"; do
      rm -f "$path"
    done
  fi
}
trap cleanup EXIT

usage() {
  printf '%s\n' \
    "Usage:" \
    "  .codex/codex-mode.sh <@seat|seat|planning|coding|reviewing> [options] [prompt]" \
    "  .codex/codex-mode.sh run [options] [prompt]" \
    "  .codex/codex-mode.sh status" \
    "  .codex/codex-mode.sh doctor" \
    "" \
    "Seats:" \
    "  @spec spec  @gate gate planning  @build build coding  @verify verify reviewing  @audit audit" \
    "" \
    "Flow options:" \
    "  --full-flow | --full_flow | -full_flow" \
    "  --supervised | --read-only | --propose | --approval-gate | --standard" \
    "" \
    "Environment:" \
    "  CODEX_MODEL_OVERRIDE=<model> overrides the selected seat for one launch." \
    "  CODEX_<ROUTE>_MODEL_OVERRIDE=<model> keeps route-named compatibility overrides." \
    "  CODEX_USE_FALLBACK=1 selects the configured fallback for the selected seat." \
    "  CODEX_REASONING_EFFORT=<effort> explicitly selects a catalog-supported effort."
}

is_valid_mode() {
  [[ "$1" == "planning" || "$1" == "coding" || "$1" == "reviewing" ]]
}

is_valid_flow() {
  [[ "$1" == "standard" || "$1" == "full_flow" ]]
}

is_valid_seat() {
  case "$1" in
    spec|gate|build|verify|audit|owner) return 0 ;;
    *) return 1 ;;
  esac
}

seat_from_arg() {
  case "$1" in
    @spec|spec) printf '%s' "spec" ;;
    @gate|gate|planning) printf '%s' "gate" ;;
    @build|build|coding) printf '%s' "build" ;;
    @verify|verify|reviewing) printf '%s' "verify" ;;
    @audit|audit) printf '%s' "audit" ;;
    @owner|owner) printf '%s' "owner" ;;
    *) return 1 ;;
  esac
}

route_for_seat() {
  case "$1" in
    spec|gate) printf '%s' "planning" ;;
    build) printf '%s' "coding" ;;
    verify|audit) printf '%s' "reviewing" ;;
    owner) return 1 ;;
    *) return 1 ;;
  esac
}

seat_tag() {
  case "$1" in
    spec) printf '%s' '@spec' ;;
    gate) printf '%s' '@gate' ;;
    build) printf '%s' '@build' ;;
    verify) printf '%s' '@verify' ;;
    audit) printf '%s' '@audit' ;;
    owner) printf '%s' '@owner' ;;
    *) return 1 ;;
  esac
}

read_mode() {
  local mode
  if [[ -f "$MODE_FILE" ]]; then
    mode="$(sed -n 's/^mode=//p' "$MODE_FILE" | tail -n1)"
    if is_valid_mode "$mode"; then
      printf '%s' "$mode"
      return 0
    fi
  fi
  printf '%s' "$DEFAULT_MODE"
}

read_flow() {
  local flow
  if [[ -f "$MODE_FILE" ]]; then
    flow="$(sed -n 's/^flow=//p' "$MODE_FILE" | tail -n1)"
    if is_valid_flow "$flow"; then
      printf '%s' "$flow"
      return 0
    fi
  fi
  printf '%s' "$DEFAULT_FLOW"
}

read_locked_seat() {
  local seat mode
  if [[ -f "$MODE_FILE" ]]; then
    seat="$(sed -n 's/^seat=//p' "$MODE_FILE" | tail -n1)"
    if is_valid_seat "$seat"; then
      printf '%s' "$seat"
      return 0
    fi
  fi
  mode="$(read_mode)"
  seat_from_arg "$mode"
}

write_mode() {
  local mode="$1"
  local flow="$2"
  local seat="$3"
  cat > "$MODE_FILE" <<LOCK
mode=$mode
flow=$flow
seat=$seat
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCK
}

truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fallback_requested() {
  truthy "${CODEX_USE_FALLBACK:-}"
}

profile_warning() {
  if [[ -n "${CODEX_MODEL_PROFILE:-}" ]]; then
    echo "WARN: CODEX_MODEL_PROFILE is ignored for this release; seats.json is authoritative." >&2
  fi
}

new_temp() {
  local temp_dir
  temp_dir="${TMPDIR:-/tmp}"
  NEW_TEMP="$(mktemp "$temp_dir/agent-seats-launcher.XXXXXX")" || {
    echo "ERROR: cannot allocate a temporary capture file" >&2
    return 1
  }
  TEMP_FILES+=("$NEW_TEMP")
}

emit_file_stderr() {
  if [[ -s "$1" ]]; then
    cat "$1" >&2
  fi
  return 0
}

read_data_lines() {
  DATA_LINES=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    DATA_LINES+=("$line")
  done < "$1"
}

resolve_seat_data() {
  local requested="$1"
  local output_file error_file line_count
  new_temp || return 1
  output_file="$NEW_TEMP"
  new_temp || return 1
  error_file="$NEW_TEMP"
  if ! AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" resolve "$requested" >"$output_file" 2>"$error_file"; then
    emit_file_stderr "$error_file"
    echo "ERROR: cannot resolve seat $requested; repair seats.json with scripts/agent-seats.sh validate or reset." >&2
    return 1
  fi
  emit_file_stderr "$error_file"
  read_data_lines "$output_file"
  line_count=0
  for line in "${DATA_LINES[@]}"; do
    line_count=$((line_count + 1))
  done
  if [[ "$line_count" -ne 8 ]]; then
    echo "ERROR: seats resolve interface returned $line_count lines; expected exactly 8." >&2
    return 1
  fi
  SEAT_DATA=("${DATA_LINES[@]}")
}

model_info_data() {
  local model="$1"
  local output_file error_file line_count
  new_temp || return 1
  output_file="$NEW_TEMP"
  new_temp || return 1
  error_file="$NEW_TEMP"
  if ! AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" model-info "$model" >"$output_file" 2>"$error_file"; then
    emit_file_stderr "$error_file"
    echo "ERROR: model $model is unavailable in the seats catalog; add it to catalog.models before launching." >&2
    return 1
  fi
  emit_file_stderr "$error_file"
  read_data_lines "$output_file"
  line_count=0
  for line in "${DATA_LINES[@]}"; do
    line_count=$((line_count + 1))
  done
  if [[ "$line_count" -ne 3 ]]; then
    echo "ERROR: model-info interface returned $line_count lines; expected exactly 3." >&2
    return 1
  fi
  MODEL_DATA=("${DATA_LINES[@]}")
}

validate_explicit_effort() {
  local model="$1"
  local effort="$2"
  local supported_efforts="$3"
  case "$effort" in
    [a-z]*)
      case "$effort" in
        *[!a-z0-9_-]*)
          echo "ERROR: effort '$effort' must be one lowercase single token matching [a-z][a-z0-9_-]*." >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "ERROR: effort '$effort' must be one lowercase single token matching [a-z][a-z0-9_-]*." >&2
      return 1
      ;;
  esac
  local supported
  for supported in $supported_efforts; do
    if [[ "$supported" == "$effort" ]]; then
      return 0
    fi
  done
  echo "ERROR: effort '$effort' is not supported by $model (supported: $supported_efforts); add the effort to catalog.models.$model.efforts or choose one listed." >&2
  return 1
}

require_seats_for_launch() {
  if [[ ! -e "$SEATS_FILE" ]]; then
    echo "WARN: seats.json is missing; initializing it once before launch." >&2
    if ! AGENT_SEATS_FILE="$SEATS_FILE" \
      AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
      AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
      "$SEATS_SCRIPT" init >/dev/null; then
      echo "ERROR: seats.json could not be initialized; run scripts/agent-seats.sh init or reset and retry." >&2
      return 1
    fi
  fi
  if [[ ! -f "$SEATS_FILE" ]]; then
    echo "ERROR: seats.json is unavailable after initialization; run scripts/agent-seats.sh init." >&2
    return 1
  fi
  if ! AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" validate >/dev/null; then
    echo "ERROR: active seats.json is invalid; repair it with scripts/agent-seats.sh set or reset." >&2
    return 1
  fi
}

resolve_effective() {
  local requested_seat="$1"
  local route="$2"
  local default_model fallback_model mode_override mode_override_source
  local selected_effort explicit_effort supported_efforts
  local catalog_host catalog_default_effort
  local source fallback_effort

  resolve_seat_data "$requested_seat" || return 1
  LOCKED_SEAT="${SEAT_DATA[0]}"
  LOCKED_TAG="${SEAT_DATA[1]}"
  LOCKED_PHASE="${SEAT_DATA[2]}"
  LOCKED_HOST="${SEAT_DATA[3]}"
  default_model="${SEAT_DATA[4]}"
  selected_effort="${SEAT_DATA[5]}"
  fallback_model="${SEAT_DATA[6]}"
  fallback_effort="${SEAT_DATA[7]}"

  [[ "$LOCKED_HOST" == "codex" ]] || return 2
  if [[ "$requested_seat" == "owner" ]]; then
    return 2
  fi

  mode_override=""
  mode_override_source=""
  case "$route" in
    planning)
      mode_override="${CODEX_PLANNING_MODEL_OVERRIDE:-}"
      mode_override_source="CODEX_PLANNING_MODEL_OVERRIDE"
      ;;
    coding)
      mode_override="${CODEX_CODING_MODEL_OVERRIDE:-}"
      mode_override_source="CODEX_CODING_MODEL_OVERRIDE"
      ;;
    reviewing)
      mode_override="${CODEX_REVIEWING_MODEL_OVERRIDE:-}"
      mode_override_source="CODEX_REVIEWING_MODEL_OVERRIDE"
      ;;
    *) echo "ERROR: invalid route for seat $requested_seat" >&2; return 1 ;;
  esac

  if [[ -n "${CODEX_MODEL_OVERRIDE:-}" ]]; then
    EFFECTIVE_MODEL="$CODEX_MODEL_OVERRIDE"
    MODEL_SOURCE="CODEX_MODEL_OVERRIDE"
    source="override"
  elif [[ -n "$mode_override" ]]; then
    EFFECTIVE_MODEL="$mode_override"
    MODEL_SOURCE="$mode_override_source"
    source="override"
  elif fallback_requested; then
    if [[ -z "$fallback_model" ]]; then
      echo "ERROR: seat $LOCKED_TAG has no configured fallback; clear CODEX_USE_FALLBACK or configure fallback_model and fallback_effort in seats.json." >&2
      return 1
    fi
    EFFECTIVE_MODEL="$fallback_model"
    MODEL_SOURCE="CODEX_USE_FALLBACK"
    source="fallback"
  else
    if [[ -z "$default_model" ]]; then
      echo "ERROR: seat $LOCKED_TAG has no configured Codex model." >&2
      return 1
    fi
    EFFECTIVE_MODEL="$default_model"
    MODEL_SOURCE="default"
    source="default"
  fi

  model_info_data "$EFFECTIVE_MODEL" || return 1
  catalog_host="${MODEL_DATA[0]}"
  catalog_default_effort="${MODEL_DATA[1]}"
  supported_efforts="${MODEL_DATA[2]}"
  if [[ "$catalog_host" != "codex" ]]; then
    echo "ERROR: model $EFFECTIVE_MODEL belongs to host $catalog_host; choose a Codex model in catalog.models." >&2
    return 1
  fi

  case "$source" in
    fallback) EFFECTIVE_EFFORT="$fallback_effort" ;;
    default) EFFECTIVE_EFFORT="$selected_effort" ;;
    override) EFFECTIVE_EFFORT="$catalog_default_effort" ;;
  esac
  if [[ -z "$EFFECTIVE_EFFORT" ]]; then
    echo "ERROR: seat $LOCKED_TAG has no effort for model $EFFECTIVE_MODEL; repair seats.json." >&2
    return 1
  fi

  explicit_effort="${CODEX_REASONING_EFFORT:-}"
  if [[ -n "$explicit_effort" ]]; then
    validate_explicit_effort "$EFFECTIVE_MODEL" "$explicit_effort" "$supported_efforts" || return 1
    EFFECTIVE_EFFORT="$explicit_effort"
  else
    validate_explicit_effort "$EFFECTIVE_MODEL" "$EFFECTIVE_EFFORT" "$supported_efforts" || return 1
  fi
}

compute_conflict() {
  local seat_id="$1"
  local effective_model="$2"
  local conflict_stderr
  new_temp || return 1
  conflict_stderr="$NEW_TEMP"
  if ! CONFLICT="$(
    AGENT_SEATS_FILE="$SEATS_FILE" \
      AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
      AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
      "$SEATS_SCRIPT" conflict "$seat_id" "$effective_model" 2>"$conflict_stderr"
  )"; then
    emit_file_stderr "$conflict_stderr"
    echo "ERROR: could not evaluate seat conflict for $seat_id." >&2
    return 1
  fi
  emit_file_stderr "$conflict_stderr"
  case "$CONFLICT" in
    0|1) ;;
    *) echo "ERROR: conflict interface returned '$CONFLICT'; expected 0 or 1." >&2; return 1 ;;
  esac
}

print_launch_summary() {
  local route="$1"
  local flow="$2"
  local seat_id="$3"
  local model="$4"
  local model_source="$5"
  local effort="$6"
  local sandbox="$7"
  local approval="$8"
  {
    echo "Codex launch: seat=$(seat_tag "$seat_id") route=$route flow=$flow model=$model reasoning=$effort sandbox=$sandbox approval=$approval"
    echo "Model source: $model_source"
    if [[ "$CONFLICT" == "1" ]]; then
      echo "policy_exception=gate_coding authorization=user_session"
    fi
    if [[ "$model_source" == "default" ]]; then
      echo "If Codex reports model capacity, rerun: CODEX_USE_FALLBACK=1 .codex/codex-mode.sh $(seat_tag "$seat_id")"
    fi
  } >&2
}

resolve_codex_bin() {
  local candidate
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi
  for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex \
    "$HOME/.local/bin/codex" "$HOME/.npm-global/bin/codex" "$HOME/.bun/bin/codex"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: Codex CLI not found. Install it or add it to PATH." >&2
  return 127
}

mode_prompt() {
  local route="$1"
  local flow="$2"
  local seat_id="$3"
  local model="$4"
  local model_source="$5"
  local effort="$6"
  local seed
  seed="SEAT LOCK: $(seat_tag "$seat_id") · phase $LOCKED_PHASE · launch_model=$model model_source=$model_source"
  if [[ "$CONFLICT" == "1" ]]; then
    seed="$seed policy_exception=gate_coding authorization=user_session"
  fi
  case "$route:$flow" in
    planning:standard)
      printf '%s' "$seed MODE LOCK: PLANNING-SUPERVISED. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. This flow is read-only: respect scripts/agent-hook.sh no-scan-paths and do not mutate files unless the user grants that exact action." ;;
    planning:full_flow)
      printf '%s' "$seed MODE LOCK: PLANNING-FULL-FLOW. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. The request grants bounded project-local execution only; respect scripts/agent-hook.sh no-scan-paths and require exact approval for external paths, installs, commits, pushes, force operations, or local-only permission changes." ;;
    coding:standard)
      printf '%s' "$seed MODE LOCK: CODING-SUPERVISED. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. This flow is read-only: respect scripts/agent-hook.sh no-scan-paths and do not mutate files unless the user grants that exact action." ;;
    coding:full_flow)
      printf '%s' "$seed MODE LOCK: CODING-FULL-FLOW. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. The request grants bounded project-local implementation, tests, and verification only; respect pre-edit/no-scan guards and require exact approval for external paths, installs, commits, pushes, force operations, or local-only permission changes." ;;
    reviewing:standard)
      printf '%s' "$seed MODE LOCK: REVIEWING-SUPERVISED. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. Severity must name its trigger condition and frequency, or mark itself as an estimate. Open with the verdict and the blocker count, then the findings; no preamble, no recap, no closing pleasantry. State each defect as cause and consequence without alarm words. Before sending, delete any hedging adverb that carries no uncertainty; keep a hedge that carries real uncertainty. This flow is findings-first and read-only: respect scripts/agent-hook.sh no-scan-paths and do not remediate unless the user grants an exact patch scope." ;;
    reviewing:full_flow)
      printf '%s' "$seed MODE LOCK: REVIEWING-FULL-FLOW. Seat $(seat_tag "$seat_id") is in phase $LOCKED_PHASE; use the packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. Severity must name its trigger condition and frequency, or mark itself as an estimate. Open with the verdict and the blocker count, then the findings; no preamble, no recap, no closing pleasantry. State each defect as cause and consequence without alarm words. Before sending, delete any hedging adverb that carries no uncertainty; keep a hedge that carries real uncertainty. The request grants project-local review and verification only; respect scripts/agent-hook.sh no-scan-paths and do not remediate unless fixes or an exact patch scope were requested. External paths and mutating git operations require exact approval." ;;
    *) echo "ERROR: invalid route/flow combination." >&2; return 1 ;;
  esac
}

run_doctor() {
  local doctor_mode doctor_flow doctor_seat doctor_route resolve_rc no_scan_paths
  local path
  DOCTOR_FAIL=0
  DOCTOR_WARN=0
  echo "Codex helper doctor..."
  profile_warning
  doctor_mode="$(read_mode)"
  doctor_flow="$(read_flow)"
  doctor_seat="$(read_locked_seat)"
  doctor_route="$(route_for_seat "$doctor_seat" || true)"

  if [[ ! -e "$SEATS_FILE" ]]; then
    doctor_warn "seats.json missing; launch commands may initialize it"
  elif AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" validate >/dev/null; then
    doctor_ok "seats.json is valid"
    if AGENT_SEATS_FILE="$SEATS_FILE" \
      AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
      AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
      "$SEATS_SCRIPT" show; then
      if resolve_effective "$doctor_seat" "$doctor_route"; then
        doctor_ok "locked $(seat_tag "$doctor_seat"): model=$EFFECTIVE_MODEL effort=$EFFECTIVE_EFFORT source=$MODEL_SOURCE"
      else
        resolve_rc=$?
        if [[ "$resolve_rc" -eq 2 ]]; then
          doctor_ok "locked $(seat_tag "$doctor_seat"): host=$LOCKED_HOST (Codex launch unavailable)"
        else
          doctor_bad "locked $(seat_tag "$doctor_seat") could not resolve effective model"
        fi
      fi
    else
      doctor_bad "seat roster could not be displayed"
    fi
    if [[ -f "$LEGACY_PROFILES" ]]; then
      doctor_warn "legacy model-profiles.json present; seats.json is authoritative"
    fi
  else
    doctor_bad "seats.json is invalid; run scripts/agent-seats.sh validate or reset"
  fi

  for path in \
    AGENTS.md \
    CLAUDE.md \
    docs/agent-configs/agent-bootstrap.lock.json \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/context-policy.json \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md \
    docs/agent-configs/task-journal.md \
    .claude/commands/council.md \
    .claude/commands/karpathy.md \
    .codex/config.toml \
    .codex/codex-mode.sh \
    .codex/README.md \
    .claude/settings.json \
    .claude/README.md \
    .claude/commands/planning.md \
    .claude/commands/planning-full-flow.md \
    .claude/commands/coding.md \
    .claude/commands/coding-full-flow.md \
    .claude/commands/reviewing.md \
    .claude/commands/reviewing-full-flow.md \
    .claude/commands/codex/setup.md \
    .claude/commands/codex/rescue.md \
    .claude/commands/codex/status.md \
    .claude/commands/doctor.md \
    .claude/commands/project-onboarding.md \
    .agents/skills/doubt-driven/SKILL.md \
    docs/agent-configs/project-onboarding.md \
    docs/agent-configs/project-brief.md \
    docs/superpowers/specs/README.md \
    docs/superpowers/specs/project-tech-stack.md \
    docs/superpowers/plans/README.md; do
    doctor_file "$path"
  done

  if [[ -f "$PROJECT_ROOT/docs/agent-configs/project-brief.md" ]] &&
    grep -Fq '<!-- UNFILLED -->' "$PROJECT_ROOT/docs/agent-configs/project-brief.md"; then
    doctor_warn "project brief is unfilled; run project onboarding before substantive work"
  else
    doctor_ok "project brief is filled or not required"
  fi

  doctor_context_budget
  doctor_exec scripts/agent-seats.sh
  doctor_exec scripts/install-rtk.sh
  doctor_exec scripts/rtk
  doctor_exec scripts/agent-hook.sh
  doctor_exec scripts/agent-guard.sh
  doctor_exec scripts/agent-tech-stack-lib.sh
  doctor_exec scripts/detect-agent-tech-stack.sh
  doctor_exec scripts/verify-ai-deps.sh
  doctor_bash scripts/agent-seats.sh
  doctor_bash scripts/install-rtk.sh
  doctor_bash scripts/rtk
  doctor_bash .codex/codex-mode.sh
  doctor_bash scripts/agent-hook.sh
  doctor_bash scripts/agent-guard.sh
  doctor_bash scripts/agent-tech-stack-lib.sh
  doctor_bash scripts/detect-agent-tech-stack.sh
  doctor_bash scripts/verify-ai-deps.sh

  if command -v python3 >/dev/null 2>&1 && python3 -m json.tool "$PROJECT_ROOT/.claude/settings.json" >/dev/null 2>&1; then
    doctor_ok "Claude settings JSON is valid"
  else
    doctor_bad "Claude settings JSON is invalid"
  fi
  if grep -Fq './scripts/agent-hook.sh claude-pretool' "$PROJECT_ROOT/.claude/settings.json"; then
    doctor_ok "Claude PreToolUse uses shared agent hook"
  else
    doctor_bad "Claude PreToolUse does not use shared agent hook"
  fi
  if grep -Fq '"matcher": "Edit|Write|MultiEdit"' "$PROJECT_ROOT/.claude/settings.json"; then
    doctor_ok "Claude PreToolUse guards edit/write tools"
  else
    doctor_bad "Claude PreToolUse does not guard edit/write tools"
  fi
  if [[ -x "$PROJECT_ROOT/scripts/rtk" ]] && "$PROJECT_ROOT/scripts/rtk" --version 2>/dev/null | grep -Fq '0.37.2'; then
    doctor_ok "rtk wrapper resolves pinned version 0.37.2"
  else
    doctor_warn "rtk pinned binary is not installed; run: bash scripts/install-rtk.sh before using rtk-specific hooks"
  fi
  if [[ -x "$DETECTOR" ]] && "$DETECTOR" --summary >/dev/null 2>&1; then
    doctor_ok "runtime detector runs"
  else
    doctor_bad "runtime detector failed"
  fi
  if [[ -x "$AGENT_HOOK" ]] && "$AGENT_HOOK" guard-local-state >/dev/null 2>&1; then
    doctor_ok "local-only agent state is not tracked"
  else
    doctor_bad "local-only agent state guard failed"
  fi
  if [[ -x "$AGENT_GUARD" ]] && "$AGENT_GUARD" check >/dev/null 2>&1; then
    doctor_ok "agent guard check passes"
  else
    doctor_bad "agent guard check failed"
  fi
  no_scan_paths="$("$AGENT_HOOK" no-scan-paths 2>/dev/null || true)"
  if [[ -x "$AGENT_HOOK" ]] &&
    printf '%s\n' "$no_scan_paths" | grep -Fq '.claude/worktrees/' &&
    printf '%s\n' "$no_scan_paths" | grep -Fq '.gemini/' &&
    printf '%s\n' "$no_scan_paths" | grep -Fq '.openclaude/' &&
    printf '%s\n' "$no_scan_paths" | grep -Fq 'AGENTS.local.md' &&
    printf '%s\n' "$no_scan_paths" | grep -Fq '*.jks'; then
    doctor_ok "no-scan guard lists local/vendor/sensitive paths"
  else
    doctor_bad "no-scan guard missing local/vendor/sensitive paths"
  fi
  if [[ -x "$AGENT_HOOK" ]] && "$AGENT_HOOK" codex-preflight --check-only "$doctor_route" "$doctor_flow" >/dev/null 2>&1; then
    doctor_ok "shared agent hook codex preflight passes"
  else
    doctor_bad "shared agent hook codex preflight failed"
  fi

  if [[ "$DOCTOR_FAIL" -gt 0 ]]; then
    echo "Doctor failed: $DOCTOR_FAIL issue(s)." >&2
    return 1
  fi
  if [[ "$DOCTOR_WARN" -gt 0 ]]; then
    echo "Doctor passed with $DOCTOR_WARN warning(s)."
  else
    echo "Doctor passed."
  fi
}

doctor_ok() {
  printf '  ok    %s\n' "$1"
}
doctor_bad() {
  printf '  FAIL  %s\n' "$1"
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
}
doctor_warn() {
  printf '  WARN  %s\n' "$1"
  DOCTOR_WARN=$((DOCTOR_WARN + 1))
}
doctor_file() {
  if [[ -f "$PROJECT_ROOT/$1" ]]; then
    doctor_ok "file exists: $1"
  else
    doctor_bad "missing file: $1"
  fi
}
doctor_exec() {
  if [[ -x "$PROJECT_ROOT/$1" ]]; then
    doctor_ok "executable: $1"
  else
    doctor_bad "not executable: $1"
  fi
}
doctor_bash() {
  if bash -n "$PROJECT_ROOT/$1"; then
    doctor_ok "bash syntax: $1"
  else
    doctor_bad "bash syntax failed: $1"
  fi
}
estimate_tokens_for_file() {
  local path="$1" words chars
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  read -r words chars < <(wc -w -c < "$path")
  awk -v words="$words" -v chars="$chars" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}
sum_estimated_tokens() {
  local total=0 token_count relpath
  for relpath in "$@"; do
    token_count="$(estimate_tokens_for_file "$PROJECT_ROOT/$relpath")"
    total=$((total + token_count))
  done
  printf '%s' "$total"
}
doctor_context_budget() {
  local core_tokens full_tokens
  core_tokens="$(sum_estimated_tokens AGENTS.md docs/agent-configs/project-agent-context.md docs/agent-configs/project-brief.md)"
  full_tokens="$(sum_estimated_tokens AGENTS.md docs/agent-configs/project-agent-context.md docs/agent-configs/project-brief.md docs/agent-configs/agent-mode-contracts.md docs/agent-configs/agent-handoff-schema.md docs/agent-configs/karpathy-llm-coding-agent-config.md docs/agent-configs/llm-council-agent-workflow.md docs/agent-configs/task-journal.md)"
  if [[ "$core_tokens" -gt 4000 ]]; then
    doctor_warn "core startup context estimate: $core_tokens tokens exceeds gate 4000"
  elif [[ "$core_tokens" -gt 3800 ]]; then
    doctor_warn "core startup context estimate: $core_tokens tokens (gate 4000, amber above 3800)"
  else
    doctor_ok "core startup context estimate: $core_tokens tokens (gate 4000, amber above 3800)"
  fi
  if [[ "$full_tokens" -gt 6200 ]]; then
    doctor_warn "on-demand full workflow context estimate: $full_tokens tokens exceeds gate 6200"
  elif [[ "$full_tokens" -gt 5900 ]]; then
    doctor_warn "on-demand full workflow context estimate: $full_tokens tokens (gate 6200, amber above 5900)"
  else
    doctor_ok "on-demand full workflow context estimate: $full_tokens tokens (gate 6200, amber above 5900)"
  fi
}

run_status() {
  local current_mode current_flow current_seat
  profile_warning
  current_mode="$(read_mode)"
  current_flow="$(read_flow)"
  current_seat="$(read_locked_seat)"
  echo "Current mode: $current_mode"
  echo "Current flow: $current_flow"
  echo "Locked seat: $(seat_tag "$current_seat")"
  if [[ ! -e "$SEATS_FILE" ]]; then
    echo "WARN: seats.json missing; status is read-only and launch commands will initialize it." >&2
    return 0
  fi
  if ! AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" show; then
    echo "ERROR: seats.json is invalid; status is read-only." >&2
    return 1
  fi
  if [[ -f "$LEGACY_PROFILES" ]]; then
    echo "WARN: legacy model-profiles.json present; seats.json is authoritative." >&2
  fi
  local current_route resolve_rc
  current_route="$(route_for_seat "$current_seat" || true)"
  if resolve_effective "$current_seat" "$current_route"; then
    echo "Effective model: $EFFECTIVE_MODEL"
    echo "Effective effort: $EFFECTIVE_EFFORT"
    echo "Model source: $MODEL_SOURCE"
  else
    resolve_rc=$?
    if [[ "$resolve_rc" -eq 2 ]]; then
      echo "Locked occupant: $LOCKED_HOST (Codex launch unavailable)"
      return 0
    fi
    return "$resolve_rc"
  fi
}

run_launch() {
  local requested_seat="$1"
  local route="$2"
  local flow="$3"
  local persist="$4"
  shift 4 || true
  local sandbox approval seed codex_bin prompt resolve_rc
  reject_nested_launch || return 1
  profile_warning
  require_seats_for_launch || return 1
  if resolve_effective "$requested_seat" "$route"; then
    :
  else
    resolve_rc=$?
    if [[ "$resolve_rc" -eq 2 ]]; then
      echo "ERROR: seat $LOCKED_TAG is occupied by $LOCKED_HOST; open it in that host." >&2
    fi
    return "$resolve_rc"
  fi
  compute_conflict "$requested_seat" "$EFFECTIVE_MODEL" || return 1
  if [[ "$flow" == "full_flow" ]]; then
    sandbox="workspace-write"
    approval="$FULL_FLOW_APPROVAL"
  else
    sandbox="read-only"
    approval="$STANDARD_APPROVAL"
  fi
  seed="$(mode_prompt "$route" "$flow" "$requested_seat" "$EFFECTIVE_MODEL" "$MODEL_SOURCE" "$EFFECTIVE_EFFORT")"
  codex_bin="$(resolve_codex_bin)" || return $?
  if [[ "$persist" == "true" ]]; then
    write_mode "$route" "$flow" "$requested_seat"
  fi
  if [[ -x "$AGENT_HOOK" ]] &&
    ! "$AGENT_HOOK" codex-preflight "$route" "$flow"; then
    echo "ERROR: agent hook preflight failed for route $route." >&2
    return 1
  fi
  print_launch_summary "$route" "$flow" "$requested_seat" "$EFFECTIVE_MODEL" "$MODEL_SOURCE" "$EFFECTIVE_EFFORT" "$sandbox" "$approval"
  prompt=""
  if [[ "$#" -gt 0 ]]; then
    prompt="$*"
    export CODEX_HARNESS_SESSION=1
    cleanup
    trap - EXIT
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$EFFECTIVE_MODEL" -c "model_reasoning_effort=\"$EFFECTIVE_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"$'\n\n'"USER PROMPT:"$'\n'"$prompt"
  else
    export CODEX_HARNESS_SESSION=1
    cleanup
    trap - EXIT
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$EFFECTIVE_MODEL" -c "model_reasoning_effort=\"$EFFECTIVE_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"
  fi
}

reject_nested_launch() {
  if [[ "${CODEX_HARNESS_SESSION:-}" == "1" ]]; then
    echo "ERROR: accidental nested Codex launch blocked; exit the current harness session before starting another." >&2
    return 1
  fi
}

run_flow_flag() {
  FLOW="$DEFAULT_FLOW"
  if [[ "$1" == "-full_flow" || "$1" == "--full-flow" || "$1" == "--full_flow" ]]; then
    FLOW="full_flow"
    return 0
  fi
  if [[ "$1" == "-standard" || "$1" == "--standard" || "$1" == "--supervised" ||
    "$1" == "--read-only" || "$1" == "--propose" || "$1" == "--approval-gate" ]]; then
    FLOW="standard"
    return 0
  fi
  return 1
}

cmd="status"
if [[ "$#" -gt 0 ]]; then
  cmd="$1"
  shift
fi
case "$cmd" in
  -h|--help|help)
    usage
    ;;
  planning|coding|reviewing|@spec|spec|@gate|gate|@build|build|@verify|verify|@audit|audit)
    requested_seat="$(seat_from_arg "$cmd")"
    route="$(route_for_seat "$requested_seat")"
    flow="$DEFAULT_FLOW"
    if [[ "$#" -gt 0 ]] && run_flow_flag "$1"; then
      flow="$FLOW"
      shift
    fi
    run_launch "$requested_seat" "$route" "$flow" true "$@"
    ;;
  @owner|owner)
    echo "ERROR: seat @owner is human-owned and is never launchable by this helper." >&2
    exit 2
    ;;
  run)
    stored_flow="$(read_flow)"
    stored_seat="$(read_locked_seat)"
    flow="$stored_flow"
    if [[ "$#" -gt 0 ]] && run_flow_flag "$1"; then
      flow="$FLOW"
      shift
    fi
    route="$(route_for_seat "$stored_seat")"
    run_launch "$stored_seat" "$route" "$flow" false "$@"
    ;;
  status)
    run_status
    ;;
  doctor)
    run_doctor
    ;;
  *)
    echo "ERROR: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
EOF

  make_executable "$LAST_WRITTEN_FILE"
}
