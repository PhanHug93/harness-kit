# One-shot install, reinstall and update; verification evidence; seat consistency

Date: 2026-10-15, Asia/Ho_Chi_Minh.
Branch: `feature/improve_update_version` (from main `428a377`).
Status: design approved by the owner on 2026-10-15, section by section;
implemented 2026-10-16. Deviations and known limits are in
`docs/superpowers/plans/oneshot-install-update/journal.md`.
Delivery: one commit for everything (owner decision).

Three parts share this design because they touch the same scripts:
one-shot install, reinstall and update (sections 1–6); verification evidence
(section 7); seat process consistency from the 2026-10-15 audit (section 8,
which maps each finding to its fix; the audit table itself stays local).
Lessons from a downstream iOS run are generalised; nothing here targets one
stack.

## Problem (verified)

- **Two upgrade paths, many manual steps.** README Option A (curl one-shot)
  and Option B (`agent-update`, `agent-upgrade`, `agent-init`) both need about
  ten commands. Option A tells the operator to re-run `--status`, `--diff`
  and `--upgrade-plan`, which the one-shot already ran. The one-shot does not
  run `pre-final --run-verify` or `verify-ai-deps.sh --json`. A fresh install
  is a separate multi-step path (home installer, then `agent-init`).
- **Three whole-tree copies per run.** `--status` (via
  `generated_file_allowlist`), `--upgrade-plan` and `--diff` each call
  `copy_target_for_diff` and re-run full generation
  (`bootstrap-multi-agent-project.sh:1039,1112,1290`). The copy skips only a
  stack-specific denylist (`snapshot_path_is_personal`, `:942`: `*.xcconfig`,
  `google-services.json`…), so `.env`, `.mcp.json` and `.cclsp.json` are
  copied to the temp directory.
- **Shared mutable home.** The one-shot and `agent-update --self-update` write
  one home (`~/dev/agent-bootstrap`). A downstream Android session upgraded it
  while an iOS session was using it.
- **Branch and WIP friction.** The one-shot creates and switches to
  `feature/upgrade-harness-kit` by default and stops on any uncommitted change.
- **Ignore block contradiction.** The generator appends the local-only block to
  `.gitignore` (`render.sh` `append_gitignore_block`), while
  `agent-local-only-check.sh:135-137` reports a tracked `.gitignore` whose
  working tree contains that block. Nearly every project tracks `.gitignore`.
  Confirmed by reading the code; verification case 10 reproduces it.
- **Local patches lost.** `--apply-candidates` replaces a file with its
  candidate, dropping local edits (iOS report: `rtk` and the checker).
- **Version-specific steps are manual.** Untracking files that became
  local-only is only a hint (`agent-local-only-check.sh:232`).
- **No verdict.** A run prints the logs of about eight steps and no short
  result or next action.
- **Nothing is reused between upgrades.** The lock, tech-stack contract,
  context pack, baseline and journals exist, but nothing records per-file
  hashes, conflict resolutions, local patches or decisions. Every upgrade
  re-reads and re-analyses the project.

Verification evidence (verified):

- `pre-final --run-verify` exits 0 with `gate=pass-with-warn` when no command
  ran, even in strict mode (`agent-guard.sh:1568-1571,1603-1604`), while the
  mode contracts say "Unavailable/skipped execution cannot pass".
- Pre-final runs only detector commands (`agent-guard.sh:1412`). The project's
  own `verification[]` in `project-tech-stack.json` (user-owned, validated by
  `verify-ai-deps.sh:560-568`) is never run.
- The detector proposes commands it cannot know (placeholder scheme, a fixed
  simulator; `detect.sh:695-697`), and scope is guessed from substrings, so
  discovery commands count as passes and real unit tests are skipped (C3).
- Nothing checks the toolchain or the base build before work starts; a
  downstream run spent about 1.1M tokens before a pre-existing build failure
  surfaced.
- Each later `@gate` round re-reads everything (about 200k tokens per round in
  the downstream run); no rule covers later rounds.

The seat audit found 31 more inconsistencies (5 high, 15 medium, 11 low); the
audit table stays local and section 8 lists each finding with its fix.

## Goals

- One command for install, reinstall and update, usable by hand. No step needs
  an agent; agents and CI use the same command and flags.
- Works for any stack and language; nothing assumes Android, iOS or a build
  tool.
