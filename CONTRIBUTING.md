# Contributing to Harness Kit

This guide is for changing, testing and releasing the kit. Using the kit is in
[README.md](README.md); file formats and commands are in the
[reference](docs/agent-configs/bootstrap-multi-agent-project/README.md).

## Rules first

- The [mandatory Git-flow rules](AGENTS.md#mandatory-git-flow-authorization)
  apply to this repository and to every branch. The kit also writes them into
  downstream `AGENTS.md` (both `full` and `infra`). They are agent operating
  rules, not server-side branch protection.
- Development records follow [docs/superpowers/README.md](docs/superpowers/README.md):
  specs of started work and plan journals are pushed; drafts, plans, task
  packets and evidence stay local.

## Repository layout

- `agent-bootstrap/` is the complete copyable bundle. Keep its entrypoint and
  `lib/` directory together. `MANIFEST.md` lists every file and its drift rule.
- `agent-bootstrap/lib/writers-*.sh` write the generated files as heredocs.
- `agent-bootstrap/migrations/` holds the one-time update steps.
- `scripts/` holds the repository wrappers, the release script and the tests.
- `docs/agent-configs/bootstrap-multi-agent-project/` holds the template
  mirror, the schemas and the reference.
- `docs/agent-configs/EXTENSION-GUIDE.md` shows how to add a detected stack,
  a tool surface, a guard check or an optional skill.

## Changing the bundle

- Runtime scripts in `agent-bootstrap/` (`agent-guard.sh`, `agent-hook.sh`,
  `verify-ai-deps.sh`, `detect-agent-tech-stack.sh`, `agent-tech-stack-lib.sh`,
  …) are the source: edit them in place. The writers copy them into targets;
  `agent-hook.sh` and `verify-ai-deps.sh` get the target's preset on their
  `WORKFLOW_PRESET=` line.
- Keep the template mirror, the home installer's copy list and `MANIFEST.md`
  in step with the bundle; the drift test checks all three.
- A change that must reach existing projects once (removing a leftover file,
  moving a setting) is a migration; see below.

## Tests

On every edit, run the fast tier:

```bash
bash scripts/test.sh                  # fast tier in parallel; lists every failure at the end
bash scripts/test.sh --only <suite>   # repeatable; --skip <suite> leaves one out
bash scripts/test.sh --list           # the table: suite, tier, CI group, mode
```

`scripts/test.sh` holds the only list of suites. Each runs with an empty
stdin and its own log, `-j N` sets the parallel jobs (default: CPU count, at
most 4), and `serial` rows (`guard-race`) run alone after the batch.
`scripts/test-fast.sh` still works and calls it.

The full tier adds the drift test groups, the upgrade suites and the
historical migration campaigns:

```bash
bash scripts/test.sh --full           # about 13 minutes on an idle Mac
bash scripts/test-bootstrap-multi-agent-project.sh --group contracts   # one drift group
```

The drift test has six groups (`--list-groups`). Each one sets up what it
needs, writes nothing into the source tree (it checks `git status` at the
end), and can run in parallel with the others. While suites run, do not add
or edit files in the repository: a new untracked file fails that check, and
bash reads a running script as it goes. Together the groups check:

- the canonical home export, generated runtime scripts and the manifest
  inventory;
- onboarding fixtures, model routing, non-destructive migration;
- context budgets and version pins.

`python3 scripts/test-workspace-repository-guard.py` covers real
repositories, symlinks, worktrees, stale sessions, changed workdirs and the
generated launcher and hooks. `scripts/test-hook-hot-path.sh` holds the
hook's per-call budget of `python3` and `git` starts.

CI (`.github/workflows/test.yml`) has four jobs:

- `gate` decides whether the heavy jobs are needed (`scripts/ci-gate.sh`);
- `lint` runs on Linux;
- `tests` is a matrix of four groups on Linux and macOS;
- `record` runs last.

A push to `main` or a release tag skips `tests` when the same tree already
passed: the `record` job of a fully green run uploads `tested-tree-<tree>`.
Pull requests and manual runs always test in full. When you add a suite, give
it a group in the table; `bash scripts/test.sh --check-ci` (a lint row) fails
if the workflow's matrix and the table's groups differ.

## Agent docs and the rule inventory

The docs a project's agents read (AGENTS.md, CLAUDE.md, the mode contracts,
the handoff schema and reference, RECOVERY, the READMEs under `.claude/` and
`.codex/`, the skills) keep each rule in one file, in plain short sentences.
`scripts/rule-inventory.tsv` lists every mandatory rule with its preset, the
generated file that owns it and a short exact phrase.
`bash scripts/test-rule-inventory.sh` (seconds) generates fresh `full` and
`infra` targets and checks that each phrase is in its owner file (and, for a
`single` rule, nowhere else), that `CLAUDE.md` is the only wrapper and starts
with `@AGENTS.md`, and that a `full` target's agent docs stay under the word
ceiling.

