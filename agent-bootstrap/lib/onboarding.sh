#!/usr/bin/env bash
# agent-bootstrap/lib/onboarding.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits the agent-driven onboarding
# scaffold (procedure doc, Claude command, empty project brief, specs/plans
# skeleton). Full-workflow only. Do not execute directly.

write_project_onboarding() {
  write_file "$TARGET_DIR/docs/agent-configs/project-onboarding.md" <<'EOF_ONBOARD'
# Project Onboarding (agent procedure)

Run this once when landing in a project whose
`docs/agent-configs/project-brief.md` still carries the `<!-- UNFILLED -->`
marker. Tool-agnostic: Claude, Codex, Gemini, or any agent can follow it.

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
5. Do NOT invent facts. If something cannot be verified from the code, record it
   under Open Questions.
6. Keep secrets out of the brief (no tokens, keys, credentials, sensitive data).
   Respect `scripts/agent-hook.sh no-scan-paths`.
7. Set the `Last verified:` line near the top of the brief to the current commit
   sha (`./scripts/rtk git rev-parse --short HEAD`) and today's date. Re-run this
   onboarding when the brief's recorded commit is far behind `HEAD`.

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
EOF_CMD

  write_file "$TARGET_DIR/docs/agent-configs/project-brief.md" <<'EOF_BRIEF'
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
EOF_SPECS

  write_file "$TARGET_DIR/docs/superpowers/plans/README.md" <<'EOF_PLANS'
# Plans

Implementation plans live here, one folder per topic:
`docs/superpowers/plans/<topic>/`. Each plan breaks a spec into bite-sized,
verifiable tasks. Reference the plan path from commits/PRs for traceability.
EOF_PLANS
}