- Never overwrites local edits. Never commits, pushes or switches branches
  unless asked. Install, reinstall and update change no tracked file by
  default.
- Each run reuses recorded project knowledge instead of re-deriving it.
- Each kit release carries its own migrations.
- A verification pass always means a declared command really ran on a known
  commit; "nothing ran" is never a pass.
- Every rule a seat reads agrees with the other docs and with the scripts.

## Non-goals

- Project-specific follow-ups (CI baselines, version pins in the app's own
  README). The kit reports exact facts; the project acts on them.
- Daily-session context. The context pack and the context-economy rules keep
  that role; knowledge serves install, reinstall and update only.
- Calling agentmemory from scripts. Agents save `memory_note` themselves.
- Changing `agent-update --self-update` for the shared home.

## Decisions (owner, 2026-10-15)

| Topic | Decision |
|---|---|
| Scope | Downstream install, reinstall and update; parts A (safety), B (one command), C (migrations) in one spec |
| Kit source | Per-project copy `.harness-kit/v<ver>/` (local-only) |
| Branch | Never touched unless `--branch NAME` is given |
| Verification | Harness checks once; project checks only with `--project-verify` |
| Architecture | Thin entry script; the orchestration runs from the target version's kit copy |
| Memory | Two layers: deterministic knowledge in the project; agents save `memory_note` to agentmemory |
| Manual use | Flags and re-runs, every result prints the next command; no interactive mode |
| Ignore target | Default `.git/info/exclude` |
| Verification evidence | Include the three downstream proposals (contract-first commands, baseline check, delta review for later `@gate` rounds) |
| Seat audit | Fix all 31 findings in this commit |
| Closure | The active seat records the user's close decision; the journal is required when the task changed tracked files |
| Stop hook | Runs and blocks only when this session changed files; the Codex launcher runs pre-final once when an `@build` session ends |
| Context budget | Count what seats really read, trim to at most 5,900 on demand; above a gate `verify-ai-deps` fails |
| Gate coding | Warn only; the launcher never writes an authorization |
| Delivery | One commit |

## Design

### 1. Entry points and modes

`agent-bootstrap/harness-kit-one-shot.sh` is the entry script (about 100
lines). It:

1. resolves the target version: its own pinned version by default,
   `--to <ver>`, or `--to latest` (highest `v*` tag from `git ls-remote`);
2. fetches the release into `.harness-kit/.fetch-XXXXXX/`, or copies it from
   `--source-dir DIR` (offline), requires `agent-bootstrap/VERSION` to equal
   the version, and renames the directory to `.harness-kit/v<ver>/`. A valid
   existing copy is reused and never modified; an invalid one is refused with
   the path to remove;
3. adds `/.harness-kit/` and `/.tools/` to the exclude file before anything
   else is written, so a first `--plan` leaves nothing untracked;
4. runs `.harness-kit/v<ver>/agent-bootstrap/harness-kit-run.sh` with the
   original arguments.

The generator also emits the entry script as the runtime script
`scripts/harness-kit.sh`, pinned to the generating version, so after the first
install no curl or shell helper is needed. Running it with no arguments is a
reinstall of the installed version; `--to latest` updates. The old name
`harness-kit-one-shot-upgrade.sh` stays as a byte-identical copy for existing
links; `release.sh --check` fails if the two differ. The home helpers
`agent-upgrade` and `agent-init` prefer the project's
`.harness-kit/v<lock version>/` and fall back to the home.

`harness-kit-run.sh` detects the mode and prints it on the first line:

| Project state | Mode | Behaviour |
|---|---|---|
| No lock | install | Generate everything, create knowledge, verify |
| Lock version equals target | reinstall | Restore missing or damaged kit files, keep local patches. `--reset`: kit output wins for every kit-owned file (backup, journal, rollback); project-owned files (brief, `seats.json`, USER overlays) are still preserved |
| Lock version older | update | All phases, including migrations |
| Lock version newer | refused | Suggests `--rollback <STAMP>` |

### 2. Phases

| Phase | Work | Stops when |
|---|---|---|
| preflight | git repository, mode, ignore target, tracked files this run would write | a tracked file it would write has uncommitted changes; a tracked write on a protected branch (A2) |
| stage | detect once (read-only), generate once into staging, classify every file | never |
| apply | write create/update/merge results with backups and journal; conflicts keep the local file and get a candidate | never overwrites |
| migrate | migrations between the installed and target version, plus pending decisions | a migration fails |
| verify | harness checks once | a check fails |
| report | summary, `report.json`, knowledge update | never |