When you reword a generated doc, reword its rows in the same change; the
inventory diff then shows every rule that changed or left. A few phrases are
still matched line by line in `scripts/test-verification-evidence.sh`,
`scripts/test-local-only-mode.sh` and `scripts/test-onboarding-fixtures.sh`:
keep each of those on one line.

## Release

Write the notes under `## Unreleased` in `CHANGELOG.md`, then run:

```bash
bash scripts/release.sh <YYYY.MM.DD.N> --title "<summary>"
```

`agent-bootstrap/VERSION` is the single source: the script updates every
version pin, turns `## Unreleased` into the release heading, renames
`next-*` migrations, syncs the template mirror, and
verifies the result. It never commits, tags or pushes. Before an authorized
tag, run `bash scripts/release.sh --check-tag v<version>`; CI repeats this
check on every tag push.

## Adding a migration

A migration changes an existing project once, during an update. Add
`agent-bootstrap/migrations/next-<slug>.sh`; `scripts/release.sh <version>`
renames it to `<version>-<slug>.sh` and rewrites its id. The file defines
`MIGRATION_ID` (its name without `.sh`), `MIGRATION_SINCE=next`,
`MIGRATION_KIND`, `MIGRATION_SUMMARY` and three functions:

- `migration_needed` checks the project's actual state, not only versions;
- `migration_describe` prints one line of facts;
- `migration_apply` is idempotent and backs up each file with
  `migration_backup PATH` before writing it.

An `auto` migration touches only kit-owned local files and state, and runs on
its own; it may delete such a file only when its bytes are exactly what a kit
wrote, or a tool cache the kit installed in its own layout. A `decision`
migration (tracked files, the index, project content or other deletions) runs
only after `--accept <id>`; `--decline <id>` is remembered until its facts
change. Migrations use only git, POSIX tools and `python3`, and
never commit, push or switch branches. Name the id under `## Unreleased` in
`CHANGELOG.md` and add a case to `scripts/test-harness-migrations.sh`: needed,
apply, not needed, and a second apply that changes nothing.
`scripts/release.sh --check` checks the ids, versions, functions and changelog
entries.

## Verification scope and downstream feedback

Choose acceptance scope before dispatch. A downstream app that does not publish
harness-kit can record **app local accepted; kit release pending** after reviewing
the exact imported artifact, preserving project-owned files and USER overlays,
checking relevant read/write boundaries, reviewing preview/promotion with recorded
preimages and backups, confirming detector/lock consistency, and running the real
app build. Record the owner decision for any deferred AC. A data-loss defect still
blocks local acceptance; this distinction never overrides a gate `no`, grants file
or Git permissions, or changes seats and non-goals. Release-kit matrix work belongs
to the upstream kit team, not automatically to the downstream app team.

Kit release acceptance additionally needs full regression on macOS and Linux,
tags and tagless historical migrations, explicit absent-PATH coverage, and Linux
descriptor tracing where required by the release scope. A stubbed Flutter/Xcode
fixture proves command construction, not an actual downstream app build.

- One downstream report opens one task packet; later findings from the same
  report are added to that packet instead of opening new ones.
- The kit releases on its own cadence with `scripts/release.sh`. Downstream apps
  upgrade only to published release tags, never to unreleased kit branches, and
  app acceptance does not wait for unreleased kit work.
- A kit defect found downstream is fixed and released in the kit first; the app
  then picks it up through a normal reviewed upgrade.

## Campaign evidence and stopping rules

Use the command graph below to prepare a campaign table with the exact command,
source/test/fixture fingerprints, environment mode, evidence paths, one verification
owner, and caps before execution. All temporary targets, fixtures and evidence
belong below a private campaign parent. Do not snapshot a shared system temp root.

