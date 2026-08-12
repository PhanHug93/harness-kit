# Claude–Codex Collaboration Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a compact, honest Claude Desktop/Cowork–Codex collaboration protocol in which Claude owns analysis and cross-review, GPT-5.6 Sol owns implementation-boundary and final technical review, GPT-5.6 Luna owns bounded implementation, and the user owns every final decision.

**Architecture:** Keep harness-kit a factory. Extend the existing generated contracts, host pointers, Codex launcher, model profile, guard, and candidate migration path; do not self-bootstrap this repository or add a runner, route, schema, lock service, telemetry store, or Superpowers updater. Put durable protocol detail in the two existing on-demand contract documents, keep always-on and launcher surfaces thin, and test behavior in temporary generated targets.

**Tech Stack:** Bash, Python 3 standard library, JSON, Markdown, Git, and the existing `agent-bootstrap` writer/runtime/test harness.

---

## Locked Scope and Execution Rules

- Work on branch `feature/change_gpt_flow`.
- Treat `docs/superpowers/specs/2026-08-10-claude-codex-collaboration-flow-design.md` as the approved design source.
- Preserve pre-existing untracked files under `data/` and `docs/superpowers/plans/2026-06-24-harness-path-c-observability-enforcement.md`; never stage them with this work.
- Do not bootstrap this repository onto itself. Every generated-output assertion and smoke test uses a temporary target.
- Use test-first changes: add focused failing assertions, observe the intended failure, implement the smallest coherent change, then rerun the focused test.
- Use `apply_patch` for source edits and inspect the exact staged set before every commit.
- Keep schema `agent-model-profiles/v1`; do not add task-packet schemas, new model routes, `.codex/model-routing.local.json`, or file-based authorization.
- Keep `docs/agent-configs/task-journal.md` generated as optional legacy guidance. Remove only mandatory collaboration references and the pre-final journal gate.
- Keep both token thresholds fixed: core `<= 4000`, full workflow `<= 6200`. Reduce duplicated text instead of increasing either threshold.
- Every task states its completion criteria before it starts, naming which failures are allowed to remain at its end. A task with no named allowed failures must end with a green suite. Do not iterate past a task's stated criteria.
- Planned bundle release is `2026.08.10.1`; update every live version/pin surface listed in Task 6, but preserve historical statements in changelogs and old design records.

## Task Loop Limits and Stopping Rules

These apply to every task. They are stated once here so individual tasks add only their own Definition of Done and focused command.

**Passes per task**

- At most one implementation pass and one remediation pass.
- At most one spec review and one spec re-review.
- At most one quality review and one quality re-review.
- Focused tests carry the RED/GREEN loop. The full suite runs once, immediately before closing the task.
- If the full suite fails, one fix round and one rerun are allowed. If it still fails, stop with `NEEDS_USER_DECISION`.

**What blocks a task**

- Only P0/P1, or a direct violation of an acceptance criterion in design section 17, blocks a task.
- P2/P3 findings unrelated to correctness, security, data loss, or approved scope go to the Deferred Findings Backlog at the end of this plan. They never extend the current task.

**Reviewer limits**

- A reviewer may not reopen approved architecture and may not pull a later task's requirements into the current task.
- After a re-review, a reviewer may not raise new findings except a P0/P1 regression supported by direct evidence.

**When a limit is reached**

Stop and present to the user: the evidence gathered, the findings that remain, their impact, and the choice of accept, defer, or revise. Do not start another pass.

**Definition of Done (applies to every task)**

A task is complete only when all five hold:

1. its focused tests pass;
2. the full suite has been run once and passes, or the task has stopped under the rule above;
3. no P0/P1 and no acceptance-criteria violation remains open;
4. the commit contains only files listed for that task;
5. `data/` and `docs/superpowers/plans/2026-06-24-harness-path-c-observability-enforcement.md` remain unchanged and untracked.

Each task below adds its task-specific criteria, its focused command, and the failures it is allowed to leave behind.

## File Map

- Modify: `agent-bootstrap/lib/writers-docs.sh`
  - Generate the canonical role/phase contract and six-artifact handoff contract.
  - Thin `AGENTS.md`, `CLAUDE.md`, `.claude/README.md`, command surfaces, and Codex seeds.
  - Update `.codex/config.toml`, `.codex/codex-mode.sh`, `.codex/README.md`, and Codex doctor behavior.
- Modify: `agent-bootstrap/lib/onboarding.sh`
  - Remove mandatory per-task journal language while retaining optional durable-checkpoint guidance.
- Modify: `agent-bootstrap/model-profiles/codex-model-profiles.json`
  - Set Sol/Luna/Sol primary routes and Terra fallbacks.
- Modify: `agent-bootstrap/agent-guard.sh`
  - Remove `mtime`-selected journal/memory validation from pre-final.
- Modify: `agent-bootstrap/lib/writers-runtime.sh`
  - Make the emitted verifier report the real `6200` full-context threshold.
- Modify: `agent-bootstrap/verify-ai-deps.sh`
  - Keep the canonical runtime verifier snapshot byte-equivalent to generated behavior.
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
  - Cover generated contracts, model routing, loader failures, nested launch, guard removal, migration candidates, budgets, mirrors, and version pins.
- Modify: `scripts/test-onboarding-fixtures.sh`
  - Replace mandatory-journal assertions with optional-journal and canonical-protocol assertions.
