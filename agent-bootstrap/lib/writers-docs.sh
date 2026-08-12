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

- One branch, one commit: fold work with \`git commit --amend\` (or
  \`git reset --soft <base>\` for several) so the branch stays a single commit.
- Branch names: \`feature/<slug>\` for features, \`bugfix/<slug>\` for fixes;
  branch off the latest default branch; keep one logical change per branch.
- Commit messages: Conventional Commits \`type(scope): subject\`
  (\`feat|fix|docs|refactor|test|chore|release\`).
- No agent identity: never put AI/agent names or \`Co-Authored-By\` agent
  trailers in commit messages or branch names.
- Amended push: \`git push --force-with-lease\` (never plain \`--force\`), only on
  your own \`feature/\`/\`bugfix/\` branch, never the default or shared branch.
- Approval: do not commit, push, tag, or merge without explicit human approval
  (these are outward-facing).

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
- Run \`scripts/agent-guard.sh pre-edit <path>\` before changing protected
  context, harness, CI, release, or generated-runtime paths. For intentional
  protected edits, rerun with \`--ack <reason>\` and keep the reason in the
  handoff or final summary.
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

  write_overlay_file "$TARGET_DIR/AGENTS.md" <<EOF
# Agent Conventions - $PROJECT_NAME

Portable multi-agent workflow for Codex, Claude, and thin tool adapters. Durable
behavior belongs in \`docs/agent-configs/\`.

## Startup Context Budget

Always read at startup:

- This file.
- \`docs/agent-configs/project-agent-context.md\`.
- \`docs/agent-configs/project-brief.md\` when filled; if it still has
  \`<!-- UNFILLED -->\`, run \`docs/agent-configs/project-onboarding.md\` before
  substantive work.
- The output of \`scripts/agent-guard.sh preflight\` and
  \`scripts/detect-agent-tech-stack.sh --markdown\` when available.

Read on demand:

- \`docs/agent-configs/agent-mode-contracts.md\` when selecting/switching modes.
- \`docs/agent-configs/agent-handoff-schema.md\` when ownership changes.
- \`.agents/tasks/<task-id>/\` for the selected local collaboration packet.
- \`docs/agent-configs/karpathy-llm-coding-agent-config.md\` before substantial
  edits or production-risk refactors.
- \`docs/agent-configs/llm-council-agent-workflow.md\` for councils or high-risk
  architecture/security/release tradeoffs.
- Skills under \`.agents/skills/\` only when their descriptions match the
  current task.

Keep the always-on/core startup context under roughly 4k estimated tokens.
$mobile_skill_read_on_demand_bullet


At the start of substantive work:

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
\`scripts/agent-guard.sh pre-final --run-verify --verify-scope full\`. If a
detected command is a placeholder or needs unavailable local services, record
the skip reason in the handoff or final summary and rerun with \`--advisory\`
only when the user or CI environment explicitly requires advisory mode.
Optional git gate: \`scripts/install-git-hooks.sh\`.

Stack detection logic lives in \`scripts/agent-tech-stack-lib.sh\`; update that
library rather than duplicating detection rules in multiple scripts.
Runtime detector output is bound by
\`docs/agent-configs/agent-bootstrap.lock.json\`; refresh the lock intentionally
with \`bash scripts/bootstrap-multi-agent-project.sh --refresh-lock\` after
stack or module changes.

If the script is unavailable, infer from build/config files and state
uncertainty instead of guessing.

## Agentmemory Usage

Agentmemory is the long-term memory layer for project context when the global
MCP tools are available. The bootstrap installs
\`.agents/skills/agentmemory-mcp/SKILL.md\` automatically; agents should use
that skill for recall/save rules. Store shared product/domain requirements with
platform_scope=shared, and keep implementation details in platform-specific
memories such as platform_scope=android or platform_scope=ios.

For non-trivial decisions, the \`doubt-driven\` skill
(\`.agents/skills/doubt-driven/SKILL.md\`) provides a fresh-context adversarial
check.

## Collaboration

Use \`.agents/tasks/<task-id>/\` for local collaboration state. Canonical roles,
transitions, gates, and review limits live in
\`docs/agent-configs/agent-mode-contracts.md\`; packet and artifact formats live
in \`docs/agent-configs/agent-handoff-schema.md\`. Do not let two agents edit the
same files concurrently.

## Local State And No-Scan Guard

Agents must not scan, read, grep, diff, summarize, or print local-only state,
tool caches, generated output, or sensitive machine files unless the user names
the exact path and asks for that exact inspection.

\`\`\`bash
scripts/agent-hook.sh no-scan-paths
scripts/agent-hook.sh guard-local-state
\`\`\`

The no-scan list covers local worktrees, vendor runtime state, personal
overrides, tool caches, build output, local Codex state, \`.env*\`,
\`local.properties\`, \`keystore.properties\`, and key/keystore material. The
tracked-state guard fails on agent runtime state; sensitive project files
remain no-scan.

## Work Modes

- \`planning\`: strategy, specs, architecture, deep refactor planning, and
  performance improvement planning. Default is project-local full-flow.
- \`coding\`: implementation, refactoring, bug fixes, tests, and verification.
  Follow the canonical adequacy gate before implementation.
- \`reviewing\`: one findings-first pass. Review mode may run project-local
  verification in full-flow. Remediation edits require the review request to
  ask for fixes or an exact patch scope. Use council only on demand for
  high-risk or disputed work.

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

Default posture for planning/coding/reviewing is project-local full-flow.
Use supervised/read-only/propose arguments only when the user wants
step-by-step approval. Full-flow does not authorize external-path mutations,
installs, commits, pushes, force operations, or local-only secret/permission
file changes without exact approval.

## Git Workflow

All shell git commands must go through:

\`\`\`bash
./scripts/rtk git ...
\`\`\`

If \`./scripts/rtk\` is missing or cannot resolve the pinned rtk binary, run:

\`\`\`bash
bash scripts/install-rtk.sh
\`\`\`

- One branch, one commit: fold work with \`git commit --amend\` (or
  \`git reset --soft <base>\` for several) so the branch stays a single commit.
- Branch names: \`feature/<slug>\` for features, \`bugfix/<slug>\` for fixes;
  branch off the latest default branch; keep one logical change per branch.
- Commit messages: Conventional Commits \`type(scope): subject\`
  (\`feat|fix|docs|refactor|test|chore|release\`).
- No agent identity: never put AI/agent names or \`Co-Authored-By\` agent
  trailers in commit messages or branch names.
- Amended push: \`git push --force-with-lease\` (never plain \`--force\`), only on
  your own \`feature/\`/\`bugfix/\` branch, never the default or shared branch.
- Approval: do not commit, push, tag, or merge without explicit human approval
  (these are outward-facing).

Never silently revert user work. Never hide uncertainty behind confident
wording. No success claim without fresh verification or a clearly stated reason
why verification was not run.

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

Detected facts above are the seed. The durable deep context lives in
\`docs/agent-configs/project-brief.md\`. If that file still carries its
\`<!-- UNFILLED -->\` marker, run project onboarding
(\`docs/agent-configs/project-onboarding.md\`) before substantive work. The
onboarding pass also updates project-specific tech-stack notes in this file and
fills \`docs/superpowers/specs/project-tech-stack.md\`.

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

Detection is file-signature based. Treat it as a starting point, then refine
this file after inspecting the actual architecture, modules, test layout, and
deployment process.

## Verification Commands

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

Agents must prefer these commands when relevant. If a command is not valid for
this project, update this file in the same change that introduces the correct
workflow.

## Detection Warnings

<!-- BEGIN MANAGED: multi-agent-bootstrap:detection-warnings -->
$warning_bullets
<!-- END MANAGED: multi-agent-bootstrap:detection-warnings -->

## Stack-Specific Overlay

<!-- BEGIN MANAGED: multi-agent-bootstrap:stack-overlay -->
$stack_overlay_content
<!-- END MANAGED: multi-agent-bootstrap:stack-overlay -->

## Agent Safety Bridge

- Use \`docs/agent-configs/agent-handoff-schema.md\` when transferring work
  between agents or phases.
- Run \`scripts/agent-guard.sh pre-edit <path>\` before changing protected
  context, harness, CI, release, or generated-runtime paths. For intentional
  protected edits, rerun with \`--ack <reason>\` and keep the reason in the
  handoff or final summary.
- Run \`scripts/agent-hook.sh no-scan-paths\` before broad search and avoid
  local-only/tool-cache/generated/sensitive paths unless explicitly requested.

## Project-Specific Rules To Fill In

- Protected files and directories:
- Generated files that must not be edited manually:
- Security, privacy, compliance, or credential rules:
- Architecture boundaries:
- Test strategy:
- Release or deployment constraints:
- Project-specific tech-stack overrides and commands:

## Tech-Stack Customization Rule

At the start of substantive work, agents should run:

\`\`\`bash
scripts/agent-guard.sh preflight
scripts/detect-agent-tech-stack.sh --markdown
\`\`\`

When agentmemory MCP tools are available, agents should also recall relevant
project context. If agentmemory is unavailable, agents should combine this file,
the detector output, and nearby build/config files, then state uncertainty
instead of guessing.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/agent-handoff-schema.md" <<'EOF'
# Agent Handoff Schema

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Canonical packet and artifact format. Role, transition, and gate policy lives only in
`docs/agent-configs/agent-mode-contracts.md`.

## Local packet and active-task selection

Packets live at `.agents/tasks/<task-id>/`. They are ignored, ephemeral state
and may be lost. Git does not enforce their rules: artifact ownership and append-only behavior are conventions, not access controls.

`.agents/tasks/ACTIVE` is a cache; each task's `state.json` is authoritative.
On resume, scan states and select exactly one open task when only one exists.
Repair or ignore a stale `ACTIVE` cache. Multiple open tasks require the user to choose.
Never select the newest task automatically. Report malformed state; do not infer it.

## Maximum artifact set

1. `state.json`
2. `task.md`
3. `codex-review.md`
4. `implementation.md`
5. `claude-review.md`
6. `user-decision.md`

Only `state.json` and `task.md` are created initially. Create the rest on demand.

## State contract

Concrete initial example:

```json
{
  "protocol_version": "claude-codex-collaboration/v1",
  "task_id": "checkout-timeout-fix",
  "status": "open",
  "phase": "analysis",
  "owner": "claude",
  "requested_action": "prepare the specification for Sol technical review",
  "base_commit": null,
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

Allowed values are exact:

- `status`: `open | awaiting_user | closed`
- `phase`: `analysis | technical_review | implementation | verification | cross_review | resolution | closed`
- `owner`: `claude | codex | user`
- `spec_sufficiency.verdict`: `not_reviewed | sufficient | partially_sufficient | insufficient`
- `spec_sufficiency.sufficient_for_coding_model`: `not_reviewed | yes | no`
- `verification.runner`: `none | claude | codex`
- `verification.status`: `not_run | pass | fail | blocked`

`requested_action` names one next action. `base_commit` is captured on the first entry into implementation and anchors full-diff review. `revision_rounds` starts
at zero and increments on return to implementation. Verification records runner,
result, reason, and real report path.

## Artifact contracts

### `task.md`

`task.md` starts with:

```markdown
## Request (verbatim)

> <original request with secrets redacted>
```

Record objective, acceptance criteria, scope/non-goals, evidence, constraints,
interfaces, edge cases, migration/security/privacy impact, verification,
assumptions, and implementation boundaries. When Sol returns `task.md` to analysis, append `## Specification revision <n>` and preserve `## Request (verbatim)` and prior history.

### `codex-review.md`

`codex-review.md` has exactly two top-level sections with numbered attempts:

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
If work later returns to specification review, insert the next numbered pre-coding `### Attempt <n>` immediately before the Final heading without modifying prior attempts.
State sufficiency matches the latest pre-coding attempt.
`fresh_session_attestation` is procedural-only and is not proof of session, model, account, or host independence.

### `implementation.md`

Append `## Implementation attempt <n>` with model/source, route, scope, files,
verification, deviations, risks, blockers, and any adequacy downgrade. Sol coding records
`policy_exception=sol_coding`, `authorization=user_session`, and the reason.
Those fields are an audit-only procedural declaration and cannot provide file-based authorization; the user must open a new Sol coding session.

### `claude-review.md`

Append one findings-first `## Cross-review attempt <n>` checking
state/review consistency, the `base_commit` diff, verification, and approved
scope. It requires these procedural declarations to be present: `fresh_session_attestation`, actual author model, actual reviewer model, and model source for each. It also checks whether author/reviewer model and session declarations contradict.

### `user-decision.md`

When required, append the dated action, scope, authorization, and alternatives.

Prior attempts remain immutable by convention. Repeated work appends the next numbered attempt.

Keep secrets, local-only permission state, and large generated logs out of the
packet when a path and concise summary are sufficient.
EOF

  write_overlay_file "$TARGET_DIR/docs/agent-configs/agent-mode-contracts.md" <<'EOF'
# Agent Mode Contracts

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Canonical roles, transitions, and gates. Host files and launchers point here;
packet formats live in `docs/agent-configs/agent-handoff-schema.md`.

Common rules:
- Refresh stack context with `scripts/detect-agent-tech-stack.sh --markdown`
  when available, and respect `scripts/agent-hook.sh no-scan-paths`.
- Keep collaboration packets under `.agents/tasks/<task-id>/` and use
  `docs/agent-configs/agent-handoff-schema.md` for their state and artifacts.
- One phase owner writes at a time. Packet ownership is a coordination
  convention, not an authorization or security boundary.
- Project-local full-flow does not authorize external paths, installs, commits,
  pushes, force operations, or local-only secret/permission changes without
  exact user approval.

## Claude–Codex Collaboration Protocol

### Constrained transitions

- `analysis` · Claude -> `technical_review`
- `technical_review` · Codex Sol -> `analysis` | `implementation` | `resolution`
- `implementation` · Codex Luna -> `verification` | `resolution`
- `verification` · Codex Sol -> `implementation` | `cross_review` | `resolution`
- `cross_review` · Claude -> `implementation` | `resolution`
- `resolution` · User -> `closed` | user-selected prior phase

`awaiting_user` is valid only with `resolution` · User. `closed` is valid only with phase `closed`.
All other active combinations use `open` and the owner
shown above. Claude implementation requires an explicit user decision recorded
in the task packet.

### Gates and authority

- Sol owns the blocking adequacy verdict for requirements, interfaces, edge
  cases, tests, migrations, security/privacy, and implementation boundaries.
- Luna may downgrade `yes` when implementation evidence exposes a specification
  gap, but may never upgrade `no`; a missing or inconsistent Sol verdict blocks
  implementation.
- The protocol allows the initial implementation plus at most two remediation rounds.
  A further failure moves to `awaiting_user` resolution.
- Verification records the runner, status, reason, and real report; unavailable
  or skipped execution must not be reported as a pass.
- Claude performs one findings-first cross-review pass covering state/review consistency,
  `base_commit`, verification, any Sol-coding decision and reason, and the
  approved scope. Claude requires these procedural declarations to be present: `fresh_session_attestation`, actual author model, actual reviewer model, and model source for each.
  Claude also checks author and reviewer model declarations and author and reviewer session declarations for contradictions.
- Sol coding is an escalation: the user must open a new Sol coding session.
  `policy_exception=sol_coding` plus `authorization=user_session` is an
  audit-only procedural declaration and cannot provide file-based authorization.
- The user is the final authority for closure, bounded revision, a return to a
  prior phase, Claude implementation, or a Sol-coding policy exception.

## Planning Mode

Analyze the request, evidence, constraints, risks, and verification. Preserve
packet history. Use council only on demand for high-risk or disputed work.

## Coding Mode

Luna implements only after the latest Sol verdict permits coding. Prefer focused
root-cause patches, tests, and fresh verification; otherwise move to resolution.

## Reviewing Mode

Ordinary review is one findings-first, evidence-backed pass. Sol owns technical
review; Claude owns cross-review. Remediation requires exact requested scope;
council is on demand for high-risk or disputed work.
The `Severity trigger` finding obligation is defined by the reviewing launcher.

## Project-Specific Mode Overrides

<!-- BEGIN USER: mode-contracts:overrides -->
<!-- Add project-specific mode rules/overrides here; preserved across harness upgrades. -->
<!-- END USER: mode-contracts:overrides -->
EOF

  write_file "$TARGET_DIR/docs/agent-configs/karpathy-llm-coding-agent-config.md" <<'EOF'
# LLM Coding Workflow

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Treat natural language as a control plane, not as a substitute for engineering
understanding. Before changing code, read relevant files, nearby tests, project
rules, and current diffs. Preserve user work.

Production work requires:
- context gathering before edits,
- small coherent patches,
- explicit assumptions and risks,
- no unrelated refactors,
- tests or a justified verification substitute,
- final diff review before success claims.

Do not prompt-code random fixes until a symptom disappears. Identify the root
cause, verify behavior, or state what remains unknown.

## Procedure

1. Gather context first: read the relevant files, nearby tests, project rules,
   and current diffs. State what you read.
2. State explicit assumptions and risks before editing.
3. Make one small coherent patch; no unrelated refactors.
4. Verify with tests or a justified substitute; review the final diff.
5. Hand off with `docs/agent-configs/agent-handoff-schema.md` when ownership
   changes. No success claim without evidence.

For a durable task-specific decision, an optional journal may be kept using
`docs/agent-configs/task-journal.md`.

## Stop conditions

- Stop if you cannot identify the root cause; do not prompt-code until a symptom
  disappears. Record the unknown in the handoff.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/llm-council-agent-workflow.md" <<'EOF'
# Hybrid Council Workflow

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Council is advisory; one executor owns any patch.

Use council on demand for user-requested, high-risk, or disputed work involving
architecture, migration, data loss, security/privacy, billing, release,
performance, concurrency, or unclear root cause.

Planner/BA checks scope; Dev Lead checks architecture; QC checks regressions;
Tester names evidence; Chair synthesizes.

The coordinator chairs. Override only with evidence, user instruction, or a
safer stop; preserve high-impact minority objections.

Ordinary review remains one findings-first pass under
`docs/agent-configs/agent-mode-contracts.md`; council is not a mandatory review
stage.

For non-trivial decisions, optionally apply the `doubt-driven` skill
(`.agents/skills/doubt-driven/SKILL.md`) before the verdict.

## Procedure

1. State the question and why council is warranted.
2. Each role gives a position with evidence (file:line) and a confidence.
3. Cross-review the strongest assumptions and missing evidence.
4. Chair synthesizes: selected approach, rejected alternatives, preserved
   minority objections, executor, verification commands, stop-conditions.
5. Return the verdict to the single executor using
   `docs/agent-configs/agent-handoff-schema.md` when ownership changes.

## Stop conditions

- Stop and ask the user when the council cannot reach a verifiable position from
  repo evidence.
- Escalate credible P0/P1 security, privacy, data-loss, billing, release, or
  compliance risk even when the majority disagrees.
EOF

}

