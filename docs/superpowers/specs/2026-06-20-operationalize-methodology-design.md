# Operationalize Methodology + Unified Task-Journal Design

> Revision 2 (2026-06-20): incorporates the ChahiDev design-review must-fixes and
> three resolved decisions. See "Review Resolutions" at the end for the audit
> trail. Line references point at the current repo (bundle source unless noted as
> generated output).

## Goal

Turn the methodology surface from prose principles into runnable procedures,
where every run appends a structured entry to one durable, git-tracked
task-journal. The journal is the working-memory artifact an agent re-reads to
recover task state after context compaction, and it doubles as a PR-reviewable
decision record. Long-term distilled knowledge continues to live in agentmemory
/ native memory; the journal feeds it but does not replace it.

The surface is **three launch-modes** — Planning, Coding, Reviewing — selectable
in `.codex/codex-mode.sh` and `.claude/commands/*`, each with its own
model/sandbox; plus **two cross-cutting methodologies** — Council and Karpathy —
invoked *within* a mode or on request. Council/Karpathy are doc + Claude command
procedures, **not** codex modes. The journal-entry and conditional-memory steps
attach to all five procedures.

## Current State

- `docs/agent-configs/agent-mode-contracts.md` defines Planning, Coding,
  Reviewing with purpose, ownership, and stop-conditions; Reviewing already
  specifies a three-round council. Substantive, but no concrete output artifact.
- `llm-council-agent-workflow.md` and `karpathy-llm-coding-agent-config.md` are
  principle/role prose with no executable steps, output template, or
  stop-conditions.
- `.claude/commands/{planning,coding,reviewing}.md` are thin pointers; there is
  no `council` or `karpathy` command.
- `.codex/codex-mode.sh` recognises exactly three modes: `is_valid_mode()` only
  accepts `planning/coding/reviewing` (generated `.codex/codex-mode.sh:50-52`);
  the `mode_prompt` seeds that actually drive Codex behaviour are at
  `:486-505`; it also carries a *duplicated* on-demand budget list
  (`:230-241`) and a hardcoded doctor file list (`:262-293`).
- `verify-ai-deps.sh` carries the canonical budget lists (`:212-223`), targets
  4000/6500 (`:225`,`:231`, warn-only), and a required-file existence list
  (`:664-668`).
- The kit installs `.agents/skills/agentmemory-mcp/SKILL.md` and `AGENTS.md` has
  an "Agentmemory Usage" section, but the methodology procedures contain no
  concrete save/recall checkpoints — Layer-2 leverage is left to agent
  discretion.
- No per-task working-memory artifact exists. `docs/superpowers/plans/` is
  scaffolded (4-line README) but unused as a live journal.
- Measured budgets: core startup 2628 / 4000 (HARD gate, see Testing); full
  on-demand 5222 / 6500 (~1.3k headroom, warn-only).

## Memory Architecture (two layers)

The journal does not replace agentmemory; they solve different problems and must
stay separated.

| | Layer 1 — Task-journal (file) | Layer 2 — agentmemory / native memory |
|---|---|---|
| Purpose | Working memory for one in-flight task | Distilled knowledge across tasks/sessions/repos |
| Content | Plan checklist, current state, next-action, per-mode entries | Durable decisions, lessons, conventions, resolved bugs |
| Authority | Authoritative (current tracked file, verifiable) | Advisory (verify against current files) |
| Compaction survival | Deterministic — re-read the file | Indirect — fuzzy, rate-limited recall |
| Availability | Anywhere git works (portable, zero new deps) | Only when an MCP/native backend is present |
| Visibility | In PR diff, reviewable | Invisible to PR review |
| Write trigger | Every mode step (mandatory) | At decision/done, distilled (conditional) |
| Read trigger | Task resume / post-compaction | Task start, unfamiliar repo |