| Parent command / group | Covered children / mode | Fixture / evidence |
| --- | --- | --- |
| `bash scripts/test-bootstrap-multi-agent-project.sh [--group G]` | Six groups (focus install inventory contracts prefinal lifecycle): onboarding; generator/detector/guard; seats and launcher with inherited PATH | Private target and fixtures; capture parent stdout/stderr/exit |
| `HARNESS_MIGRATION_HISTORICAL_SOURCE=tags bash scripts/test-one-shot-upgrade.sh` | One-shot; selector/negative archive probes; partial-auto selector; one full tags migration | Independent Git clone for ref mutations; source refs unchanged; migration summary/provenance |
| `bash scripts/test-historical-fixtures.sh` (runs `test-agent-seats-migration.py --historical-source fixtures` in a source copy with no `.git`) | One full tagless fixture migration | Checked-in archives + manifest; migration summary/provenance |
| `bash scripts/test-seats-no-path.sh`: seats and launcher with PATH removed from the process environment | Absent PATH only; use an absolute Python path and `SEATS_QA_BASH=/bin/bash` | Separate private generated target; seats JSON and launcher output |
| Linux descriptor probe from the release recipe | Descriptor resolution and external sentinel preservation | Trace + parser result + sentinel bytes/mode/inode |

Do not run onboarding again after a full bootstrap pass, or the same historical
migration after one-shot already covered it. Inherited PATH does not prove absent
PATH. Partial-auto uses the real selector/export/validation functions without a
third full migration. The Python migration module can be imported without parsing
arguments or starting a campaign; call `configure(argv)` explicitly for a selector
probe, or `main(argv)` for the full CLI campaign. CLI source mode overrides the
environment. Both full tags and tagless release migrations remain required.

Keep each execution attempt in a new directory; retain its exact command, inputs,
environment mode, exit code, stdout/stderr and result. Never overwrite a failed or
interrupted attempt with a later pass. On resume, reconcile the campaign ledger
from completed result artifacts before scheduling work. An existing compatible
PASS remains valid even if a stale ledger says running.

Reuse evidence only when its source, test, recipe, fixture and environment
(mode, OS, interpreter/tool versions and relevant variables) dependencies match.
Mark only dependent ACs stale after a change, and state the changed dependency or
missing evidence before a retest. Corrupt/missing results are unavailable evidence,
not PASS. Preserve separate failure, timeout, interruption and runner/setup-error
verdicts; none alone diagnoses a production defect. One independent reviewer probe
should supplement author evidence on the same frozen artifact rather than repeat
unchanged parent suites.

Record UTC start/end timestamps and their elapsed difference separately from the
monotonic duration measurement; investigate discrepancies without relabeling either
measurement as CPU time or monetary cost. Missing token telemetry is unavailable,
not zero. Cached input is a subset of input; reasoning is a subset of output.
Sum measured use across author, verifier and coordinator without double counting.

Set one campaign-wide warning threshold and hard stop before execution, including
review, fixture setup and all subprocesses. For a bounded local integration,
start with a 45-minute elapsed cap and a warning at 35 minutes; use smaller caps
when the app recipe permits. A longer release matrix needs its own explicit budget.
Record a token cap when telemetry is available; otherwise enforce the elapsed cap
and report token usage unavailable. Stop dispatching at the hard limit, terminate
remaining work, preserve partial evidence and report pending ACs. A new candidate,
packet, process or session does not reset this budget. Report a new failure or
scope expansion before another attempt; do not silently raise caps or add stress
campaigns. Existing task/review records can hold this information; no new runtime
schema, CLI option or mandatory gate is required.

## Superpowers policy

Superpowers is an external upstream at <https://github.com/obra/superpowers>.
Harness-kit does not install, update, or synchronize it and adds no updater;
upstream owns its host-specific installation paths.

- Pin a tested upstream release tag; never auto-track `main`.
- Review quarterly, or when a relevant release is published.
- Inspect the release diff and run two or three representative brainstorming
  tasks before moving the pin.
- Freeze on the last validated release when a new one gives no relevant benefit
  or introduces regression risk.

Kit guidance is written for v7.0.0 and stays compatible with v5.0.7. It relies
on the default `docs/superpowers/{specs,plans}` paths, the user-preference
override for them and `.superpowers/brainstorm/`; a release that changes any of
these needs a kit update first. Before moving a pin to v7.0.0, run a quick, a
small and a project task and check where the design was saved, that nothing
was committed and that the visual companion stopped.

A `v5.1.0` match was reported from a separate environment comparison, not from
this repository; reverify it before any update.

## Agentmemory version pin

Each release names the agentmemory version it was tested with:
`AGENTMEMORY_TESTED` in the verifier heredoc (`lib/writers-runtime.sh`, synced
to `agent-bootstrap/verify-ai-deps.sh`), the setup line of the
`agentmemory-mcp` skill and README's agentmemory section;
`scripts/test-agentmemory-check.sh` fails when they differ. `release.sh` never
moves it. Move the pin only after running the kit's seat flow against the new
version on Claude Code and Codex: save, search, a lesson, an action, and the
profile.