write_task_journal_doc() {
  write_file "$TARGET_DIR/docs/agent-configs/task-journal.md" <<'EOF'
# Task Journal (Optional working memory)

Task journals are optional, git-tracked durable-decision notes. They do not
select the active collaboration task; `.agents/tasks/*/state.json` is the
authoritative local workflow state described in
`docs/agent-configs/agent-handoff-schema.md`.

When a task-specific decision should survive packet loss or context compaction,
create `docs/superpowers/plans/<topic>/journal.md` and append a concise dated
entry. Bootstrap never creates per-task journals.

## Optional fields

- `memory`: a saved durable-memory id, `none`, or `n/a` when no backend exists.
- `save_decision`: `saved`, `journal-only`, `rejected`, or `n/a`.
- `evidence`: a supporting file, test, command, or user-decision summary.
- `recall_verified`: `yes`, `n/a`, or `acked-deferred` when recall was relevant.
- `verification`: the real verification report path, such as
  `.agents/state/last-verify-report.json`, or `n/a` with a short reason.

If used, append new entries rather than rewriting prior decisions. Keep secrets,
credentials, local permission state, and large generated logs out of the file.
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

In Claude Code, the shared hook guards Edit/Write/MultiEdit paths before
protected file edits and delegates shell git handling to the pinned rtk wrapper.
It is not a security boundary for arbitrary Bash commands.
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

Default Claude behavior is handoff, not direct implementation. Execute only
after an explicit user decision and a blocking Sol adequacy verdict permit
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
argument-hint: [planning|coding|reviewing] <stalled task or rescue target>
---

# Codex Rescue Handoff

Default to handoff, not direct implementation. Read
`docs/agent-configs/agent-mode-contracts.md`,
`docs/agent-configs/agent-handoff-schema.md`, and
`docs/agent-configs/project-agent-context.md`, then use the selected packet under
`.agents/tasks/<task-id>/`. Run
`scripts/detect-agent-tech-stack.sh --markdown` when available and
`scripts/agent-hook.sh no-scan-paths` before broad search.

Return one launch command and one schema-compliant handoff:

```bash
.codex/codex-mode.sh <planning|coding|reviewing> "<handoff prompt>"
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

Model defaults live in `docs/agent-configs/model-profiles.json`; set
`CODEX_MODEL_PROFILE=<profile>` to test a different profile without editing
generated scripts. All modes default to project-local full-flow execution. Use
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

Fallback defaults come from `docs/agent-configs/model-profiles.json`. Override
per launch when capacity or rollout needs a one-shot change:

```bash
CODEX_MODEL_OVERRIDE=gpt-5.4 .codex/codex-mode.sh planning
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
MODEL_PROFILES="$PROJECT_ROOT/docs/agent-configs/model-profiles.json"

DEFAULT_MODE="planning"
DEFAULT_FLOW="full_flow"
STANDARD_APPROVAL="on-request"
FULL_FLOW_APPROVAL="never"
REASONING_EFFORT=""
MODEL_PROFILE=""
MODEL_PROFILE_ERROR=""

PLANNING_MODEL=""
CODING_MODEL=""
REVIEWING_MODEL=""
PLANNING_FALLBACK_MODEL=""
CODING_FALLBACK_MODEL=""
REVIEWING_FALLBACK_MODEL=""

if [[ -n "${HOME:-}" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

usage() {
  printf '%s\n' \
    "Usage:" \
    "  .codex/codex-mode.sh planning [prompt]" \
    "  .codex/codex-mode.sh planning --supervised [prompt]" \
    "  .codex/codex-mode.sh coding [prompt]" \
    "  .codex/codex-mode.sh coding --supervised [prompt]" \
    "  .codex/codex-mode.sh reviewing [prompt]" \
    "  .codex/codex-mode.sh reviewing --supervised [prompt]" \
    "  .codex/codex-mode.sh run [prompt]" \
    "  .codex/codex-mode.sh status" \
    "  .codex/codex-mode.sh doctor" \
    "" \
    "Capacity handling:" \
    "- CODEX_USE_FALLBACK=1 uses the configured fallback model for the selected mode." \
    "- CODEX_MODEL_OVERRIDE=<model> selects an explicit model for one launch." \
    "- CODEX_REASONING_EFFORT=<effort> overrides xhigh only when capacity requires it."
}

is_valid_mode() {
  [[ "$1" == "planning" || "$1" == "coding" || "$1" == "reviewing" ]]
}

is_valid_flow() {
  [[ "$1" == "standard" || "$1" == "full_flow" ]]
}

read_mode() {
  if [[ -f "$MODE_FILE" ]]; then
    local mode
    mode="$(sed -n 's/^mode=//p' "$MODE_FILE" | tail -n1)"
    if is_valid_mode "$mode"; then
      printf '%s' "$mode"
      return 0
    fi
  fi
  printf '%s' "$DEFAULT_MODE"
}

read_flow() {
  if [[ -f "$MODE_FILE" ]]; then
    local flow
    flow="$(sed -n 's/^flow=//p' "$MODE_FILE" | tail -n1)"
    if is_valid_flow "$flow"; then
      printf '%s' "$flow"
      return 0
    fi
  fi
  printf '%s' "$DEFAULT_FLOW"
}

write_mode() {
  local mode="$1"
  local flow="$2"
  cat > "$MODE_FILE" <<LOCK
mode=$mode
flow=$flow
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCK
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fallback_requested() {
  truthy "${CODEX_USE_FALLBACK:-}"
}

load_model_profile() {
  local requested_profile="${CODEX_MODEL_PROFILE:-}"
  local parsed=""
  local effective_effort=""
  local -a fields=()

  MODEL_PROFILE_ERROR=""
  if ! command -v python3 >/dev/null 2>&1; then
    MODEL_PROFILE_ERROR="model profile error: python3 is required to load $MODEL_PROFILES"
    return 1
  fi

  if ! parsed="$(python3 - "$MODEL_PROFILES" "$requested_profile" 2>&1 <<'PY_MODEL_PROFILE'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
requested = sys.argv[2]
required_keys = (
    "reasoning_effort",
    "planning_model",
    "coding_model",
    "reviewing_model",
    "planning_fallback_model",
    "coding_fallback_model",
    "reviewing_fallback_model",
)
allowed_efforts = {"none", "low", "medium", "high", "xhigh", "max"}
model_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")

try:
    document = json.loads(path.read_text(encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(f"model profile error: file not found: {path}")
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"model profile error: cannot read {path}: {exc}")
except json.JSONDecodeError as exc:
    raise SystemExit(
        f"model profile error: malformed JSON in {path}: line {exc.lineno} column {exc.colno}"
    )

if not isinstance(document, dict):
    raise SystemExit("model profile error: top-level JSON value must be an object")
if document.get("schema") != "agent-model-profiles/v1":
    raise SystemExit("model profile error: schema must be agent-model-profiles/v1")

profile_name = requested or document.get("default_profile")
if not isinstance(profile_name, str) or not profile_name:
    raise SystemExit("model profile error: default_profile must be a non-empty string")
profiles = document.get("profiles")
if not isinstance(profiles, dict):
    raise SystemExit("model profile error: profiles must be an object")
profile = profiles.get(profile_name)
if not isinstance(profile, dict):
    raise SystemExit(f"model profile error: selected profile '{profile_name}' is missing")

for key in required_keys:
    if key not in profile:
        raise SystemExit(
            f"model profile error: profile '{profile_name}' is missing required field '{key}'"
        )
    if not isinstance(profile[key], str):
        raise SystemExit(
            f"model profile error: profile '{profile_name}' field '{key}' must be a string"
        )

effort = profile["reasoning_effort"]
if effort not in allowed_efforts:
    raise SystemExit(f"model profile error: unsupported reasoning_effort '{effort}'")
for key in required_keys[1:]:
    if not model_pattern.fullmatch(profile[key]):
        raise SystemExit(f"model profile error: invalid model id for '{key}'")

print("\t".join([profile_name] + [profile[key] for key in required_keys]))
PY_MODEL_PROFILE
  )"; then
    MODEL_PROFILE_ERROR="$parsed"
    return 1
  fi

  IFS=$'\t' read -r -a fields <<< "$parsed"
  if [[ "${#fields[@]}" -ne 8 ]]; then
    MODEL_PROFILE_ERROR="model profile error: parser returned ${#fields[@]} fields; expected 8"
    return 1
  fi

  effective_effort="${fields[1]}"
  if [[ -n "${CODEX_REASONING_EFFORT:-}" ]]; then
    case "$CODEX_REASONING_EFFORT" in
      none|low|medium|high|xhigh|max) effective_effort="$CODEX_REASONING_EFFORT" ;;
      *)
        MODEL_PROFILE_ERROR="model profile error: unsupported CODEX_REASONING_EFFORT '$CODEX_REASONING_EFFORT'"
        return 1
        ;;
    esac
  fi

  MODEL_PROFILE="${fields[0]}"
  REASONING_EFFORT="$effective_effort"
  PLANNING_MODEL="${fields[2]}"
  CODING_MODEL="${fields[3]}"
  REVIEWING_MODEL="${fields[4]}"
  PLANNING_FALLBACK_MODEL="${fields[5]}"
  CODING_FALLBACK_MODEL="${fields[6]}"
  REVIEWING_FALLBACK_MODEL="${fields[7]}"
}

model_for_mode() {
  case "$1" in
    planning) printf '%s' "$PLANNING_MODEL" ;;
    coding) printf '%s' "$CODING_MODEL" ;;
    reviewing) printf '%s' "$REVIEWING_MODEL" ;;
    *) return 1 ;;
  esac
}

