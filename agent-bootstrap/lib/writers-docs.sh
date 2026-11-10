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
  write_file "$TARGET_DIR/.agents/skills/agentmemory-mcp/SKILL.md" <<'EOF'
---
name: agentmemory-mcp
description: Shared long-term memory through the agentmemory MCP tools - memories (decisions and facts), lessons (do-not-repeat rules), actions (follow-up work) and the project profile. Use when you start or continue non-trivial work, settle a decision, get corrected by the user, find or finish an out-of-scope follow-up, or touch architecture, config, auth, build, release or migration files. Skip for typo fixes, formatting-only changes and quick questions the current files answer.
---

# Agentmemory

The task packet owns the current task's state (`.agents/tasks/*/state.json`
is authoritative; a task journal is a durable-decision note, not active state).
Agentmemory keeps what outlives one task. Memory is advisory: current files,
tests, docs and user instructions win. If the tools are not available, say
that recall and save were skipped and carry on.

Supported hosts: Claude Code and Codex only, for now.

## Parameters

- Always pass `project` = the repository folder name.
- Saves may add `agentId` = your seat (`spec`, `gate`, `build`, `verify`,
  `audit`). Never pass `agentId` to a search: it hides other seats' records.

## Start of a task (every seat)

One call each, no near-identical repeats in a session:

- `memory_profile`: the files and topics the project touches most.
- `memory_lesson_recall` with the task type ("migration", "release", "tests").
- `memory_smart_search` for earlier decisions on the area.
- `memory_file_history` before editing config, auth, build or release files.
- No task given: `memory_next` for the top unblocked follow-up.

## While working

- A decision settles: `memory_save` at that moment, with the reason, 2-5
  concepts and real file paths.
- The user corrects your approach: `memory_lesson_save`, confidence 0.7, one
  rule with its consequence. A repeated correction reuses the earlier wording,
  so the lesson grows stronger.
- A review finding worth not repeating: `memory_lesson_save`, confidence 0.5.

## Closing

- Out-of-scope follow-ups noted in the packet: `memory_action_create` (title,
  description, priority, `project`, `requires` when known).
- A finished follow-up: `memory_action_update` to `done` with the result, or
  `blocked` with the reason.

## Ask the user first

Deleting memories or lessons, export, heal, reflect, consolidate and
crystallize.

## Not used

Leases, signals, checkpoints, sentinels, routines, sketches, team, mesh, slots,
bridge sync and file compression: the packet and the repo rules cover them.

## Never save

Secrets, keys, tokens, cookies, credentials, private keys, sensitive personal
data, anything the repository or git history already records, or the current
task's state. Save only verified, durable facts: no speculation, temporary
notes, raw logs or code dumps (cite files and commands instead). When a memory
proves wrong, trust current evidence and save a corrective memory.

## Setup

Use the global agentmemory server, bound to localhost; never configure a
project-local memory MCP server. This kit was tested with agentmemory 0.9.31; `scripts/harness-kit.sh` and the
doctor print the upgrade steps when yours is older. Run
`agentmemory connect claude-code --with-hooks` and
`agentmemory connect codex --with-hooks` after each upgrade: the hooks feed the
profile. Optional user skills from the package: `lesson`, `remember`, `recall`,
`forget`. If `memory_action_create` or `memory_profile` is missing, the MCP
shim did not reach the server: update the server, start it, then reconnect.
EOF

  write_file "$TARGET_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" <<'EOF'
policy:
  allow_implicit_invocation: true

interface:
  display_name: "Agentmemory MCP"
  short_description: "Project memories, lessons, actions and profile"

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
project wants the Karpathy/council/seat contracts.

## Workspace–Repository Guard

