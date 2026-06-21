#!/usr/bin/env bash
# agent-bootstrap/lib/onboarding.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits the agent-driven onboarding
# scaffold (procedure doc, Claude command, empty project brief, specs/plans
# skeleton). Full-workflow only. Do not execute directly.

write_project_onboarding() {
  write_file "$TARGET_DIR/docs/agent-configs/first-10-minutes.md" <<'EOF_FIRST_10'
# First 10 Minutes

Use this as the first operator path after generating the harness into a project.
It is intentionally short: install the pinned runtime, validate the guardrails,
then let an agent fill the project-specific onboarding contract from source
evidence.

## Operator path

```bash
bash scripts/install-rtk.sh
scripts/agent-hook.sh doctor
scripts/agent-guard.sh preflight
scripts/agent-onboarding.sh next
```

Then open an agent session and run `/project-onboarding`, or follow
`docs/agent-configs/project-onboarding.md` manually.

## Onboarding readiness gate

```bash
scripts/agent-onboarding.sh status
scripts/agent-onboarding.sh check
scripts/verify-ai-deps.sh
```

`status` and `next` are guidance commands. `check` is the strict gate and exits
non-zero until `docs/agent-configs/project-brief.md` and
`docs/superpowers/specs/project-tech-stack.json` are source-backed and filled.
The verifier reports onboarding readiness but does not fail a fresh bootstrap
only because onboarding is still unfilled.
EOF_FIRST_10

  write_file "$TARGET_DIR/docs/agent-configs/project-onboarding.md" <<'EOF_ONBOARD'
# Project Onboarding (agent procedure)

Run this once when landing in a project whose
`docs/agent-configs/project-brief.md` still carries the `<!-- UNFILLED -->`
marker. Tool-agnostic: Claude, Codex, Gemini, or any agent can follow it.
Run `scripts/agent-onboarding.sh next` to see the current missing pieces.

## Procedure
1. Read `docs/agent-configs/project-agent-context.md` (detected stack, modules,
   verification commands) as the seed.
2. Run `scripts/detect-agent-tech-stack.sh --markdown` to refresh detected facts.
3. Explore the codebase to understand: what the project is, top-level
   architecture, module/package responsibilities, key domains, conventions,
   protected/sensitive areas, build/test/run commands, and known gotchas. Prefer
   the repo's code-intelligence (e.g. CodeGraph) and entry points over
   exhaustive reading.
4. Fill every section of `docs/agent-configs/project-brief.md`, removing the
   `<!-- UNFILLED -->` marker. Be concrete: name real files, modules, and
   commands. State uncertainty explicitly instead of guessing.
5. Update `docs/agent-configs/project-agent-context.md` with project-specific
   tech-stack overrides: protected paths, generated files, architecture
   boundaries, test strategy, release constraints, and commands that replaced
   detector placeholders.
6. Fill `docs/superpowers/specs/project-tech-stack.md` and
   `docs/superpowers/specs/project-tech-stack.json` with the verified
   project-specific tech-stack, module map, conventions, source evidence, and
   verification matrix. Keep `project-tech-stack.json` schema-valid; use
   `"status": "partial"` when some facts are still open questions.
   Add more topic specs under `docs/superpowers/specs/<topic>/` when onboarding
   discovers durable domain or architecture decisions.
7. Do NOT invent facts. If something cannot be verified from the code, record it
   under Open Questions.
8. Keep secrets out of the brief/specs (no tokens, keys, credentials, sensitive
   data).
   Respect `scripts/agent-hook.sh no-scan-paths`.
9. Set the `Last verified:` line near the top of the brief to the current commit
   sha (`./scripts/rtk git rev-parse --short HEAD`) and today's date. Re-run this
   onboarding when the brief's recorded commit is far behind `HEAD`.
10. Run `scripts/agent-onboarding.sh status`, then
    `scripts/agent-onboarding.sh check`. If the strict check fails, fix the
    missing brief sections, evidence, verification entries, or `Last verified`
    values before substantive implementation work.

## Definition of Done

- `docs/agent-configs/project-brief.md` no longer contains
  `<!-- UNFILLED -->`.
- Every required brief section has source-backed content or an explicit open
  question.
- `docs/superpowers/specs/project-tech-stack.md` no longer contains
  `<!-- UNFILLED -->` and every required section has concrete content.
- `docs/superpowers/specs/project-tech-stack.json` has
  `"status": "filled"`, non-empty `last_verified.commit`,
  `last_verified.date`, `source_evidence`, and `verification`.
- Every `source_evidence[].path` is a safe project-relative path to an existing
  file, every evidence claim is non-empty, and every verification entry has
  non-empty `command`, `purpose`, and `source`.
- `scripts/agent-onboarding.sh check` exits 0.
- `scripts/verify-ai-deps.sh` exits 0.

## Output
A fully-filled `project-brief.md` — the durable deep-context an agent reads at
the start of work in this project. Commit only when the user asks; git via
`./scripts/rtk git`.
EOF_ONBOARD

  write_file "$TARGET_DIR/.claude/commands/project-onboarding.md" <<'EOF_CMD'
---
description: Build deep project context for a freshly bootstrapped repo by reading the codebase and filling docs/agent-configs/project-brief.md.
---

# Project Onboarding

Follow `docs/agent-configs/project-onboarding.md` to build deep project context.
Fill every section of `docs/agent-configs/project-brief.md` and remove its
`<!-- UNFILLED -->` marker. Be concrete, do not invent facts, keep secrets out.
Finish by running `scripts/agent-onboarding.sh check`.
EOF_CMD

  write_user_owned_file "$TARGET_DIR/docs/agent-configs/project-brief.md" <<'EOF_BRIEF'
# Project Brief

<!-- UNFILLED -->
<!-- Run project onboarding to populate. See docs/agent-configs/project-onboarding.md -->

Last verified: <commit-sha> / <date> (update when you re-onboard)

> Deep, durable project context for agents. Generated empty by bootstrap; filled
> by the onboarding step. Keep it current when architecture/conventions change.

## What this project is

## Architecture overview

## Entry points / where to start reading

## Modules / packages and responsibilities

## Key domains and business rules

## Key invariants / things that must stay true

## Conventions (code style, patterns, naming)

## Protected / sensitive areas

## Build, test, and run commands

## Known gotchas and pitfalls

## Open questions
EOF_BRIEF

  write_file "$TARGET_DIR/docs/superpowers/specs/README.md" <<'EOF_SPECS'
# Specs

Design specs live here, one folder per topic:
`docs/superpowers/specs/<topic>/`. Each spec captures objective, design,
boundaries, success criteria, and open questions. Reference the spec path from
commits/PRs for traceability.

On first onboarding, fill `docs/superpowers/specs/project-tech-stack.md` with
the verified project-specific tech-stack, module map, conventions, protected
paths, generated-file ownership, and verification matrix. Keep it source-backed:
cite real files and commands rather than guesses. Keep the paired
`docs/superpowers/specs/project-tech-stack.json` schema-valid for lightweight
tooling checks.
EOF_SPECS

  write_user_owned_file "$TARGET_DIR/docs/superpowers/specs/project-tech-stack.md" <<'EOF_TECH_STACK_SPEC'
# Project Tech Stack Spec

<!-- UNFILLED -->
<!-- Run project onboarding to populate this file from actual project files. -->

Last verified: <commit-sha> / <date>

## Stack summary

## Module / package map

## Architecture boundaries

## Generated files and ownership

## Protected paths and sensitive config

## Verification matrix

## Conventions agents must follow

## Open questions
EOF_TECH_STACK_SPEC

  write_user_owned_file "$TARGET_DIR/docs/superpowers/specs/project-tech-stack.json" <<'EOF_TECH_STACK_CONTRACT'
{
  "schema": "agent-project-tech-stack/v1",
  "status": "unfilled",
  "last_verified": {
    "commit": "",
    "date": ""
  },
  "stacks": [],
  "modules": [],
  "architecture_boundaries": [],
  "generated_files": [],
  "protected_paths": [],
  "verification": [],
  "conventions": [],
  "source_evidence": [],
  "open_questions": []
}
EOF_TECH_STACK_CONTRACT

  write_file "$TARGET_DIR/docs/superpowers/plans/README.md" <<'EOF_PLANS'
# Plans

Implementation plans live here, one folder per topic:
`docs/superpowers/plans/<topic>/`. Each plan breaks a spec into bite-sized,
verifiable tasks. Reference the plan path from commits/PRs for traceability.

## Task journal

Each task keeps a working-memory journal at `<topic>/journal.md` — append-only,
one entry per mode step, following the schema in
`docs/agent-configs/task-journal.md`. It survives context compaction and is the
task's durable decision record. Keep entries concise; the journal stays in place
when the task lands.
EOF_PLANS
}