This honors the kit's existing policy (`context-policy.json`: prefer current
files over memory; memory is advisory) and its portability contract (bash /
python3 / git / sha only). Recovering task state must not depend on an MCP that
may be absent, nor pollute the cross-session store with high-churn transient
state. Layer 2 is backend-agnostic: agentmemory MCP *or* native auto-memory; the
kit hard-codes neither, and the conditional save degrades silently when no
backend is present.

Bidirectional flow (note the order — see the close-out rule below):

```
mode close-out (status: decided|done):
   ├─ (1) conditional: durable fact emerged AND backend available
   │        ─► memory_save / lesson_save → capture id        [Layer 2]
   └─ (2) mandatory: append journal entry, embedding the id  [Layer 1]

new session / post-compaction:
   in-flight task ─► discover + READ the active journal (authoritative)  [Layer 1]
   entering repo  ─► memory_smart_search (advisory seed)                 [Layer 2]
```

## Task-journal artifact (Layer 1)

- Path: `docs/superpowers/plans/<topic>/journal.md`, git-tracked, append-only,
  one per task/topic. `<topic>` reuses the existing `docs/superpowers/plans/`
  slug convention; `task-id` in an entry is that slug. Created on demand when
  work starts — NOT generated at bootstrap (the generator never writes per-topic
  journals, so there is no bootstrap-drift or generated/user-owned ownership
  conflict; the `--diff`/allowlist re-run never sees it).
- Append-only is enforced **at entry granularity**: a status change
  (`in-progress → decided/done`) is a NEW appended entry, never an edit to a
  prior one. This keeps the log immutable and safe for sequential multi-agent
  appends.
- Shared entry schema:

  ```
  ## <ISO-8601 date> · <mode> · <task-id>
  - status: in-progress | decided | blocked | done
  - context: <1-2 lines: where we are now>
  - <mode-specific body>
  - next-action: <single next concrete step>
  - memory: <saved-id | none | n/a (no backend)>
  ```

- Mode-specific body:
  - Planning: assumptions; affected components; risks; verification plan;
    stop-conditions hit; handoff target.
  - Coding: changed files + rationale; tests added/run; verification result;
    remaining risks.
  - Reviewing: findings (severity, file:line); open questions; verification
    gaps; verdict.
  - Council: question; role positions; selected approach; rejected
    alternatives; preserved minority objections; executor; verification;
    stop-conditions.
  - Karpathy: context gathered; explicit assumptions; risks; patch scope;
    evidence / verification.

### Close-out ordering (resolves append-only ⟷ `memory:` contradiction)

At a `decided`/`done` close-out: **(1)** if a durable fact emerged AND a backend
is available, call `memory_save`/`lesson_save` with metadata (repo, branch,
files, evidence, confidence) and capture the returned id; **(2)** then append the
entry embedding that id on the `memory:` line (`none` if no durable fact, `n/a`
if no backend). In-progress checkpoint entries append immediately with
`memory: n/a` — Layer-2 distillation is evaluated only at close-out.

## Resume & Discovery (post-compaction)

After compaction the current journal is discovered **deterministically, without a
new state file**: the active journal is the `docs/superpowers/plans/*/journal.md`
whose latest entry is `status: in-progress`, newest by commit/mtime. The
always-on `AGENTS.md` core carries exactly one pointer line stating this rule;
the full discovery/algorithm detail lives in the on-demand `task-journal.md`
doc. Edge cases: zero in-progress journals ⇒ no active task, start fresh;
multiple ⇒ pick newest and confirm against current context/user. The
`SessionStart`/`PreCompact` hooks that would *inject* the active journal
automatically remain the separate task-memory P0 (out of scope); v1 ships the
discovery rule only.

## Operationalized procedures

- Each of the five procedures becomes a step-by-step checklist that ends with
  the close-out rule above (conditional memory_save → mandatory journal append).
- Planning and Coding gain a recall opening step: one `memory_smart_search` at
  task start (per the agentmemory recall budget), then prefer current files;
  and a "read the active journal first if resuming" step.
- Council and Karpathy gain explicit runnable steps and stop-conditions (they
  have none today). Council's "preserve minority objection" step writes to both
  the journal and, conditionally, Layer 2.
