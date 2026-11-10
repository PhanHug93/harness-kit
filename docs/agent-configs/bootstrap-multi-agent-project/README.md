# Harness Kit Reference

The details behind [README.md](../../../README.md): file layout, commands,
upgrade rules, budgets and contracts. Changing the kit itself is in
[CONTRIBUTING.md](../../../CONTRIBUTING.md).

## Bundle and home layout

`agent-bootstrap/` is the whole kit as one copyable folder; `MANIFEST.md`
lists every file and its drift rule.

```text
agent-bootstrap/
├── VERSION, MANIFEST.md, README.md
├── harness-kit-one-shot.sh        # entry: fetch a release, run it
├── harness-kit-run.sh             # install, reinstall or update one project
├── bootstrap-multi-agent-project.sh  # the generator
├── agent-bootstrap-update.sh, install-agent-bootstrap-home.sh
├── lib/                           # generator libraries; keep beside the entry
├── migrations/                    # one-time update steps
├── model-profiles/                # legacy defaults, read only during migration
├── policies/                      # context policy, retired-file inventory
├── schemas/                       # JSON schemas for the kit's files
├── templates/                     # base, overlays, workflows, tool contract
└── agent-*.sh, agent-tier.py, detect-agent-tech-stack.sh, verify-ai-deps.sh,
    install-git-hooks.sh, githooks/   # runtime scripts
```

The runtime scripts at the bottom are what the generator copies into a
project's `scripts/`; run them from a generated project, not from the
bundle. The home install (`$HOME/dev/agent-bootstrap` by default) holds the
same files.