fallback_model_for_mode() {
  case "$1" in
    planning) printf '%s' "$PLANNING_FALLBACK_MODEL" ;;
    coding) printf '%s' "$CODING_FALLBACK_MODEL" ;;
    reviewing) printf '%s' "$REVIEWING_FALLBACK_MODEL" ;;
    *) return 1 ;;
  esac
}

DOCTOR_FAIL=0
DOCTOR_WARN=0

doctor_ok() {
  printf '  ok    %s\n' "$1"
}

doctor_bad() {
  printf '  FAIL  %s\n' "$1"
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
}

doctor_warn() {
  printf '  warn  %s\n' "$1"
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
  local path="$1"
  local words="0"
  local chars="0"
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
  local total=0
  local token_count=0
  local relpath
  for relpath in "$@"; do
    token_count="$(estimate_tokens_for_file "$PROJECT_ROOT/$relpath")"
    total=$((total + token_count))
  done
  printf '%s' "$total"
}

doctor_context_budget() {
  local core_tokens
  local full_tokens
  core_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md)"
  full_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md \
    docs/agent-configs/task-journal.md)"

  if [[ "$core_tokens" -gt 4000 ]]; then
    doctor_warn "core startup context estimate: ${core_tokens} tokens exceeds gate 4000; the 4000 gate is enforced by the harness test suite"
  elif [[ "$core_tokens" -gt 3800 ]]; then
    doctor_warn "core startup context estimate: ${core_tokens} tokens (gate 4000, amber above 3800); measure after any edit to a counted file"
  else
    doctor_ok "core startup context estimate: ${core_tokens} tokens (gate 4000, amber above 3800)"
  fi

  if [[ "$full_tokens" -gt 6200 ]]; then
    doctor_warn "on-demand full workflow context estimate: ${full_tokens} tokens exceeds gate 6200; the 6200 gate is enforced by the harness test suite"
  elif [[ "$full_tokens" -gt 5900 ]]; then
    doctor_warn "on-demand full workflow context estimate: ${full_tokens} tokens (gate 6200, amber above 5900); measure after any edit to a counted file"
  else
    doctor_ok "on-demand full workflow context estimate: ${full_tokens} tokens (gate 6200, amber above 5900)"
  fi
}

