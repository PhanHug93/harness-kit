# Seat-first roles — journal

Spec: `docs/superpowers/specs/2026-11-04-seat-first-roles-design.md`.
Branch `feature/seat-first-roles`, from main `d854770` (release 2026.11.04.2).
Three plans, one commit at the end with the release bump.

## 2026-11-04 — why and what the owner chose

- **@gate bounced technical findings to @spec.** The one-shot release
  (`796e12d`) made @gate review-only, so every gap, technical ones included,
  went back to the spec.
- **Owner decisions (Part G):**
  - @gate writes the plan; only spec findings go back to @spec;
  - @build sends a plan gap to @gate and a spec gap to @spec;
  - at tier small one seat checks, plans, builds and verifies;
  - `/planning`, `/coding` and `/reviewing` go; `/spec`, `/gate`, `/build`,
    `/verify` and `/audit` replace them.
- **Part H** (per-packet seats with a trail) was approved on 2026-11-04 with
  its details: presets `project|claude|codex`, `check`, launcher `--task`.

## Plan 1 — seat contracts, seat commands, one Codex prompt (G1–G7)

- **Seat Contracts.** `agent-mode-contracts.md` keeps its path and USER block.
  - Shared rules: flow by tier, authority, verification, tier checkpoint,
    report style.
  - One section per seat with the same seven labels: Duty, Starts when,
    Writes, Never, Exits, By tier, End of turn.
  - @gate checks the spec as requirements, writes the plan and records the
    verdict. @build's Exits add `technical_review` (plan gap) and `analysis`
    (spec gap). At small, one seat checks, plans, codes and runs pre-final.
- **Handoff reference.** `gate-review.md` gains `plan`, `blocking_gaps`
  (spec findings only) and `resolved_in_plan`. Each review section now holds
  its own checklist: the finding classes (gate), the re-run rule (verify),
  the audit checklist, and the gate-coding escalation and fixture rules
  (implementation).
- **`task.md`.** Required: objective, user-visible behaviour, observable
  criteria, scope, constraints, owner decisions, assumptions, evidence.
  Interfaces, edge cases and implementation notes are optional input for
  @gate.
- **Claude.** Five seat commands; the six mode files are no longer written.
- **Codex.** One `seat_prompt` replaces the eight lock strings; the seed points
  to the seat's section. `planning`, `coding` and `reviewing` exit 2 with the
  seat to use.
- **Duty text.** @gate "technical gate and plan", @build "build from the
  plan", @verify "verification review"; a `seats.json` that still has an
  older kit's text shows the new one.
- **Budgets.** Three limits held:

  | Limit | Before | After | Bound |
  |---|---|---|---|
  | Agent-doc words (full) | 7,899 | 7,817 | 7,900 |
  | Kit on-demand tokens | 5,170 | 5,183 | 5,203 (ratchet) |
  | Fresh on-demand total | 5,838 | 5,849 | 5,900 (amber) |

  The first full draft of the contracts (1,306 words) broke all three. What
  made room:
  - the transition list became each seat's Exits plus a flow-by-tier list;
  - the review checklists moved to their reference sections (only the
    largest one counts);
  - the tier checkpoint's one-line prompt moved into AGENTS.md "Pick a tier";
  - plain labels instead of bold;
  - shorter Codex and Claude READMEs.
- **Tests.**
  - New: `scripts/test-seat-contracts.sh` (fast, ci-4). It checks the seat
    sections and labels, the seat commands, the removed mode files, the Codex
    seeds, the removed words and the `gate-review.md` lines.
  - Updated: verification evidence, the seats launcher, the drift contracts
    group, onboarding, one-shot and matrix. One-shot and matrix cases on an
    old install now patch `.claude/commands/codex/rescue.md`, which both kits
    write.
- **Runs.**
  - The fast tier passed 23/23 in 423 s; onboarding, verification evidence
    and one-shot ran separately and passed.
  - matrix and the drift groups contracts, lifecycle and inventory passed in
    357 s.

## Plan 2 — the old mode commands (G8)

- **Migration `2026.11.05.1-remove-mode-commands` (auto).**
  - It removes `/planning`, `/coding`, `/reviewing` and their `-full-flow`
    aliases, with their baseline copies and a backup, when a copy is unedited
    and untracked.
  - "Unedited" means byte-equal to one of 24 prints, taken by generating the
    full preset of every release tag (v2026.06.17.1 to v2026.11.04.2, two
    project names each; the files do not depend on the project), or equal to
    the baseline copy.
  - Edited, linked and outside copies stay. A tracked unedited copy stays
    too, and the update names it: "tracked by git, unedited: git rm it".