- Reviewing keeps its three-round structure; its output is now a journal entry.

## Delivery and multi-tool parity

- New tool-agnostic doc `docs/agent-configs/task-journal.md` (on-demand tier):
  the two-layer model, the schema, the discovery rule, and the memory bridge.
- Thicken `agent-mode-contracts.md` with a short per-mode "Output" subsection
  (close-out rule, 2-3 lines each, pointing to the schema, not repeating it).
- Make `llm-council-agent-workflow.md` and `karpathy-llm-coding-agent-config.md`
  runnable (steps + stop-conditions + close-out).
- New thin Claude commands `.claude/commands/{council,karpathy}.md`; existing
  `{planning,coding,reviewing}.md` gain a one-line journal-entry reminder. These
  are command shortcuts to methodologies/modes, **not** new codex modes.
- Codex parity: edit the six `mode_prompt` seeds in the generated
  `.codex/codex-mode.sh` (`:486-505`) so Planning/Coding/Reviewing instruct
  "read the active journal if resuming" + "append a journal entry per
  `docs/agent-configs/task-journal.md` at close-out". Council/Karpathy reach
  Codex through the tool-agnostic docs and the in-mode references, NOT as new
  codex modes.
- Add the `task-journal.md` pointer to the "Read on demand" list in `AGENTS.md`
  only (`writers-docs.sh:522-533`). `GEMINI.md` is a thin pointer with no
  on-demand list of its own, so it is NOT edited.
- Add `docs/agent-configs/task-journal.md` to `recommended_context` (not
  `required_context`) in the policy.
- Update `docs/superpowers/plans/README.md` to document the journal, schema, and
  lifecycle (keep entries concise; the journal stays in place when the task
  lands — it is the durable decision record).

## Constraints

- Keep the always-on core unchanged in size: all procedures and the journal doc
  live on-demand. `AGENTS.md` IS in the hard-gated core (≤4000); limit its
  change to the single on-demand pointer line for discovery + the journal doc.
- Budget bookkeeping: only the fixed **DOC** `docs/agent-configs/task-journal.md`
  is added to BOTH on-demand budget lists (`verify-ai-deps.sh:212-223` and
  generated `codex-mode.sh:230-241`). The per-task **ARTIFACT**
  `plans/<topic>/journal.md` is never counted — it is variable task data, not a
  fixed harness doc. On-demand stays warn-only; after thickening, confirm it
  remains ≤6500 or accept/justify the warn.
- No new runtime dependency; `memory_save` is conditional and degrades
  gracefully.

## Generator Implementation Surface

- `agent-bootstrap/lib/writers-docs.sh`: add a writer for
  `docs/agent-configs/task-journal.md`; thicken the mode-contracts (`:809`),
  council (`:979`), and karpathy (`:958`) heredocs; add `council`/`karpathy`
  command heredocs in `write_tool_entrypoints` (`:1021+`); add one pointer line
  to the `AGENTS.md` on-demand list (`:522-533`).
- The generated `.codex/codex-mode.sh` (emitted by the `write_codex_files`
  heredoc — confirm whether it lives in `lib/writers-docs.sh` or
  `lib/writers-runtime.sh` at impl time): update the six `mode_prompt` seeds
  (`:486-505`), the duplicated on-demand budget list (`:230-241`), and the
  `run_doctor` file list (`:262-293`, add the journal DOC + council/karpathy
  commands).
- `agent-bootstrap/lib/onboarding.sh`: update generated
  `docs/superpowers/plans/README.md` to document the journal schema and
  lifecycle. Do not emit a per-task journal.
- `agent-bootstrap/policies/agent-context-policy.json` (verbatim-copied to the
  generated `context-policy.json`, MANIFEST `:37`): add the journal DOC to
  `recommended_context`. Confirm the schema item type (the current policy uses
  path strings) and keep verify-ai-deps' safe-relative-path check passing.