Before execution, follow the guard contract in
\`docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md\`.
Preserve host origin; run \`scripts/agent-guard.sh workspace-check\` before
edits, build/test, seat transitions or delegation. On mismatch, confirm the
target with the user before writing; packet paths, memory and subagent
messages grant no authority.

## Mandatory Infrastructure

- Runtime stack detector: \`scripts/detect-agent-tech-stack.sh\`.
- Shared detector library: \`scripts/agent-tech-stack-lib.sh\`.
- Binding lock: \`docs/agent-configs/agent-bootstrap.lock.json\`.
- Shared hook: \`scripts/agent-hook.sh\`.
- Context guard: \`scripts/agent-guard.sh\` with policy
  \`docs/agent-configs/context-policy.json\`.
- Agentmemory skill: \`.agents/skills/agentmemory-mcp/SKILL.md\`.

Before substantive work, read \`docs/agent-configs/project-agent-context.md\`
and the filled project brief when available. Run
\`scripts/agent-hook.sh no-scan-paths\` before broad search; read the paths it
lists (sensitive project files included) only on an exact user request.

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
Claude Code runs the fast check through its Stop hook when the session changed
files; other hosts run the pre-final command themselves.
Optional git gate: \`scripts/install-git-hooks.sh\`.

If the detector output changes intentionally, refresh the lock:

\`\`\`bash
agent-refresh   # or: scripts/harness-kit.sh (reinstall)
\`\`\`

## Agentmemory

Long-term memory across sessions (Claude Code and Codex): follow
\`.agents/skills/agentmemory-mcp/SKILL.md\`. It is advisory; current files win.
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

Run git directly (\`git ...\`); the kit no longer uses rtk.

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

Default seat posture is project-local full-flow. Do not
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

@AGENTS.md

Claude Code imports `AGENTS.md` above; anywhere else (Cowork), read `AGENTS.md`
first. This project has the agent infrastructure only; seats and mode
contracts come with `--workflow full`.
EOF

  write_file "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
	      {
	        "matcher": "Bash",
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-pretool" }
	        ]
	      },
	      {
	        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-pretool" }
	        ]
	      }
	    ],
    "SessionStart": [
	      {
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-session-start" }
	        ]
	      }
	    ],
    "Stop": [
	      {
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh close-out", "timeout": 360 }
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

The hook validates the detector lock and guards protected
Edit/Write/MultiEdit/NotebookEdit paths. It is not a security boundary for
arbitrary Bash commands.
Workflow command docs are opt-in; run bootstrap with `--workflow full` if the
project wants seat commands.
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

## Startup Context Budget

Always read at startup:

- This file.
- \`docs/agent-configs/project-agent-context.md\`.
- \`docs/agent-configs/project-brief.md\`; if \`<!-- UNFILLED -->\`, run
  \`docs/agent-configs/project-onboarding.md\` before substantive work.
- Available preflight and stack-detector output (commands below).

Read on demand:

- \`.agents/tasks/<task-id>/\`: selected local collaboration packet.
- \`docs/agent-configs/karpathy-llm-coding-agent-config.md\` before substantial
  edits or production-risk refactors.
- \`docs/agent-configs/llm-council-agent-workflow.md\` for councils/high-risk
  architecture/security/release tradeoffs.
- \`.agents/skills/\` only for task-matching skill descriptions.
$mobile_skill_read_on_demand_bullet
- Medium tier: also \`docs/agent-configs/tier-medium.md\`.

Large tier, or any \`@seat\` session (such as medium \`@verify\`):

- \`docs/agent-configs/agent-mode-contracts.md\` for your seat's rules.
- \`docs/agent-configs/agent-handoff-schema.md\` for packets, resume and ownership.

Budget: roughly 4k estimated tokens; excludes tool-specific wrappers.
\`scripts/verify-ai-deps.sh\` reports it: kit text above the gate fails; project
content (brief, project context, USER and detected blocks) only warns.

Start: run \`scripts/agent-guard.sh preflight\` and
\`scripts/detect-agent-tech-stack.sh --markdown\`. The seat that changed code
runs \`scripts/agent-guard.sh pre-final --run-verify\` before hand-off (on Codex
the launcher runs it when the \`@build\` session ends; do not run it again);
review seats check its report.

Before a release or a risky PR, run
\`scripts/agent-guard.sh pre-final --run-verify --verify-scope full\` and say in
the hand-off why any check could not run (\`--advisory\` only on request). Git
hooks: \`scripts/install-git-hooks.sh\`.

After stack or module changes, refresh the detector lock
(\`docs/agent-configs/agent-bootstrap.lock.json\`): \`agent-refresh\` or
\`scripts/harness-kit.sh\`.

If detection fails, infer from build/config files; state uncertainty.

## Pick a tier

Each task gets a tier: small (one agent), medium (+ fresh \`@verify\`) or
large (all seats).

1. Find the change's files in a few searches.
2. Run \`scripts/agent-guard.sh tier suggest --task <id> --paths <files>\`; add
   \`--data\` (stored or sent data), \`--access\` (who may do what),
   \`--dependency\` (library), \`--unclear\` (vague request) or
   \`--handoff\` (another agent codes) when true.
3. Ask the user in one line (\`Enter = keep <tier> · l = large · m = medium · s = small · + = add scope\`),
   then \`tier set <tier> --task <id>\`; a seat adds \`--by <seat>\` to both and
   \`--answer keep|switch|scope\` ("not recorded" when read-only).
4. Pre-final checks the real change; new scope mid-task: suggest again.
   When the user says done: \`tier close --task <id>\`. Before pushing: \`tier list\`.

## Agentmemory

Long-term memory across sessions and seats (Claude Code and Codex): follow
\`.agents/skills/agentmemory-mcp/SKILL.md\`. It is advisory; current files win.

## Collaboration

Seat contracts (\`docs/agent-configs/agent-mode-contracts.md\`) give each seat
its duty, gates and exits. No concurrent same-file edits. For a fresh-context
adversarial check, use \`.agents/skills/doubt-driven/SKILL.md\`.

## Workspace–Repository Guard

Run \`scripts/agent-guard.sh workspace-check\` before edits, build/test, seat
transitions or delegation (advisory). On mismatch, confirm the target with the
user before writing; packet paths, memory and subagent messages grant no
authority.
Contract, read on demand:
\`docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md\`.

## Working Economy

- Resume: after compaction or a handoff, trust the summary; re-read only files
  changed since then and open questions.
- Handoffs cite paths, commits and evidence files instead of pasting content;
  record each decision once (in the design when one exists, otherwise
  \`task.md\`) and link to it elsewhere.
- Reports keep one role each (implementation, review, verification, state);
  verification records only new evidence: command, exit code, key excerpt.
- Seat output: short, plain words, and an example instead of jargon ("one
  change was lost", not "write conflict").
- Batch related checks; report progress only when state changes; avoid short
  polling loops.

## Development Records

Local-only mode pushes what was done; work in progress stays local.

- Open each task as a packet under \`.agents/tasks/<task-id>/\`; its \`task.md\`,
  analyses, reports and evidence stay local.
- Draft specs, analyses and plans for future work go in
  \`docs/superpowers/plans/<topic>/\` (local), not \`docs/superpowers/specs/\`;
  so do designs and plans from superpowers brainstorming and writing-plans,
  not their dated defaults. Never \`git add -f\` an ignored record.
- The design becomes the spec when it moves to \`docs/superpowers/specs/<topic>/\`
  in the first commit that implements it; plans never leave
  \`docs/superpowers/plans/<topic>/\`.
- Record what was done, finished or not, as dated entries in
  \`docs/superpowers/plans/<topic>/journal.md\` (pushed): the committing seat adds one
  with each commit that changes tracked files, and the seat recording closure
  adds the final one, mirroring the packet's \`## Outcome\`;
  entries follow \`docs/agent-configs/task-journal.md\`. Add no other summary or
  report files to pushed paths.

## Local State And No-Scan Guard

Do not scan/read/grep/diff/summarize/print local-only state, tool caches,
generated output, or sensitive machine files without an exact user-requested
path and inspection. A report path recorded in the packet or
printed by the guard (e.g. \`verify_report=\`) may be read.

\`\`\`bash
scripts/agent-hook.sh no-scan-paths
scripts/agent-hook.sh guard-local-state
\`\`\`

The first lists the no-scan paths, sensitive project files included: run it
before broad search. The second fails when agent runtime state is tracked.

## Seat Roster

$seat_roster_block

Occupants change with \`scripts/agent-seats.sh\` (per packet: \`--task <id>\`); data
lives in \`docs/agent-configs/seats.json\`.

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

## Human Approval Policy

Default: project-local full-flow for every seat. Use supervised/read-only/propose
only for user-requested step-by-step approval. Exact approval is required for
external-path mutations, installs, commits, pushes, force operations, or
local-only secret/permission file changes.

## Git Workflow

Run git directly (\`git ...\`); the kit no longer uses rtk.

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
<!-- Add project-specific agent rules (build policies, protected paths); preserved across harness upgrades. -->
<!-- END USER: agents:extra -->
EOF

  write_user_owned_file "$TARGET_DIR/docs/agent-configs/project-agent-context.md" <<EOF
# Project Agent Context - $PROJECT_NAME

Generated by \`bootstrap-multi-agent-project.sh\` on $context_generated_at.
Portable agent config version: \`$AGENT_BOOTSTRAP_VERSION\`.

## Detected Tech Stack

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-stack -->
$stack_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-stack -->

## Deep Project Context

Onboarding fills \`docs/agent-configs/project-brief.md\` and
\`docs/superpowers/specs/project-tech-stack.md\`.

## Detected Modules

<!-- BEGIN MANAGED: multi-agent-bootstrap:detected-modules -->
$module_bullets
<!-- END MANAGED: multi-agent-bootstrap:detected-modules -->

## Verification Commands

<!-- BEGIN MANAGED: multi-agent-bootstrap:verification-candidates -->
$verify_bullets
<!-- END MANAGED: multi-agent-bootstrap:verification-candidates -->

Fix an invalid command in the change that finds it.

## Detection Warnings

<!-- BEGIN MANAGED: multi-agent-bootstrap:detection-warnings -->
$warning_bullets
<!-- END MANAGED: multi-agent-bootstrap:detection-warnings -->

## Stack-Specific Overlay

<!-- BEGIN MANAGED: multi-agent-bootstrap:stack-overlay -->
$stack_overlay_content
<!-- END MANAGED: multi-agent-bootstrap:stack-overlay -->

## Agent Safety Bridge

Protected edits need \`scripts/agent-guard.sh pre-edit --ack <reason> <path>\`;
Claude Code denies unacked edits.

## Project-Specific Rules To Fill In

Protected paths, generated files, security rules, architecture boundaries,
test strategy, release constraints, stack overrides.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/agent-handoff-schema.md" <<'EOF'
# Agent Handoff Schema

Seat, transition, and gate policy lives in
`docs/agent-configs/agent-mode-contracts.md`. Allowed values, task relations,
the closing `## Outcome`, artifact formats and review checklists live in
`docs/agent-configs/agent-handoff-reference.md`; read its State values and the
section your seat writes or checks.

## Select a packet

Packets at `.agents/tasks/<task-id>/` are ignored, ephemeral; ownership and
append-only behavior are conventions, not access controls.

`.agents/tasks/ACTIVE` is a cache; each task's `state.json` is authoritative.
On resume, select the only task that is not `closed`; if it awaits the user,
show the pending question first. Repair stale `ACTIVE`. Several such tasks
require the user to choose. Never select the newest task automatically. Report
malformed state; do not infer it.

## Canonical artifact set

1. `state.json`
2. `task.md`
3. `gate-review.md`
4. `implementation.md`
5. `verify-review.md`
6. `audit-review.md`
7. `user-decision.md`

Each review file is named by the seat that writes it. Older packets may use
`codex-review.md` for 3 and 5 or `claude-review.md` for 6.
An older `codex-review.md` keeps its two sections; append each new attempt to
the matching section.
Only `state.json` and `task.md` are created initially. Other evidence is allowed
when linked from `task.md`; do not add a machine-readable attachment registry.

`tier.json` is written only by `scripts/agent-guard.sh`; agents never edit it.
A small packet can be just `state.json` plus `tier.json`.

## State contract

Initial state:

```json
{"protocol_version": "claude-codex-collaboration/v1", "task_id": "checkout-timeout-fix",
 "status": "open", "phase": "analysis", "seat": "@spec", "owner": "claude",
 "requested_action": "prepare spec for @gate", "base_commit": null,
 "source_task": null, "blocks": [], "revision_rounds": 0,
 "spec_sufficiency": {"verdict": "not_reviewed", "sufficient_for_coding_model": "not_reviewed"},
 "escalation_reason": null,
 "verification": {"runner": "none", "status": "not_run", "reason": null, "report": null},
 "updated_at": "2026-08-10T09:00:00Z"}
```

`requested_action` names the next action. Capture `base_commit` on first entry
into implementation for full-diff review (`tier set` fills a null one with
the `tier.json` `start_commit`).

## Artifact contracts

### `task.md`

`task.md` starts with:

```markdown
## Request (verbatim)

> <original request with secrets redacted>
```

Required: objective, user-visible behaviour, observable criteria, scope,
constraints, owner decisions, assumptions, evidence; optional input for
`@gate`: interfaces, edge cases, implementation notes. When `@gate` returns `task.md` to
analysis, append `## Specification revision <n>` listing the sections it changed;
preserve `## Request (verbatim)` and prior history.

Prior attempts remain immutable by convention; repeats append the next numbered
attempt.

Exclude secrets, permission state and large logs; use paths and summaries.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/agent-handoff-reference.md" <<'EOF'
# Agent Handoff Reference

Per-seat detail for `docs/agent-configs/agent-handoff-schema.md`.

## State values

