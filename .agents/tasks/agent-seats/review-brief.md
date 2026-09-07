# `@gate` review brief — packet `agent-seats`

Role: pre-coding technical review (phase `technical_review`). Output: append
`## Pre-coding technical review` / `### Attempt 1` to `codex-review.md` with
`seat: @gate`, `reviewer_model`, `model_source`, `spec_sufficiency`,
`sufficient_for_coding_model`, `blocking_gaps`, then update `state.json`
(`phase`, `owner`, `requested_action`, `spec_sufficiency`).

Read in order: `task.md` → `docs/superpowers/specs/2026-09-06-agent-seats-design.md`
→ `build-handoff.md` → `evidence/reference-agent-seats.sh` and `evidence/seats.example.json`.

## Decide (three open decisions)

1. Audit token: `gate_coding` replacing `sol_coding` (readers accept both for
   one release) — or keep `sol_coding` permanently.
2. Missing `seats.json` at launch: auto-seed from the legacy profile with a
   notice (proposed) — or fail-closed with guidance.
3. Interactive `wizard` test method: PTY helper (`script`) vs a forced-TTY
   variable; pick the one with fewer platform differences (macOS `script`
   differs from GNU).

## Check for adequacy

- Requirements: seat/occupant split, fixed tags, catalog-as-capability,
  dynamic change without regeneration, migration from `model-profiles.json`.
- Interfaces: `resolve` TSV shape and field order; `efforts`; launcher
  precedence table; exit codes (2 for non-Codex seat; 1 for validation);
  env variable compatibility (`CODEX_*_MODEL_OVERRIDE`, `CODEX_USE_FALLBACK`,
  `CODEX_REASONING_EFFORT`, `CODEX_MODEL_PROFILE` no-op).
- Edge cases: `@owner` non-human, model host mismatch, fallback missing,
  `@build` sharing a model with `@gate`/`@verify`, invalid JSON, legacy
  profile with unknown models, AGENTS.md without the managed block, USER
  overlays preserved by `render`.
- Tests: RED/GREEN discipline, two mutations, budget numbers, migration
  fixture, `grep -w` role-word check, no loosened assertions.
- Security/privacy: none new; local-only file; no secrets.
- Boundaries: copy (not heredoc) for the script; snapshot mirror for the
  verifier; no guard/hook changes; no version bump.

Verify the reference script yourself on a temporary target generated from the
worktree bundle (commands in `evidence/`-style: `suggest`, `wizard --yes`,
`render` twice, `set` invalid effort, `resolve planning`, `validate`, `reset`).

## Launch (raw Codex in the worktree; the kit repo is not a bootstrapped target)

```bash
cd /Users/admin/.config/superpowers/worktrees/agent-bootstrap/simplify-task-relations
codex -C "$PWD" --model gpt-6-astra -c 'model_reasoning_effort="ultra"' -s workspace-write -a never \
  'SEAT LOCK: @gate · phase technical_review. Packet .agents/tasks/agent-seats. Read task.md, docs/superpowers/specs/2026-09-06-agent-seats-design.md, build-handoff.md, review-brief.md. Produce the pre-coding technical review in codex-review.md (seat: @gate, reviewer_model, model_source, spec_sufficiency, sufficient_for_coding_model, blocking_gaps), rule on the three decisions in review-brief.md, run the reference script on a temporary generated target, then update state.json. Do not edit source files; do not commit.'
```

## Attempt 2 (after Specification revision 1)

- Re-read `task.md` § Specification revision 1 and the revised spec sections:
  Data model (grammar), Configuration lifecycle, Script, Roster rendering
  contract, Launcher, Packet mapping, Interactive channel and tests.
- The reference script is v2 (`evidence/reference-agent-seats.sh`, sha256 in
  `evidence/seats-qa-summary.json`). `resolve` now prints eight lines (one
  field per line); `evidence/review-probes-20260907.py` targets the v1
  single-line interface and will not run unchanged — use
  `evidence/seats-qa.py <target> <script> <out.json>` (38 checks, real PTY)
  on a temporary generated target, and rerun your own probes against the
  new interface where they still apply.
- Please rerun `show|set|resolve|wizard --yes` and one PTY wizard pass under
  macOS `/bin/bash` 3.2; the Claude QA ran on bash 5.2 only.

## Attempt 3 (after Specification revision 2 and the council)

Two passes, in this order — the second must not contaminate the first:

1. **Independent pass (contract inputs only).** Read `task.md` § Specification
   revision 2 and the spec sections "Configuration lifecycle", "Script",
   "Launcher", "Interactive channel"; then `evidence/reference-agent-seats.sh`
   (v3), `evidence/seats-qa.py` (v2) and `evidence/reference-generator-hunks.patch`.
   Run `SEATS_QA_BASH=/bin/bash python3 evidence/seats-qa.py <target> evidence/reference-agent-seats.sh <out.json>`
   on a temporary generated target as a non-root user (permission cases skip
   under root); rerun your attempt-2 probes against the eight-line `resolve`
   interface; write your findings before opening anything under
   `evidence/council/` or `council-record.md`. Claude's 103/103 and mutation
   counts are testimony, not evidence, until you have reproduced them.
2. **Reconciliation pass.** Then read `council-record.md` (chair decisions
   1–8, minority view) and `evidence/council/round*-seat*.md`. Record what the
   council found that you did not, what you found that it did not, and whether
   you confirm or overturn each chair decision — in particular conflict on
   primary reviewing models only, auto-seed only in the launch boundary, and
   `set` never creating the file. Anything stated only in those records and
   not visible in the artifacts stays unverified.

Generator hunks are a reference for `@build`; judge them for ordering,
dry-run and candidate semantics, not as a finished integration.
