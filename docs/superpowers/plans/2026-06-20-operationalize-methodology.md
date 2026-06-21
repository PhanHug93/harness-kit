# Operationalize Methodology + Unified Task-Journal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operationalize the three work-modes (Planning/Coding/Reviewing) and two cross-cutting methodologies (Council/Karpathy) into runnable procedures that each append a structured entry to one durable, git-tracked task-journal (`docs/superpowers/plans/<topic>/journal.md`), with a conditional bridge to long-term memory.

**Architecture:** This is a *generator*. Almost all changed content is emitted from heredocs in `agent-bootstrap/lib/writers-docs.sh` (docs, commands, `.codex/codex-mode.sh`) and `agent-bootstrap/lib/onboarding.sh` (plans scaffold). A few runtime scripts are real bundle files copied verbatim (`agent-bootstrap/agent-guard.sh`, `agent-bootstrap/verify-ai-deps.sh`). The journal *artifact* is created on demand by agents, never by the generator. Tests are `scripts/test-onboarding-fixtures.sh` (content assertions via `need_contains`) and `scripts/test-bootstrap-multi-agent-project.sh` (byte-identical regeneration, three-way template mirror via `cmp -s`, and a HARD core token-budget gate ≤4000).

**Tech Stack:** Bash 3.2-compatible shell, heredocs, `python3` for JSON, the kit's own test harness. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-20-operationalize-methodology-design.md`

---

## Conventions for every task

- **Working dir:** repo root `/Users/admin/projects/agent-bootstrap`.
- **TDD loop (content):** add a `need_contains` assertion in `scripts/test-onboarding-fixtures.sh` → run it and watch it FAIL → edit the writer heredoc to add the content → run it and watch it PASS.
- **Integration gate after each content task:** `bash scripts/test-bootstrap-multi-agent-project.sh` (byte-identical regen + template mirror + core ≤4000 hard gate).
- **Generated-output line numbers** (e.g. `codex-mode.sh:486`) refer to the *rendered* file; edit the matching text inside the source heredoc.
- Commit after each task with a conventional message.

## File Structure (what changes and why)

Generator source (heredoc emitters — edit these):
- `agent-bootstrap/lib/writers-docs.sh` — NEW `write_task_journal_doc()`; thicken `agent-mode-contracts.md` (heredoc at `:809`), `karpathy-llm-coding-agent-config.md` (`:958`), `llm-council-agent-workflow.md` (`:979`); NEW `council.md`/`karpathy.md` command heredocs in `write_tool_entrypoints()` (`:1021`); AGENTS.md on-demand list (`:522-533`) + startup pointer; CLAUDE.md on-demand list (`:1034-1042`); `.codex/codex-mode.sh` heredoc in `write_codex_files()` (`:1325`, body from `:1405`): mode_prompt seeds, budget list, doctor list.
- `agent-bootstrap/lib/onboarding.sh` — `docs/superpowers/plans/README.md` heredoc (`:218`): add journal schema + lifecycle.
- `agent-bootstrap/bootstrap-multi-agent-project.sh` — `main()` (`:651-676`): call `write_task_journal_doc` in the `workflow_enabled` branch.

Bundle files (copied verbatim — edit directly):
- `agent-bootstrap/verify-ai-deps.sh` — on-demand budget list (`:216`) + full-workflow required-file list (`:664`).
- `agent-bootstrap/agent-guard.sh` — `pre_final()` (`:753`): one advisory line.
- `agent-bootstrap/policies/agent-context-policy.json` — `recommended_context`.

Template mirror (three-way byte-identical pin — edit both copies in lockstep):
- `agent-bootstrap/templates/workflows/{council,karpathy,three-mode}/README.md`
- `docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/{council,karpathy,three-mode}/README.md`

Tests:
- `scripts/test-onboarding-fixtures.sh` — new `need_contains` assertions in `evaluate_common_onboarding()` (`:83-115`).

Version:
- `agent-bootstrap/VERSION`, `agent-bootstrap/bootstrap-multi-agent-project.sh` `AGENT_BOOTSTRAP_VERSION` (`:8`), `agent-bootstrap/MANIFEST.md` (`:3`).

