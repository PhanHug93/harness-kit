# Seat-first roles

**Status:** approved 2026-11-04 (Part G decisions and Part H); implemented in
release 2026.11.05.1 on branch `feature/seat-first-roles` (from main
`d854770`). The deviations are listed in
`docs/superpowers/plans/seat-first-roles/journal.md`.

Follow-up to `feature/lighter-tests-ci`. The owner decided on 2026-11-04 to
finish the test and CI work first, then to do Parts G and H together in this
branch.

## Part G — @gate plans, seats replace modes

### Why

**@gate sends purely technical findings back to @spec.** This follows from a
deliberate change, not from model behaviour:

- **The original design had @gate plan.** Spec
  `2026-08-10-claude-codex-collaboration-flow-design.md`, §5.1: "`planning`
  serves pre-coding technical review and Codex-authored planning".
- **The one-shot release changed that.** Commit `796e12d`, spec
  `2026-10-15-oneshot-install-update-design.md`, §8, items A1 and B1:
  - @gate got a `technical_review` lock. Today the `gating:*` strings of
    `mode_prompt` (`lib/writers-docs.sh`) read: "Judge the spec … Do not write
    or rewrite the spec, plan, or code."
  - Planning moved away from @gate: "`@build` writes the plan after `@gate`
    approves" (the contracts' `@spec` anchor).
- **So @gate can only judge.** It can only output a verdict, and its only
  exits are `analysis | implementation | resolution`. Every gap, technical
  ones included, becomes a blocker that goes back to @spec.
- **The spec is graded as a technical document.** Three rules make it so:
  - the `task.md` contract asks @spec for interfaces, edge cases, migration
    and implementation boundaries;
  - "every acceptance criterion names its test …; `@gate` checks this before
    coding";
  - the builder check sits with @spec.

**One seat's rules live in three places, and modes overlap seats.** The
places are:

- the mode contracts' "Gates and authority" list and the three mode sections;
- eight long Codex lock prompts (`mode_prompt`, route × flow);
- six Claude mode commands: `/planning`, `/coding` and `/reviewing`, each with
  a `-full-flow` alias.

A seat placed on Claude may also have no entry point at all: there is no
command for @gate.

### Owner decisions (2026-11-04)

- **@gate is the technical gate and the planner.** It writes the plan that
  @build executes. Only spec-level findings go back to @spec.
- **@build's returns depend on the gap.** A gap in the plan goes back to
  @gate; a gap in the spec goes back to @spec. This was the original
  2026-08-10 design.
- **Placement:** after `feature/lighter-tests-ci`, in its own branch.
- **Narrow scope (tier small):** @gate, @build and @verify are one seat.
- **Modes are removed.** `/planning`, `/coding` and `/reviewing` go, and
  their rules move into the seats.
- **Claude Code entry points:** `/spec`, `/gate`, `/build`, `/verify` and
  `/audit`.

### Owner decisions (2026-11-08, after the re-council)