`--plan` stops after stage and writes nothing in the project; it writes only
`.harness-kit/` and `.tools/agent-state/`, both local. `--rollback <STAMP>`
uses the existing journal.

### 3. Project knowledge

`.tools/agent-state/project-knowledge.json` (`harness-project-knowledge/v1`,
local-only) references the lock, tech-stack contract and baseline by hash and
adds only what is missing:

- `kit`: version, source copy, lock/contract/baseline hashes;
- `ignore_target`: `exclude` or `gitignore`;
- `files.<path>`: owner (`kit`, `user`, `overlay`), baseline hash, local hash,
  state (`clean`, `patched`, `pinned`), reason, and the last resolution
  (`resolved`, `keep-local`, `take-kit`) with the local hash it applies to;
- `migrations.<id>`: `applied`, `accepted`, `declined` or `pending`, the facts
  hash and time;
- `runs`: the five latest runs, one line each (stamp, mode, from, to, result).

An entry is reused only while its hashes match the current files; a stale
entry is recomputed alone. Current files always win over recorded knowledge.

Stage reads knowledge first: it hashes only kit-managed files, skips files
whose baseline, local and new hashes are unchanged, reapplies a recorded
resolution while the local hash matches, and generates at most once per key
(kit version, detector summary hash, workflow, overlays, skills, inventory
hash). The staging result is kept in `.tools/agent-state/staging/<key>/`, so
`--plan` followed by a real run generates once. Apply writes only changed
files and records new hashes and resolutions.

`--knowledge` prints at most 15 lines: kit version, ignore target, local
patches with reasons, pins, pending decisions and the latest runs.
`report.json` carries a `memory_note` of at most three lines for agents to
save in agentmemory; knowledge shared across projects belongs there, not in a
project file.

### 4. Safety and isolation

- **A1 Kit copy.** Fetch into a temporary directory, check, then rename; never
  leave a partial `v<ver>/`. Keep the version in use and the previous one;
  prune older copies after a successful run. Runs never write the shared home.
- **A2 Branch.** Never create or switch branches without `--branch NAME`
  (must start with `feature/` or `bugfix/`). Because of A4, install, reinstall
  and update write no tracked file and run on any branch. A run that would
  change tracked files or the index (`--ignore-target gitignore`, an accepted
  decision) is refused on `main`, `master`, `dev`, `develop` and the remote
  default branch.
- **A3 Work in progress.** Harness files are ignored and never appear in
  `git status`; local edits to them are found by hash and handled by A5. The
  run stops only when a tracked file it would write has uncommitted changes.
- **A4 Ignore target.** Default `.git/info/exclude`, resolved with
  `git rev-parse --git-path info/exclude` (correct in worktrees).
  `--ignore-target gitignore` keeps the old behaviour on request. The choice is
  stored in knowledge. The checker accepts the block in either place and stops
  reporting a tracked `.gitignore` when the block lives in exclude. Projects
  with the block in `.gitignore` get the `ignore-block-to-exclude` decision.
- **A5 No overwrite.** Each file is classified:

  | Class | Condition | Action |
  |---|---|---|
  | create | absent locally | write |
  | unchanged | local equals new | none |
  | update | local equals baseline | write new |
  | kept | new equals baseline, local differs | keep local |
  | merge | both changed, `git merge-file` clean | write merged |
  | conflict | merge conflicts, or edited JSON | keep local, write `<path>.generated.<STAMP>` |
  | unsafe | link or out-of-root | skip, report |

  `--take-kit <path>` replaces one file (backup, journal). `--resolved <path>
  [--reason TEXT]` accepts the local file as final, moves the baseline to the
  new kit output and removes the candidate. `--keep-local <path>` pins a file
  by hash; a pinned file is left alone and reported as `pinned`, and a pin
  whose hash no longer matches is reported as stale. The generator's
  `--apply-candidates` no longer replaces a file with local edits unless it is
  named with `--only`.
- **A6 Staging.** Detection runs once on the real project and only reads.
  Generation writes into staging, which holds only the kit outputs that exist
  in the project plus the baseline; the generator gets a detect root separate
  from its write root. Status, plan, diff and apply share that one result. No
  other project file is copied, so the personal-file denylist no longer
  matters here. The first planning task lists every generator read outside its
  own outputs; each must go through the read-only detect root. Projects
  without knowledge get their inventory from a generation into an empty
  staging directory with the same detection.