run_doctor() {
  DOCTOR_FAIL=0
  DOCTOR_WARN=0
  local no_scan_paths=""
  local doctor_mode=""
  local doctor_model=""
  local doctor_model_source=""
  local doctor_resolved_model=""
  local old_ifs=""
  echo "Codex helper doctor..."

  if load_model_profile; then
    doctor_mode="$(read_mode)"
    doctor_resolved_model="$(resolve_model_for_mode "$doctor_mode")"
    old_ifs="$IFS"
    IFS=$'\t'
    read -r doctor_model doctor_model_source <<< "$doctor_resolved_model"
    IFS="$old_ifs"
    doctor_ok "model profile $MODEL_PROFILE: route=$doctor_mode model=$doctor_model source=$doctor_model_source effort=$REASONING_EFFORT"
  else
    doctor_bad "$MODEL_PROFILE_ERROR"
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

  doctor_exec scripts/install-rtk.sh
  doctor_exec scripts/rtk
  doctor_exec scripts/agent-hook.sh
  doctor_exec scripts/agent-guard.sh
  doctor_exec scripts/agent-tech-stack-lib.sh
  doctor_exec scripts/detect-agent-tech-stack.sh
  doctor_exec scripts/verify-ai-deps.sh

  doctor_bash scripts/install-rtk.sh
  doctor_bash scripts/rtk
  doctor_bash .codex/codex-mode.sh
  doctor_bash scripts/agent-hook.sh
  doctor_bash scripts/agent-guard.sh
  doctor_bash scripts/agent-tech-stack-lib.sh
  doctor_bash scripts/detect-agent-tech-stack.sh
  doctor_bash scripts/verify-ai-deps.sh

  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "$PROJECT_ROOT/.claude/settings.json" >/dev/null 2>&1; then
      doctor_ok "Claude settings JSON is valid"
    else
      doctor_bad "Claude settings JSON is invalid"
    fi
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

	  if "$PROJECT_ROOT/scripts/rtk" --version 2>/dev/null | grep -Fq '0.37.2'; then
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

  if [[ -x "$AGENT_HOOK" ]] && "$AGENT_HOOK" codex-preflight --check-only "$(read_mode)" "$(read_flow)" >/dev/null 2>&1; then
    doctor_ok "shared agent hook codex preflight passes"
  else
    doctor_bad "shared agent hook codex preflight failed"
  fi

  if [[ "$DOCTOR_FAIL" -gt 0 ]]; then
    echo "Doctor failed: $DOCTOR_FAIL issue(s)." >&2
    exit 1
  fi

  if [[ "$DOCTOR_WARN" -gt 0 ]]; then
    echo "Doctor passed with $DOCTOR_WARN warning(s)."
  else
    echo "Doctor passed."
  fi
}