- **Deviation from the spec: tracked copies stay.** The spec asked the auto
  migration to remove unedited tracked copies too. `CONTRIBUTING.md` allows
  an auto migration to delete only files that are not tracked; deleting a
  tracked file needs a `decision` migration (`--accept`). The precedent
  `2026.11.04.1-remove-legacy-entrypoints` keeps tracked copies the same way.
  A decision migration for tracked copies can follow if the owner wants it.
- **Tests.**
  - `test-harness-migrations.sh`: needed, apply, not needed, a second apply
    that changes nothing, kept copies (edited, tracked with the hint,
    linked), and no selection on a fresh project.
  - Two mutations, both caught: removing tracked copies, skipping the
    backup.
  - Historical campaign (`test-agent-seats-migration.py`): after the update,
    the projects from v2026.08.10.1 and v2026.09.07.1 have the five seat
    commands and no mode commands (50/50 checks). The other tags are covered
    through the prints, not by a full update each.
- **Runs.** migrations 139 s; one-shot-upgrade 238 s; oneshot, matrix and
  drift install passed again with the migration in place (262 s).

## Plan 3 — seats per packet (H1–H7)

- **Packet file.** `.agents/tasks/<id>/seats.json` (`agent-packet-seats/v1`)
  holds the six occupants and an append-only `history`.
  - The first `tier set` copies the project roster there (`snapshot`); later
    project changes do not move the packet.
  - A packet without the file follows the project roster.
  - Occupants are checked with the project rules and catalog.
