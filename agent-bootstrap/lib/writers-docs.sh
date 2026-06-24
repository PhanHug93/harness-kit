#!/usr/bin/env bash
# agent-bootstrap/lib/writers-docs.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits agent docs, tool entrypoints, and Codex files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

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
- handoff: prefer the task journal for resumable state; save Layer-2 handoffs
  only when cross-session recovery needs global recall, and include the journal
  path/id.

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
  stack_bullets="$(format_bullets "${TECH_STACKS[@]}")"
  module_bullets="$(format_bullets "${MODULES[@]}")"
  verify_bullets="$(format_bullets "${VERIFY_COMMANDS[@]}")"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    warning_bullets="$(format_bullets "${WARNINGS[@]}")"
  else
    warning_bullets="- None"
  fi
  stack_overlay_content="$(render_stack_overlays)"

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

If the detector output changes intentionally, refresh the lock:

\`\`\`bash
bash scripts/bootstrap-multi-agent-project.sh --refresh-lock
\`\`\`

## Agentmemory Usage

Agentmemory is the long-term memory layer for project context when the global
MCP tools are available. The bootstrap installs
\`.agents/skills/agentmemory-mcp/SKILL.md\` automatically; agents should use
that skill for recall/save rules.

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

Generated by \`bootstrap-multi-agent-project.sh\` on $STAMP.
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
  stack_bullets="$(format_bullets "${TECH_STACKS[@]}")"
  module_bullets="$(format_bullets "${MODULES[@]}")"
  verify_bullets="$(format_bullets "${VERIFY_COMMANDS[@]}")"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    warning_bullets="$(format_bullets "${WARNINGS[@]}")"
  else
    warning_bullets="- None"
  fi
  stack_overlay_content="$(render_stack_overlays)"

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
- If resuming a task, read its journal first: the newest in-progress \`docs/superpowers/plans/*/journal.md\` (see \`docs/agent-configs/task-journal.md\`).

Read on demand:

- \`docs/agent-configs/agent-mode-contracts.md\` when selecting/switching modes.
- \`docs/agent-configs/agent-handoff-schema.md\` when ownership changes.
- \`docs/agent-configs/karpathy-llm-coding-agent-config.md\` before substantial
  edits or production-risk refactors.
- \`docs/agent-configs/llm-council-agent-workflow.md\` for councils or high-risk
  architecture/security/release tradeoffs.
- \`docs/agent-configs/task-journal.md\` when recording/resuming task memory.
- Skills under \`.agents/skills/\` only when their descriptions match the
  current task.

Keep the always-on/core startup context under roughly 4k estimated tokens.
\`scripts/verify-ai-deps.sh\` and \`.codex/codex-mode.sh doctor\` report the
current estimate. This core estimate excludes tool-specific wrappers such as
\`CLAUDE.md\` and \`GEMINI.md\`.

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
the skip reason in the task journal and rerun with \`--advisory\` only when the
user or CI environment explicitly requires advisory mode.

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

## Agent Ownership Matrix

| Work phase | Primary owner | Secondary / fallback | Contract |
|---|---|---|---|
| Planning | Claude | Codex when explicitly selected or Claude unavailable | Claude owns requirements, architecture, tradeoffs, risk framing, sequencing, and Codex-ready handoff. |
| Coding | Codex | Claude when explicitly selected or Codex unavailable | Codex owns implementation, refactors, tests, verification, and self-review. |
| Reviewing | Codex | Claude for architecture/security/requirements/long-context second opinion | Codex owns ordinary branch/diff findings review. Claude labels fallback or second-opinion reviews. |
| Council | Claude for synthesis | Codex for implementation-risk and mechanical diff checks | Council is advisory. One executor owns any follow-up patch. |

Do not let two agents edit the same files concurrently. If ownership changes,
leave a handoff using \`docs/agent-configs/agent-handoff-schema.md\` before the
next agent proceeds.

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
  Must run the technical spec adequacy gate before implementation.
- \`reviewing\`: findings-first review with three council rounds. Review mode
  may run project-local verification in full-flow. Remediation edits require
  the review request to ask for fixes or an exact patch scope.

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

Generated by \`bootstrap-multi-agent-project.sh\` on $STAMP.
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

Use this schema whenever work moves between Claude and Codex, or between
planning, coding, reviewing, and council phases.

## Required Fields

- `handoff_id`
- `from_agent`
- `to_agent`
- `work_phase`: `planning`, `coding`, `reviewing`, or `council`
- `ownership`: `primary`, `fallback`, or `second-opinion`
- `flow`: `full_flow` or `supervised`
- `task_summary`
- `repo_state`
- `target_files`
- `protected_paths`
- `non_goals`
- `constraints`
- `acceptance_criteria`
- `verification_commands`
- `risks`
- `open_questions`
- `next_action`
- `stop_conditions`

## Template

```markdown
## Agent Handoff