### 5. Command surface, output and report

| Group | Flags |
|---|---|
| Choose the work | none (auto mode), `--to <ver>\|latest`, `--plan`, `--reset`, `--rollback <STAMP>`, `--knowledge` |
| First install | `--workflow infra\|full`, `--ignore-target exclude\|gitignore`, `--source-dir DIR` |
| After a run | `--take-kit <path>`, `--resolved <path> [--reason TEXT]`, `--keep-local <path>`, `--accept <id>`, `--decline <id>` |
| Other | `--branch NAME`, `--project-verify`, `--json` |

Old flags keep working: `--no-branch` and `--allow-dirty` are defaults and
print a note; `--apply-retirements` means `--accept <ver>-retire-files`;
`--apply-candidates` prints that `--take-kit` and `--resolved` replace it;
`--skip-verify` remains and the result line says `verify skipped`.

Console output is at most about 12 lines: mode and versions; one line per
phase with its duration; `RESULT: done | needs review | failed`; each open item
with the exact next command; the report path. Full phase logs go to
`.tools/agent-state/upgrades/<STAMP>/`.

Exit codes: `0` done; `3` needs review (conflict or pending decision); `1`
refused or failed (preflight, fetch, migration, verify), with a report when
one can be written; `2` usage error.

`report.json` (`harness-kit-run-report/v1`): mode, from, to, stamp; status and
duration per phase; file counts per class with conflict, kept and pinned
lists; migrations applied, pending (with the accept command) and declined;
verification results; `next` commands; `memory_note`.

Verification runs each harness check once: `scripts/agent-hook.sh doctor`,
`scripts/agent-guard.sh preflight`, `scripts/verify-ai-deps.sh --json` (dropped
if doctor already runs it). `--project-verify` adds
`scripts/agent-guard.sh pre-final --run-verify --verify-scope fast`.

### 6. Migrations

Each migration is `agent-bootstrap/migrations/<version>-<slug>.sh`, named after
the release that adds it. It defines `MIGRATION_ID`, `MIGRATION_SINCE`,
`MIGRATION_KIND` (`auto` or `decision`), `MIGRATION_SUMMARY` and:

- `migration_needed`: checks the project's actual state, not only versions;
- `migration_describe`: one line of facts;
- `migration_apply`: idempotent; writes only through journaled helpers.

| Kind | May touch | Runs |
|---|---|---|
| `auto` | kit-owned local files and state only | automatically, journaled |
| `decision` | tracked files, the index, project content, or deletions | only with `--accept <id>`; `--decline <id>` is remembered until the facts hash changes; A2 applies when it changes tracked files or the index |

Selection: migrations with `installed < SINCE <= target` whose
`migration_needed` holds, plus pending decisions. Install and reinstall run no
new migrations and only repeat pending decisions. Order is version, then file
name; a failure stops later migrations. State lives in knowledge, not the lock.
Migrations use only git, POSIX tools and python3; anything stack-specific
reads the tech-stack contract. They never commit, push or switch branches.

`release.sh --check` adds: unique ids, `SINCE <= VERSION`, all three functions
defined, and the version's CHANGELOG entry names each id. Every migration gets
a fixture case: needed, apply, not needed, second apply changes nothing. README
gains a short "Adding a migration" section.

First migrations, all `decision` (`<ver>` is the release that ships this
design):

| id | Effect |
|---|---|
| `2026.10.13.2-untrack-local-records` | `git rm --cached` files that are now local-only (index only; files stay). The report gives the count and the first ten paths |
| `<ver>-ignore-block-to-exclude` | Move the block from `.gitignore` to exclude; when the block was never committed, this only cleans the working tree |
| `<ver>-retire-files` | The existing HK-07 retirement plan with verified backups; it deletes only ignored harness files, so A2 does not apply |

### 7. Verification evidence

**Command source and grading (V1; C3).**

- `pre-final --run-verify` and `baseline` take commands from the contract's
  `verification[]` when it has at least one entry. Detector commands are used
  only when it is empty; the report then says `source: detector`.
- Each contract entry may declare `scope: fast|full` (default `fast`).
  Substring guessing remains only for detector commands. Discovery commands
  (`-list`, `--version`, `--help`) never count as evidence.