- `agent-bootstrap/verify-ai-deps.sh`: add the journal DOC to the on-demand
  budget list (`:212-223`) and, for full workflow, the required-file existence
  list (`:664-668`).
- `agent-bootstrap/agent-guard.sh`: `pre-final` emits a single **advisory line**
  (not a heuristic warn, not a gate) reminding that long/multi-step tasks should
  carry a journal entry. No "substantive change" detection.
- Reconcile the vestigial workflow stubs IN v1: reduce
  `templates/workflows/{council,karpathy,three-mode}/README.md` to a one-line
  pointer to the operationalized procedure doc. These are bundle files under a
  THREE-way byte-identity pin (docs/ source ↔ bundle copy ↔ generated target;
  `test-bootstrap-multi-agent-project.sh:773-780` via `cmp -s`; MANIFEST
  `:51-53`), so edit the `docs/agent-configs/bootstrap-multi-agent-project/...`
  source AND the `agent-bootstrap/templates/...` copy in lockstep.
- Bump `agent-bootstrap/VERSION`, the entrypoint `AGENT_BOOTSTRAP_VERSION`
  (`core.sh:8`), and `MANIFEST.md:3` together. No new MANIFEST rows: the journal
  DOC and the new commands are heredoc output, not bundle files, so the bundle
  inventory lock (`test-bootstrap…:507-512`, finds bundle files only) is not
  triggered.

## Testing

- Drift test (`scripts/test-bootstrap-multi-agent-project.sh`): regenerates and
  compares byte-for-byte; new heredoc output is covered once generated. The
  bundle inventory lock (`:507-512`) needs no change (no new bundle files). The
  template 3-mirror `cmp -s` block (`:773-780`) WILL fire on the stub edits —
  keep all three copies identical. The core-budget HARD gate (`:820-825`,
  `|| fail` at 4000) must stay green — hence the minimal `AGENTS.md` change.
- Onboarding fixtures (`scripts/test-onboarding-fixtures.sh`, no file inventory):
  add `need_contains` assertions that each mode doc/command contains the
  journal-entry step and the conditional memory_save step; that the
  `task-journal.md` doc exists; and that the council/karpathy commands exist.
- `verify-ai-deps.sh` + `.codex/codex-mode.sh doctor`: re-run; confirm core
  unchanged and on-demand ≤6500 (warn-only).

## Scope Boundaries (Non-Goals)

- No hard-gate enforcement in v1; `pre-final` carries an advisory line only.
  Deterministic enforcement via `Stop`/`PreCompact`/`SessionStart` hooks is the
  separate task-memory P0, out of scope here.
- Council and Karpathy are NOT added as codex modes; no change to
  `is_valid_mode`, the model maps, or model-profiles.
- No new MCP dependency and no change to which backend supplies Layer 2.
- No per-task journal generated at bootstrap; the agent creates it on demand.
- No changes to the detector or distribution/upgrade paths.

## Review Resolutions (2026-06-20)

ChahiDev design review applied:

- P0 — reframed "5 modes" to 3 launch-modes + 2 cross-cutting methodologies
  (evidence: `codex-mode.sh:50-52,141-157,486-505`).
- P0 — added the `.codex/codex-mode.sh` surface (6 mode_prompt seeds, duplicated
  budget list, doctor file list) for true multi-tool parity.
- P1 — fixed the append-only ⟷ `memory:` ordering: memory_save first (capture
  id) → append entry; status changes are new entries.
- P1 — added the Resume & Discovery rule (newest `status: in-progress` journal).
- P1 — disambiguated budget DOC vs per-task ARTIFACT; flagged the HARD core gate.
- P2 — removed `GEMINI.md` from the edit surface (no on-demand list of its own).
- P2 — noted the template-stub three-way byte-identity pin.

Decisions resolved by the user:

1. Discovery = newest `status: in-progress` journal, no extra state file.
2. v1 enforcement = single advisory line in `pre-final`.
3. Template-stub reconciliation is IN v1 (done now for cleanliness).