- Modify: `README.md` and `agent-bootstrap/README.md`
  - Document Cowork setup, responsibility boundaries, routing, Superpowers policy, and the current one-shot release pin.
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/README.md`
  - Correct live budgets to `4000`/`6200` and align its live one-shot example.
- Modify: `agent-bootstrap/VERSION`, `agent-bootstrap/bootstrap-multi-agent-project.sh`, `agent-bootstrap/MANIFEST.md`, `agent-bootstrap/harness-kit-one-shot-upgrade.sh`, and `CHANGELOG.md`
  - Publish version `2026.08.10.1` consistently.

Files intentionally unchanged unless a failing test proves the approved design wrong:

- `agent-bootstrap/schemas/agent-model-profiles-v1.schema.json`
- `agent-bootstrap/lib/render.sh`
- `agent-bootstrap/agent-local-only-check.sh`
- `.gitignore`
- all Superpowers skill files and upstream installation logic

## Independent Claude Checkpoints

Request one fresh-context Claude review after each major slice, not after every
small edit:

1. after Task 3: generated contracts, role boundaries, Cowork setup, context
   duplication, route precedence, loader failure behavior, and nested-launch
   wording. Tasks 1–3 form one uncommittable block, so this is the first point
   with a green suite to verify against;
2. after Task 4: journal-gate removal;
3. after Tasks 5–6: both budget reporters, candidate migration, Superpowers
   policy, and release/version consistency;
4. after Task 7: final diff and verification evidence.

For each checkpoint, give Claude only the approved design, the relevant plan
tasks, the current diff, and fresh test output. Use this instruction:

```text
Review this checkpoint independently and findings-first. Verify claims against
the current repository and test evidence. Report P0–P3 findings with exact
file/line evidence and end with APPROVE, APPROVE_WITH_CHANGES, or BLOCK. Do not
reopen accepted architecture; flag only repository contradictions, regressions,
missing acceptance coverage, false enforcement claims, or unnecessary
complexity. The user—not either agent—makes the final decision.
```

Present every checkpoint verdict to the user before starting the next major
slice. Do not silently implement a Claude suggestion that changes accepted
scope.

Record each checkpoint's findings as checkboxes in this plan file under the task
they affect, not only in conversation. A finding that is not worth a line in this
file is not worth acting on later.

---

### Task 1: Lock the Generated Collaboration Contracts

**Files:**
- Modify: `scripts/test-onboarding-fixtures.sh`
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/lib/writers-docs.sh`
- Modify: `agent-bootstrap/lib/onboarding.sh`

- [ ] **Step 1: Record the worktree baseline without touching user files**

Run:

```bash
git branch --show-current
git status --short
```

Expected: branch is `feature/change_gpt_flow`; the two pre-existing untracked paths may appear and remain untouched.

- [ ] **Step 2: Replace assertions that make journals mandatory**

In `scripts/test-onboarding-fixtures.sh`, keep assertions that `task-journal.md` exists and documents its optional verification/memory fields. Remove assertions requiring every startup, mode, council, Karpathy, command, Codex seed, or pre-final flow to read or append a journal.

Add these focused assertions:

```bash
need_contains "$mode_contracts" "## Claude–Codex Collaboration Protocol" "mode contracts collaboration protocol"
need_contains "$mode_contracts" "analysis · Claude" "mode contracts analysis owner"
need_contains "$mode_contracts" "technical_review · Codex Sol" "mode contracts technical review owner"
need_contains "$mode_contracts" "implementation · Codex Luna" "mode contracts implementation owner"
need_contains "$mode_contracts" "At most two remediation rounds" "mode contracts remediation limit"
need_contains "$mode_contracts" "not a security boundary" "mode contracts enforcement boundary"
need_contains "$agents" ".agents/tasks/" "AGENTS active task pointer"
need_not_contains "$agents" "## Agent Ownership Matrix" "AGENTS duplicates ownership matrix"
need_contains "$task_journal" "Optional" "task journal is optional"
need_not_contains "$agents" "newest in-progress" "AGENTS no longer auto-selects a journal"
```

Replace removed command/journal assertions with checks that each relevant host surface points to `agent-mode-contracts.md`, `agent-handoff-schema.md`, and `.agents/tasks/` instead of copying the protocol.

- [ ] **Step 3: Add generated handoff-contract assertions**

In `scripts/test-bootstrap-multi-agent-project.sh`, after the full-workflow generated-file checks, assert all six artifact names and the complete state vocabulary:

```bash
handoff_contract="$(cat "$TMP_DIR/docs/agent-configs/agent-handoff-schema.md")"
for artifact in state.json task.md codex-review.md implementation.md claude-review.md user-decision.md; do
  need_contains "$handoff_contract" "$artifact" "handoff contract artifact $artifact"
done
for field in protocol_version task_id status phase owner requested_action base_commit revision_rounds spec_sufficiency escalation_reason verification updated_at; do
  need_contains "$handoff_contract" "$field" "handoff state field $field"
done
need_contains "$handoff_contract" "claude-codex-collaboration/v1" "handoff protocol version"
need_contains "$handoff_contract" "## Request (verbatim)" "handoff immutable request heading"
need_contains "$handoff_contract" "## Pre-coding technical review" "handoff pre-coding section"
need_contains "$handoff_contract" "## Final technical review" "handoff final review section"
need_contains "$handoff_contract" "sufficient_for_coding_model" "handoff blocking adequacy field"
need_contains "$handoff_contract" "fresh_session_attestation" "handoff procedural review attestation"
need_contains "$handoff_contract" "policy_exception=sol_coding" "handoff Sol coding exception record"
```

Also assert the contract says:

- only `state.json` and `task.md` exist at task creation;
- `ACTIVE` is a cache and `state.json` is authoritative;
- one open task is selected, stale `ACTIVE` is repaired, and multiple open tasks require user choice;
- `.agents/` is ignored/ephemeral and append-only/ownership rules are conventions;
- `base_commit` is captured on first entry to implementation;
- prior attempts are preserved and new attempts are numbered.

- [ ] **Step 4: Add role, transition, and gate assertions**

Assert generated `agent-mode-contracts.md` contains exactly these six normal transitions:

```text
analysis · Claude -> technical_review
technical_review · Codex Sol -> analysis | implementation | resolution
implementation · Codex Luna -> verification | resolution
verification · Codex Sol -> implementation | cross_review | resolution
cross_review · Claude -> implementation | resolution
resolution · User -> closed | user-selected prior phase
```

Add negative assertions for removed behavior:

```bash
need_not_contains "$mode_contracts" "Three rounds:" "ordinary review no mandatory council simulation"
need_not_contains "$mode_contracts" "per-mode journal" "collaboration has no mandatory journal"
need_not_contains "$mode_contracts" "--escalated" "no file-authorized escalation route"
need_not_contains "$handoff_contract" "cross_review_model" "Claude cross-review is not a Codex route"
```