- **Commands** (`scripts/agent-seats.sh`):
  - `show|use|set|history|check|resolve --task <id>`, `open-packet`, and
    `tier-line`/`close-line` for `agent-tier.py`.
  - Presets: `project` copies the roster again; `claude` puts every seat but
    @owner on Claude; `codex` puts every seat but @owner on Codex.
  - A change needs `--reason` (the user's words). A closed packet refuses
    changes, and a change that alters nothing is not logged.
  - Writes take the packet folder's `flock`, the same lock `agent-tier.py`
    takes; `agent-tier.py` calls the helper after releasing its own lock.
- **Deviation: the `codex` preset.** In the approved detail, a seat moving to
  Codex took the project's @verify occupant, else @gate's. Trying it moved
  @build onto the reviewer model. A seat now first takes its own project
  occupant when that one is on Codex, then @verify's, then @gate's.
- **Tier output.** `tier set` prints `Seats for <tier>: ...` (small: "which
  plans, builds and verifies"). `tier close` prints `Seats at close: ...
  (N changes)` for the final journal entry. The first state's `owner`
  follows the packet's @spec.
- **Codex launcher.**
  - `--task <id>` may appear in any order with the flow flag.
  - Without it, `run` uses the lock's `task=`, else the only open packet. With
    several open packets it prints a note and uses the project roster.
  - The seed names the packet. A seat the packet gives another host is
    refused, naming the packet and the `--task` form of `set`.
- **Claude seat commands.** Each one runs
  ``!`scripts/agent-seats.sh check <seat> --host claude` `` (with
  `allowed-tools`) and obeys a `STOP`.
  - The task id is not put into the shell line, so a typed argument cannot
    inject a command.
  - `check` uses the only open packet. With several, its output says to run
    it again with `--task`.
- **Docs.**
  - New handoff-reference section "Packet seats"; one line each in AGENTS.md
    and `.codex/README.md`; both READMEs.
  - To stay under 7,900 words: removed tier-medium's `## Done` (AGENTS.md
    step 4 says it), CLAUDE.md's host-model line (the roster says it) and a
    README comment; shortened seat-command descriptions.
- **Tests.**
  - New `scripts/test-packet-seats.sh` (fast, ci-4, about 15 s). It covers:
    - snapshot once, show, presets and no-op, one seat, `codex` choices;
    - check, including `STOP` with several open packets;
    - usage errors, the append-only log, the `codex` refusal, an old
      packet;
    - the launcher: seed, lock, `run`, exit 2, default packet, `status`
      and the packet's overlap;
    - repair after a catalog change, a linked seats file;
    - the state owner, close.
  - Three mutations, all caught: snapshot on every set, launcher ignores the
    packet, history rewritten.
- **Review.** A read-only review of the packet code found nine issues; all
  are fixed:
  - The Claude check now passes `--task "$ARGUMENTS"`. `allowed-tools` allows
    only `scripts/agent-seats.sh check`, so a compound command still needs
    approval.
  - With several open packets and no task, `check` answers `STOP` and asks
    for `--task`.
  - The launcher's `model_overlap` fact comes from the packet.
  - A catalog change no longer locks a packet. Reading checks only the shape;
    occupants are checked on a change and at launch; `show` warns and names
    `use project`.
  - The `STOP` hint can be pasted (`--model <id>`, double quotes).
  - `status` names the locked packet, and the fallback hint keeps `--task`.
  - Only an explicit `--task` goes into the lock; a lock whose packet folder
    is gone is ignored.
  - A host-controlled seat that only loses a `model` field is not logged as
    a change.
  - A linked packet `seats.json` is refused.
  - `tier set` warns when a full install has no `seats.json`.
- **Kept: the launcher refuses with exit 2,** the same code as the existing
  refusal for the project roster; the spec said 1.
- **Budgets at the end:**

  | Limit | Value | Bound |
  |---|---|---|
  | Agent-doc words | 7,897 | 7,900 |
  | Kit on-demand tokens | 5,190 | 5,203 |
  | Fresh on-demand total | 5,856 | 5,900 |

## End of the branch

- **Release 2026.11.05.1.** `scripts/release.sh` renamed the migration to
  `2026.11.05.1-remove-mode-commands`.
- **Full tier, run twice.**
  - First run: 36/38. `tiers` compared the old one-line `tier set` output,
    and verification evidence looked for tier-medium's removed `## Done`.
    Both tests now check the new output.
  - After the review fixes: 38/38 in 755 s.
- **Deviations from the spec, in one place:**
  - Plan 1 updated the suites that named the modes; Plan 2 kept the
    migration.
  - The seat sections use plain labels. The transition list became each
    seat's Exits, and the review checklists moved to the handoff reference:
    these are the token budgets.
  - The migration keeps tracked copies (CONTRIBUTING's rule for auto
    migrations).
  - The `codex` preset first gives a seat its own project occupant on Codex.
  - The launcher refuses with exit 2.
  - The historical campaign covers its two refs; the prints cover every tag.

## 2026-11-07/08 — re-council and fixes (amended into this commit)

The owner asked for an honest, independent re-council of `9bb2be9`: four
read-only Claude seats (scope, design, regressions, evidence), one Codex
review, and the chair reproducing install `d854770` → update end to end.
Verdict: request changes. Owner decisions (2026-11-08): who codes at small
and medium is the packet's @build on the host the user picks per task; the
fixes and the update-verify fix go into this commit (amend); the stacked
edit-guard branch is rebased on it.

- **`/spec <new-id>` aborted.** `check` failed with "task X has no packet"
  before the folder existed, and Claude Code aborts a command whose `!` line
  exits non-zero. A task with no packet folder now follows the project
  roster (check, resolve, launcher).
- **One rule without `--task`.** The Claude check stopped on several open
  packets while the launcher used the project roster (spec H4). The check
  now applies H4 and prints the same note.
- **Small and medium.** CLAUDE.md and the contracts said Claude implements;
  `/build` refused under the default roster. Both now say the packet's
  @build codes, on the host the user picks; `tier set` prints the command
  that moves @build.
- **Kept mode commands were silent.** With nothing to remove the migration is
  not selected, so its "git rm it" line never showed. The verifier (part of
  the doctor) now warns about each mode command still there.
- **Smaller ones.** `use project` repairs a broken packet `seats.json` (the
  bad file stays as `seats.json.broken-<time>`), and the launcher's error
  points at that, not at the project `reset`; the @build close-out passes
  `--task`; history entries are type-checked (a bad one gave a traceback);
  the Codex rescue command no longer offers the removed mode words; @build's
  "never change the plan" applies at large only.
- **Found outside this branch: updates failed their own check.** Verify ran
  the doctor before preflight, so the old install's context pack (digests
  of the old AGENTS.md and lock) failed `agent-guard.sh check` with "stale
  required context": `RESULT: failed` and a rollback hint on every update of
  a project whose install ran verify (reproduced 00aeab2→d854770,
  d854770→9bb2be9, d854770→5c83bea). Preflight now runs first. The one-shot
  suite missed it because its update cases skip verify.
- **Left as is:** `spec_owner` falls back to Claude, not the project roster,
  on a broken packet file; `same_host` fires on the default roster; one
  `.codex-mode-lock` per project; `--task=<id>` is not accepted.
- **Spec synced:** G8 (tracked copies kept, doctor warns), H2 (codex preset
  order, repair), H4 (exit 2, the shared rule, close-out `--task`).
- **Evidence.** Full tier 34/38 on the first run: four suites pinned the old
  Authority wording or hit SC2015 in the new test. After those fixes the
  eight affected suites pass. End to end: install `d854770`, track two mode
  commands, update → `RESULT: done`, the doctor names both kept commands,
  `check spec --task fix-login` is ok. Budgets: agent docs 7,895 of 7,900
  words (room for the edit-guard branch's +2), on-demand kit 5,185 of 5,203
  tokens.