- `status`: `open | awaiting_user | closed`
- `phase`: `analysis | technical_review | implementation | verification | cross_review | resolution | closed`
- `owner`: `claude | codex | user | agent`
- `spec_sufficiency.verdict`: `not_reviewed | sufficient | partially_sufficient | insufficient`
- `spec_sufficiency.sufficient_for_coding_model`: `not_reviewed | yes | no`
- `verification.runner`: `none | claude | codex | agent`
- `closed_by`: `user` (set with `closed`)
- `verification.status`: `not_run | pass | fail | blocked`; from a guard report:
  `pass → pass; fail, error → fail; unverified → not_run`

`seat` is an optional protocol tag; when absent, derive it from `phase` as in
each seat's Starts when (`closed` → `@owner`). `owner` names the
occupant's host class: host `human` uses `owner: user`; hosts other than claude
and codex use `owner: agent` with `"occupant": {"host": "<host>"}`, and an
agent runner records `"verification": {"runner": "agent", "runner_host": "<host>"}`.

## Task relations

- `source_task` (missing: `null`) is `null`, a task id or
  `<task-id>#<finding-id>` naming why the task exists, with an existing
  packet's id when available; details stay in `task.md`.
- `blocks` (missing: `[]`) lists unique ids of tasks that cannot continue while
  this packet is active. A closed packet's edges are inactive; nothing is
  written in reverse or to the blocked packet.
- Existing `claude-codex-collaboration/v1` packets remain valid. A missing
  referenced packet invalidates nothing: record the uncertainty and continue.
- A closed child returns an outcome to evaluate; closure alone neither proves
  the source finding resolved nor advances the blocked task.

Conventions the writer keeps and the reviewer checks (no guard, hook or
runtime reads these fields): continue the current task while the root cause
and implementation scope are unchanged, keeping review retries in it; open a
child task only for a distinct finding with independently closable scope,
recording the split rationale in `task.md`; per exact `source_task` value, at
most one active child may block a target; no task sources from or blocks
itself; active blocking edges are acyclic.

## Artifact formats

### `task.md` closing outcome

The seat that moves the packet to `resolution` appends one concise section to
`task.md`:

```markdown
## Outcome

- Summary: <change or finding>
- Evidence: <test/report/review path>
- Effect on source: <source task decision/action>
```

The fields are prose, not enums, and do not drive an automatic transition. The
final journal entry (`docs/agent-configs/task-journal.md`) mirrors its Summary,
Evidence, and Effect on source.

Then ask the user to decide: close, another bounded pass, or a prior phase.

### `gate-review.md`

```markdown
## Pre-coding technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
reviewed_revision: <latest specification revision n, or 0>
spec_sufficiency: sufficient | partially_sufficient | insufficient
sufficient_for_coding_model: yes | no
plan: <path> | none
blocking_gaps: none | <spec findings only>
resolved_in_plan: none | <technical findings and where the plan answers them>
```

State sufficiency matches the latest attempt. A later round reads its previous
verdict and the newest `## Specification revision <n>`, not a git diff. A `spec` finding (unclear or
conflicting requirement, missing owner decision, scope change, undefined
behaviour the user sees) blocks and returns the packet to `@spec`. A
`technical` finding (files, races, test design, migration steps,
performance) is resolved in the plan and listed in `resolved_in_plan`. The
plan is `docs/superpowers/plans/<topic>/plan.md` or
`.agents/tasks/<task-id>/plan.md`; skip writing-plans' execution-method choice.

### `verify-review.md`

```markdown
## Final technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
fresh_session_attestation: yes | no
reviewed_base_commit: <commit>
verdict: pass | changes_required | blocked
```

Review history is append-only and immutable; each round appends the next
numbered `### Attempt <n>`.
A medium human review records `reviewer_model: human` and a `pr: <url>` line.
`@verify` checks the hand-off report against the diff, re-runs only a check
whose evidence is missing, stale or inconsistent (or one focused test for a
specific doubt), and recommends heavier validation instead of running it.
`fresh_session_attestation` is procedural-only and is not proof of session, model, account, or host independence.

### `implementation.md`

Append `## Implementation attempt <n>` with model/source, route, scope, files,
verification, deviations, risks, blockers, and adequacy downgrade. A `@gate`
coding escalation records `policy_exception=gate_coding`,
`authorization=user_session`, and the reason; readers accept legacy `sol_coding`
for one release. Gate coding is an escalation: the user must open a new session for the
`@gate` occupant to code; its `policy_exception` record is an audit-only
procedural declaration and cannot provide file-based authorization.

Fixtures cross the boundary they claim (a real HTTP 401,
not `status: 401` in JSON). An equivalence or invariance guard names the
production boundary its fixture crosses, declares its mutation in the packet
before the test is written, and must fail when the fixture transform is
replaced with identity.

### `audit-review.md`

Append one findings-first `## Cross-review attempt <n>` with
`verdict: pass | changes_required`. `@audit` checks state/review consistency,
`base_commit`, verification, any gate-coding decision and reason, and
approved scope. It also checks that no `resolved_in_plan` decision
contradicts an owner decision or acceptance criterion.
Required procedural declarations: `fresh_session_attestation`, actual author model, actual reviewer model, and model source for each.
Check author/reviewer model and session declarations for contradictions.

### `user-decision.md`

Append one dated entry per user decision: the user's words, action, scope,
authorization, and alternatives. An entry allowing another pass records
`revision_rounds` reset to 0.

### Packet seats

The first `tier set` copies the project roster to
`.agents/tasks/<task-id>/seats.json`;
`scripts/agent-seats.sh use|set ... --task <id> --reason "<the user's words>"`
changes and logs it (`--help`). `owner` follows the phase's seat
there; launchers refuse a seat it gives another host; `tier close` prints the
final arrangement for the journal. `@audit` reads `show --task <id>` facts.
EOF

  write_overlay_file "$TARGET_DIR/docs/agent-configs/agent-mode-contracts.md" <<'EOF'
# Seat Contracts

One phase owner writes at a time; ownership is a coordination convention,
not an authorization or security boundary.

## Shared rules

### Flow by tier

- small: `analysis` -> `implementation` -> `resolution`
- medium: `analysis` -> `implementation` -> `verification` -> `resolution`
- large: every seat below, in order

`awaiting_user` is valid only with `resolution` · `@owner`. `closed` is valid only with phase `closed`.
Other active combinations use `open` and the phase's seat.

### Authority

- Only the packet's `@build` codes, on the host the user picks per task, after
  a confirmed small or medium tier (in `tier.json`) or, at large, `@gate` approval.
- `@gate` owns the blocking adequacy verdict on the spec. `@build` may downgrade `yes`
  for a spec gap it finds, but may never upgrade `no`.
- `revision_rounds` counts returns to `implementation` only; at 2, that seat
  moves the packet to `resolution` with `awaiting_user` and asks whether
  another bounded pass is worth its cost.
- The active seat (the seat the user is talking to) records each user decision,
  the close included, in `user-decision.md`; these are
  the only writes a non-owner seat may make to a resolution packet.
- Severity names its trigger condition and frequency, or is marked as an estimate.

### Verification

- Only the executing host may declare a pass for what it ran.
  Skipped or unavailable checks never pass.
- The seat that changed code runs focused tests while editing, then the
  declared mutations and full suite once.
- Seats do not spawn reviewers beyond the doubt-driven skill or a council the
  user asked for.
- Memory: `@verify` and `@audit` save a lesson for a defect worth not
  repeating; the seat recording closure turns the packet's out-of-scope
  follow-ups into agentmemory actions.

### Tier checkpoint

AGENTS.md `## Pick a tier` steps 2–3 as the seat (Claude Code: the option
list, keep first). Add scope: revise, then suggest again.

### Report style

Verdict and blocker count first, then findings as cause and consequence; no
preamble, recap, pleasantry, alarm words or empty hedges.

## `@spec`

- Duty: analysis and specification; the only seat that brainstorms.
- Starts when: phase `analysis`: a new task, or a spec gap comes back.
- Writes: `task.md` and the design; new behaviour opens with
  `superpowers:brainstorming` (its steps when absent), a bug with systematic
  debugging; a return revises the design.
- Never: the plan or code.
- Exits: `technical_review` (large) or `implementation`.
- By tier: small and medium: request and criteria only.
- End of turn: the tier checkpoint.

## `@gate`