Positive assertions must cover:

- `status: awaiting_user` only with `phase: resolution` and `owner: user`;
- `status: closed` only with `phase: closed`;
- Sol owns the blocking adequacy verdict;
- Luna can downgrade `yes` but cannot upgrade `no`;
- initial implementation plus at most two remediation rounds;
- verification records `runner`, `status`, `reason`, and the real report reference;
- Claude cross-review checks review/state consistency, `base_commit`, verification, declarations, Sol-coding decision/reason, and scope;
- user action is final authority.

- [ ] **Step 5: Run focused tests and observe intended failures**

Run:

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: failures name missing collaboration-protocol text and old mandatory-journal/three-round behavior. No failure comes from the two pre-existing untracked paths.

- [ ] **Step 6: Rewrite the canonical generated handoff document**

In the existing `agent-handoff-schema.md` heredoc in `agent-bootstrap/lib/writers-docs.sh`, define the six-artifact packet under `.agents/tasks/<task-id>/` using the exact field names and enums from the approved design.

Use this complete state example:

```json
{
  "protocol_version": "claude-codex-collaboration/v1",
  "task_id": "checkout-timeout-fix",
  "status": "open",
  "phase": "technical_review",
  "owner": "codex",
  "requested_action": "Review whether the specification is sufficient for Luna",
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
  "updated_at": "2026-08-10T00:00:00Z"
}
```

Document the exact artifact headings and key-value fields from Design §§7.1–7.5. Do not add another JSON schema or version file.

- [ ] **Step 7: Rewrite the canonical generated mode contract**

In the existing `agent-mode-contracts.md` heredoc, add one `## Claude–Codex Collaboration Protocol` section with:

- the six-row owner/phase table;
- the six-row allowed-transition table;
- the Sol adequacy gate and Luna downgrade-only rule;
- verification ownership versus `verification.runner`;
- one findings-first ordinary review pass;
- the two-remediation limit;
- user-opened Sol coding escalation and its audit-only semantics;
- explicit convention/enforcement limitations.

Keep existing general planning/coding/reviewing permissions and stop conditions where compatible. Remove the mandatory BA/Dev Lead/QC three-round paragraph and all requirements to close every mode through a journal.

- [ ] **Step 8: Thin always-on and specialized guidance**

In `agent-bootstrap/lib/writers-docs.sh` and `agent-bootstrap/lib/onboarding.sh`:

- replace the `AGENTS.md` ownership matrix with a short pointer to the canonical documents and `.agents/tasks/`;
- remove the “newest in-progress journal” startup rule;
- remove mandatory journal close-out from AGENTS, mode sections, Karpathy, council, Claude commands, and Codex prompts;
- retain a short optional durable-decision statement and generated `task-journal.md`;
- make ordinary review one findings-first pass and refer high-risk/disputed work to council on demand;
- keep mode prompts limited to mode, flow, `.agents/tasks/`, and the two canonical documents.

Do not delete `write_task_journal_doc()` or its call from `bootstrap-multi-agent-project.sh`.

- [ ] **Step 9: Rerun the focused contract tests**

Run:

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: contract and optional-journal assertions pass. If the main test stops on model values deliberately deferred to Task 3, keep the new assertions and continue directly to Task 3 before committing; do not weaken them.

- [ ] **Step 9b: Confirm Task 1 completion criteria before committing**

Task 1 closed at `6d1d260`. Criteria 1 and 3 were met by that commit; criterion 2 was never measured, so it is carried forward to Task 2's Definition of Done. Retained here as the standard for any Task 1 rework.

1. Every assertion added in Steps 2-4 passes.
2. The full-workflow context estimate measured **here** is `<= 6200`. Measure now; do not defer to Task 5:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh 2>&1 | grep -E 'context estimate|context too'
```

3. The only remaining failures are the deferred model-value assertions owned by Task 3. Name each remaining failure and confirm it is on that list. Any failure not on the list is a Task 1 failure and must be fixed here.

If (2) fails, remove duplicated protocol/journal/review text now rather than in Task 5. Design section 13 requires the measured set to be net-reductive **before** the canonical protocol is added, so deferring the measurement inverts the required order.

- [ ] **Step 10: Commit the canonical contract slice**

Run:

```bash
git diff --check
git add agent-bootstrap/lib/writers-docs.sh agent-bootstrap/lib/onboarding.sh scripts/test-onboarding-fixtures.sh scripts/test-bootstrap-multi-agent-project.sh
git diff --cached --check
git commit -m "feat: generate Claude-Codex collaboration contracts"
```

Expected: only the four named files are staged; pre-existing untracked paths remain untracked.

---

### Task 2: Add Claude Desktop/Cowork Folder Guidance

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/lib/writers-docs.sh`
- Modify: `README.md`
- Modify: `agent-bootstrap/README.md`

**Resume state (2026-08-10).** Task 1 closed at `6d1d260`. Task 2 is already in progress with uncommitted changes in `README.md`, `agent-bootstrap/README.md`, `agent-bootstrap/lib/writers-docs.sh`, and `scripts/test-bootstrap-multi-agent-project.sh`. Continue from that worktree. Do not revert, rewrite, or restart those files. A step below that the working tree already satisfies is confirmed by running the focused command in Step 2, not by redoing the edit.

**Carry-forward from Task 1.** Task 1 closed without measuring the full-workflow context estimate, which design section 13 requires to happen before the canonical protocol is added. Measure it as the first item of this task's Definition of Done. If it exceeds `6200`, that is a Task 1 regression and takes priority over the remaining Task 2 steps.

- [ ] **Step 1: Add failing Cowork-surface assertions**

Assert generated `.claude/README.md` contains one copy/paste Folder Instructions block with these meanings:

```text
Read CLAUDE.md first.
Follow the canonical role and handoff documents named there.
Use .agents/tasks/ for the active Claude–Codex handoff.
Do not assume Claude Code hooks run in Cowork.
If Bash is unavailable, continue analysis/cross-review and record verification as blocked or delegated with a reason.
```