- A command with a placeholder never runs.
- When no command ran, the status is `unverified`: strict mode (the default)
  fails with a non-zero exit, advisory mode warns. The message names the fix:
  fill `verification[]` in `docs/superpowers/specs/project-tech-stack.json`.

**Baseline check (V2).**

- `scripts/agent-guard.sh baseline` runs the contract commands (fast scope) on
  the current HEAD and stores `.agents/state/baseline-report.json`.
- The result is keyed by commit, the hash of `verification[]` and a toolchain
  fingerprint; the same key reuses the result without running anything.
- The fingerprint is the output of the contract's optional `toolchain[]`
  commands (for example `node --version`, `go version`, `xcodebuild -version`);
  projects declare their own, so no stack is assumed. Contracts without
  `toolchain[]` stay valid; the fingerprint is then empty and the report says
  so.
- Red exits non-zero. The mode contracts say: before the first `@gate` round,
  run `baseline`; when it is red, stop and report to the user. `unverified`
  does not block, and `@gate` lists "baseline unknown" as a risk.

**Reports (C2, C4, C5).**

- The verification report gains `commit`, `dirty`, `scope`, and `source` per
  command; its schema is published as `agent-guard-verification/v2`.
  `pre-final` writes `last-verify-report.json`; the Stop hook writes
  `closeout-verify.json`, so it never overwrites `@build`'s evidence.
- Status mapping to the packet is written once in the handoff reference:
  `pass` → `pass`; `fail`, `error`, budget exhausted → `fail`; `unverified` →
  `not_run`.
- The event log records a pre-final verification only after it really ran;
  an aborted run is logged as unavailable.
- Reading a named report is allowed; the no-scan rule covers broad searches.

**Stop hook and automatic gates (C1, C2).**

- SessionStart stores a snapshot (path and hash) of the files that differ from
  HEAD. Stop compares it with the current tree; when this session changed no
  file, close-out exits 0. Edits made through Bash count, because the snapshot
  compares content. A concurrent session in the same tree can still trigger it;
  this is documented.
- When the session changed files, close-out runs fast verification and blocks
  (exit 2) on any non-pass status among executed commands (fail, error, budget
  exhausted) or when pre-final itself failed. It reads the report path from the
  guard, not a fixed path. `.claude/settings.json` gives the hook a timeout
  that covers the fast budget.
- `codex-mode.sh` runs `pre-final --run-verify` once when an `@build` session
  ends and prints the result, so the implementing seat on Codex gets the same
  gate.

**Who verifies (C6, C7).**

- AGENTS.md says: the seat that changed code runs `pre-final --run-verify`
  before hand-off; review seats check that report. `--verify-scope full`
  stays for release or high-risk readiness.
- "Seats do not spawn extra reviewer helpers" becomes "beyond the doubt-driven
  skill (at most three cycles) or a council the user asked for".

**Later `@gate` rounds (V3).** Each verdict records the revision it reviewed.
A later round reads its previous verdict and the diff since that revision, and
re-reads whole sections only where the diff touches requirements, interfaces
or acceptance criteria. A fresh seat gets the previous verdict and the diff in
its prompt.

### 8. Seat process consistency

Fixes for the audit findings, host- and stack-neutral:

