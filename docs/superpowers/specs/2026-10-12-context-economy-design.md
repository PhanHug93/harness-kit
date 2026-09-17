# Context economy: deduplicated startup docs and working-economy rules

Date: 2026-10-12, Asia/Ho_Chi_Minh.
Branch: `feature/verification-feedback` (same single commit as sub-projects A and D).
Scope: sub-project B+C of the context/process feedback plan.
Inputs: the downstream agent self-review on process overhead (re-reading,
duplicated handoff context, overlapping reports, late fixture-fidelity catch,
fragmented coordination) and `startup-context-budget-research` RQ4/RQ5.
Status: approved by the owner on 2026-10-12.

## B. Deduplication

| Change | Before → after (heuristic tokens, FULL Android fixture) |
|---|---|
| B1 Tool contract (rendered into `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, `.cursor/rules`) keeps a short guard summary and points to the full contract | guard section ≈628 → ≈100 per host file |
| B2 AGENTS.md no longer requires reading the full guard contract at startup; a short guard section points to it (read on demand) | ≈900 fewer tokens per session start |
| B3 Full-workflow `CLAUDE.md` drops text repeated from AGENTS.md (first run, startup and on-demand lists, detector/no-scan) | 1462 → 692 (incl. tool contract) |
| B4 `agent-handoff-schema.md` keeps the per-handoff contract; allowed values, seat derivation, examples, task relations, the closing Outcome and per-artifact formats move to `agent-handoff-reference.md` | 1970 → 694 (+ 1404 read on demand) |
| B5 The schema's guard pointer names the real contract path | — |

Deferred: detector blocks in the user-owned `project-agent-context.md` (new
targets only) and trimming mode contracts.

## C. Working-economy rules

- AGENTS.md (host auto-loaded, survives compaction) gains `## Working Economy`:
  resume from the summary and re-read only changed files and open questions;
  handoffs cite paths/commits/evidence instead of pasting, and each decision is
  recorded once in `task.md`; reports keep one role each and verification
  records only new evidence; batch checks and report progress only on state
  changes.
- Mode contracts gate rule: every acceptance criterion names its test and the
  observable it asserts, checked by `@gate` before coding; fixtures cross the
  production boundary they claim (a real HTTP 401, not `status: 401` in JSON).
  The existing equivalence/invariance guard rule is kept verbatim.

## Result and verification

Verifier on the FULL fixture: core 2573 / 4000, on-demand 5072 / 6200 (was
6196). Tests: handoff assertions read schema + reference; new assertions pin the
reference pointer, the working-economy rules, the gate rule, the guard summary in
host files and the absence of repeated startup text in `CLAUDE.md`. Full
bootstrap suite, launcher suite, onboarding fixtures and template mirror check.