Assert generated `CLAUDE.md` points to both canonical documents without
reproducing the six-row owner table. In a dedicated target, create a sentinel
root `README.md` before bootstrap, save its checksum, run the full workflow
bootstrap, and assert the checksum is unchanged; Cowork setup belongs only in
generated `.claude/README.md`.

- [ ] **Step 2: Run the main test and observe the missing pointer failure**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL on new `.claude/README.md`/`CLAUDE.md` assertions.

- [ ] **Step 3: Generate the one-time Cowork pointer**

Update the `.claude/README.md` heredoc inside `write_tool_entrypoints()` with a clearly delimited, copy/paste-ready Folder Instructions paragraph. It points to target `CLAUDE.md` and does not inline the protocol.

Update generated `CLAUDE.md` to state Claude’s two default responsibilities—analysis/specification and independent cross-review—and point to:

```text
docs/agent-configs/agent-mode-contracts.md
docs/agent-configs/agent-handoff-schema.md
.agents/tasks/
```

Keep Claude Code hooks optional and explicitly avoid claiming Cowork hook support.

- [ ] **Step 4: Document operator setup and limitations**

Add a compact Claude Desktop/Cowork section to root and bundle READMEs:

1. Open the generated target folder in Cowork.
2. Copy the Folder Instructions block from generated `.claude/README.md` once.
3. Give Claude the problem; Claude creates or resumes the task packet.
4. Open Codex through the routed launcher for technical review, implementation, and final review.
5. Return to Claude for cross-review and to the user for resolution.

State that packet ownership, append-only history, host/model/session independence, and Sol authorization are conventions or audit declarations, not security controls.

- [x] **Step 4b: Task 2 Definition of Done**

Focused command:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh 2>&1 | grep -E 'Cowork|context estimate|context too'
```

In addition to the global Definition of Done:

1. the measured full-workflow estimate is `<= 6200` and the core estimate is `<= 4000` (carry-forward from Task 1);
2. every Cowork-surface assertion added in Step 1 passes;
3. allowed remaining failures: only the deferred model-value assertions owned by Task 3, named explicitly.

Measured on a temporary full-workflow target while preserving the uncommitted
Task 2 work. Initial result: core `2894 / 4000`, full `6206 / 6200`. The single
allowed reduction pass removed one redundant optional task-journal bullet from
generated `AGENTS.md`; neither canonical contract changed. Remeasurement:

```text
core = 2875 / 4000 (headroom 1125)
full = 6187 / 6200 (headroom 13)
```

The generated reporter still labels the legacy full budget as `6500`; Task 5
owns aligning both reporters to the already-enforced `6200` gate.

- [ ] **Step 5: Rerun and commit the Cowork slice**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
git diff --check
git add agent-bootstrap/lib/writers-docs.sh scripts/test-bootstrap-multi-agent-project.sh README.md agent-bootstrap/README.md
git diff --cached --check
git commit -m "docs: add Cowork collaboration setup"
```

Expected: Cowork assertions pass and the commit contains no target root README writer.

---

### Task 3: Implement Strict Three-Route Model Loading

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/model-profiles/codex-model-profiles.json`
- Modify: `agent-bootstrap/lib/writers-docs.sh`

- [ ] **Step 1: Add exact profile and config assertions**

Replace the GPT-5.5 assertion with exact checks for:

```json
{
  "reasoning_effort": "xhigh",
  "planning_model": "gpt-5.6-sol",
  "coding_model": "gpt-5.6-luna",
  "reviewing_model": "gpt-5.6-sol",
  "planning_fallback_model": "gpt-5.6-terra",
  "coding_fallback_model": "gpt-5.6-terra",
  "reviewing_fallback_model": "gpt-5.6-terra"
}
```

Assert generated `.codex/config.toml`:

```bash
need_not_contains "$(cat "$ROOT_DIRECT_DIR/.codex/config.toml")" 'model = ' "Codex config has no hard-coded model"
need_not_contains "$(cat "$ROOT_DIRECT_DIR/.codex/config.toml")" 'model_reasoning_effort' "Codex config has no hard-coded effort"
need_contains "$(cat "$ROOT_DIRECT_DIR/.codex/config.toml")" '"CODEX_HARNESS_SESSION"' "Codex shell policy passes nesting marker"
```

Keep the v1 schema assertion and assert no `cross_review` or `escalated_coding_model` field is generated.

- [ ] **Step 2: Add a fake Codex executable that captures arguments and environment**

Create a fake `codex` earlier in `PATH` that writes each argument and `CODEX_HARNESS_SESSION` to a capture file, then exits successfully. Exercise generated `.codex/codex-mode.sh` without a real model.

Cover:

| Invocation | Expected model | Expected source | Expected effort |
|---|---|---|---|
| `planning` | `gpt-5.6-sol` | `default` | `xhigh` |
| `coding` | `gpt-5.6-luna` | `default` | `xhigh` |
| `reviewing` | `gpt-5.6-sol` | `default` | `xhigh` |
| `CODEX_USE_FALLBACK=1 coding` | `gpt-5.6-terra` | `CODEX_USE_FALLBACK` | `xhigh` |
| `CODEX_CODING_MODEL_OVERRIDE=custom-coder coding` | `custom-coder` | `CODEX_CODING_MODEL_OVERRIDE` | `xhigh` |
| `CODEX_MODEL_OVERRIDE=global-model CODEX_CODING_MODEL_OVERRIDE=custom-coder CODEX_USE_FALLBACK=1 coding` | `global-model` | `CODEX_MODEL_OVERRIDE` | `xhigh` |
| `CODEX_REASONING_EFFORT=high coding` | `gpt-5.6-luna` | `default` | `high` |

For every route, assert the child sees `CODEX_HARNESS_SESSION=1` and arguments include `--model` and `-c model_reasoning_effort=...`.

- [ ] **Step 3: Add invalid-profile dispatch tests**

Create generated targets whose `model-profiles.json` is, in turn:

- malformed JSON;
- missing the selected profile;
- missing `coding_fallback_model`;
- using `reasoning_effort: "turbo"`;
- using an empty fallback while `CODEX_USE_FALLBACK=1` is requested.

Assert:

```text
planning/coding/reviewing/run -> actionable diagnostic, non-zero, no Codex launch
doctor                          -> profile diagnostic plus later independent checks, non-zero at end
status                          -> profile diagnostic, non-zero
help                            -> usage, zero, no profile load
cross_review                    -> unknown command, non-zero
```

For doctor, assert output contains both the profile error and a later line such as `core startup context estimate`. This locks SR-002.

- [ ] **Step 4: Add accidental nested-launch tests**

With `CODEX_HARNESS_SESSION=1` present, assert `planning`, `coding`, `reviewing`, and `run` exit non-zero before fake Codex. In the same environment, `help` succeeds and `doctor`/`status` reach normal diagnostics.

Error text calls this accidental nesting and does not call it authorization or a security boundary.

- [ ] **Step 5: Run the main test and observe routing failures**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL on old GPT-5.5 values, hard-coded config keys, or missing strict loader/nesting behavior.

- [ ] **Step 6: Update the stable profile without changing schema**

Change only the seven values under `profiles.stable` in `agent-bootstrap/model-profiles/codex-model-profiles.json` to the exact Sol/Luna/Sol and Terra values above. Leave `schema`, `default_profile`, and the v1 schema file unchanged.

- [ ] **Step 7: Remove duplicated model authority from generated config**

In the `.codex/config.toml` heredoc:

- remove `model = ...`;
- remove `model_reasoning_effort = ...`;
- add `CODEX_HARNESS_SESSION` to `shell_environment_policy.include_only`;
- preserve approval, sandbox, login-shell, web, and app policies.

Replace doctor’s grep for `model_reasoning_effort = "xhigh"` with profile/effective-route diagnostics. Valid generated profiles keep all existing doctor success tests green.

- [ ] **Step 8: Replace the awk parser with one atomic Python parser**

The Python 3 stdlib parser must:

1. require top-level schema `agent-model-profiles/v1`;
2. use `CODEX_MODEL_PROFILE` when set, otherwise JSON `default_profile`;
3. require the seven existing profile keys;
4. accept efforts only from `none`, `low`, `medium`, `high`, `xhigh`, `max`;
5. require model IDs to match `^[A-Za-z0-9][A-Za-z0-9._:/-]*$` so tab/newline-delimited output cannot be injected;
6. emit exactly eight tab-separated values: profile name plus seven validated values;
7. assign launcher globals only after parsing and field-count validation succeed.

Use one `MODEL_PROFILE_ERROR` string for actionable failures. Do not retain hard-coded model/fallback defaults that could mask missing fields.

- [ ] **Step 9: Dispatch commands before strict loading**

Implement exactly:

```text
help:
  print usage and exit 0 without loading JSON