resolve_model_for_mode() {
  local mode="$1"
  local default_model=""
  local fallback_model=""
  local mode_override=""
  local mode_override_source=""

  default_model="$(model_for_mode "$mode")"
  fallback_model="$(fallback_model_for_mode "$mode")"

  case "$mode" in
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
  esac

  if [[ -n "${CODEX_MODEL_OVERRIDE:-}" ]]; then
    printf '%s\t%s\n' "$CODEX_MODEL_OVERRIDE" "CODEX_MODEL_OVERRIDE"
  elif [[ -n "$mode_override" ]]; then
    printf '%s\t%s\n' "$mode_override" "$mode_override_source"
  elif fallback_requested; then
    printf '%s\t%s\n' "$fallback_model" "CODEX_USE_FALLBACK"
  else
    printf '%s\t%s\n' "$default_model" "default"
  fi
}

sol_coding_audit_record() {
  printf 'policy_exception=%s authorization=%s' "sol_coding" "user_session"
}

print_launch_summary() {
  local mode="$1"
  local flow="$2"
  local model="$3"
  local model_source="$4"
  local sandbox="$5"
  local approval="$6"
  local fallback_model=""
  local flow_arg=""

  fallback_model="$(fallback_model_for_mode "$mode")"
  if [[ "$flow" == "standard" ]]; then
    flow_arg=" --supervised"
  fi

  {
    echo "Codex launch: mode=$mode flow=$flow model=$model reasoning=$REASONING_EFFORT sandbox=$sandbox approval=$approval"
    echo "Model source: $model_source"
    if [[ "$mode" == "coding" && "$model" == "gpt-5.6-sol" ]]; then
      sol_coding_audit_record
      echo
    fi
    if [[ "$model_source" == "default" ]]; then
      echo "If Codex reports model capacity, rerun: CODEX_USE_FALLBACK=1 .codex/codex-mode.sh $mode$flow_arg"
      echo "Fallback model for $mode: $fallback_model. Explicit override: CODEX_MODEL_OVERRIDE=<model> .codex/codex-mode.sh $mode$flow_arg"
    fi
  } >&2
}