- handoff_id:
- from_agent:
- to_agent:
- work_phase:
- ownership:
- flow:
- task_summary:
- repo_state:
- target_files:
- protected_paths:
- non_goals:
- constraints:
- acceptance_criteria:
- verification_commands:
- risks:
- open_questions:
- next_action:
- stop_conditions:
```

Do not paste secrets, local-only permission state, or large generated logs into
a handoff when a path and summary are sufficient.
EOF

  write_overlay_file "$TARGET_DIR/docs/agent-configs/agent-mode-contracts.md" <<'EOF'
# Agent Mode Contracts

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Shared behavior for Codex, Claude, and other agents. Tool files may choose
model/sandbox mechanics, but must not weaken these contracts.

Common rules:
- Refresh stack context with `scripts/detect-agent-tech-stack.sh --markdown`
  when available, and respect `scripts/agent-hook.sh no-scan-paths`.
- Use `docs/agent-configs/agent-handoff-schema.md` when ownership changes.
- If resuming, read the newest in-progress `docs/superpowers/plans/*/journal.md`.
- At close-out, append to docs/superpowers/plans/<topic>/journal.md using the
  schema in `docs/agent-configs/task-journal.md`. For decided/done durable facts,
  save memory first when a backend is available and put the id on `memory:`.

## Agent Ownership Matrix

| Work phase | Primary owner | Secondary / fallback | Required handoff |
|---|---|---|---|
| Planning | Claude | Codex when explicitly selected/unavailable | Scope, assumptions, components, risks, verification, Codex-ready handoff. |
| Coding | Codex | Claude when explicitly selected/unavailable | Changed files, rationale, tests, verification, remaining risks. |
| Reviewing | Codex | Claude for architecture/security/requirements second opinion | Findings first; label primary, second-opinion, or fallback. |
| Council | Claude for synthesis | Codex for implementation-risk and mechanical diff checks | Advisory output only. One executor owns follow-up patch. |

## Planning Mode

Purpose: feature planning, refactor strategy, architecture tradeoffs, and
performance planning. Claude is primary; Codex is fallback or user-selected.

Rules: load context before deciding; explore unclear requirements; use council
only when requested or high-risk; produce assumptions, risks, verification, stop
conditions, and a Codex-ready handoff when coding follows.

Stop when missing acceptance criteria, users, data ownership, rollback, or
verification would change the plan; when independent subsystems need
decomposition; or before architecture, data, security/privacy, release, or
performance changes without council/user confirmation.

Journal body: assumptions; affected components; risks; verification plan;
stop-conditions hit; handoff target.

## Coding Mode

Purpose: implementation, refactoring, bug fixes, tests, and verification. Codex
is primary; Claude executes only when selected or Codex is unavailable.

Technical Spec Adequacy Gate: before implementation, classify the spec as
`sufficient`, `partially sufficient`, or `insufficient`. Warn on missing
requirements, APIs, edge cases, tests, migration, security/privacy, or acceptance
criteria; continue only when gaps are low risk or accepted.

Rules: prefer root-cause fixes, small coherent patches, useful tests, narrow side
effects, explicit failure paths, and fresh verification before success claims.

Journal body: changed files + rationale; tests added/run; verification result;
remaining risks.

## Reviewing Mode

Purpose: findings-first branch, diff, architecture, requirement, regression, UX,
security, and verification review. Codex is primary; Claude is second-opinion or
fallback for architecture/security/requirements/long-context work.

Default: full-flow may run project-local verification. Supervised/read-only
review needs user-gated write actions. Remediation requires a fix request or
exact patch scope; commits, pushes, installs, force ops, external paths, and
local-only secrets/permission files require exact approval.

Three rounds: (1) BA checks requirements/user impact, Dev Lead checks stack and
architecture, QC checks regressions/UX/tests; (2) cross-review assumptions and
missing evidence; (3) synthesize findings by severity with file:line, impact,
fix guidance, open questions, and verification gaps.

Stop when base/scope/target/acceptance criteria are ambiguous, before supervised
write commands, before unrequested remediation, or for credible P0/P1 security,
privacy, data-loss, billing, release, or compliance risk.

Journal body: findings (severity, file:line); open questions; verification gaps;
verdict.

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
5. Close out: append to docs/superpowers/plans/<topic>/journal.md using
   `docs/agent-configs/task-journal.md` (context gathered, assumptions, risks,
   patch scope, evidence/verification). No success claim without evidence.

## Stop conditions

- Stop if you cannot identify the root cause; do not prompt-code until a symptom
  disappears. Record the unknown under the entry's next-action.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/llm-council-agent-workflow.md" <<'EOF'
# Hybrid Council Workflow

Portable agent config version: see `docs/agent-configs/agent-bootstrap.lock.json`.

Council is for decisions/review, not shared editing. One executor owns any patch.
Council output is advisory until verified.

Use council when the user asks for it or when a high-risk decision needs a
checkpoint: architecture boundaries, migrations, data loss, security/privacy,
permissions, billing, release risk, performance-sensitive paths, concurrency,
or unclear root cause.

Default roles: Planner/BA checks scope and user impact; Dev Lead checks
architecture/stack/SOLID/integration; QC checks edge cases, regressions, UX,
concurrency, and tests; Tester names verification evidence; Chair synthesizes.

Chair is the current primary agent, or the parent/coordinating agent in delegated
councils. Chair may override consensus only with repo evidence, direct user
instruction, or a safer stop condition. Preserve minority objections for
security, privacy, data loss, compliance, billing, release, architecture, or
irreversible user impact.

For review mode, use the explicit three-round process in
`docs/agent-configs/agent-mode-contracts.md`.

For non-trivial decisions, optionally apply the `doubt-driven` skill
(`.agents/skills/doubt-driven/SKILL.md`) as a fresh-context adversarial
checkpoint before the verdict stands.

## Procedure

1. State the council question and why it crosses a high-risk threshold
   (architecture, migration, data loss, security/privacy, permissions, billing,
   release, performance, concurrency, or unclear root cause).
2. Each role gives a position with evidence (file:line) and a confidence.
3. Cross-review the strongest assumptions and missing evidence.
4. Chair synthesizes: selected approach, rejected alternatives, preserved
   minority objections, executor, verification commands, stop-conditions.
5. Close out: append to docs/superpowers/plans/<topic>/journal.md using
   `docs/agent-configs/task-journal.md`, recording step 4. If the decision is
   durable and a backend exists, memory_save first and embed the id on `memory:`.

## Stop conditions

- Stop and ask the user when the council cannot reach a verifiable position from
  repo evidence.
- Escalate any credible P0/P1 security, privacy, data-loss, billing, release, or
  compliance risk even if the majority deems it unlikely; record it as a
  preserved minority objection.
EOF

}

write_task_journal_doc() {
  write_file "$TARGET_DIR/docs/agent-configs/task-journal.md" <<'EOF'
# Task Journal (working memory)

The task journal is Layer 1 working memory: a git-tracked, append-only record for
one in-flight task. Re-read it after compaction. It complements, but does not
replace, Layer 2 memory (agentmemory/native durable knowledge).

## Where

append to docs/superpowers/plans/<topic>/journal.md, one file per task/topic.
Create it on demand when work starts; bootstrap never generates per-task
journals.

## Entry schema (append-only)

Append a new entry per mode step; never edit a prior entry. A status change is a
new appended entry.

    ## <ISO-8601 date> · <mode> · <task-id>
    - status: in-progress | decided | blocked | done
    - context: <1-2 lines: where we are now>
    - <mode-specific body>
    - next-action: <single next concrete step>
    - memory: <saved-id | none | n/a (no backend)>
    - save_decision: saved | journal-only | rejected | n/a
    - evidence: <file/test/command/user decision summary | none>
    - recall_verified: yes | n/a | acked-deferred
    - verification: path to the verification report `.agents/state/last-verify-report.json`, or `n/a` with a short reason when delegated to CI or blocked by the local environment

## Close-out (Layer 1 + Layer 2)

At decided/done close-out: if a durable fact emerged and a memory backend exists,
`memory_save`/`lesson_save` first, capture the id, then append the journal entry
with that id on `memory:` (`none` for no durable fact, `n/a` for no backend).
In-progress checkpoints append immediately with `memory: n/a`.

Use `save_decision: saved` only when a durable memory was written and `memory:`
contains the saved id. Use `journal-only` when the fact matters for this task but
is not durable enough for Layer 2, `rejected` when a candidate failed the storage
rubric, and `n/a` when no backend is available or the task is trivial.

For tasks that changed protected paths, close-out must include
`recall_verified: yes`, `recall_verified: n/a`, or `recall_verified:
acked-deferred`. Plain `deferred:<reason>` is not sufficient for protected-path
changes; either verify the relevant memories, state why recall is not applicable,
or leave an explicit acknowledged exception.

## Resume after compaction

The active journal is the `docs/superpowers/plans/*/journal.md` whose latest
entry is `status: in-progress`, newest by commit/mtime. Read it before
substantive work to recover the plan and next-action. Zero in-progress ⇒ no
active task, start fresh; multiple ⇒ pick newest and confirm against current
context.
EOF
}

write_tool_entrypoints() {
  tool_surface_write "$TARGET_DIR/CLAUDE.md" <<'EOF'
# Claude Instructions

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
- `docs/agent-configs/karpathy-llm-coding-agent-config.md` before substantive
  code edits or production-risk refactors
- `docs/agent-configs/llm-council-agent-workflow.md` only for council or
  high-risk review work
- `docs/agent-configs/task-journal.md` when recording or resuming task
  working-memory

Use `.claude/commands/` as mode entrypoints when the host supports project
commands:

- `/planning` for Claude-primary planning and Codex-ready handoff
- `/coding` for Codex handoff or Claude fallback execution
- `/reviewing` for Codex review handoff, Claude second opinion, or fallback
- `/planning-full-flow`, `/coding-full-flow`, `/reviewing-full-flow` as
  legacy explicit aliases
- `/codex:setup`, `/codex:rescue`, `/codex:status` for Codex readiness and
  schema-compliant handoffs
- `/doctor`

Claude is primary for planning. Codex is primary for coding and ordinary
review. Claude coding/reviewing should be fallback or second-opinion unless
the user explicitly selects Claude as executor/reviewer.

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
	    ]
	  }
}
EOF

  write_file "$TARGET_DIR/.claude/README.md" <<'EOF'
# Claude Agent Workflow

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

`/planning` is Claude-primary and should produce Codex-ready handoff when
implementation or review will follow. `/coding` is Codex-primary handoff or
Claude fallback execution. `/reviewing` is Codex-primary handoff, Claude
second-opinion, or Claude fallback review.

Read `AGENTS.md` first. Durable mode behavior lives in
`docs/agent-configs/agent-mode-contracts.md`; repo-specific stack context lives
in `docs/agent-configs/project-agent-context.md`. Handoffs use
`docs/agent-configs/agent-handoff-schema.md`.

Claude model selection is host-controlled. Keep the same mode contract if the
selected model is unavailable.

The shared Claude hook guards Edit/Write/MultiEdit paths before protected file
edits and delegates shell git handling to the pinned rtk wrapper. It is not a
security boundary for arbitrary Bash commands.
EOF

  write_file "$TARGET_DIR/.claude/commands/planning.md" <<'EOF'
# Planning Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Planning Mode.
Claude is the primary planning owner.

Operate project-local full-flow by default. Add `--supervised`, `--read-only`,
or `--propose` only when the user wants step-by-step approval.
Run `scripts/detect-agent-tech-stack.sh --markdown` when available. Use
requirement exploration and council checkpoints only when appropriate. End with
a concrete plan, assumptions, risks, verification, stop conditions, and a
Codex-ready handoff using `docs/agent-configs/agent-handoff-schema.md` when
follow-up coding/review is expected. Respect
`scripts/agent-hook.sh no-scan-paths` before broad search. Close out: append to docs/superpowers/plans/<topic>/journal.md using `docs/agent-configs/task-journal.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/coding.md" <<'EOF'
# Coding Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Coding Mode.
Codex is the primary coding owner.