- **Who codes at small and medium is the user's choice per task.** It is the
  packet's @build, on the host the user gives it (`agent-seats.sh set build
  --task <id>` or a preset); no document says Claude codes by itself.
  `tier set` prints the command that moves @build.
- **The council's fixes and the update-verify fix go into the same commit**
  (amend), and the stacked edit-guard branch is rebased on it.

### G1. One contract per seat

`docs/agent-configs/agent-mode-contracts.md` keeps its path. The USER block
`mode-contracts:overrides` survives upgrades, and many files link to the
path. Its title becomes "Seat Contracts".

**Layout:**

- **Shared rules:**
  - transitions, by tier;
  - authority and user decisions;
  - the severity rule;
  - who runs verification;
  - memory;
  - the gate-coding escalation.
- **One section per seat** (`@spec`, `@gate`, `@build`, `@verify`,
  `@audit`, `@owner`), all with the same headings: Duty · Starts when ·
  Writes · Never · Exits · By tier · End of turn.

**Where the old mode rules go.** The sections "Planning Mode", "Coding Mode"
and "Reviewing Mode" are removed, and their few rules move into seats:

- **Planning:** "weigh the request, evidence, constraints, risks and
  verification" goes to @spec and @gate.
- **Coding** goes to @build:
  - code only after approval or a confirmed small or medium tier;
  - focused root-cause patches with fresh verification;
  - "default Claude behavior is handoff" (today in `/coding`).
- **Reviewing** goes to @verify and @audit: one findings-first pass, and fix
  only the exact scope asked.

The heading above the USER block becomes "Project-Specific Seat Overrides".
The marker id does not change.

### G2. @gate writes the plan

Each round @gate does three things, in order:

1. **Check the spec at the level of requirements.** Is it clear? Is anything
   contradictory? Is an owner decision missing?
2. **Write the plan** with `superpowers:writing-plans` (when the skill is
   absent, follow its steps):
   - for a project: `docs/superpowers/plans/<topic>/plan.md`;
   - otherwise: `.agents/tasks/<task-id>/plan.md`.

   The plan names the test for every acceptance criterion. The builder check
   happens here: @gate writes the plan so that @build needs nothing more.
3. **Record the verdict** in `gate-review.md`.

| Finding class | Examples | Who handles it |
|---|---|---|
| `spec` | Unclear or conflicting requirement, missing owner decision, scope change, behaviour the user sees left undefined ("on a missing file, fail or skip?") | Back to @spec (`analysis`) |
| `technical` | Which function or file, race handling, test design, migration steps, performance approach | @gate resolves it in the plan |

**The `gate-review.md` attempt gains three lines:**

```text
plan: <path> | none
blocking_gaps: none | <spec findings only>
resolved_in_plan: none | <technical findings and where the plan answers them>
```

**Verdict.** `sufficient_for_coding_model: no` appears only when at least one
`spec` blocker remains. `agent-tier.py` keeps reading that field, and its
hint "fix the spec" stays correct.

**What @gate never does:** rewrite the spec, or code. The gate-coding
escalation is unchanged.

**@audit's checklist** gains one item: no decision listed in
`resolved_in_plan` contradicts an owner decision or acceptance criterion in
the spec.

### G3. @spec writes less

**Required in `task.md`:**

- the request, verbatim;
- the objective;
- the behaviour the user sees;
- observable acceptance criteria;
- scope and non-goals;
- constraints, including security, privacy and data impact;
- owner decisions;
- assumptions;
- evidence.

**Optional:** interfaces, edge cases, technical migration notes and
implementation boundaries. These are input for @gate and are not graded.

**Moved out of @spec:**

- The rule "each acceptance criterion names its test" goes to the plan (large
  tier). For medium it stays in the `task.md` Criteria, as now.
- @spec no longer runs the builder check.

### G4. Transitions

- `technical_review` · `@gate` → `analysis` (spec blockers only) |
  `implementation` | `resolution`
- `implementation` · `@build` → `verification` | `technical_review` (gap in
  the plan) | `analysis` (gap in the spec) | `resolution`
- The small and medium paths are unchanged.
- `revision_rounds` still counts returns to `implementation`, and at 2 the
  packet goes to `resolution` with `awaiting_user`. So @gate and @build cannot
  loop forever.

### G5. By tier

| Tier | @gate's job | Build | Verify |
|---|---|---|---|
| small (narrow scope) | The implementation seat does all three, in order:<br>• check the request, asking the user only about spec gaps;<br>• write a short plan (in `task.md` when there is one);<br>• code;<br>• run `pre-final --run-verify`. | same seat | same seat |
| medium | @build writes the plan: the `tier-medium.md` sections "Planned files" and "Criteria" are that plan | @build | a fresh @verify |
| large | @gate | @build | @verify, then @audit |

### G6. Entry points

**Claude Code.** Five new commands, written only for `--workflow full`, as
the mode commands were: `.claude/commands/{spec,gate,build,verify,audit}.md`.

- Each command has a description, `argument-hint: <task-id>`, and short
  instructions:
  1. check the packet's seat host (H4);
  2. act as @X for the selected packet, following section @X of the
     contracts and the handoff schema.
- `/council`, `/karpathy`, `/optimize-code`, `/codex:*` and `/doctor` do not
  change.

**Codex.** `mode_prompt` loses its eight lock strings. One `seat_prompt`
builds:

1. the `SEAT LOCK` seed;
2. "follow section @X of `docs/agent-configs/agent-mode-contracts.md` and the
   handoff schema";
3. one sentence for the flow:
   - supervised: read-only, and approve each action;
   - full-flow: project-local execution, with exact approval for external
     paths, installs, commits, pushes and force operations.

The seat-specific rules that today sit inside the lock strings move into the
seat sections: the gate baseline, the verdict-first order, the tier checkpoint
wording and the delta rule for a later round.

**Removed launcher words.** `codex-mode.sh` today also accepts the mode words
as seat aliases (`planning` = @spec, `coding` = @build, `reviewing` =
@verify). They now exit 2 with the new name, for example "removed: use
@spec".

**Unchanged:**

- `run` and `status`, which default to @gate;
- model routing: the internal route names, the model-profile routes, the
  `agent-seats.sh` route aliases and the `CODEX_*_MODEL_OVERRIDE` variables.
  They are configuration, and renaming them would break existing setups.

**Seat descriptions.** `agent-seats.sh` gets new default duty text:

| Seat | New duty |
|---|---|
| @gate | technical gate and plan |
| @build | build from the plan |
| @verify | verification review |

An existing `seats.json` whose duty is still a kit default from an earlier
release shows the new text; a custom duty is kept.

### G7. Docs, verifier, doctor, inventory

The command lists switch to the seat commands in:

- the AGENTS.md and CLAUDE.md text;
- `.claude/README.md`;
- the bundle README;
- the verifier's required files (`verify-ai-deps.sh`, the `.claude/commands`
  list);
- the doctor's file list (`run_doctor` in `lib/writers-docs.sh`).

**Rule inventory.** `scripts/rule-inventory.tsv` moves the affected rules to
their new owner sections and adds the G2 to G4 and H rules. The 7,900-word
ceiling (`scripts/test-rule-inventory.sh`) holds: six command files and eight
long prompts are removed, and five short commands and the seat sections are
added.

### G8. Migration `<release>-remove-mode-commands` (auto)

It works like `2026.11.04.1-remove-legacy-entrypoints.sh`:

- **Unedited copies are removed, with backups.** "Unedited" means
  byte-identical to a fingerprint of what a kit release wrote, for both
  presets. The files are `.claude/commands/{planning,coding,reviewing}.md`
  and their `-full-flow` aliases.
- **Edited copies stay,** and the update summary names them.
- **As built: tracked copies stay too** (CONTRIBUTING's rule for auto
  migrations), unlike the first draft. The install puts `.claude/` in
  `.git/info/exclude`, so tracked copies are rare. When nothing can be
  removed the migration is not selected and prints nothing, so the doctor
  (the verifier) warns about each mode command still there, edited or
  tracked, until it is deleted.

**Tests:**

- the edited, tracked, symlinked and outside-the-root cases;
- mutations, as for the earlier migrations;
- a historical-fixture campaign showing that a project from every release
  tag ends with the seat commands and no mode commands.

### G9. Tests

- **Existing suites that name the mode commands:** one-shot, verification
  evidence, onboarding and matrix. They switch to the seat commands.
- **New checks:**
  - the generated contracts have one section per seat, each with the seven
    headings;
  - each seat command points to its section;
  - `codex-mode.sh @<seat>` prompts point to the same section;
  - `codex-mode.sh planning` exits 2 with the new name;
  - the `gate-review.md` template has `plan`, `blocking_gaps` and
    `resolved_in_plan`.

## Part H — per-packet seats with a trail

Owner request (2026-11-04): a packet may change scope, so the kit must let
seats be arranged per packet. For example, one packet runs every seat on
Claude while another mixes Claude and Codex, and it must be clear which seats
Claude holds and which Codex holds. The user can change the arrangement, and
every change is logged.

Today seats exist only at project level, in `docs/agent-configs/seats.json`.
`agent-seats.sh set` changes them for the whole project, and the only trail
is git history. `codex-mode.sh` does not know which packet it serves.

### H1. Two levels

- **Project:** `docs/agent-configs/seats.json` stays the default and its
  format does not change.
- **Packet:** `.agents/tasks/<id>/seats.json`, schema
  `agent-packet-seats/v1`:

  ```json
  {"schema": "agent-packet-seats/v1", "task": "<id>",
   "seats": {"spec": {"host": "claude"},
             "build": {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh",
                       "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"}},
   "history": [{"at": "<UTC>", "by": "@spec", "change": "snapshot",
                "from": null, "to": "<roster>", "reason": "first tier set"}]}
  ```

  - `seats` holds one occupant per seat (all six). Occupants are validated
    with the project rules against the project `catalog`.
  - The first `tier set` snapshots the project roster into it, so later
    project changes do not move a packet that is already in flight. When the
    project file is missing or invalid, no snapshot is taken and `tier set`
    warns.
  - A packet without this file follows the project roster, as today (old
    packets keep working).

### H2. Commands

All in `scripts/agent-seats.sh`, under the same packet lock that `tier` uses:

- `show --task <id>`: seats grouped by host, for example
  `Claude: @spec @audit · Codex: @gate (gpt-6-astra ultra) @build (gpt-5.6-luna xhigh) @verify (…) · You: @owner`,
  then the seats the packet's tier uses and the H6 facts.
- `use project|claude|codex --task <id> --reason "<user words>"` applies a
  preset:
  - `project`: copy the current project roster again. On a broken packet
    file it moves the file aside (`seats.json.broken-<time>`) and starts a
    new trail with a `repair` entry;
  - `claude`: every seat except @owner on Claude;
  - `codex`: every seat except @owner on Codex. A seat already on Codex keeps
    its model. Another seat takes its own project occupant when that one is
    on Codex (as built: the first draft moved @build onto the reviewer
    model), else the project's @verify occupant, else its @gate occupant,
    when that one is on Codex. When none is, the command refuses and names
    `set <seat> --host codex --model …`.
- `set <seat> --host … [--model … --effort …] --task <id> --reason "<user words>"`
  changes one seat, with the same options and validation as the project-level
  `set`.
- `history --task <id>` prints the log, oldest first.
- `check <seat> --host claude|codex --task <id>` exits 0 when the seat sits
  on that host for the packet. Otherwise it exits 1 and names the host that
  holds it. It is read-only; the Claude seat commands use it. A task with no
  packet folder yet (a new task for `/spec <id>`) follows the project roster.
  Without `--task` it applies the launcher's rule (H4).

`use` and `set` with `--task` need `--reason`, the user's own words. A closed
packet refuses changes.

### H3. Trail

- **History.** Every change appends one entry to the packet file's
  `history`: `at`, `by` (the seat that recorded it), `change` (`snapshot`,
  `preset <name>` or `seat <seat>`), `from`, `to` and `reason`. Entries are
  never rewritten; a change that leaves the roster as it was is not recorded.
- **`user-decision.md`** gets its entry from the active seat, as the existing
  rule requires; the command prints a reminder.
- **Journal.** `tier close` prints the final arrangement and the number of
  changes, and the seat that records closure copies that line into the final
  `task-journal` entry, which is committed.

### H4. The packet arrangement is enforced

- **Codex launcher.** `codex-mode.sh @seat --task <id>`:
  - takes the occupant from the packet file;
  - refuses with exit 2 (as built; the draft said 1) when the seat sits on
    another host for this packet,
    naming the host and the `use`/`set` command that changes it;
  - writes `task=<id>` into its lock, so `run` keeps the packet.

  Without `--task` it applies the handoff schema's selection rule: the only
  packet that is not closed is the packet. With several open packets and no
  `--task`, it follows the project roster and prints one line naming
  `--task`. The Claude `check` applies the same rule.
  - Its @build close-out runs `pre-final --run-verify --task <id>` for the
    packet it launched.
- **Claude seat commands.** Their first step runs
  `scripts/agent-seats.sh check <seat> --host claude --task <id>`. On exit 1
  the seat stops and tells the user which host holds the seat.
- **`state.json` owner.** When the phase changes, `owner` is the host class of
  the new phase's seat in the packet file (the project roster when there is
  none). `agent-tier.py` reads the packet file first when it writes the first
  state.

### H5. Scope changes

Each `tier set` prints the seats the tier uses and the host of each one, for
example
`Seats for medium: @spec claude → @build codex (gpt-5.6-luna) → @verify codex (gpt-6-astra)`.
For small it names the one implementation seat that plans, builds and
verifies.

### H6. Independence

An all-Claude or all-Codex packet is allowed. `show --task` lists the facts:

- `same_host`: a review seat (@gate, @verify, @audit) on the same host as
  @build;
- `model_overlap`: the existing Codex primary-model overlap.

They go to @audit and never block.

### H7. Tests

- the three presets, including the `codex` refusal;
- precedence: packet, then project;
- history is append-only, and a no-op change is not recorded;
- an old packet with no seats file;
- `check` exit codes;
- Codex refuses a seat that belongs to another host, keeps `task=` in its
  lock, and picks the only open packet without `--task`;
- `tier set` takes the snapshot once and prints the seat line;
- `tier close` prints the arrangement line.

## Delivery

Three plans in this branch, one commit at the end with the release bump:

1. **G1–G7:** contracts, seat commands, `seat_prompt`, duty text, docs,
   verifier, doctor, inventory.
2. **G8–G9:** the migration and the suite updates.
3. **H1–H7:** packet seats, commands, enforcement, tier output.