planning | coding | reviewing | run:
  reject CODEX_HARNESS_SESSION nesting
  strictly load profile and effort
  launch selected route

doctor:
  attempt profile load
  report failure through doctor_bad
  continue independent checks
  exit non-zero if any doctor_bad occurred

status:
  attempt profile load
  explain and exit non-zero on failure
  otherwise print effective mode/profile/model/source/effort

anything else:
  print unknown command and usage; exit 2
```

Export `CODEX_HARNESS_SESSION=1` immediately before `exec codex`, not at script startup.

- [ ] **Step 10: Preserve exact precedence and audit Sol coding**

Implement only:

```text
CODEX_MODEL_OVERRIDE
mode-specific CODEX_{PLANNING|CODING|REVIEWING}_MODEL_OVERRIDE
CODEX_USE_FALLBACK=1 resolved from active profile
active profile primary model
```

`CODEX_REASONING_EFFORT` overrides validated profile effort independently. Remove silent fallback to GPT-5.4 and do not add local routing JSON.

When coding resolves specifically to `gpt-5.6-sol`, print and seed this audit record:

```text
policy_exception=sol_coding authorization=user_session
```

The implementation handoff records the existing task’s `escalation_reason`. Do not require a file as authorization and do not add `--escalated`.

- [ ] **Step 11: Keep launcher prompts lean**

Each route prompt contains only mode/flow, actual model/source, `.agents/tasks/`, the two canonical contract pointers, its route-specific blocking rule, and the existing project-local permission boundary. Do not duplicate the ownership matrix, state schema, journal, or council protocol.

The `reviewing` route's blocking rule is the single finding obligation from design section 8.4, stated in the prompt and nowhere else:

- severity must name its trigger condition and frequency, or mark itself an estimate.

One rule, not four. Three further candidates were withdrawn after the 2026-08-10 A/B review of the Task 1 diff: the three-blocker cap and the removal-hypothesis obligation were never exercised by that case, and the measurement/verification exemption was exercised and failed, because a review rule shapes how a finding is written but cannot cause a finding to exist. Do not restore any of them without a measured effect; each unmeasured line dilutes the one with evidence behind it.

This text lives in the route prompt because it must apply to every reviewing run. `agent-mode-contracts.md` names the obligation by title and points here; it does not restate it. Assert the presence in the prompt, the absence of a second copy in the contract, and the absence of the three withdrawn rules from both.

- [ ] **Step 11b: Confirm Task 3 completion criteria**

Tasks 1-3 form one uncommittable block, and Task 3 is where it closes. Task 3 is complete only when the route, precedence, diagnostic, and nesting assertions pass **and** no failure remains from Tasks 1-2. Allowed remaining failures: none. If you intend to leave a failure, name it and stop instead of proceeding to Task 4.

- [ ] **Step 12: Rerun and commit routing**

Run:

```bash
bash -n agent-bootstrap/lib/writers-docs.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git diff --check
git add agent-bootstrap/model-profiles/codex-model-profiles.json agent-bootstrap/lib/writers-docs.sh scripts/test-bootstrap-multi-agent-project.sh
git diff --cached --check
git commit -m "feat: route Codex work across Sol Luna and Terra"
```

Expected: route, precedence, diagnostics, and nesting tests pass; schema v1 is not staged.

---

### Task 4: Remove Journal-Dependent Pre-Final Enforcement

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/agent-guard.sh`