| IDs | Fix |
|---|---|
| A1 | `codex-mode.sh planning` opens `@spec`; when `@spec` sits on another host it says so and suggests `agent-seats.sh set`. `@gate` gets its own `technical_review` lock with the review rules (verdict first, findings first, severity trigger) |
| A2 | The severity-trigger rule moves from the Codex launcher into the mode contracts |
| A3 | `/codex:rescue` and `/codex:setup` offer only seats whose host is `codex` (from `agent-seats.sh show`), otherwise `agent-seats.sh set` |
| B1 | `/planning` ends with the design and builder-check answers, not a plan; `@build` writes the plan after `@gate` approves |
| B2 | The seat that moves a packet to `resolution` drafts `## Outcome` and asks the user. When the user decides to close, the active seat records `closed`, `closed_by: user` and the user's words in `user-decision.md`. This is the only write a non-owner seat may make to a resolution packet |
| B3 | The journal entry is required when the task changed tracked files and is written by the seat that records closure; otherwise optional. AGENTS.md, `task-journal.md` and the plans README say the same |
| B4 | AGENTS.md: the design becomes the spec when it moves to `specs/`; plans never leave `plans/<topic>/` |
| B5 | `planning-full-flow`, `coding-full-flow` and `reviewing-full-flow` point to their canonical commands and add nothing of their own |
| B6 | A council never changes the phase owner; its executor is the seat that owns the current phase |
| D1 | The Claude edit hook blocks (exit 2) every policy refusal: outside the root, missing required context, failed preflight. Internal errors (for example no python3) warn without blocking |
| D2 | The launcher never writes `authorization=user_session`. A model overlap (`@build` with `@gate`'s or `@verify`'s model, `@verify` with `@build`'s) prints a warning and adds the fact `model_overlap=<seat>` to the seed for `@audit` |
| E1 | Resume selects the only task that is not `closed`; when it awaits the user, the pending question is shown first |
| E2 | `revision_rounds` counts only returns to `implementation`; it resets to 0 when the user allows another pass (recorded in `user-decision.md`); the seat whose return reaches 2 moves the packet to `resolution` with `awaiting_user` |
| E3 | Host `human` maps to `owner: user`; phase `closed` derives `@owner` |
| E4 | Review files are named by seat (`verify-review.md`, `audit-review.md`); readers still accept `codex-review.md` and `claude-review.md` |
| F1 | `validate` rejects unknown keys and seats, matching the schema |
| F2 | The catalog error says to add the model to `catalog.models` in `seats.json` |
| F3 | Doctor warns when the AGENTS.md roster differs from `agent-seats.sh render` |
| F4 | A legacy effort outside the allowed set is kept with a diagnostic note and replaced by the seat default; launches no longer fail |
| F5 | The base template drops "Claude planning, Codex coding/review" and points to `seats.json` |
| F6 | `RECOVERY.md` uses commands that exist (`scripts/harness-kit.sh`, `agent-init`); status lines print the real context-pack path |
| F7 | Both token estimators use one function (bytes / 4) |
| G1 | `verify-ai-deps` fails above a gate (startup 4,000, on-demand 6,200) and warns above amber; the false "enforced by the harness test suite" text goes |
| G2 | The on-demand estimate counts what seats read: core, mode contracts, handoff schema, the reference's "State values" plus its largest seat section, the Karpathy and council docs; `task-journal.md` leaves the set. Text is trimmed (duplicates between the schema and the reference first) so on-demand stays at or below 5,900 after sections 7 and 8 add their rules |

Behaviour changes downstream: strict `pre-final` fails when nothing ran;
`verify-ai-deps` fails above a budget gate; `validate` rejects unknown keys;
the Stop hook no longer runs for sessions that changed nothing. The one-shot
report lists each as a next action when it applies (for example "fill
`verification[]`").

## Compatibility and rollout

- Existing projects: the first run of the new entry script (or the old link)
  is an update. Knowledge is built from the lock and baseline; projects without
  a baseline take the legacy candidate path. Pending decisions are untrack,
  ignore block and retirements.
- New files: `harness-kit-one-shot.sh`, `harness-kit-run.sh`, `migrations/`,
  runtime `scripts/harness-kit.sh` (synced by `sync-runtime-snapshots.sh`),
  schemas for knowledge and the run report. The lock schema does not change.
- Release pins move to the new entry script and URL; MANIFEST, README and
  CHANGELOG are updated. README Option A/B becomes one "Install, reinstall and
  update" section.
- Context budget: measured with the G2 rule, on-demand context is about
  6,300–6,600 today. Upgrade guidance stays in the kit README; generated files
  replace the old upgrade commands with one `scripts/harness-kit.sh` line.
  Sections 7 and 8 replace text rather than add it, and the trim brings
  on-demand to at most 5,900.

## Verification

New fast-tier test `scripts/test-harness-kit-oneshot.sh`. Each case runs on
three fixtures modelled on the existing tests: no stack, one web or backend
project (`package.json` or `pyproject.toml`), one mobile project
(`build.gradle.kts` or `Package.swift`). Updates start from
`scripts/fixtures/historical-bundles/`.

| # | Case | Expected |
|---|---|---|
| 1 | install on a new repository on `main` | exit 0, clean `git status`, block in exclude, knowledge written |
| 2 | reinstall after deleting one kit file and patching another | file restored, patch kept |
| 3 | `--reset`, then `--rollback` | patch replaced with backup; rollback restores it |
| 4 | update from an old bundle with a conflicting patch | exit 3; `--resolved` gives exit 0; next update reapplies from knowledge |
| 5 | `--keep-local` | pinned file untouched; editing it reports a stale pin |
| 6 | untrack decision | pending gives exit 3; refused on `main`; `--accept` on a feature branch changes only the index; `--decline` holds until facts change |
| 7 | old project with the block in `.gitignore` | `ignore-block-to-exclude` pending |
| 8 | staging privacy | sentinel `.env`, `.mcp.json`, `x.xcconfig` never appear in staging or the private temp directory |
| 9 | counts | `--plan` then a run generates once and copies the tree zero times |
| 10 | checker | tracked `.gitignore` plus block in exclude passes (fails on current main) |
| 11 | edges | downgrade refused; usage error exit 2; `--json` fields; summary within 12 lines; worktree uses the common exclude file |
| 12 | entry script | VERSION mismatch refused; interrupted fetch leaves no `v<ver>/`; two copies kept |

Mutations the test must catch: overwrite on conflict; staging copies the whole
tree; a decision runs without `--accept`.

New fast-tier test `scripts/test-verification-evidence.sh` (sections 7 and 8,
same three fixtures; commands are stubs that write marker files, so no stack is
needed):

| # | Case | Expected |
|---|---|---|
| 13 | contract has commands | contract commands run, detector commands do not, report `source: contract` |
| 14 | empty contract | detector commands run, report `source: detector` |
| 15 | nothing runnable | strict exits non-zero with `unverified`; advisory warns |
| 16 | discovery command only | `unverified`, never `pass` |
| 17 | `scope: full` entry | skipped under fast, runs under full |
| 18 | baseline green twice | second call reuses the result (marker count unchanged) |
| 19 | new commit, contract change, toolchain output change | baseline runs again |
| 20 | baseline red | non-zero exit |
| 21 | Stop with no change in this session, dirty tree | exit 0, no verification |
| 22 | Stop after this session edits (Edit tool and Bash) | verification runs; fail, error or budget exhaustion blocks with exit 2 |
| 23 | Stop hook report | written to `closeout-verify.json`; `last-verify-report.json` unchanged |
| 24 | aborted pre-final | event logged as unavailable, not as the old result |
| 25 | edit hook | outside root, missing context and failed preflight exit 2; missing python3 warns |
| 26 | launcher model overlap | warning and `model_overlap=` in the seed, no `authorization=` |
| 27 | `codex-mode.sh planning` | resolves `@spec`; `@gate` gets the `technical_review` lock |
| 28 | `validate` with an unknown key or seat | rejected |
| 29 | legacy effort outside the set | kept with a note, launch resolves the default |
| 30 | roster drift | doctor warns |
| 31 | budget | the G2 set is measured; above a gate `verify-ai-deps` exits non-zero |

Text assertions in the bootstrap suite cover the doc fixes (A2, B1–B6, C6,
C7, E1–E4, F5, F6, V3) by marker, not exact wording.

Mutations the tests must also catch: zero commands graded as pass; the
contract ignored; the baseline cache ignoring the toolchain; the Stop hook
checking the whole tree; the launcher writing an authorization.

Full tier: `test-one-shot-upgrade.sh` covers the old flags and the historical
migrations; the bootstrap suite updates its upgrade, guard and hook
assertions. CI is unchanged. A one-off timing of plan and apply, old versus
new, on a synthetic tree of about 50k files is recorded in the journal; it is
not a CI job.

## Risks

1. Generator reads outside its outputs: inventoried first in the plan (A6).
2. Projects without a baseline see more conflicts on their first run (legacy
   path).
3. Exclude file in worktrees and submodules: resolved with
   `git rev-parse --git-path`.
4. bash 3.2 on macOS must keep working.
5. Context budget: if trimming cannot reach 5,900 on demand without dropping a
   rule, stop and ask the owner before raising any threshold.
6. Downstream behaviour changes (strict pre-final, budget gate, `validate`):
   each must be reported by the one-shot run with its fix, never silently.
7. Size: one very large commit. The plan orders tasks so each part is tested
   before the next starts, and the full tier runs once before the commit.

## Delivery

One commit on `feature/improve_update_version`. That commit moves this design
to `docs/superpowers/specs/2026-10-15-oneshot-install-update-design.md` and
adds `docs/superpowers/plans/oneshot-install-update/journal.md`. The audit
table stays local.