resolve_codex_bin() {
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  local candidate
  for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.local/bin/codex" "$HOME/.npm-global/bin/codex" "$HOME/.bun/bin/codex"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "ERROR: Codex CLI not found. Install it or add it to PATH." >&2
  exit 127
}

mode_prompt() {
  local mode="$1"
  local flow="$2"
  local model="$3"
  local model_source="$4"
  local provenance="actual_model=$model model_source=$model_source."
  local sol_coding_audit=""
  if [[ "$mode" == "coding" && "$model" == "gpt-5.6-sol" ]]; then
    sol_coding_audit=" $(sol_coding_audit_record). Record the existing task's escalation_reason in implementation.md."
  fi
  case "$mode:$flow" in
    planning:standard)
      printf '%s' "MODE LOCK: PLANNING-SUPERVISED. $provenance Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. This flow is read-only: respect scripts/agent-hook.sh no-scan-paths and do not mutate files unless the user grants that exact action."
      ;;
    planning:full_flow)
      printf '%s' "MODE LOCK: PLANNING-FULL-FLOW. $provenance Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. The request grants bounded project-local execution only; respect scripts/agent-hook.sh no-scan-paths and require exact approval for external paths, installs, commits, pushes, force operations, or local-only permission changes."
      ;;
    coding:standard)
      printf '%s' "MODE LOCK: CODING-SUPERVISED. $provenance$sol_coding_audit Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. This flow is read-only: respect scripts/agent-hook.sh no-scan-paths and do not mutate files unless the user grants that exact action."
      ;;
    coding:full_flow)
      printf '%s' "MODE LOCK: CODING-FULL-FLOW. $provenance$sol_coding_audit Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. The request grants bounded project-local implementation, tests, and verification only; respect pre-edit/no-scan guards and require exact approval for external paths, installs, commits, pushes, force operations, or local-only permission changes."
      ;;
    reviewing:standard)
      printf '%s' "MODE LOCK: REVIEWING-SUPERVISED. $provenance Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. Severity must name its trigger condition and frequency, or mark itself as an estimate. This flow is findings-first and read-only: respect scripts/agent-hook.sh no-scan-paths and do not remediate unless the user grants an exact patch scope."
      ;;
    reviewing:full_flow)
      printf '%s' "MODE LOCK: REVIEWING-FULL-FLOW. $provenance Use the selected packet under .agents/tasks/<task-id>/. Apply docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. Severity must name its trigger condition and frequency, or mark itself as an estimate. The request grants project-local review and verification only; respect scripts/agent-hook.sh no-scan-paths and do not remediate unless fixes or an exact patch scope were requested. External paths and mutating git operations require exact approval."
      ;;
  esac
}