- [ ] **Step 1: Replace the old memory-journal gate tests**

Delete the block headed `memory pre-final journal gate`, including fixtures expecting missing `memory:`, missing/deferred `recall_verified`, or missing evidence to affect pre-final.

Add one regression fixture that:

1. bootstraps a full target;
2. initializes and commits a baseline;
3. runs preflight;
4. creates no journal;
5. proves pre-final is decided only by current guard/context checks and does not print `no task journal found`;
6. adds an unrelated old journal with incomplete memory fields;
7. reruns preflight then pre-final and proves that old journal neither fails nor warns.

Keep existing `task-journal.md` content assertions near lines 1307, 1454, and 1455.

- [ ] **Step 2: Run the main test and observe old journal behavior**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because generated guard still scans or warns about the newest journal.

- [ ] **Step 3: Remove the validator at its root**

In `agent-bootstrap/agent-guard.sh`:

- delete `latest_journal_closeout()`;
- delete `memory_gate_fail()` if no callers remain;
- delete `validate_memory_closeout()`;
- remove its single pre-final call;
- remove helpers made unreachable only by these deletions.

Do not alter context-pack checks, protected-path checks, verification execution, guard event schemas, or stats.

- [ ] **Step 3b: Task 4 Definition of Done**

Focused command:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh 2>&1 | grep -E 'pre-final|journal|memory'
```

In addition to the global Definition of Done: `validate_memory_closeout`, `latest_journal_closeout`, and `memory_gate_fail` are gone from `agent-guard.sh`; the `memory pre-final journal gate` test block is removed; `docs/agent-configs/task-journal.md` is still generated and its three content assertions still pass. Allowed remaining failures: none.

- [ ] **Step 4: Verify and commit**

Run:

```bash
bash -n agent-bootstrap/agent-guard.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git diff --check
git add agent-bootstrap/agent-guard.sh scripts/test-bootstrap-multi-agent-project.sh
git diff --cached --check
git commit -m "fix: decouple pre-final from task journals"
```

Expected: guard regressions pass; generated guard matches the canonical snapshot; optional journal content remains.

---

### Task 5: Align Both Budgets and Prove Candidate Migration

**Files:**
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/lib/writers-docs.sh`
- Modify: `agent-bootstrap/lib/writers-runtime.sh`
- Modify: `agent-bootstrap/verify-ai-deps.sh`
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/README.md`

- [ ] **Step 1: Add exact reporter assertions**

After generated doctor and verifier run, assert both outputs contain:

```text
core startup context estimate: ... (gate 4000, amber above 3800)
on-demand full workflow context estimate: ... (gate 6200, amber above 5900)
```

Assert neither live reporter says `budget 6500`. Assert the thresholds appear, not which branch fired: the amber branch is state-dependent and asserting it would break the moment a reduction moves the target back to green. Retain the full gate and add an explicit core gate using the same existing extraction strategy:

```bash
[[ "$core_tokens" -le 4000 ]] || fail "core startup context exceeds 4000: $core_tokens"
[[ "$on_demand_tokens" -le 6200 ]] || fail "full workflow context exceeds 6200: $on_demand_tokens"
```

Do not add a third estimator.

- [ ] **Step 2: Add non-destructive model-profile migration assertions**

Extend the candidate lifecycle with a generated target:

1. bootstrap with `--workflow full`;
2. replace only `docs/agent-configs/model-profiles.json` with the old valid GPT-5.5/GPT-5.4 stable profile and save its checksum;
3. rerun bootstrap;
4. assert the old file checksum is unchanged;
5. assert exactly one managed `model-profiles.json.generated.*` candidate contains Sol, Luna, and Terra values;
6. assert `--status --json` reports pending candidates;
7. run `--apply-candidates`;
8. assert the new route values are promoted and pending count is zero.

Do not add a migration CLI or special-case writer path.

- [ ] **Step 3: Run and observe reporter failures**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL because one or both live reporters still display `6500`, or because context exceeds a locked threshold.

- [ ] **Step 4: Align all live full-budget reporters**

Replace the two-way `6500` check with a three-way band in exactly:

- Codex doctor heredoc in `agent-bootstrap/lib/writers-docs.sh`;
- verifier heredoc in `agent-bootstrap/lib/writers-runtime.sh`;
- canonical verifier snapshot `agent-bootstrap/verify-ai-deps.sh`.

Shape, using each file's own ok/warn/bad helpers:

```bash
if   [[ "$full_tokens" -gt 6200 ]]; then bad  "on-demand full workflow context estimate: ${full_tokens} exceeds gate 6200"
elif [[ "$full_tokens" -gt 5900 ]]; then warn "on-demand full workflow context estimate: ${full_tokens} (gate 6200, amber above 5900); measure after any edit to a counted file"
else                                     ok   "on-demand full workflow context estimate: ${full_tokens} (gate 6200, amber above 5900)"
fi
```

Same shape for core with gate `4000` and amber `3800`. Above the gate is `bad`, not `warn`: if the test will fail, the reporter must not say it in a warning voice. Amber is advisory only and the test gates are unchanged. This addresses SR-001 and removes the false headroom that a single aligned threshold would still leave. Do not rewrite old changelog or design/plan records.

- [ ] **Step 5: Correct active bootstrap documentation**

Verified 2026-08-10: that file contains neither `3000` nor `6500`; the only live stale value was its one-shot release pin, already aligned to the current `VERSION`. A repo-wide grep leaves `CHANGELOG.md:354` as the sole `3000` occurrence, and it is historical and stays. SR-003 therefore needs no documentation edit beyond the pin.

- [ ] **Step 6: Measure and reduce duplication until both gates pass**

Run the main test and record the two values. If full workflow exceeds `6200`, remove duplicated protocol/journal/review text from AGENTS, CLAUDE, mode prompts, command wrappers, Karpathy, or council. Keep canonical contracts complete and never raise a threshold.

- [ ] **Step 6b: Confirm Task 5 completion criteria**

Task 5 is complete only when both reporters print the gate and amber thresholds for both budgets, neither says `budget 6500`, the measured full-workflow value is `<= 6200`, the measured core value is `<= 4000`, and no gate was raised. Record which band each budget is in; the full workflow is expected to be amber at current values. Allowed remaining failures: none. If a budget still fails after removing duplication, stop and report rather than adjusting a gate.

- [ ] **Step 7: Verify and commit**

Run:

```bash
bash -n agent-bootstrap/lib/writers-runtime.sh
bash -n agent-bootstrap/verify-ai-deps.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git diff --check
git add agent-bootstrap/lib/writers-docs.sh agent-bootstrap/lib/writers-runtime.sh agent-bootstrap/verify-ai-deps.sh docs/agent-configs/bootstrap-multi-agent-project/README.md scripts/test-bootstrap-multi-agent-project.sh
git diff --cached --check
git commit -m "fix: align workflow budgets and migration checks"
```

Expected: both reporters say `6200`, runtime drift checks pass, and old profiles remain untouched until candidate application.

---

### Task 6: Document Superpowers Policy and Publish the Bundle Version

**Files:**
- Modify: `README.md`
- Modify: `agent-bootstrap/README.md`
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/README.md`
- Modify: `agent-bootstrap/VERSION`
- Modify: `agent-bootstrap/bootstrap-multi-agent-project.sh`
- Modify: `agent-bootstrap/MANIFEST.md`
- Modify: `agent-bootstrap/harness-kit-one-shot-upgrade.sh`
- Modify: `scripts/test-bootstrap-multi-agent-project.sh`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add Superpowers policy assertions**