---

### Task 1: Branch + task-journal DOC + wire into generator

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` (add `write_task_journal_doc()`)
- Modify: `agent-bootstrap/bootstrap-multi-agent-project.sh:651-676` (call it)
- Modify: `agent-bootstrap/verify-ai-deps.sh:216,664`
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Create the working branch** (repo rule: never work on `main` directly)

```bash
git checkout -b feat/operationalize-methodology-journal
```

- [ ] **Step 2: Write the failing assertion** — in `scripts/test-onboarding-fixtures.sh`, inside `evaluate_common_onboarding()` after line 115, add:

```bash
  local task_journal="$dir/docs/agent-configs/task-journal.md"
  need_contains "$(cat "$task_journal" 2>/dev/null)" "## <ISO-8601 date> · <mode> · <task-id>" "task journal doc schema header"
  need_contains "$(cat "$task_journal" 2>/dev/null)" "status: in-progress | decided | blocked | done" "task journal doc status enum"
  need_contains "$(cat "$task_journal" 2>/dev/null)" "newest" "task journal doc resume/discovery rule"
```

- [ ] **Step 3: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh`
Expected: FAIL — `task journal doc schema header missing ...` (file not generated yet).

- [ ] **Step 4: Add the writer** — in `agent-bootstrap/lib/writers-docs.sh`, add this function (place it just before `write_tool_entrypoints()` at `:1021`):

````bash
write_task_journal_doc() {
  write_file "$TARGET_DIR/docs/agent-configs/task-journal.md" <<'EOF'
# Task Journal (working memory)

The task journal is Layer 1 working memory: a durable, git-tracked, append-only
record of one in-flight task. It survives context compaction (re-read the file)
and doubles as a PR-reviewable decision record. It does NOT replace agentmemory /
native memory (Layer 2, long-term distilled knowledge); the journal feeds it.

## Where

`docs/superpowers/plans/<topic>/journal.md` — one per task/topic, reusing the
`docs/superpowers/plans/` slug convention. Create it on demand when work starts;
bootstrap never generates it.

## Entry schema (append-only)

Append a new entry per mode step; never edit a prior entry. A status change is a
NEW appended entry.

    ## <ISO-8601 date> · <mode> · <task-id>
    - status: in-progress | decided | blocked | done
    - context: <1-2 lines: where we are now>
    - <mode-specific body>
    - next-action: <single next concrete step>
    - memory: <saved-id | none | n/a (no backend)>

## Close-out (Layer 1 + Layer 2)

At a decided/done close-out: (1) if a durable fact emerged AND a memory backend
is available, `memory_save`/`lesson_save` with metadata (repo, branch, files,
evidence, confidence) and capture the id; (2) then append the entry embedding
that id on the `memory:` line (`none` if no durable fact, `n/a` if no backend).
In-progress checkpoints append immediately with `memory: n/a`.

## Resume after compaction

The active journal is the `docs/superpowers/plans/*/journal.md` whose latest
entry is `status: in-progress`, newest by commit/mtime. Read it before
substantive work to recover the plan and next-action. Zero in-progress ⇒ no
active task, start fresh; multiple ⇒ pick newest and confirm against current
context.
EOF
}
````

- [ ] **Step 5: Call it in the generator** — in `agent-bootstrap/bootstrap-multi-agent-project.sh`, in `main()` inside the `if workflow_enabled; then` block (around `:669-672`, next to `write_doubt_driven_skill`/`write_project_onboarding`), add:

```bash
    write_task_journal_doc
```