- Duty: technical gate and plan.
- Starts when: phase `technical_review` (large).
  `@gate` runs `scripts/agent-guard.sh baseline` before its first round
  (`fail` or `error`: stop and tell the user; `unverified`: note "baseline
  unknown").
- Writes: checks the spec as requirements;
  writes the plan with `superpowers:writing-plans`; then
  the verdict in `gate-review.md`.
  Every acceptance criterion names its test and what it checks.
- Never: rewrite the spec, or code.
- Exits: `analysis` (spec blockers only), `implementation` or `resolution`.
- By tier: large only.
- End of turn: the report style with severities; the tier checkpoint
  (add scope goes to `@spec`).

## `@build`

- Duty: build from the plan.
- Starts when: phase `implementation`: the latest `@gate` approval (large: a
  missing or inconsistent verdict blocks coding), or
  a confirmed small or medium tier.
  Default Claude behavior is handoff, not direct implementation.
- Writes: focused root-cause patches with fresh verification;
  `implementation.md` (large); updates the plan's spec path when the spec moves.
- Never: change the spec (gaps go to `@spec`) or, at large, the plan (gaps
  go to `@gate`).
- Exits: `verification`, `technical_review` (large: plan gap), `analysis` (spec gap) or `resolution`.
- By tier: small: one seat checks the request, plans briefly, codes and
  runs `scripts/agent-guard.sh pre-final --run-verify`; medium:
  `docs/agent-configs/tier-medium.md`.
- End of turn: inspect the final diff; hand off.

## `@verify`

- Duty: verification review.
- Starts when: phase `verification`; medium: a fresh session.
- Writes: `verify-review.md`.
- Never: fix beyond the exact scope asked.
- Exits: `implementation`, `cross_review` or `resolution`.
- By tier: medium and large.
- End of turn: the report style.

## `@audit`

- Duty: independent cross-review.
- Starts when: phase `cross_review` (large).
- Writes: `audit-review.md`.
- Never: fix beyond the exact scope asked.
- Exits: `implementation` or `resolution`.
- By tier: large only.
- End of turn: the report style.

## `@owner`

- Duty: the user's decision.
- Starts when: phase `resolution`.
- Writes: nothing; the active seat records it.
- Never: launched.
- Exits: `closed` or a user-selected prior phase.
- By tier: all.
- End of turn: done: `tier close --task <id>`.

## Project-Specific Seat Overrides

<!-- BEGIN USER: mode-contracts:overrides -->
<!-- Add project-specific mode rules/overrides here; preserved across harness upgrades. -->
<!-- END USER: mode-contracts:overrides -->
EOF

  write_file "$TARGET_DIR/docs/agent-configs/karpathy-llm-coding-agent-config.md" <<'EOF'
# LLM Coding Workflow

Natural language is a control plane, not engineering understanding.
Production changes require this procedure.

## Procedure

1. Before edits, read relevant files, nearby tests, project rules, and current
   diffs. State what you read.
2. State explicit assumptions and risks before editing.
3. Make one small coherent patch; no unrelated refactors.
4. Verify with tests or a justified substitute; review the final diff.
5. Hand off with `docs/agent-configs/agent-handoff-schema.md` when ownership
   changes.

## Stop conditions

- Identify the root cause or stop; never prompt-code until symptoms disappear.
  Record unknowns in the handoff.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/llm-council-agent-workflow.md" <<'EOF'
# Hybrid Council Workflow

Council advises on user-requested high-risk/disputed architecture, migration,
data loss, security/privacy, billing, release, performance, concurrency or
unclear root causes; ordinary review needs none. A council
never changes the phase owner; its executor is the seat that owns the current phase.

Planner/BA: scope; Dev Lead: architecture; QC: regressions; Tester: evidence;
Chair (the coordinator): synthesis. The chair overrides only with evidence,
user instruction, or a safer stop and preserves high-impact minority
objections. Before non-trivial verdicts, optionally apply `doubt-driven`.

## Procedure

1. State the question and council rationale.
2. Each role gives its position, file:line evidence, and confidence.
3. Cross-review assumptions and missing evidence.
4. Chair synthesizes approach, rejected alternatives, minority objections,
   verification commands, and stop-conditions.
5. Record the verdict in the current packet for the phase owner.

## Stop conditions

- Stop and ask the user if repo evidence cannot support a verifiable position.
- Escalate credible P0/P1 security, privacy, data-loss, billing, release, or
  compliance risk even when the majority disagrees.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/tier-medium.md" <<'EOF'
# Medium Tier

Medium is a change one agent can code, then a fresh `@verify` session reviews.
Example: add one screen or one API endpoint.

## `task.md` for medium

This short form replaces the long heading list in the handoff schema.

```markdown
## Request
<the user's words>
## Planned files
- app/settings/SettingsView.swift
## Criteria
- The Settings screen shows the user's name -> npm test settings
```

Each criterion names the test command that checks it.

## Checkpoint

After `task.md` is written and before coding, run the tier checkpoint of
`docs/agent-configs/agent-mode-contracts.md` as `--by @build`, with the files
`task.md` plans (`Enter = keep medium · l = large · s = small · + = add scope`).

## `verify-review.md`

Use the `verify-review.md` format in the handoff reference and add
`same_vendor: yes|no`; a fresh session from the same vendor is allowed. A human
review counts only as `reviewer_model: human` with a `pr: <url>` line and
`verdict: pass`; before the first push, `pr: pending` counts at push, then
fill in the link.

## Lower effort

Medium review can run cheaper: `CODEX_REASONING_EFFORT=high .codex/codex-mode.sh @verify`.

EOF

}

write_task_journal_doc() {
  write_file "$TARGET_DIR/docs/agent-configs/task-journal.md" <<'EOF'
# Task Journal

Journals preserve decisions in Git; they never select active tasks. `.agents/tasks/*/state.json` is authoritative; see
`docs/agent-configs/agent-handoff-schema.md`.

Create `docs/superpowers/plans/<topic>/journal.md` with dated entries to survive
packet loss/compaction. Bootstrap never creates per-task journals. The journal
records what was done, finished or not; with `docs/superpowers/specs/` it is the
only development record pushed in local-only mode. Draft specs, analyses, plans
for future work, reviews and `.agents/` stay local.

The committing seat adds a dated entry
with each commit that changes tracked files, so work is recorded finished or
not. The seat recording closure adds the final entry.
Manually mirror `task.md` Summary, Evidence, and Effect on source into it.

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

@AGENTS.md

Claude Code imports `AGENTS.md` above; anywhere else (Cowork), read `AGENTS.md`
first. This file adds only what is specific to Claude.

- Claude holds `@spec` (analysis/specification) and `@audit` (independent
  cross-review) by default; see the seat roster. Who implements: the
  packet's `@build` (the user picks its host).
- Seats and gates: `docs/agent-configs/agent-mode-contracts.md`; packets:
  `docs/agent-configs/agent-handoff-schema.md`, under `.agents/tasks/<task-id>/`.
- Commands in `.claude/commands/`: `/spec`, `/gate`, `/build`, `/verify`,
  `/audit` (one per seat), `/codex:setup`, `/codex:rescue`, `/codex:status`,
  `/doctor`.
EOF

  write_file "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
	      {
	        "matcher": "Bash",
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-pretool" }
	        ]
	      },
	      {
	        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-pretool" }
	        ]
	      }
	    ],
    "SessionStart": [
	      {
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh claude-session-start" }
	        ]
	      }
	    ],
    "Stop": [
	      {
	        "hooks": [
	          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/agent-hook.sh close-out", "timeout": 360 }
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

Seat commands follow `docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.

In Claude Code, the shared hook denies protected
Edit/Write/MultiEdit/NotebookEdit paths with exit 2 unless
`pre-edit --ack <reason> <path>` exists for that path. It is not a security
boundary for Bash.
EOF

  write_file "$TARGET_DIR/.claude/commands/spec.md" <<'EOF'
---
description: Seat @spec, analysis and specification.
argument-hint: <task-id>
allowed-tools: Bash(scripts/agent-seats.sh check:*)
---

!`scripts/agent-seats.sh check spec --host claude --task "$ARGUMENTS"`

Obey its STOP. Act as `@spec` for `.agents/tasks/$ARGUMENTS/`: follow section `@spec` of
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/gate.md" <<'EOF'
---
description: Seat @gate, technical gate and plan.
argument-hint: <task-id>
allowed-tools: Bash(scripts/agent-seats.sh check:*)
---

!`scripts/agent-seats.sh check gate --host claude --task "$ARGUMENTS"`

Obey its STOP. Act as `@gate` for `.agents/tasks/$ARGUMENTS/`: follow section `@gate` of
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/build.md" <<'EOF'
---
description: Seat @build, build from the plan.
argument-hint: <task-id>
allowed-tools: Bash(scripts/agent-seats.sh check:*)
---

!`scripts/agent-seats.sh check build --host claude --task "$ARGUMENTS"`

Obey its STOP. Act as `@build` for `.agents/tasks/$ARGUMENTS/`: follow section `@build` of
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/verify.md" <<'EOF'
---
description: Seat @verify, verification review.
argument-hint: <task-id>
allowed-tools: Bash(scripts/agent-seats.sh check:*)
---

!`scripts/agent-seats.sh check verify --host claude --task "$ARGUMENTS"`

Obey its STOP. Act as `@verify` for `.agents/tasks/$ARGUMENTS/`: follow section `@verify` of
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/audit.md" <<'EOF'
---
description: Seat @audit, independent cross-review.
argument-hint: <task-id>
allowed-tools: Bash(scripts/agent-seats.sh check:*)
---

!`scripts/agent-seats.sh check audit --host claude --task "$ARGUMENTS"`

Obey its STOP. Act as `@audit` for `.agents/tasks/$ARGUMENTS/`: follow section `@audit` of
`docs/agent-configs/agent-mode-contracts.md` and
`docs/agent-configs/agent-handoff-schema.md`.
EOF

  write_file "$TARGET_DIR/.claude/commands/council.md" <<'EOF'
---
description: Run the on-demand hybrid council methodology.
---

# Council

Follow `docs/agent-configs/llm-council-agent-workflow.md`. Council is advisory
until verified; the Chair preserves minority objections and the seat that owns
the current phase executes any patch.
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

  write_file "$TARGET_DIR/.claude/commands/codex/setup.md" <<'EOF'
---
description: Validate Codex readiness and prepare launch instructions.
argument-hint: [--doctor|--status] <optional Codex setup task>
---

# Codex Setup Bridge

Offer only seats whose host is `codex` in `scripts/agent-seats.sh show`;
otherwise suggest `scripts/agent-seats.sh set <seat> --host codex --model <id>`.

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
argument-hint: [@spec|@gate|@build|@verify|@audit] <stalled task or rescue target>
---

# Codex Rescue Handoff

Offer only seats whose host is `codex` in `scripts/agent-seats.sh show`;
otherwise suggest `scripts/agent-seats.sh set <seat> --host codex --model <id>`.
Choose the seat that matches the packet phase.

Default to handoff, not direct implementation. Read
`docs/agent-configs/agent-mode-contracts.md`,
`docs/agent-configs/agent-handoff-schema.md`, and
`docs/agent-configs/project-agent-context.md`, then use the selected packet under
`.agents/tasks/<task-id>/`. Run
`scripts/detect-agent-tech-stack.sh --markdown` when available and
`scripts/agent-hook.sh no-scan-paths` before broad search.

Return one launch command and one schema-compliant handoff:

```bash
.codex/codex-mode.sh <@spec|@gate|@build|@verify|@audit> --task <task-id> "<handoff prompt>"
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
inherit = "core"
include_only = ["PATH", "HOME", "PWD", "SHELL", "TMPDIR", "CODEX_HARNESS_SESSION", "AGENT_HOST_SESSION_ID", "AGENT_WORKSPACE_CONTEXT"]
ignore_default_excludes = false

[apps._default]
destructive_enabled = false
open_world_enabled = false
default_tools_approval_mode = "prompt"
EOF

  write_file "$TARGET_DIR/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "^(apply_patch|Edit|Write)$",
        "hooks": [
          { "type": "command", "command": "sh -c 'exec \"$(git rev-parse --show-toplevel)/scripts/agent-hook.sh\" codex-pretool'", "timeout": 30 }
        ]
      }
    ]
  }
}
EOF

  write_overlay_file "$TARGET_DIR/.codex/README.md" <<'EOF'