Assert root and bundle READMEs state:

- upstream is `https://github.com/obra/superpowers`;
- harness-kit does not install or update it;
- pin a tested release tag and never auto-track `main`;
- review quarterly or for a relevant release;
- inspect the release diff and run two or three representative brainstorming tasks;
- freeze the last validated tag if a release gives no relevant benefit or regresses behavior;
- the reported `v5.1.0` match came from a separate environment comparison and must be reverified before update.

Assert no generated launcher/bootstrap code references `sync-to-codex-plugin`, automatic Superpowers installation, or an update path.

- [ ] **Step 2: Lock the new version in tests**

Change the hard-coded bundle expectation from `2026.07.04.1` to `2026.08.10.1`. Assert these live surfaces agree:

```text
agent-bootstrap/VERSION
agent-bootstrap/bootstrap-multi-agent-project.sh AGENT_BOOTSTRAP_VERSION
agent-bootstrap/MANIFEST.md Version
agent-bootstrap/harness-kit-one-shot-upgrade.sh DEFAULT_REF and help text
README.md one-shot URL
agent-bootstrap/README.md one-shot URL
docs/agent-configs/bootstrap-multi-agent-project/README.md live one-shot URL
```

- [ ] **Step 3: Run and observe policy/version failures**

Run:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: FAIL on old version/pins or missing Superpowers policy.

- [ ] **Step 4: Write the operational policy**

Add the concise policy to root and bundle READMEs. Present `v5.1.0` only as a prior external comparison requiring re-verification, not a repository-proven fact or managed pin. This addresses SR-004.

Do not install the optional Superpowers plugin, modify the active user-level skill, fetch upstream during bootstrap, or add a scheduled updater.

- [ ] **Step 5: Bump live surfaces to `2026.08.10.1`**

Update the seven version/pin surfaces in Step 2. Add a top `CHANGELOG.md` entry covering:

- Claude/Cowork–Codex contracts;
- Sol/Luna/Sol routing with explicit Terra fallbacks;
- strict profile diagnostics and accidental nesting guard;
- journal-independent pre-final;
- corrected `6200` reporter;
- non-destructive candidate migration;
- external pinned-release Superpowers policy.

Leave old changelog entries untouched.

- [ ] **Step 5b: Task 6 Definition of Done**

Focused command:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh 2>&1 | grep -E 'version|pin|Superpowers'
```

In addition to the global Definition of Done: every live version pin equals `2026.08.10.1` and matches `agent-bootstrap/VERSION`; historical statements in `CHANGELOG.md` are unchanged; the Superpowers policy text asserts pin-by-release and no updater. Allowed remaining failures: none.

- [ ] **Step 6: Verify and commit release metadata**

Run:

```bash
bash scripts/test-one-shot-upgrade.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git diff --check
git add README.md agent-bootstrap/README.md docs/agent-configs/bootstrap-multi-agent-project/README.md agent-bootstrap/VERSION agent-bootstrap/bootstrap-multi-agent-project.sh agent-bootstrap/MANIFEST.md agent-bootstrap/harness-kit-one-shot-upgrade.sh scripts/test-bootstrap-multi-agent-project.sh CHANGELOG.md
git diff --cached --check
git commit -m "chore: release collaboration flow bundle"
```

Expected: one-shot derives `2026.08.10.1` from VERSION; all live pins agree; inventory and canonical-home export pass.

---

### Task 7: Run Release Verification and Temporary-Target Protocol Smoke

**Files:**
- Modify only if verification exposes a defect in an already listed implementation file.
- Never create source-repository `AGENTS.md`, `CLAUDE.md`, or `.agents/tasks/` through self-bootstrap.

- [ ] **Step 1: Run syntax and static checks**

Run:

```bash
bash -n agent-bootstrap/bootstrap-multi-agent-project.sh
bash -n agent-bootstrap/agent-guard.sh
bash -n agent-bootstrap/verify-ai-deps.sh
bash -n agent-bootstrap/harness-kit-one-shot-upgrade.sh
bash -n scripts/test-bootstrap-multi-agent-project.sh
bash -n scripts/test-onboarding-fixtures.sh
bash -n scripts/test-one-shot-upgrade.sh
git diff --check
```

Expected: every command exits `0` and diff check prints nothing.

- [ ] **Step 2: Run all affected test entrypoints**

Run:

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-one-shot-upgrade.sh
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: all three scripts print success and exit `0`.

- [ ] **Step 3: Generate a clean temporary full target**

Run:

```bash
SMOKE_TARGET="$(mktemp -d)"
bash agent-bootstrap/bootstrap-multi-agent-project.sh --target "$SMOKE_TARGET" --workflow full
bash agent-bootstrap/bootstrap-multi-agent-project.sh --target "$SMOKE_TARGET" --status --json
(cd "$SMOKE_TARGET" && .codex/codex-mode.sh doctor)
(cd "$SMOKE_TARGET" && scripts/verify-ai-deps.sh --json)
```

Expected:

- no generated drift or pending candidates;
- doctor succeeds with a valid profile and reports `4000`/`6200`;
- verifier JSON has `"fail":0`;
- generated config has no model/effort hard-code;
- generated `.claude/README.md` contains the Cowork pointer.

- [ ] **Step 4: Manually exercise one six-phase packet**

Use task id `collaboration-smoke` and follow only generated contracts:

1. Claude analysis creates `state.json` and `task.md` with verbatim request and secret-redaction rule.
2. Planning review appends pre-coding attempt 1 with `spec_sufficiency: sufficient` and `sufficient_for_coding_model: yes`.
3. Record the target Git commit in `base_commit`; coding appends implementation attempt 1 without a seventh artifact.
4. Fresh reviewing appends final technical review attempt 1 with procedural attestation and reviewed base commit.
5. Claude appends one cross-review checking sufficiency, verification, declarations, policy exception, and scope. This step runs in a Claude session the **user** opens with the packet. Do not shell out to a Claude CLI to satisfy it: design section 2 rules out a runner in either direction. A Codex session reaching this step records the handoff and stops. The two canonical Codex review headings are:

   `## Pre-coding technical review`

   `## Final technical review`