- [ ] **Step 6: Count the DOC in the on-demand budget + require it** — in `agent-bootstrap/verify-ai-deps.sh`, add to the `full_tokens` list (after the `llm-council-agent-workflow.md \` line near `:222`):

```bash
    docs/agent-configs/task-journal.md \
```

and add the same path to the full-workflow required-file `for path in` list at `:664` (after `llm-council-agent-workflow.md \`):

```bash
    docs/agent-configs/task-journal.md \
```

- [ ] **Step 7: Run the assertion; expect PASS**

Run: `bash scripts/test-onboarding-fixtures.sh`
Expected: PASS.

- [ ] **Step 8: Run the drift gate**

Run: `bash scripts/test-bootstrap-multi-agent-project.sh`
Expected: PASS (byte-identical regen; core budget still ≤4000 — this DOC is on-demand, not core).

- [ ] **Step 9: Commit**

```bash
git add agent-bootstrap/lib/writers-docs.sh agent-bootstrap/bootstrap-multi-agent-project.sh agent-bootstrap/verify-ai-deps.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: add task-journal working-memory doc and wire it into full workflow"
```

---

### Task 2: Thicken mode-contracts with per-mode "Output" close-out

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` (the `agent-mode-contracts.md` heredoc at `:809`)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertion** — in `evaluate_common_onboarding()`, add (after the Task 1 assertions):

```bash
  local mode_contracts="$dir/docs/agent-configs/agent-mode-contracts.md"
  need_contains "$(cat "$mode_contracts" 2>/dev/null)" "task-journal.md" "mode contracts reference the journal close-out"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh`
Expected: FAIL — `mode contracts reference the journal close-out missing 'task-journal.md'`.

- [ ] **Step 3: Add an "Output" block to each of the three modes** — in the `agent-mode-contracts.md` heredoc, append to **Planning Mode** (after its stop conditions), **Coding Mode** (after coding rules), and **Reviewing Mode** (after its stop conditions) a block. Planning:

```markdown
Output:
- Append a Planning journal entry per `docs/agent-configs/task-journal.md`
  (assumptions, affected components, risks, verification plan, stop-conditions
  hit, handoff target). At decided/done, run the close-out (conditional
  memory_save → entry). If resuming, read the active journal first.
```

Coding (same shape, body = `changed files + rationale; tests added/run; verification result; remaining risks`). Reviewing (body = `findings (severity, file:line); open questions; verification gaps; verdict`).

- [ ] **Step 4: Run the assertion; expect PASS**

Run: `bash scripts/test-onboarding-fixtures.sh`
Expected: PASS.

- [ ] **Step 5: Run the drift gate + commit**

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
git add agent-bootstrap/lib/writers-docs.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: add journal close-out output to planning/coding/reviewing contracts"
```

---

### Task 3: Operationalize Council doc + add `/council` command

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` (`llm-council-agent-workflow.md` heredoc at `:979`; new command heredoc in `write_tool_entrypoints()` near the other commands, after `reviewing.md` at `:1207`)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertions**

```bash
  local council_doc="$dir/docs/agent-configs/llm-council-agent-workflow.md"
  need_contains "$(cat "$council_doc" 2>/dev/null)" "task-journal.md" "council doc has journal close-out"
  need_contains "$(cat "$dir/.claude/commands/council.md" 2>/dev/null)" "llm-council-agent-workflow.md" "council command points to the doc"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh`
Expected: FAIL on both.

- [ ] **Step 3: Make the council doc runnable** — in the `llm-council-agent-workflow.md` heredoc, after the existing roles/chair content, append:

```markdown
## Procedure

1. State the council question and why it crosses a high-risk threshold
   (architecture, migration, data loss, security/privacy, permissions, billing,
   release, performance, concurrency, or unclear root cause).
2. Each role gives a position with evidence (file:line) and a confidence.
3. Cross-review the strongest assumptions and missing evidence.
4. Chair synthesizes: selected approach, rejected alternatives, preserved
   minority objections, executor, verification commands, stop-conditions.
5. Close out: append a Council entry per `docs/agent-configs/task-journal.md`
   recording all of step 4. If the decision is durable and a backend is
   available, memory_save it first and embed the id on the entry's `memory:`
   line.

## Stop conditions

- Stop and ask the user when the council cannot reach a verifiable position from
  repo evidence.
- Escalate any credible P0/P1 security, privacy, data-loss, billing, release, or
  compliance risk even if the majority deems it unlikely; record it as a
  preserved minority objection.
```

- [ ] **Step 4: Add the command** — in `write_tool_entrypoints()`, after the `reviewing.md` heredoc (`:1207`), add:

````bash
  write_file "$TARGET_DIR/.claude/commands/council.md" <<'EOF'
---
description: Run the hybrid council methodology and record the verdict in the task journal.
---

# Council

Follow `docs/agent-configs/llm-council-agent-workflow.md`. Council is advisory
until verified; the Chair preserves minority objections and one executor owns any
follow-up patch. Close out by appending a Council entry per
`docs/agent-configs/task-journal.md` (question, positions, selected approach,
rejected alternatives, preserved minority objections, executor, verification,
stop-conditions), and conditionally `memory_save` the decision.
EOF
````

- [ ] **Step 5: Run assertions; expect PASS, then drift gate + commit**

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git add agent-bootstrap/lib/writers-docs.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: operationalize council workflow with runnable steps and /council command"
```

---

### Task 4: Operationalize Karpathy doc + add `/karpathy` command

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` (`karpathy-llm-coding-agent-config.md` heredoc at `:958`; new command heredoc after `council.md` from Task 3)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertions**

```bash
  local karpathy_doc="$dir/docs/agent-configs/karpathy-llm-coding-agent-config.md"
  need_contains "$(cat "$karpathy_doc" 2>/dev/null)" "task-journal.md" "karpathy doc has journal close-out"
  need_contains "$(cat "$dir/.claude/commands/karpathy.md" 2>/dev/null)" "karpathy-llm-coding-agent-config.md" "karpathy command points to the doc"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh` → FAIL on both.

- [ ] **Step 3: Make the karpathy doc runnable** — append to the `karpathy-llm-coding-agent-config.md` heredoc:

```markdown
## Procedure

1. Gather context first: read the relevant files, nearby tests, project rules,
   and current diffs. State what you read.
2. State explicit assumptions and risks before editing.
3. Make one small coherent patch; no unrelated refactors.
4. Verify with tests or a justified substitute; review the final diff.
5. Close out: append a Karpathy entry per `docs/agent-configs/task-journal.md`
   (context gathered, assumptions, risks, patch scope, evidence/verification).
   No success claim without evidence.

## Stop conditions

- Stop if you cannot identify the root cause; do not prompt-code until a symptom
  disappears. Record the unknown under the entry's next-action.
```

- [ ] **Step 4: Add the command** — after the `council.md` heredoc:

````bash
  write_file "$TARGET_DIR/.claude/commands/karpathy.md" <<'EOF'
---
description: Apply the context-first Karpathy coding discipline and record it in the task journal.
---

# Karpathy

Follow `docs/agent-configs/karpathy-llm-coding-agent-config.md`: context first,
small coherent patches, explicit assumptions/risks, evidence before success
claims. Close out by appending a Karpathy entry per
`docs/agent-configs/task-journal.md`.
EOF
````

- [ ] **Step 5: Run assertions; expect PASS, then drift gate + commit**

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git add agent-bootstrap/lib/writers-docs.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: operationalize karpathy workflow with runnable steps and /karpathy command"
```

---

### Task 5: AGENTS.md resume pointer + on-demand listings (AGENTS.md + CLAUDE.md)

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` — AGENTS.md heredoc startup block (`:509-520`) + on-demand list (`:522-533`); CLAUDE.md on-demand list (`:1034-1042`)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertion** (note: existing test at `:114` already requires `Read on demand`; we add the journal pointer)

```bash
  need_contains "$agents" "task-journal.md" "AGENTS.md references the task journal"
```

(`$agents` is already loaded in `evaluate_common_onboarding`; reuse it.)

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh` → FAIL.

- [ ] **Step 3: Add one resume pointer to the startup block** — in the AGENTS.md heredoc startup list (the `- The output of scripts/agent-guard.sh preflight ...` area near `:518`), add a single line (keep it ONE line — AGENTS.md is in the hard-gated ≤4000 core):

```markdown
- If resuming a task, read its journal first: the newest in-progress
  `docs/superpowers/plans/*/journal.md` (see `docs/agent-configs/task-journal.md`).
```

- [ ] **Step 4: Add the DOC to both on-demand lists** — in the AGENTS.md "Read on demand:" list (`:522-533`) add:

```markdown
- `docs/agent-configs/task-journal.md` when recording or resuming task
  working-memory.
```

and add the equivalent line to the CLAUDE.md "Read on demand:" list (`:1034-1042`).

- [ ] **Step 5: Run assertion; expect PASS, then drift gate (core budget is the key check)**

Run: `bash scripts/test-onboarding-fixtures.sh` → PASS
Run: `bash scripts/test-bootstrap-multi-agent-project.sh`
Expected: PASS — verify the "core startup context too large" gate (`:820-825`) does NOT fire; the added core line is ~1 sentence.

- [ ] **Step 6: Commit**

```bash
git add agent-bootstrap/lib/writers-docs.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: add journal resume pointer and on-demand listing to AGENTS.md/CLAUDE.md"
```

---

### Task 6: Codex parity — mode_prompt seeds, budget list, doctor list

**Files:**
- Modify: `agent-bootstrap/lib/writers-docs.sh` — `write_codex_files()` heredoc (`:1405` onward). Generated-output anchors: `mode_prompt` seeds `codex-mode.sh:486-505`, `doctor_context_budget` list `:230-241`, `run_doctor` file list `:262-293`.
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertions**

```bash
  local codex_mode="$dir/.codex/codex-mode.sh"
  need_contains "$(cat "$codex_mode" 2>/dev/null)" "task-journal.md" "codex seeds reference the journal"
  need_contains "$(cat "$codex_mode" 2>/dev/null)" "docs/agent-configs/task-journal.md" "codex doctor lists the journal doc"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh` → FAIL.

- [ ] **Step 3: Append the journal instruction to all six mode_prompt seeds** — inside the `mode_prompt()` heredoc text (the six `printf '%s' "MODE LOCK: ..."` strings), append to each seed string:

```
 Read the active task journal (newest in-progress docs/superpowers/plans/*/journal.md) before substantive work, and append a journal entry per docs/agent-configs/task-journal.md at close-out.
```

- [ ] **Step 4: Add the DOC to the codex budget list** — in the `doctor_context_budget` `full_tokens` list (heredoc text matching `codex-mode.sh:236-241`), after `docs/agent-configs/llm-council-agent-workflow.md \`:

```
    docs/agent-configs/task-journal.md \
```

- [ ] **Step 5: Add the journal doc + new commands to the doctor file list** — in the `run_doctor` `for path in ...` list (heredoc text matching `codex-mode.sh:262-293`), add:

```
    docs/agent-configs/task-journal.md \
    .claude/commands/council.md \
    .claude/commands/karpathy.md \
```

- [ ] **Step 6: Run assertion; expect PASS, then verify generated codex doctor runs**

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS. The drift test's generated-target smoke already runs `bash -n .codex/codex-mode.sh`; confirm no syntax error from the heredoc edits.

- [ ] **Step 7: Commit**

```bash
git add agent-bootstrap/lib/writers-docs.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: codex parity — journal step in mode seeds, budget and doctor lists"
```

---

### Task 7: Policy `recommended_context`

**Files:**
- Modify: `agent-bootstrap/policies/agent-context-policy.json`
- Test: `scripts/test-onboarding-fixtures.sh` (verifier smoke already runs the policy validation)

- [ ] **Step 1: Confirm the schema item type** (the current `recommended_context` is an array of path strings)

Run: `python3 -m json.tool agent-bootstrap/schemas/agent-context-policy-v1.schema.json | grep -A8 '"recommended_context"'`
Expected: items are `{"type": "string"}` (string paths). If items are objects, use `{"path": "...", "reason": "..."}` instead in Step 2.

- [ ] **Step 2: Add the journal DOC** — in `agent-bootstrap/policies/agent-context-policy.json`, add to the `recommended_context` array (after `docs/agent-configs/project-onboarding.md`):

```json
    "docs/agent-configs/task-journal.md"
```

- [ ] **Step 3: Validate JSON + schema + verifier**

```bash
python3 -m json.tool agent-bootstrap/policies/agent-context-policy.json >/dev/null && echo "JSON ok"
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS — the generated `context-policy.json` is a verbatim copy, and `verify-ai-deps.sh` validates `recommended_context` entries as safe relative paths.

- [ ] **Step 4: Commit**

```bash
git add agent-bootstrap/policies/agent-context-policy.json
git commit -m "feat: add task-journal doc to recommended context policy"
```

---

### Task 8: `pre-final` advisory line

**Files:**
- Modify: `agent-bootstrap/agent-guard.sh:753-761` (`pre_final()`)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertion**

```bash
  need_contains "$(cat "$dir/scripts/agent-guard.sh" 2>/dev/null)" "docs/superpowers/plans/*/journal.md" "pre-final advises on the journal"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh` → FAIL.

- [ ] **Step 3: Add the advisory line** — in `agent-bootstrap/agent-guard.sh`, in `pre_final()` immediately after the existing success print (`:761`), add:

```bash
  printf 'agent-guard: note — for a long or multi-step task, ensure the active journal (docs/superpowers/plans/*/journal.md) carries an up-to-date entry.\n'
```

(This is advisory only — it does not change the exit code and performs no "substantive change" detection.)

- [ ] **Step 4: Run assertion; expect PASS; sanity-run the guard**

```bash
bash scripts/test-onboarding-fixtures.sh
bash agent-bootstrap/agent-guard.sh --help >/dev/null 2>&1 || true
bash scripts/test-bootstrap-multi-agent-project.sh
```

Expected: PASS (the guard snapshot still matches the generated copy; `pre_final` exit code unchanged).

- [ ] **Step 5: Commit**

```bash
git add agent-bootstrap/agent-guard.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: add advisory journal reminder to agent-guard pre-final"
```

---

### Task 9: plans/README.md journal schema + lifecycle

**Files:**
- Modify: `agent-bootstrap/lib/onboarding.sh:218-224` (the `docs/superpowers/plans/README.md` heredoc)
- Test: `scripts/test-onboarding-fixtures.sh:83-115`

- [ ] **Step 1: Write the failing assertion**

```bash
  need_contains "$(cat "$dir/docs/superpowers/plans/README.md" 2>/dev/null)" "journal.md" "plans README documents the journal"
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `bash scripts/test-onboarding-fixtures.sh` → FAIL.

- [ ] **Step 3: Extend the heredoc** — append to the `plans/README.md` heredoc:

```markdown

## Task journal

Each task keeps a working-memory journal at `<topic>/journal.md` — append-only,
one entry per mode step, following the schema in
`docs/agent-configs/task-journal.md`. It survives context compaction and is the
task's durable decision record. Keep entries concise; the journal stays in place
when the task lands.
```

- [ ] **Step 4: Run assertion; expect PASS, then drift gate + commit**

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-bootstrap-multi-agent-project.sh
git add agent-bootstrap/lib/onboarding.sh scripts/test-onboarding-fixtures.sh
git commit -m "feat: document the task journal in the plans scaffold README"
```

---

### Task 10: Reconcile vestigial workflow stubs (three-way mirror)

**Files (edit both copies of each, identically):**
- Modify: `agent-bootstrap/templates/workflows/{council,karpathy,three-mode}/README.md`
- Modify: `docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/{council,karpathy,three-mode}/README.md`

- [ ] **Step 1: Replace each stub with a one-line pointer.** Council (both copies, identical content):

```markdown
# Council Workflow

Operationalized as `docs/agent-configs/llm-council-agent-workflow.md` and the
`/council` command. This template is a pointer only.
```

Karpathy (both copies):

```markdown
# Karpathy-Style LLM Coding Workflow

Operationalized as `docs/agent-configs/karpathy-llm-coding-agent-config.md` and
the `/karpathy` command. This template is a pointer only.
```

Three-mode (both copies):

```markdown
# Three-Mode Workflow

Operationalized in `docs/agent-configs/agent-mode-contracts.md` (Planning,
Coding, Reviewing). This template is a pointer only.
```

- [ ] **Step 2: Run the drift gate — the `cmp -s` mirror check enforces lockstep**

Run: `bash scripts/test-bootstrap-multi-agent-project.sh`
Expected: PASS. If it fails with `bundle template ... drifted` or `generated template ... drifted`, a copy is out of sync — make all three (docs source, bundle, regenerated target) identical.

- [ ] **Step 3: Commit**

```bash
git add agent-bootstrap/templates/workflows docs/agent-configs/bootstrap-multi-agent-project/templates/workflows
git commit -m "chore: reduce vestigial workflow template stubs to pointers"
```

---

### Task 11: Version bump + full verification

**Files:**
- Modify: `agent-bootstrap/VERSION`
- Modify: `agent-bootstrap/bootstrap-multi-agent-project.sh:8` (`AGENT_BOOTSTRAP_VERSION`)
- Modify: `agent-bootstrap/MANIFEST.md:3`

- [ ] **Step 1: Read the current version**

Run: `cat agent-bootstrap/VERSION`
Expected: the previous release before this hardening pass; final release target is `2026.06.21.2`.

- [ ] **Step 2: Bump all three in lockstep** — set `agent-bootstrap/VERSION` to `2026.06.21.2`; set `AGENT_BOOTSTRAP_VERSION="2026.06.21.2"` at `bootstrap-multi-agent-project.sh:8`; set `Version: ` `2026.06.21.2`` `` in `MANIFEST.md:3`.

- [ ] **Step 3: Confirm `--version` matches**

Run: `bash agent-bootstrap/bootstrap-multi-agent-project.sh --version`
Expected: `bootstrap-multi-agent-project 2026.06.21.2 (stable)`.

- [ ] **Step 4: Full gate — drift, fixtures, and a real generate+verify**

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
bash scripts/test-onboarding-fixtures.sh
TMP="$(mktemp -d)"; printf '{"name":"demo"}\n' > "$TMP/package.json"
bash agent-bootstrap/bootstrap-multi-agent-project.sh --target "$TMP" --workflow full >/dev/null
( cd "$TMP" && bash scripts/verify-ai-deps.sh ) | grep -iE 'token|FAIL|warn' || true
( cd "$TMP" && bash .codex/codex-mode.sh doctor ) | grep -iE 'token|FAIL|missing' || true
rm -rf "$TMP"
```

Expected: both test scripts PASS; verifier prints core ≤4000 (ok) and on-demand ≤6500 (ok or an accepted warn); no `missing file` for `task-journal.md`, `council.md`, `karpathy.md`.

- [ ] **Step 5: Update CHANGELOG (follow existing style at `CHANGELOG.md`)** — add a release entry summarizing: concrete journal target wording, restored on-demand budget headroom, robust upgrade safeguards, operationalized methodology procedures, unified task-journal (Layer 1) with conditional agentmemory bridge (Layer 2), codex parity, advisory pre-final, stub reconciliation.

- [ ] **Step 6: Commit**

```bash
git add agent-bootstrap/VERSION agent-bootstrap/bootstrap-multi-agent-project.sh agent-bootstrap/MANIFEST.md CHANGELOG.md
git commit -m "release: agent-bootstrap 2026.06.21.2"
```

---

## Self-Review (spec coverage)

- Journal artifact + schema → Task 1 (doc), Task 9 (plans README). ✓
- Two-layer memory + close-out ordering (memory_save → append) → Task 1 doc, woven into Tasks 2-4 procedures. ✓
- Resume/discovery rule → Task 1 doc + Task 5 AGENTS.md pointer. ✓
- 3 modes operationalized → Task 2. Council/Karpathy → Tasks 3-4. ✓
- Multi-tool parity (Codex seeds + doctor + budget) → Task 6; Claude commands → Tasks 3-4; tool-agnostic docs → Tasks 2-4. ✓
- Budget DOC-not-artifact, both lists → Task 1 (verify-ai-deps) + Task 6 (codex-mode). ✓
- Policy recommended_context → Task 7. ✓
- Advisory pre-final → Task 8. ✓
- Stub reconciliation (3-way pin) → Task 10. ✓
- Version/MANIFEST + full verify + CHANGELOG → Task 11. ✓
- GEMINI.md excluded (no on-demand list) → confirmed, not edited. ✓

No placeholders; every content step shows paste-ready text; command/path/identifier names are consistent across tasks (`write_task_journal_doc`, `task-journal.md`, `journal.md`).