## Home install and shell helpers

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc   # from a checkout
source ~/.zshrc
```

- `--home DIR` picks another folder; `--dry-run` previews; `--no-git` skips
  the local history.
- The installer copies the bundle, backs up each changed file before replacing
  it, and adds a managed block to `~/.zshrc` only with `--write-zshrc`.

The block exports `AGENT_BOOTSTRAP_HOME` and defines:

- `agent-upgrade`: `scripts/harness-kit.sh --to latest`, or the home's
  `harness-kit-one-shot.sh --to latest` when the project has none;
- `agent-init`: the generator from the project's `.harness-kit/v<version>/`
  copy, or from the home when there is none;
- `agent-next`: `agent-init --first-10`;
- `agent-doctor`: `scripts/agent-hook.sh doctor`;
- `agent-refresh`: `agent-init --refresh-lock` after stack or module changes;
- `agent-update`: the home's Git-backed updater (`--check` compares the home
  with the latest `vYYYY.MM.DD.N` tag, `--self-update` refreshes it).

`scripts/install-agent-bootstrap-home.sh` and
`scripts/bootstrap-multi-agent-project.sh` in the repository are compatibility
wrappers. A project may also link `scripts/bootstrap-multi-agent-project.sh`
to the home's generator; a generated project does not need it.

## Generator commands

`scripts/harness-kit.sh` is the normal entry. The generator
(`agent-init`, or `bash bootstrap-multi-agent-project.sh --target "$PWD"`)
follows the same file rules and adds lifecycle commands:

```bash
agent-init --workflow full          # generate (default preset: infra)
agent-init --status --json          # versions, drift, pending candidates
agent-init --first-10               # the first-run path
agent-init --diff                   # preview generated-file diffs
agent-init --upgrade-plan --json    # the action per file; writes nothing
agent-init --apply-candidates       # promote reviewed candidates
agent-init --retirement-plan        # read-only retired-file plan
```

- `--apply-candidates` promotes the latest candidate for each generated path
  (from the generated-file allowlist only) and removes older ones; files with
  local edits stay unless named with `--only <path>` (repeatable).
- `--keep <path>` (repeatable) leaves a file untouched: no write, no
  candidate.
- Every run prints an upgrade id; `--rollback <id>` restores what that run
  changed and removes what it created, keeping (and listing, exit 3) any file
  edited since.
- `--skip-existing` leaves existing files alone and creates missing ones;
  `--force` overwrites on purpose, with backups unless `--no-backup`.
- Old one-shot options still work and print a note: `--no-branch` and
  `--allow-dirty` are defaults, `--dry-run` means `--plan`,
  `--apply-retirements` accepts the retire-files decision, `--apply-candidates`
  points to `--take-kit` and `--resolved`. `harness-kit-one-shot-upgrade.sh`
  is an identical copy of the entry under its old name.

## How upgrades treat your files

A local-only baseline (`.tools/agent-state/harness-baseline/`) keeps the last
kit output of every generated file, and each run puts every file in one class:

| Class | When | Action |
|---|---|---|
| create | the file is missing | write it |
| unchanged | the file equals the new kit output | none |
| update | you have not edited the file | write the new kit output |
| kept | the kit did not change the file, you did | keep yours |
| merge | both changed and the merge is clean | write the merged file |
| conflict | both changed and the merge fails, or the file is JSON (`.claude/settings.json` is merged when the result is still valid JSON) | keep yours; the kit's goes to `<path>.generated.<STAMP>` |
| unsafe | a link or a path outside the project | skip and report |
| pinned | pinned with `--keep-local` (or the generator's `--keep`) | leave it alone; a pin edited since is reported as stale |

Filled briefs, tech-stack evidence, `seats.json` and USER sections survive
every run, including `--reset`. Projects generated before 2026.10.13.1 have no
baseline, so their first update reports every changed kit file as a conflict;
`scripts/harness-kit.sh --take-kit all` takes the kit's files and backs yours
up.

`--diff`, `--upgrade-plan` and `--status` generate into a temporary staging
folder holding only the kit's outputs, the configuration it reads back (lock,
brief, tech-stack contract, `seats.json`, candidates) and, for the plan, the
baseline. Detection reads the project in place, so large checkouts take
seconds. Personal and secret files never reach staging: `*.local.*`, signing
certificates, provisioning profiles, `*.xcconfig`, Firebase config files,
`.netrc`, `.npmrc` and `.pypirc`.

## Retired harness files

Older releases generated a remote CI workflow,
`.github/workflows/agent-guard.yml`, and its template mirror (`v2026.08.10.1`).
The closed inventory matches each only by its exact 605-byte SHA-256; there is
no path or digest override. Generation, `--force`, `--diff`,
`--upgrade-plan`, `--status`, `--apply-candidates`, `--cleanup-backups`,
`agent-update --apply` and a plain `scripts/harness-kit.sh` run only show a
read-only plan. Removal is explicit: accept the `retire-files` decision, or run
`agent-init --apply-retirements`.

- Each removal rechecks the file, writes a verified backup
  `<path>.bak.retirement.<run-id>` (mode and mtime kept), then removes only the
  checked file. `--apply-retirements --dry-run` reports the plan only.
- `--retirement-scope local-only` (default) covers untracked, Git-ignored
  copies; `all-matching` adds tracked and non-Git copies.
- Edited bytes, links (leaf or parent), special and multi-link files and every
  `*.generated.*` candidate of a retired path are preserved and reported.
- Exits: 0 done, 1 inspection/backup/delete error (completed backups kept), 2
  invalid arguments before any write (including `--force`, `--skip-existing`,
  `--no-backup` or another action alongside), 3 a file was preserved for
  review, 130/143 interrupted.
- `--status --json` stays `agent-bootstrap-status/v1`; `--status-version 2`
  adds the retirement report. Restore with the recipe in the generated
  `docs/agent-configs/RECOVERY.md`; it never overwrites a file.

Newer leftovers (rtk, the old host wrappers) are removed by `auto` migrations
during `update`: only byte-exact kit copies, each backed up first.

## What the kit generates

Both presets (`infra` is the generator default; the one-shot entry installs
`full` unless told otherwise):

- `AGENTS.md`, and `CLAUDE.md` that imports it.
- `docs/agent-configs/project-agent-context.md`, `agent-bootstrap.lock.json`,
  `context-policy.json` and `RECOVERY.md`.
- `docs/agent-configs/bootstrap-multi-agent-project/`: the templates and
  `schemas/*.schema.json`.
- `.claude/settings.json` (hooks) and `.claude/README.md`.
- `.agents/skills/agentmemory-mcp/`.
- `scripts/`: `agent-guard.sh`, `agent-tier.py`, `agent-hook.sh`,
  `agent-tech-stack-lib.sh`, `detect-agent-tech-stack.sh`,
  `verify-ai-deps.sh`, `agent-local-only-check.sh`, `install-git-hooks.sh`,
  `githooks/pre-push`, `harness-kit.sh`.
- The local-only ignore block, in `.git/info/exclude` by default.

`full` adds:

- `docs/agent-configs/`: `seats.json`, `agent-mode-contracts.md`,
  `agent-handoff-schema.md`, `agent-handoff-reference.md`, `tier-medium.md`,
  `task-journal.md`, `karpathy-llm-coding-agent-config.md`,
  `llm-council-agent-workflow.md`, `first-10-minutes.md`,
  `project-onboarding.md` and the empty `project-brief.md`.
- `.codex/config.toml`, `.codex/codex-mode.sh` (seat launcher and `doctor`),
  `.codex/README.md`.
- `.claude/commands/`: `/spec`, `/gate`, `/build`, `/verify`, `/audit` (one
  per seat), `/council`, `/karpathy`, `/doctor`,
  `/project-onboarding`, `/codex:setup`, `/codex:rescue`, `/codex:status`.
- `.agents/skills/doubt-driven/`.
- `docs/superpowers/specs/README.md`, `project-tech-stack.{md,json}` and
  `docs/superpowers/plans/README.md`.
- `scripts/agent-seats.sh` and `scripts/agent-onboarding.sh`.

`--add-skill mobile-optimization` (Android Kotlin or iOS Swift projects) adds
the skill under `.agents/skills/` and its pointers: a Claude `/optimize-code`
command, a Cursor rule (`.cursor/rules/`) and a Windsurf rule
(`.windsurf/rules/`).

## Stack detection and the lock

```bash
scripts/detect-agent-tech-stack.sh --summary
scripts/detect-agent-tech-stack.sh --markdown
```

Agents run the detector at the start of substantive work.
`scripts/agent-tech-stack-lib.sh` owns detection, and
`docs/agent-configs/agent-bootstrap.lock.json` records its output; the hook
compares the two so stack or module drift is visible. Refresh the lock after
an intended change with `agent-refresh`.

## Onboarding outputs

`full` writes empty, source-backed context files instead of guessing. The
`/project-onboarding` command scans the project and fills:

- `docs/agent-configs/project-brief.md`: architecture and domain context;
- `docs/agent-configs/project-agent-context.md`: protected paths, generated
  files, commands, release constraints;
- `docs/superpowers/specs/project-tech-stack.md` and `.json`: the verified
  stack and module map, conventions, evidence and verification commands;
- more `docs/superpowers/specs/<topic>/` files for durable decisions it finds.

Readiness is computed each time, not stored: `scripts/agent-onboarding.sh
status` and `next` report what is missing; `check` exits non-zero until the
brief has no `UNFILLED` marker, the Markdown spec is filled, evidence paths
exist, and every verification entry has a command, purpose and source. The
kit's onboarding fixtures (`scripts/test-onboarding-fixtures.sh`) show filled
examples.

## Verification details

- `pre-final --run-verify` takes its commands from `verification[]` in
  `docs/superpowers/specs/project-tech-stack.json` (each entry may set
  `scope: fast|full`); detector commands are used only when that list is
  empty. Placeholders (`xcodebuild ... <scheme>`) never run, and discovery
  commands such as `--version` or `--help` are not evidence.
- The report (`agent-guard-verification/v2`) goes to
  `.agents/state/last-verify-report.json`; an `agent-guard-event/v2` event
  with separate `gate_status` and `verification.status` goes to
  `.agents/state/session-events.jsonl`.
- `unverified` is never a pass: strict mode (default) exits 4, advisory mode
  warns.
- `scripts/agent-guard.sh baseline` runs the fast commands on the current
  commit before the first `@gate` round. It caches by commit,
  `verification[]`, toolchain fingerprint and scope, so a repeat runs nothing;
  a red baseline is reported before review starts.
- The Claude Code Stop hook verifies only when the session changed files; the
  Codex `@build` seat runs pre-final once when its session ends. A later
  `@gate` round reads its previous verdict and the spec sections changed
  since, not a git diff.

## Tier measurement

- On a feature branch, the change is everything since it left the default
  branch. A branch cut from another branch (`develop`, a parent PR) needs
  `--base <branch>` on any `tier set`; a stacked branch then counts only its
  own work once the parent is merged. Pre-final reminds you only when the
  task started on commits the default branch does not have.
- When every work branch starts from the same branch that is not the
  default one, name it once as `tier_base` in `project-tech-stack.json`
  (for example `"tier_base": "origin/develop"`). It then takes the default
  branch's place in every rule here. The name is looked up as a local
  branch, then as a remote one (`origin/develop`), then on `origin`; a
  slash in it (`release/next`) changes nothing. A name that is no branch
  warns and the default branch is used. With no tier declared, the warning
  says what its count starts from (`since origin/master, 2023-04-13`), so
  a base far in the past is easy to spot.
- A task started on the default branch moves to a new branch made from its
  work when you run `tier set` there. On the default branch the change is
  everything since `tier set`, minus commits pulled from teammates and
  commits already pushed, so each push is checked on its own.
- The pre-push hook (`pre-final --committed --advisory`) counts only
  committed work on the checked-out branch, for the task in
  `.agents/tasks/ACTIVE`. A push with no declared tier is not measured:
  after `tier close` that is the usual push. The hook names the packets
  still open on the pushed branch (the one the push sends, also when
  another one is checked out; a push of tags alone names none) and counts
  the other ones that are not closed (`tier list` shows them). It warns
  and does not refuse a push, also when verification failed or did not
  run; only kit local-only files in the pushed commits refuse it. A linked
  worktree has no kit files, so it has no push check.
- When git cannot tell the task's work apart (a rebase of a commit made
  before the task), pre-final names the cause and does not fail.
- Thresholds live in `docs/agent-configs/context-policy.json`. Edit them
  there; when a kit update also changes that file, the update stops with a
  conflict (`--resolved` keeps yours, `--take-kit` takes the kit's). Binary
  types that should count like images go in `binary_asset_extensions` in
  `project-tech-stack.json`, for example `["psd", "sketch"]`.
- A lower tier than suggested needs a reason, which covers only that
  suggestion. Lowering while a review is negative also needs one, and the PR
  line says "lowered despite a negative @gate review". Once coding has
  started, a raise needs the new tier's reviews. With no tier, pre-final only
  warns.

`tier stats` (`--since YYYY-MM-DD`, `--json`) shows how tiers worked out on
this machine:

```text
Tasks: 18 (15 closed, 3 open) since 2026-10-23
Tier: small 9 · medium 6 · large 3 · handoff 4 · raised after coding 1
Suggestion: kept 14 · lowered with a reason 2 · raised 2
Warnings: pre-final 5 on 4 tasks · push 3 on 3 tasks
Time to close (median): small 36 min · medium 3.1 h · large 1.8 d
```

## Context budgets

`scripts/verify-ai-deps.sh` estimates two budgets (`--context-budget` runs
only this check; `--json` adds `context_budget`; `.codex/codex-mode.sh doctor`
prints the numbers):

- core startup: gate `4000`, amber above `3800`;
- full on-demand workflow: gate `6200`, amber above `5900`.

The core estimate covers `AGENTS.md`, the project agent context and the
project brief; it excludes tool-specific wrappers such as `CLAUDE.md`. The
on-demand estimate adds what a working seat reads: seat contracts, handoff
schema, the handoff reference's `State values` section and its largest other
section, and the Karpathy and council workflows. Each estimate is split into
kit text and project content (the brief, the project agent context,
`<!-- BEGIN USER -->` regions and the detector-filled managed blocks). Kit
text above a gate fails; project content above a gate only warns and names the
largest project files. Amber means it still passes but should be measured
again before adding guidance. Estimates use max(bytes/4, words × 1.3).

## Agent Guard Lite

A file-based guardrail, not a daemon or broker:

- `docs/agent-configs/context-policy.json` lists required and recommended
  context, protected path patterns and the change protocol.
- `scripts/agent-guard.sh preflight` checks required context and writes
  `.agents/state/context-pack.json`; `check` does the same without writing
  (the verifier and doctor use it).
- `scripts/agent-guard.sh pre-edit <path>` classifies protected context,
  harness, CI, release and generated paths; a protected path fails unless
  rerun with `--ack <reason>`, logged in `.agents/state/guard-ack.log`. Claude
  Code's `Edit`, `Write`, `MultiEdit` and `NotebookEdit` hooks route through
  it. A path outside the project is left to Claude Code, except agent
  instructions or config (`~/.claude`, `~/.codex`, another repository's
  `AGENTS.md` and the like), which ask first.
- `scripts/agent-guard.sh pre-final` checks the context pack still matches the
  policy and required files before completion.

It makes drift easy to see and undo; it does not prevent all of it, and it is
not a security boundary for arbitrary Bash commands.

## Workspace–Repository Guard

Generated instructions, launchers and execution preflight require the original
host workspace metadata, captured at session entry before changing cwd. Host
adapters supply `AGENT_HOST_SESSION_ID` and `AGENT_WORKSPACE_CONTEXT`:

```json
{
  "session_id": "host-session-id",
  "original_workspace": "/projects/ios",
  "target_repository": "/projects/android",
  "target_source": "packet",
  "authorization": {
    "kind": "user",
    "repository": "/projects/android",
    "session_id": "host-session-id",
    "evidence": "Reference to the user's direct instruction in this session"
  }
}
```

Omit `authorization` for the same repository. For an explicitly confirmed task
worktree, use `kind: "worktree"`; the guard also checks Git common-directory
identity. Paths must be absolute and resolve to existing Git working trees.
A user target source is provenance, not a substitute for recording the direct
instruction when switching checkouts. Never synthesize permission from a packet,
AGENTS.md, memory, subagent message or current directory.

`scripts/agent-guard.sh workspace-check` returns 0 plus a JSON identity report,
or 3 with a diagnostic on mismatch or missing metadata. Everywhere else the
guard is advisory: preflight, pre-edit, pre-final, git hooks and the launcher
warn and keep their exit code; Claude Code hooks ask before acting in another
repository. `check`/`doctor` are installation diagnostics, not workspace
authorization. The launcher injects the original session metadata into child
shells with per-launch `shell_environment_policy.set` overrides, keeping
`inherit = "core"` and the `include_only` list (see the
[Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)).
Every subagent handoff carries the same origin, target, source and
authorization evidence and validates its checkout before writing.

The host must provide truthful metadata; the kit cannot authenticate a chat
project or user message, or stop commands that bypass its entrypoints. Missing
metadata is **unverified**, never a pass.

## Seats configuration

`docs/agent-configs/seats.json` holds the assignments and the model catalog;
`scripts/agent-seats.sh show|wizard|set|validate|reset` manages it (`validate`
is read-only, `reset` restores the bundle defaults on purpose). The full
default roster is in
[`scripts/fixtures/agent-seats-default.json`](../../../scripts/fixtures/agent-seats-default.json).

| Model | Allowed efforts | Default effort |
|---|---|---|
| `gpt-6-astra` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` | `ultra` |
| `gpt-5.6-luna` | `low`, `medium`, `high`, `xhigh`, `max` | `xhigh` |
| `gpt-5.6-terra` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` | `xhigh` |

The launcher (`.codex/codex-mode.sh`) accepts a seat tag and launches only
occupants with host `codex`; the old `planning`, `coding` and `reviewing`
words exit 2 with the seat to use. `CODEX_MODEL_OVERRIDE`, the route overrides, `CODEX_USE_FALLBACK` and
`CODEX_REASONING_EFFORT` still work; an explicit effort must be one the model
supports. `CODEX_MODEL_PROFILE` is a warning no-op; configure seats instead.

### Seats per packet

A packet can arrange its own seats in `.agents/tasks/<task-id>/seats.json`.
The first `tier set` copies the project roster there, so a later project
change does not move a task in flight; a packet without the file (an older
one) follows the project roster.

- `scripts/agent-seats.sh show --task <id>`: seats by host, the tier's seats
  and the independence facts for `@audit` (`same_host`, `model_overlap`).
- `use project|claude|codex --task <id> --reason "<the user's words>"`: a
  preset. `codex` keeps a seat already on Codex, gives another seat its
  project occupant when that one is on Codex, else the project's `@verify`
  (or `@gate`) occupant.
- `set <seat> --host ... --task <id> --reason ...`: one seat.
- `history --task <id>`: every change with its time, seat, before/after and
  reason; entries are only appended.

`.codex/codex-mode.sh @<seat> --task <id>` and the Claude seat commands
(`scripts/agent-seats.sh check`) refuse a seat that the packet gives to
another host. Without `--task` they use the only open packet, else the
project roster. `tier set` prints the tier's seats; `tier close` prints the
final arrangement and the number of changes.

Upgrades from older releases:

- `seats.json` is created only when missing; an existing one always wins and
  stays byte-identical, and it never becomes a candidate.
- A customized legacy `model-profiles.json` moves its default profile's
  models, efforts and fallbacks to `@gate`, `@build` and `@verify`; unknown ids
  are kept with a note. The legacy file stays untouched for recovery. A legacy
  profile equal to the old defaults adopts the new occupants with a note.
- Invalid active configuration is reported for repair; the launcher refuses to
  start and nothing resets it to defaults.
- Release 2026.09.10.1 changed the catalog only for fresh installs and
  `reset`. To adopt it in an existing project, edit only the three
  `catalog.models.<model>.efforts` arrays (pick a supported value first for
  any setting that uses `none`), then run `scripts/agent-seats.sh validate`.
- After upgrading, check `scripts/agent-seats.sh show`, `validate` and
  `.codex/codex-mode.sh status`.

## Contracts and schemas

The verifier performs manual contract validation for the bootstrap lock, the
active seats configuration, the context policy, the project tech-stack
contract and the schema catalog metadata. The JSON schemas copied into
`docs/agent-configs/bootstrap-multi-agent-project/schemas/` are references for
people and external tools; the kit runs no generic schema engine.

## Validate a generated project

```bash
scripts/detect-agent-tech-stack.sh --summary
scripts/agent-guard.sh preflight
scripts/agent-onboarding.sh status
scripts/agent-onboarding.sh check
scripts/verify-ai-deps.sh            # add --json for machine output
scripts/agent-hook.sh doctor
.codex/codex-mode.sh doctor          # full preset
```

## Out of scope

The kit deliberately skips a build step or self-extracting payload, `dist/`
artifacts, manifest YAML or per-template manifests, lock v2 and per-template
versioning, and template extraction beyond the copyable shell bundle. They
suit a public reusable framework, not this one-maintainer workflow.