# Codex Mode Helper

Open a seat that `docs/agent-configs/seats.json` gives to Codex with
`.codex/codex-mode.sh`, not raw `codex`. Seats and their roles are in the
`AGENTS.md` roster; `@gate` opens only by its tag.

```bash
.codex/codex-mode.sh @spec    # only if the roster assigns @spec to Codex
.codex/codex-mode.sh @gate
.codex/codex-mode.sh @build
.codex/codex-mode.sh @verify
.codex/codex-mode.sh @audit   # only if the roster assigns @audit to Codex
.codex/codex-mode.sh run      # relaunch the locked seat (@gate when none)
.codex/codex-mode.sh status
.codex/codex-mode.sh doctor
```

- An `@build` session ends with one `scripts/agent-guard.sh pre-final --run-verify`,
  which is @build's hand-off check (do not run it again). The launcher prints
  its last line and report path and exits with Codex's exit code.
  `CODEX_SKIP_CLOSEOUT=1` skips it; so do SIGTERM/SIGHUP (forwarded to Codex)
  and a Codex exit of 126 or above.
- Two checking seats on one primary model: the seed records
  `model_overlap=<seats>` for `@audit`, never an authorization.
- `--task <id>` follows that packet's seats (default: the only open packet).
- `.codex/hooks.json` guards `apply_patch` once trusted (`/hooks` in Codex).
- Approval flags (`--supervised`, `--read-only`, `--propose`, `--standard`)
  follow the AGENTS.md approval policy.

At capacity (`Selected model is at capacity`), use the seat's fallback once or
override one launch:

```bash
CODEX_USE_FALLBACK=1 .codex/codex-mode.sh @build
CODEX_MODEL_OVERRIDE=gpt-5.6-terra .codex/codex-mode.sh @gate
CODEX_REASONING_EFFORT=high CODEX_USE_FALLBACK=1 .codex/codex-mode.sh @build
```

Per-seat overrides: `.codex/codex-mode.sh --help`.

Seat rules: one section per seat in `docs/agent-configs/agent-mode-contracts.md`. Packets:
`docs/agent-configs/agent-handoff-schema.md`, under `.agents/tasks/<task-id>/`.
Respect `scripts/agent-hook.sh no-scan-paths` before broad search.

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
# Where the user started the launcher; captured before any directory change.
LAUNCH_ORIGIN="$(pwd -P)"
MODE_FILE="$PROJECT_ROOT/.codex-mode-lock"
AGENT_HOOK="$PROJECT_ROOT/scripts/agent-hook.sh"
AGENT_GUARD="$PROJECT_ROOT/scripts/agent-guard.sh"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
VERIFY_AI_DEPS="$PROJECT_ROOT/scripts/verify-ai-deps.sh"
SEATS_SCRIPT="$PROJECT_ROOT/scripts/agent-seats.sh"
SEATS_FILE="$PROJECT_ROOT/docs/agent-configs/seats.json"
LEGACY_PROFILES="$PROJECT_ROOT/docs/agent-configs/model-profiles.json"
AGENTS_MD="$PROJECT_ROOT/AGENTS.md"

# With no lock file, `run` and `status` use @gate (route gating), as before.
DEFAULT_MODE="gating"
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
MODEL_OVERLAP=""
# The packet whose seats this launch follows (empty: the project roster).
PACKET_TASK=""
# The packet a launch named with --task; only that one goes into the lock.
LOCK_TASK=""
LAUNCH_FLOW=""
LAUNCH_REST=()
CODEX_CHILD_PID=""
CODEX_SIGNAL_PENDING=""

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
    "  .codex/codex-mode.sh <@seat> [--task <id>] [options] [prompt]" \
    "  .codex/codex-mode.sh run [--task <id>] [options] [prompt]   # relaunch the locked seat; @gate when no lock exists" \
    "  .codex/codex-mode.sh status" \
    "  .codex/codex-mode.sh doctor" \
    "" \
    "Seats:" \
    "  @spec @gate @build @verify @audit (also without @)" \
    "  planning, coding and reviewing are removed: use @spec, @build and @verify." \
    "" \
    "Packet:" \
    "  --task <id>  open the seat as that packet arranges it (scripts/agent-seats.sh show --task <id>);" \
    "               without it: the locked packet for run, else the only open packet, else the project roster." \
    "" \
    "Flow options:" \
    "  --full-flow | --full_flow | -full_flow" \
    "  --supervised | --read-only | --propose | --approval-gate | --standard" \
    "" \
    "Environment:" \
    "  CODEX_MODEL_OVERRIDE=<model> overrides the selected seat for one launch." \
    "  CODEX_<ROUTE>_MODEL_OVERRIDE=<model> keeps route-named compatibility overrides:" \
    "    CODEX_PLANNING_MODEL_OVERRIDE (@spec), CODEX_GATING_MODEL_OVERRIDE (@gate)," \
    "    CODEX_CODING_MODEL_OVERRIDE (@build), CODEX_REVIEWING_MODEL_OVERRIDE (@verify, @audit)." \
    "  CODEX_USE_FALLBACK=1 selects the configured fallback for the selected seat." \
    "  CODEX_REASONING_EFFORT=<effort> explicitly selects a catalog-supported effort." \
    "  CODEX_SKIP_CLOSEOUT=1 skips the pre-final verification after an @build session."
}

is_valid_mode() {
  [[ "$1" == "planning" || "$1" == "gating" || "$1" == "coding" || "$1" == "reviewing" ]]
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
    @gate|gate) printf '%s' "gate" ;;
    @build|build) printf '%s' "build" ;;
    @verify|verify) printf '%s' "verify" ;;
    @audit|audit) printf '%s' "audit" ;;
    @owner|owner) printf '%s' "owner" ;;
    *) return 1 ;;
  esac
}