Default Claude behavior is Codex handoff, not direct implementation. Execute
with Claude only when Codex is unavailable or the user explicitly selects
Claude. If executing, run the Technical Spec Adequacy Gate, implement scoped
changes, run relevant verification, and inspect the final diff before claiming
success. Handoffs use `docs/agent-configs/agent-handoff-schema.md`; respect
`scripts/agent-hook.sh no-scan-paths` before broad search. Close out: append to docs/superpowers/plans/<topic>/journal.md using `docs/agent-configs/task-journal.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/planning-full-flow.md" <<'EOF'
# Planning Full-Flow Mode

Legacy alias for default `/planning` full-flow. Apply
`docs/agent-configs/agent-mode-contracts.md` Planning Mode with project-local
execution approval for the current user task. Run
`scripts/detect-agent-tech-stack.sh --markdown` when available. Do not mutate
outside the project root, do not edit local-only permission state, and do not
run mutating git commands without exact approval.
EOF

  write_file "$TARGET_DIR/.claude/commands/coding-full-flow.md" <<'EOF'
# Coding Full-Flow Mode

Legacy alias for `/coding`. Codex remains the primary coding owner. Produce a
Codex handoff unless Codex is unavailable or the user explicitly selects Claude
execution. If executing, apply Coding Mode with project-local implementation,
test, verification, and self-review approval for the current user task.
EOF

  write_file "$TARGET_DIR/.claude/commands/reviewing.md" <<'EOF'
# Reviewing Mode

Apply `docs/agent-configs/agent-mode-contracts.md` Reviewing Mode.
Codex is the primary ordinary review owner.

Default Claude behavior is Codex review handoff or Claude second-opinion. Be
primary only when Codex is unavailable, the user explicitly selects Claude, or
the review is mainly architecture/security/requirements/long-context synthesis.
Findings first, ordered by severity. Close out: append to docs/superpowers/plans/<topic>/journal.md using `docs/agent-configs/task-journal.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/council.md" <<'EOF'
---
description: Run the hybrid council methodology and record the verdict in the task journal.
---