run_codex_with_mode() {
  local mode="$1"
  local flow="$2"
  local persist="${3:-false}"
  shift 3 || true

  local model model_source sandbox approval seed codex_bin
  case "$mode" in
    planning|coding|reviewing) ;;
    *) echo "ERROR: invalid mode: $mode" >&2; exit 2 ;;
  esac

  local resolved_model old_ifs
  resolved_model="$(resolve_model_for_mode "$mode")"
  old_ifs="$IFS"
  IFS=$'\t'
  read -r model model_source <<< "$resolved_model"
  IFS="$old_ifs"

  if [[ "$flow" == "full_flow" ]]; then
    sandbox="workspace-write"
    approval="$FULL_FLOW_APPROVAL"
  else
    sandbox="read-only"
    approval="$STANDARD_APPROVAL"
  fi

  seed="$(mode_prompt "$mode" "$flow" "$model" "$model_source")"
  codex_bin="$(resolve_codex_bin)"
  [[ "$persist" == "true" ]] && write_mode "$mode" "$flow"
  if [[ -x "$AGENT_HOOK" ]]; then
    "$AGENT_HOOK" codex-preflight "$mode" "$flow"
  fi
  print_launch_summary "$mode" "$flow" "$model" "$model_source" "$sandbox" "$approval"

  local prompt=""
  if [[ $# -gt 0 ]]; then
    prompt="$*"
    export CODEX_HARNESS_SESSION=1
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$model" -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"$'\n\n'"USER PROMPT:"$'\n'"$prompt"
  else
    export CODEX_HARNESS_SESSION=1
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$model" -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"
  fi
}

reject_nested_launch() {
  if [[ "${CODEX_HARNESS_SESSION:-}" == "1" ]]; then
    echo "ERROR: accidental nested Codex launch blocked; exit the current harness session before starting another." >&2
    return 1
  fi
}

require_model_profile() {
  if load_model_profile; then
    return 0
  fi
  echo "ERROR: $MODEL_PROFILE_ERROR" >&2
  return 1
}

cmd="${1:-status}"
case "$cmd" in
  -h|--help|help)
    usage
    ;;
  planning|coding|reviewing)
    reject_nested_launch || exit 1
    require_model_profile || exit 1
    shift || true
    flow="$DEFAULT_FLOW"
    if [[ "${1:-}" == "-full_flow" || "${1:-}" == "--full-flow" || "${1:-}" == "--full_flow" ]]; then
      flow="full_flow"
      shift || true
    elif [[ "${1:-}" == "-standard" || "${1:-}" == "--standard" || "${1:-}" == "--supervised" || "${1:-}" == "--read-only" || "${1:-}" == "--propose" || "${1:-}" == "--approval-gate" ]]; then
      flow="standard"
      shift || true
    fi
    run_codex_with_mode "$cmd" "$flow" true "$@"
    ;;
  run)
    reject_nested_launch || exit 1
    require_model_profile || exit 1
    shift || true
    flow="$(read_flow)"
    if [[ "${1:-}" == "-full_flow" || "${1:-}" == "--full-flow" || "${1:-}" == "--full_flow" ]]; then
      flow="full_flow"
      shift || true
    elif [[ "${1:-}" == "-standard" || "${1:-}" == "--standard" || "${1:-}" == "--supervised" || "${1:-}" == "--read-only" || "${1:-}" == "--propose" || "${1:-}" == "--approval-gate" ]]; then
      flow="standard"
      shift || true
    fi
    run_codex_with_mode "$(read_mode)" "$flow" false "$@"
    ;;
  doctor)
    run_doctor
    ;;
  status)
    require_model_profile || exit 1
    current_mode="$(read_mode)"
    current_flow="$(read_flow)"
    resolved_model="$(resolve_model_for_mode "$current_mode")"
    old_ifs="$IFS"
    IFS=$'\t'
    read -r current_model current_model_source <<< "$resolved_model"
    IFS="$old_ifs"
    echo "Current mode: $current_mode"
    echo "Current flow: $current_flow"
    echo "Model profile: $MODEL_PROFILE"
    echo "Reasoning effort: $REASONING_EFFORT"
    echo "Default model: $(model_for_mode "$current_mode")"
    echo "Effective model: $current_model ($current_model_source)"
    echo "Fallback model: $(fallback_model_for_mode "$current_mode")"
    echo "Capacity fallback: CODEX_USE_FALLBACK=1 .codex/codex-mode.sh $current_mode$([[ "$current_flow" == "standard" ]] && printf ' --supervised')"
    echo "Explicit override: CODEX_MODEL_OVERRIDE=<model> .codex/codex-mode.sh $current_mode$([[ "$current_flow" == "standard" ]] && printf ' --supervised')"
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