route_for_seat() {
  case "$1" in
    spec) printf '%s' "planning" ;;
    gate) printf '%s' "gating" ;;
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
  # A lock without seat= predates seats: its mode=planning meant @gate.
  mode="$(read_mode)"
  case "$mode" in
    planning|gating) printf '%s' "gate" ;;
    coding) printf '%s' "build" ;;
    reviewing) printf '%s' "verify" ;;
    *) return 1 ;;
  esac
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
  if [[ -n "$LOCK_TASK" ]]; then
    printf 'task=%s\n' "$LOCK_TASK" >> "$MODE_FILE"
  fi
}

# The lock's packet while its folder still exists.
read_locked_task() {
  local task=""
  if [[ -f "$MODE_FILE" ]]; then
    task="$(sed -n 's/^task=//p' "$MODE_FILE" | tail -n1)"
  fi
  if [[ -n "$task" && -d "$PROJECT_ROOT/.agents/tasks/$task" ]]; then
    printf '%s' "$task"
  fi
}

# Leading launch options, in any order: --task <id> and one flow flag. Sets
# LAUNCH_FLOW (empty when none was given), PACKET_TASK and LAUNCH_REST.
parse_launch_options() {
  LAUNCH_FLOW=""
  LAUNCH_REST=()
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--task" ]]; then
      if [[ "$#" -lt 2 || -z "$2" ]]; then
        echo "ERROR: --task requires a task id." >&2
        return 2
      fi
      PACKET_TASK="$2"
      shift 2
    elif [[ -z "$LAUNCH_FLOW" ]] && run_flow_flag "$1"; then
      LAUNCH_FLOW="$FLOW"
      shift
    else
      break
    fi
  done
  if [[ "$#" -gt 0 ]]; then
    LAUNCH_REST=("$@")
  fi
}

# Without --task, the only open packet decides (agent-seats.sh prints a note
# and nothing when there are several); none means the project roster.
select_packet() {
  if [[ -z "$PACKET_TASK" ]]; then
    PACKET_TASK="$(AGENT_SEATS_FILE="$SEATS_FILE" AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
      AGENT_SEATS_AGENTS_MD="$AGENTS_MD" "$SEATS_SCRIPT" open-packet)" || return 1
  fi
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
    "$SEATS_SCRIPT" resolve "$requested" ${PACKET_TASK:+--task "$PACKET_TASK"} >"$output_file" 2>"$error_file"; then
    emit_file_stderr "$error_file"
    if [[ -n "$PACKET_TASK" ]] && grep -Fq ".agents/tasks/$PACKET_TASK/seats.json" "$error_file"; then
      echo "ERROR: cannot resolve seat $requested for packet $PACKET_TASK; fix it with scripts/agent-seats.sh use project --task $PACKET_TASK --reason \"<your words>\"." >&2
    else
      echo "ERROR: cannot resolve seat $requested; repair seats.json with scripts/agent-seats.sh validate or reset." >&2
    fi
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
    gating)
      mode_override="${CODEX_GATING_MODEL_OVERRIDE:-}"
      mode_override_source="CODEX_GATING_MODEL_OVERRIDE"
      if [[ -n "${CODEX_PLANNING_MODEL_OVERRIDE:-}" ]]; then
        echo "WARN: CODEX_PLANNING_MODEL_OVERRIDE now applies to @spec (route planning) and is ignored for @gate; use CODEX_GATING_MODEL_OVERRIDE." >&2
      fi
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

# A shared primary model with a reviewing seat is recorded as a fact for @audit
# (model_overlap=<seats>) and warned about; it never authorizes anything.
compute_overlap() {
  local seat_id="$1"
  local effective_model="$2"
  local overlap_stderr
  new_temp || return 1
  overlap_stderr="$NEW_TEMP"
  if ! MODEL_OVERLAP="$(
    AGENT_SEATS_FILE="$SEATS_FILE" \
      AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
      AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
      "$SEATS_SCRIPT" model-overlap --quiet "$seat_id" "$effective_model" ${PACKET_TASK:+--task "$PACKET_TASK"} 2>"$overlap_stderr"
  )"; then
    emit_file_stderr "$overlap_stderr"
    echo "ERROR: could not evaluate the model overlap for $seat_id." >&2
    return 1
  fi
  emit_file_stderr "$overlap_stderr"
  case "$MODEL_OVERLAP" in
    *[!a-z,]*) echo "ERROR: model-overlap interface returned '$MODEL_OVERLAP'; expected a comma-separated seat list." >&2; return 1 ;;
  esac
}