# Council

Follow `docs/agent-configs/llm-council-agent-workflow.md`. Council is advisory
until verified; the Chair preserves minority objections and one executor owns any
patch. Close out: append to docs/superpowers/plans/<topic>/journal.md using `docs/agent-configs/task-journal.md`, and conditionally `memory_save` the decision.
EOF

  write_file "$TARGET_DIR/.claude/commands/karpathy.md" <<'EOF'
---
description: Apply the context-first Karpathy coding discipline and record it in the task journal.
---

# Karpathy

Follow `docs/agent-configs/karpathy-llm-coding-agent-config.md`: context first,
small coherent patches, explicit assumptions/risks, evidence before success
claims. Close out: append to docs/superpowers/plans/<topic>/journal.md using `docs/agent-configs/task-journal.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/reviewing-full-flow.md" <<'EOF'
# Reviewing Full-Flow Mode

Legacy alias for `/reviewing`. Codex remains the primary ordinary review
owner. Use Claude for second-opinion/fallback review unless the user explicitly
selects Claude as primary. Do not apply remediation edits unless the request
asks for fixes or an exact patch scope. Findings first.
EOF

  write_file "$TARGET_DIR/.claude/commands/codex/setup.md" <<'EOF'
---
description: Validate Codex readiness and prepare launch instructions.
argument-hint: [--doctor|--status] <optional Codex setup task>
---

# Codex Setup Bridge

Read `AGENTS.md`, `CLAUDE.md`, `docs/agent-configs/agent-mode-contracts.md`,
`docs/agent-configs/agent-handoff-schema.md`, and
`docs/agent-configs/project-agent-context.md`.

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
`docs/agent-configs/project-agent-context.md`. Run
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
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
approval_policy = "never"
sandbox_mode = "workspace-write"
approvals_reviewer = "user"
allow_login_shell = false
web_search = "disabled"

[shell_environment_policy]
inherit = "none"
include_only = ["PATH", "HOME", "PWD", "SHELL"]
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

Agent ownership:
- Claude is primary for planning and Codex-ready handoff.
- Codex is primary for coding and ordinary review.
- Claude coding/reviewing is fallback or second-opinion unless explicitly
  selected.
- Handoffs use `docs/agent-configs/agent-handoff-schema.md`.
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
REASONING_EFFORT="xhigh"
MODEL_PROFILE="${CODEX_MODEL_PROFILE:-stable}"

PLANNING_MODEL="gpt-5.5"
CODING_MODEL="gpt-5.5"
REVIEWING_MODEL="gpt-5.5"
PLANNING_FALLBACK_MODEL="${CODEX_PLANNING_FALLBACK_MODEL:-gpt-5.4}"
CODING_FALLBACK_MODEL="${CODEX_CODING_FALLBACK_MODEL:-gpt-5.4}"
REVIEWING_FALLBACK_MODEL="${CODEX_REVIEWING_FALLBACK_MODEL:-gpt-5.4}"

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

profile_value() {
  local profile="$1"
  local key="$2"
  [[ -f "$MODEL_PROFILES" ]] || return 0
  awk -v profile="$profile" -v key="$key" '
    $0 ~ "\"" profile "\"[[:space:]]*:" { in_profile = 1; next }
    in_profile && $0 ~ /^[[:space:]]*}/ { exit }
    in_profile {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if ($0 ~ pattern) {
        sub(".*" pattern, "")
        sub("\".*", "")
        print
        exit
      }
    }
  ' "$MODEL_PROFILES"
}

load_model_profile() {
  local profile="$1"
  local value=""
  value="$(profile_value "$profile" reasoning_effort)"
  [[ -n "$value" ]] && REASONING_EFFORT="$value"
  value="$(profile_value "$profile" planning_model)"
  [[ -n "$value" ]] && PLANNING_MODEL="$value"
  value="$(profile_value "$profile" coding_model)"
  [[ -n "$value" ]] && CODING_MODEL="$value"
  value="$(profile_value "$profile" reviewing_model)"
  [[ -n "$value" ]] && REVIEWING_MODEL="$value"
  value="$(profile_value "$profile" planning_fallback_model)"
  [[ -n "$value" ]] && PLANNING_FALLBACK_MODEL="${CODEX_PLANNING_FALLBACK_MODEL:-$value}"
  value="$(profile_value "$profile" coding_fallback_model)"
  [[ -n "$value" ]] && CODING_FALLBACK_MODEL="${CODEX_CODING_FALLBACK_MODEL:-$value}"
  value="$(profile_value "$profile" reviewing_fallback_model)"
  [[ -n "$value" ]] && REVIEWING_FALLBACK_MODEL="${CODEX_REVIEWING_FALLBACK_MODEL:-$value}"
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

  if [[ "$core_tokens" -le 4000 ]]; then
    doctor_ok "core startup context estimate: ${core_tokens} tokens (budget 4000)"
  else
    doctor_warn "core startup context estimate: ${core_tokens} tokens exceeds budget 4000"
  fi

  if [[ "$full_tokens" -le 6500 ]]; then
    doctor_ok "on-demand full workflow context estimate: ${full_tokens} tokens (budget 6500)"
  else
    doctor_warn "on-demand full workflow context estimate: ${full_tokens} tokens exceeds budget 6500"
  fi
}

run_doctor() {
  DOCTOR_FAIL=0
  DOCTOR_WARN=0
  local no_scan_paths=""
  echo "Codex helper doctor..."

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

  if grep -Fq 'model_reasoning_effort = "xhigh"' "$PROJECT_ROOT/.codex/config.toml"; then
    doctor_ok "Codex config uses xhigh reasoning"
  else
    doctor_bad "Codex config does not use xhigh reasoning"
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
    if [[ "$model_source" != "default" ]]; then
      echo "Model source: $model_source"
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
  case "$mode:$flow" in
    planning:standard)
      printf '%s' "MODE LOCK: PLANNING-SUPERVISED. Read-only planning. Claude is primary for planning; Codex planning is fallback/user-selected. Apply docs/agent-configs/agent-mode-contracts.md Planning Mode and docs/agent-configs/agent-handoff-schema.md for handoff. Run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available; respect scripts/agent-hook.sh no-scan-paths. Do not mutate files unless the user explicitly grants that exact action. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
      ;;
    planning:full_flow)
      printf '%s' "MODE LOCK: PLANNING-FULL-FLOW. Claude is primary for planning; Codex planning is fallback/user-selected. Apply Planning Mode and docs/agent-configs/agent-handoff-schema.md for handoff. Run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available; respect scripts/agent-hook.sh no-scan-paths. The current user request grants project-local execution only. Keep scope bounded and produce implementation-ready handoff when coding follows. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
      ;;
    coding:standard)
      printf '%s' "MODE LOCK: CODING-SUPERVISED. Codex is primary for coding. Read-only coding analysis. Apply Coding Mode, docs/agent-configs/agent-handoff-schema.md for handoff, run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available, respect scripts/agent-hook.sh no-scan-paths, and run the Technical Spec Adequacy Gate before proposing implementation. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
      ;;
    coding:full_flow)
      printf '%s' "MODE LOCK: CODING-FULL-FLOW. Codex is primary for coding. Apply Coding Mode and docs/agent-configs/agent-handoff-schema.md for handoff. Run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available; run scripts/agent-guard.sh pre-edit <path> before protected paths and respect scripts/agent-hook.sh no-scan-paths. The current user request grants project-local implementation, tests, verification, and self-review. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
      ;;
    reviewing:standard)
      printf '%s' "MODE LOCK: REVIEWING-SUPERVISED. Codex is primary for ordinary review. Read-only review. Run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available; respect scripts/agent-hook.sh no-scan-paths. Apply Reviewing Mode with the three-round BA / Senior Dev-Tech Lead / Senior QC council and docs/agent-configs/agent-handoff-schema.md for handoff. Findings first. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
      ;;
    reviewing:full_flow)
      printf '%s' "MODE LOCK: REVIEWING-FULL-FLOW. Codex is primary for ordinary review. Apply Reviewing Mode with project-local full access and docs/agent-configs/agent-handoff-schema.md for handoff. Run scripts/agent-guard.sh preflight and scripts/detect-agent-tech-stack.sh --markdown when available; respect scripts/agent-hook.sh no-scan-paths. You may run project-local verification commands even when they create build/test outputs. Do not apply remediation edits unless the request asks for fixes or an exact patch scope. Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append to docs/superpowers/plans/<topic>/journal.md using docs/agent-configs/task-journal.md at close-out."
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

  seed="$(mode_prompt "$mode" "$flow")"
  codex_bin="$(resolve_codex_bin)"
  [[ "$persist" == "true" ]] && write_mode "$mode" "$flow"
  if [[ -x "$AGENT_HOOK" ]]; then
    "$AGENT_HOOK" codex-preflight "$mode" "$flow"
  fi
  print_launch_summary "$mode" "$flow" "$model" "$model_source" "$sandbox" "$approval"

  local prompt=""
  if [[ $# -gt 0 ]]; then
    prompt="$*"
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$model" -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"$'\n\n'"USER PROMPT:"$'\n'"$prompt"
  else
    exec "$codex_bin" -C "$PROJECT_ROOT" --model "$model" -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -s "$sandbox" -a "$approval" "$seed"
  fi
}

cmd="${1:-status}"
load_model_profile "$MODEL_PROFILE"
case "$cmd" in
  planning|coding|reviewing)
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
  -h|--help|help)
    usage
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