6. User appends the decision and closes state.

Confirm phase/owner/status at each transition, preservation of prior attempts, and no more than six filenames. This smoke does not claim external models, accounts, or sessions were cryptographically proven.

- [ ] **Step 5: Exercise two principal failure paths**

In a second temporary packet:

- set Sol adequacy to `sufficient_for_coding_model: no` and confirm Luna guidance blocks rather than upgrades it;
- set `revision_rounds` to `2` with another `changes_required` verdict and confirm movement to `status: awaiting_user`, `phase: resolution`, `owner: user` rather than a third remediation.

Confirm Cowork without Bash is instructed to record verification as blocked or delegated with a non-empty reason, never pass or silent skip.

- [ ] **Step 6: Verify final scope**

Run:

```bash
git status --short --branch
git diff main...HEAD --stat
git log --oneline --decorate -12
git diff --check main...HEAD
```

Expected:

- only intended files changed relative to `main`;
- pre-existing untracked paths remain unstaged;
- no schema, render change, classifier, root gitignore, Superpowers skill, updater, daemon, or telemetry store was added;
- commits are narrow and diff check is clean.

- [ ] **Step 6b: Task 7 Definition of Done**

Task 7 is the release gate, so the full suite runs here and the stopping rule applies without exception: one fix round, one rerun, then `NEEDS_USER_DECISION`. In addition to the global Definition of Done: every entrypoint in Step 2 passes; the temporary-target smoke run in Steps 3-5 completes all six phases; `git status --short` shows only files in this plan's File Map plus the two preserved untracked paths. Allowed remaining failures: none.

- [ ] **Step 7: Request final independent Claude review**

Give a fresh-context Claude session only the approved design, this plan, `git diff main...HEAD`, and Steps 1–6 evidence. Ask for findings first with P0–P3 severity, file/line evidence, and `APPROVE`, `APPROVE_WITH_CHANGES`, or `BLOCK`.

Ask it specifically to check repository contradictions, false enforcement claims, duplicate context, route precedence, invalid-profile doctor behavior, migration non-destructiveness, and both budget reporters. Do not reopen architecture.

If it finds defects, return to the relevant task, add a regression first, apply the smallest fix, rerun all Step 2 tests, and request one final pass.

---

## Deferred Findings Backlog

P2/P3 findings that do not touch correctness, security, data loss, or approved scope are recorded here and do not extend the task that raised them. Each entry names the raising task, the finding, and the impact.

- CR-S1 (P2): the temporary smoke used a non-canonical pre-coding heading. Future smoke instructions now quote the canonical headings.
- CR-S2 (P2): the initial smoke used an implementation summary as verification evidence. This remediation replaces it with real verifier output.

## Final Acceptance Checklist

- [ ] Canonical contracts define six phases, constrained transitions, six artifacts, exact state fields, Sol adequacy, Luna downgrade-only behavior, final review from `base_commit`, Claude cross-review, two-remediation limit, and user resolution.
- [ ] AGENTS, CLAUDE, Cowork README, commands, and Codex seeds point to canonical documents without duplicating protocol.
- [ ] Cowork works through Folder Instructions and capability probing, without relying on Claude Code hooks.
- [ ] Only planning, coding, and reviewing routes exist; stable profile is Sol/Luna/Sol with explicit Terra fallbacks and `xhigh`.
- [ ] Profile parsing is strict and atomic; launches fail closed, doctor diagnoses then fails, status explains then fails, and help works without profiles.
- [ ] `CODEX_HARNESS_SESSION` catches accidental nesting and is not described as security.
- [ ] Sol coding is a human-opened audit exception, not file-authorized.
- [ ] Pre-final never selects an unrelated journal by `mtime`; optional task-journal guidance remains.
- [ ] Existing targets receive candidates and are not silently overwritten.
- [ ] Doctor and verifier both report `4000` core and `6200` full; measured outputs pass.
- [ ] Superpowers remains external, manual, pinned-release policy only.
- [ ] Version and pins agree at `2026.08.10.1`, tests and smoke pass, and fresh Claude review has no unresolved P0/P1.

## Execution Handoff

Choose one mode after approving this plan:

1. **Subagent-Driven (recommended):** use `superpowers:subagent-driven-development` in this task, one implementation subtask at a time with review between tasks.
2. **Inline Execution:** continue in this task and execute Tasks 1–7 sequentially with the stated test and commit checkpoints.