codex_hook_trusted() {
  # Codex runs a project hook only after /hooks trusts it; it then records a
  # trusted_hash under [hooks.state."<root>/.codex/hooks.json:pre_tool_use:0:0"]
  # in its config. The kit cannot recompute that hash, so this finds the
  # record only: a changed hook entry would still need /hooks again.
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [[ -f "$config" ]] || return 1
  awk -v head="[hooks.state.\"$PROJECT_ROOT/.codex/hooks.json:pre_tool_use:0:0\"]" '
    $0 == head { inside = 1; next }
    inside && /^[[:space:]]*\[/ { inside = 0 }
    inside && /^[[:space:]]*trusted_hash[[:space:]]*=/ { hash = 1 }
    inside && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false/ { off = 1 }
    END { exit !(hash && !off) }
  ' "$config"
}

codex_hook_trust_note() {
  codex_hook_trusted ||
    echo "WARN: Codex has no trust record for the edit guard hook: open codex, run /hooks, trust scripts/agent-hook.sh codex-pretool" >&2
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
    if [[ -n "$MODEL_OVERLAP" ]]; then
      echo "WARN: model_overlap=$MODEL_OVERLAP: $(seat_tag "$seat_id") runs on $model, the primary model of the listed seat(s); recorded as a fact for @audit, not an authorization."
    fi
    if [[ "$model_source" == "default" ]]; then
      echo "If Codex reports model capacity, rerun: CODEX_USE_FALLBACK=1 .codex/codex-mode.sh $(seat_tag "$seat_id")${PACKET_TASK:+ --task $PACKET_TASK}"
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

seat_prompt() {
  local flow="$1"
  local seat_id="$2"
  local model="$3"
  local model_source="$4"
  local tag seed
  tag="$(seat_tag "$seat_id")"
  local packet=".agents/tasks/<task-id>/"
  seed="SEAT LOCK: $tag · phase $LOCKED_PHASE"
  if [[ -n "$PACKET_TASK" ]]; then
    seed="$seed · packet $PACKET_TASK"
    packet=".agents/tasks/$PACKET_TASK/"
  fi
  seed="$seed · launch_model=$model model_source=$model_source"
  if [[ -n "$MODEL_OVERLAP" ]]; then
    seed="$seed model_overlap=$MODEL_OVERLAP"
  fi
  seed="$seed Act as $tag for the packet under $packet: follow section $tag of docs/agent-configs/agent-mode-contracts.md and docs/agent-configs/agent-handoff-schema.md. Respect scripts/agent-hook.sh no-scan-paths before broad search."
  case "$flow" in
    standard)
      printf '%s' "$seed SUPERVISED: read-only; do not mutate files unless the user grants that exact action." ;;
    full_flow)
      printf '%s' "$seed FULL-FLOW: project-local execution only; require exact approval for external paths, installs, commits, pushes, force operations, or local-only permission changes." ;;
    *) echo "ERROR: invalid flow: $flow" >&2; return 1 ;;
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
    doctor_roster_check
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
    .codex/hooks.json \
    .codex/codex-mode.sh \
    .codex/README.md \
    .claude/settings.json \
    .claude/README.md \
    .claude/commands/spec.md \
    .claude/commands/gate.md \
    .claude/commands/build.md \
    .claude/commands/verify.md \
    .claude/commands/audit.md \
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
  if codex_hook_trusted; then
    # Not "ok": the record may belong to an older hook entry, which Codex
    # skips until it is reviewed again (spec R4).
    doctor_info "Codex edit guard hook has a trust record; trust for the current hook entry is not verified: check /hooks in codex"
  else
    doctor_warn "Codex edit guard hook has no trust record: run /hooks in codex"
  fi

  if [[ -f "$PROJECT_ROOT/docs/agent-configs/project-brief.md" ]] &&
    grep -Fq '<!-- UNFILLED -->' "$PROJECT_ROOT/docs/agent-configs/project-brief.md"; then
    doctor_warn "project brief is unfilled; run project onboarding before substantive work"
  else
    doctor_ok "project brief is filled or not required"
  fi

  doctor_context_budget
  doctor_agentmemory
  doctor_exec scripts/agent-seats.sh
  doctor_exec scripts/agent-hook.sh
  doctor_exec scripts/agent-guard.sh
  doctor_exec scripts/agent-tier.py
  doctor_exec scripts/agent-tech-stack-lib.sh
  doctor_exec scripts/detect-agent-tech-stack.sh
  doctor_exec scripts/verify-ai-deps.sh
  doctor_bash scripts/agent-seats.sh
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
  # The hook path may also start at "$CLAUDE_PROJECT_DIR" (same rule as the verifier).
  if grep -Eq '(\./|[$][{]?CLAUDE_PROJECT_DIR[}]?(\\")?/)scripts/agent-hook\.sh(\\")? claude-pretool' "$PROJECT_ROOT/.claude/settings.json"; then
    doctor_ok "Claude PreToolUse uses shared agent hook"
  else
    doctor_bad "Claude PreToolUse does not use shared agent hook"
  fi
  if grep -Fq '"matcher": "Edit|Write|MultiEdit|NotebookEdit"' "$PROJECT_ROOT/.claude/settings.json"; then
    doctor_ok "Claude PreToolUse guards edit/write tools"
  elif grep -Fq '"matcher": "Edit|Write|MultiEdit"' "$PROJECT_ROOT/.claude/settings.json"; then
    doctor_bad "Claude PreToolUse does not guard NotebookEdit: use matcher Edit|Write|MultiEdit|NotebookEdit (see the settings.json candidate)"
  else
    doctor_bad "Claude PreToolUse does not guard edit/write tools"
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
  # Here-strings, not `printf | grep -q`, which can SIGPIPE under pipefail.
  no_scan_complete=true
  for no_scan_needle in '.claude/worktrees/' '.gemini/' '.openclaude/' 'AGENTS.local.md' '*.jks'; do
    grep -Fq -- "$no_scan_needle" <<<"$no_scan_paths" || no_scan_complete=false
  done
  if [[ -x "$AGENT_HOOK" && "$no_scan_complete" == "true" ]]; then
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
doctor_info() {
  # Not checked here, and not counted as a warning.
  printf '  info  %s\n' "$1"
}
doctor_roster_check() {
  # Drift between the AGENTS.md roster and seats.json is a warning, never a failure.
  local roster_err
  new_temp || return 0
  roster_err="$NEW_TEMP"
  if AGENT_SEATS_FILE="$SEATS_FILE" \
    AGENT_SEATS_LEGACY_PROFILES="$LEGACY_PROFILES" \
    AGENT_SEATS_AGENTS_MD="$AGENTS_MD" \
    "$SEATS_SCRIPT" roster-check "$AGENTS_MD" >/dev/null 2>"$roster_err"; then
    doctor_ok "seat roster in AGENTS.md matches seats.json"
  elif grep -Fq 'roster drift' "$roster_err"; then
    doctor_warn "roster drift: the AGENTS.md seat roster differs from seats.json; run scripts/agent-seats.sh render"
  else
    doctor_warn "seat roster check failed: $(tail -n1 "$roster_err")"
  fi
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
# The verifier is the single source of the budget numbers; the doctor relays its
# lines: kit text above a gate fails, project content above a gate only warns.
doctor_context_budget() {
  local budget_json budget_lines status label
  if [[ ! -x "$VERIFY_AI_DEPS" ]] || ! command -v python3 >/dev/null 2>&1; then
    doctor_warn "context budget not measured: needs executable scripts/verify-ai-deps.sh and python3"
    return 0
  fi
  # Exits non-zero when kit text is above a gate; the report is still written.
  budget_json="$("$VERIFY_AI_DEPS" --json --context-budget 2>/dev/null || true)"
  if ! budget_lines="$(printf '%s' "$budget_json" | python3 -c '
import json, sys
report = json.load(sys.stdin)
report["context_budget"]["core"]["kit"]
for check in report["checks"]:
    if "context estimate:" in check["label"]:
        print(check["status"] + "\t" + check["label"])
' 2>/dev/null)" || [[ -z "$budget_lines" ]]; then
    doctor_warn "context budget not measured: scripts/verify-ai-deps.sh --json --context-budget gave no report"
    return 0
  fi
  while IFS="$(printf '\t')" read -r status label; do
    case "$status" in
      fail) doctor_bad "$label" ;;
      warn) doctor_warn "$label" ;;
      *) doctor_ok "$label" ;;
    esac
  done <<<"$budget_lines"
}

# The verifier owns the agentmemory version check; the doctor relays its line.
doctor_agentmemory() {
  local line
  [[ -x "$VERIFY_AI_DEPS" ]] || return 0
  line="$("$VERIFY_AI_DEPS" --agentmemory 2>/dev/null || true)"
  [[ -z "$line" ]] || doctor_warn "$line"
}

run_status() {
  local current_mode current_flow current_seat
  profile_warning
  current_mode="$(read_mode)"
  current_flow="$(read_flow)"
  current_seat="$(read_locked_seat)"
  PACKET_TASK="$(read_locked_task)"
  echo "Current mode: $current_mode"
  echo "Current flow: $current_flow"
  echo "Locked seat: $(seat_tag "$current_seat")"
  if [[ -n "$PACKET_TASK" ]]; then
    echo "Locked packet: $PACKET_TASK"
  fi
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

workspace_environment_override() {
  # JSON basic-string escaping is TOML-compatible with literal UTF-8; escape
  # DEL as well. Keep each override in one argv entry, never evaluate its text.
  python3 - "$1" <<'PY'
import json
import os
import sys
key = sys.argv[1]
value = json.dumps(os.environ[key], ensure_ascii=False).replace(chr(127), r"\u007f")
print("shell_environment_policy.set." + key + "=" + value)
PY
}

mint_launch_envelope() {
  # The launcher acts as the host adapter: record the directory where the user
  # started it, only when no envelope exists. Never overwrite existing values.
  local minted
  [[ -z "${AGENT_WORKSPACE_CONTEXT:-}" && -z "${AGENT_HOST_SESSION_ID:-}" ]] || return 0
  minted="$(LAUNCH_ORIGIN="$LAUNCH_ORIGIN" python3 - <<'PY'
import json
import os
import uuid

origin = os.environ["LAUNCH_ORIGIN"]
session = "launch-" + uuid.uuid4().hex
print(session)
print(json.dumps(dict(original_workspace=origin, target_repository=origin, target_source="user",
                      session_id=session), ensure_ascii=False))
PY
)" || return 1
  AGENT_HOST_SESSION_ID="${minted%%$'\n'*}"
  AGENT_WORKSPACE_CONTEXT="${minted#*$'\n'}"
  export AGENT_HOST_SESSION_ID AGENT_WORKSPACE_CONTEXT
}

run_launch() {
  local requested_seat="$1"
  local route="$2"
  local flow="$3"
  local persist="$4"
  shift 4 || true
  local sandbox approval seed codex_bin prompt resolve_rc codex_rc reaped_rc
  local -a codex_argv sandbox_argv
  reject_nested_launch || return 1
  local workspace_report workspace_rc=0 workspace_context_override workspace_session_override
  mint_launch_envelope || return 1
  workspace_report="$(cd "$PROJECT_ROOT" && "$AGENT_GUARD" workspace-check)" || workspace_rc=$?
  # Advisory: a mismatch (3) launches with a warning; other failures are errors.
  if [[ "$workspace_rc" -ne 0 && "$workspace_rc" -ne 3 ]]; then
    return "$workspace_rc"
  fi
  workspace_context_override="$(workspace_environment_override AGENT_WORKSPACE_CONTEXT)" || return 1
  workspace_session_override="$(workspace_environment_override AGENT_HOST_SESSION_ID)" || return 1
  cd "$PROJECT_ROOT" || return 1
  profile_warning
  require_seats_for_launch || return 1
  if resolve_effective "$requested_seat" "$route"; then
    :
  else
    resolve_rc=$?
    if [[ "$resolve_rc" -eq 2 && -n "$PACKET_TASK" ]]; then
      echo "ERROR: seat $LOCKED_TAG sits on $LOCKED_HOST for packet $PACKET_TASK; open it there, or move it with scripts/agent-seats.sh set $LOCKED_SEAT --host codex --model <id> --task $PACKET_TASK --reason '<your words>'" >&2
    elif [[ "$resolve_rc" -eq 2 ]]; then
      echo "ERROR: seat $LOCKED_TAG is occupied by $LOCKED_HOST; open it there, or move it with scripts/agent-seats.sh set $LOCKED_SEAT --host codex --model <id>" >&2
    fi
    return "$resolve_rc"
  fi
  compute_overlap "$requested_seat" "$EFFECTIVE_MODEL" || return 1
  sandbox_argv=()
  if [[ "$flow" == "full_flow" ]]; then
    sandbox="workspace-write"
    approval="$FULL_FLOW_APPROVAL"
    # Codex keeps .agents/ read-only in its workspace sandbox. A seat writes
    # its packet files and the guard's state there, so those two folders are
    # added as writable ones; .agents/skills stays read-only. --add-dir adds
    # to the folders the user's own Codex config makes writable; an override
    # of sandbox_workspace_write.writable_roots would replace them.
    mkdir -p "$PROJECT_ROOT/.agents/tasks" "$PROJECT_ROOT/.agents/state" || return 1
    sandbox_argv=(--add-dir "$PROJECT_ROOT/.agents/tasks" --add-dir "$PROJECT_ROOT/.agents/state")
  else
    sandbox="read-only"
    approval="$STANDARD_APPROVAL"
  fi
  seed="$(seat_prompt "$flow" "$requested_seat" "$EFFECTIVE_MODEL" "$MODEL_SOURCE")"
  seed="$seed"$'\n\n'"Workspace–Repository Guard: $workspace_report"$'\n'"Preserve AGENT_WORKSPACE_CONTEXT and AGENT_HOST_SESSION_ID in every subagent handoff. Validate the actual repository before writing; packet paths never grant permission."
  if [[ "$workspace_rc" -eq 3 ]]; then
    seed="$seed"$'\n'"Workspace mismatch: confirm the target repository with the user before writing."
  fi
  codex_bin="$(resolve_codex_bin)" || return $?
  if [[ "$persist" == "true" ]]; then
    write_mode "$route" "$flow" "$requested_seat"
  fi
  if [[ -x "$AGENT_HOOK" ]] &&
    ! "$AGENT_HOOK" codex-preflight "$route" "$flow"; then
    echo "ERROR: agent hook preflight failed for route $route." >&2
    return 1
  fi
  codex_hook_trust_note
  print_launch_summary "$route" "$flow" "$requested_seat" "$EFFECTIVE_MODEL" "$MODEL_SOURCE" "$EFFECTIVE_EFFORT" "$sandbox" "$approval"
  prompt="$seed"
  if [[ "$#" -gt 0 ]]; then
    prompt="$seed"$'\n\n'"USER PROMPT:"$'\n'"$*"
  fi
  codex_argv=(-C "$PROJECT_ROOT" --model "$EFFECTIVE_MODEL" -c "$workspace_context_override" -c "$workspace_session_override" -c "model_reasoning_effort=\"$EFFECTIVE_EFFORT\"" ${sandbox_argv[@]+"${sandbox_argv[@]}"} -s "$sandbox" -a "$approval" "$prompt")
  export CODEX_HARNESS_SESSION=1
  if [[ "$requested_seat" == "build" ]] && ! truthy "${CODEX_SKIP_CLOSEOUT:-}"; then
    # Codex has no Stop hook: @build runs it as a child, then verifies once.
    # The child keeps the terminal's stdin; TERM/HUP are forwarded to it (also
    # when they arrive before the fork), and INT is left to Codex while the
    # launcher waits. An async child starts with INT/QUIT ignored, which Codex's
    # own children would inherit, so python3 restores them before exec.
    codex_rc=0
    CODEX_CHILD_PID=""
    CODEX_SIGNAL_PENDING=""
    trap 'forward_codex_signal TERM' TERM
    trap 'forward_codex_signal HUP' HUP
    trap : INT
    # Reset the signals a background child of a non-interactive shell (or
    # Python) starts with ignored, so Codex and the commands it runs behave as
    # in a terminal; a failed exec keeps the shell's 127/126 meaning.
    python3 -I -c '
import errno, os, signal, sys
for name in ("SIGINT", "SIGQUIT", "SIGPIPE", "SIGXFSZ"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), signal.SIG_DFL)
try:
    os.execvp(sys.argv[1], sys.argv[1:])
except OSError as exc:
    print(f"codex-mode: cannot start {sys.argv[1]}: {exc.strerror}", file=sys.stderr)
    sys.exit(127 if exc.errno == errno.ENOENT else 126)
' "$codex_bin" "${codex_argv[@]}" <&0 &
    CODEX_CHILD_PID=$!
    if [[ -n "$CODEX_SIGNAL_PENDING" ]]; then
      kill -s "$CODEX_SIGNAL_PENDING" "$CODEX_CHILD_PID" 2>/dev/null || :
    fi
    wait "$CODEX_CHILD_PID" || codex_rc=$?
    while kill -0 "$CODEX_CHILD_PID" 2>/dev/null; do
      codex_rc=0
      wait "$CODEX_CHILD_PID" || codex_rc=$?
    done
    if [[ "$codex_rc" -gt 128 ]]; then
      # A trapped signal interrupted wait; collect Codex's own status if known.
      reaped_rc=0
      wait "$CODEX_CHILD_PID" || reaped_rc=$?
      [[ "$reaped_rc" -eq 127 ]] || codex_rc=$reaped_rc
    fi
    trap - TERM HUP INT
    unset CODEX_HARNESS_SESSION
    if [[ -n "$CODEX_SIGNAL_PENDING" ]]; then
      echo "@build close-out skipped: Codex exited $codex_rc after SIG$CODEX_SIGNAL_PENDING; run scripts/agent-guard.sh pre-final --run-verify" >&2
      return "$codex_rc"
    fi
    if [[ "$codex_rc" -ge 126 ]]; then
      echo "@build close-out skipped: Codex exited $codex_rc; run scripts/agent-guard.sh pre-final --run-verify" >&2
      return "$codex_rc"
    fi
    run_build_closeout
    return "$codex_rc"
  fi
  cleanup
  trap - EXIT
  exec "$codex_bin" "${codex_argv[@]}"
}

# TERM/HUP trap for the @build child: remember the signal and forward it once
# the child exists. A failed kill must never end the launcher under set -e.
forward_codex_signal() {
  CODEX_SIGNAL_PENDING="$1"
  if [[ -n "$CODEX_CHILD_PID" ]]; then
    kill -s "$1" "$CODEX_CHILD_PID" 2>/dev/null || :
  fi
}

# Runs pre-final verification once after an @build session and reports it. The
# result never replaces Codex's exit code.
run_build_closeout() {
  local closeout_out closeout_rc=0 last_line report
  if [[ ! -x "$AGENT_GUARD" ]]; then
    echo "WARN: @build close-out skipped: scripts/agent-guard.sh is not executable." >&2
    return 0
  fi
  new_temp || return 0
  closeout_out="$NEW_TEMP"
  echo "@build close-out: scripts/agent-guard.sh pre-final --run-verify${PACKET_TASK:+ --task $PACKET_TASK}" >&2
  (cd "$PROJECT_ROOT" && "$AGENT_GUARD" pre-final --run-verify ${PACKET_TASK:+--task "$PACKET_TASK"}) \
    >"$closeout_out" 2>&1 </dev/null || closeout_rc=$?
  # Its last status line; the report path is printed on its own line below.
  last_line="$(awk '!/^agent-guard: verify_report=/ { line = $0 } END { print line }' "$closeout_out")"
  report="$(sed -n 's/^agent-guard: verify_report=//p' "$closeout_out" | tail -n1)"
  echo "@build close-out: pre-final exit $closeout_rc: ${last_line:-no output}" >&2
  if [[ -n "$report" ]]; then
    echo "@build close-out: verify_report=$report" >&2
  else
    echo "@build close-out: no verification report was written" >&2
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
  planning|coding|reviewing)
    case "$cmd" in
      planning) new_tag="@spec" ;;
      coding) new_tag="@build" ;;
      *) new_tag="@verify" ;;
    esac
    echo "ERROR: $cmd: removed: use $new_tag" >&2
    exit 2
    ;;
  @spec|spec|@gate|gate|@build|build|@verify|verify|@audit|audit)
    requested_seat="$(seat_from_arg "$cmd")"
    route="$(route_for_seat "$requested_seat")"
    parse_launch_options "$@" || exit 2
    flow="${LAUNCH_FLOW:-$DEFAULT_FLOW}"
    LOCK_TASK="$PACKET_TASK"
    select_packet || exit 1
    run_launch "$requested_seat" "$route" "$flow" true ${LAUNCH_REST[@]+"${LAUNCH_REST[@]}"}
    ;;
  @owner|owner)
    echo "ERROR: seat @owner is human-owned and is never launchable by this helper." >&2
    exit 2
    ;;
  run)
    stored_flow="$(read_flow)"
    stored_seat="$(read_locked_seat)"
    parse_launch_options "$@" || exit 2
    flow="${LAUNCH_FLOW:-$stored_flow}"
    if [[ -z "$PACKET_TASK" ]]; then
      PACKET_TASK="$(read_locked_task)"
    fi
    select_packet || exit 1
    route="$(route_for_seat "$stored_seat")"
    run_launch "$stored_seat" "$route" "$flow" false ${LAUNCH_REST[@]+"${LAUNCH_REST[@]}"}
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
