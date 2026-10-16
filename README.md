# Harness Kit

Harness Kit is a portable, self-testing multi-agent harness kit for adding a
predictable AI-assisted workflow to an existing project. It generates local
instructions, configurable agent seats, onboarding helpers, runtime checks, and
handoff guidance without replacing the project's application code.

Current release: [`2026.10.13.2`](agent-bootstrap/VERSION)

## What changes for the user

The full workflow gives each participant a clear responsibility:

1. `@spec` analyzes the problem and prepares the specification.
2. `@gate` checks whether the specification is complete enough to implement.
3. `@build` implements the approved, bounded change.
4. A fresh `@verify` review checks the result and its verification evidence.
5. `@audit` performs an independent cross-review.
6. `@owner` accepts, revises, escalates, or closes the task.

By the protocol, coding starts only after the technical review records that the
task is ready for the configured coding model. This is a recorded agreement,
not a lock: no script stops `@build` from starting without that verdict. The
coding pass may send an apparently ready task back for clarification, but it
cannot turn a blocking verdict into an approval. After two unsuccessful
remediation returns, the user decides whether another bounded pass is worth its
cost.

This is a coordination protocol, not an autonomous agent runner. The user opens
each host session; Harness Kit does not launch one AI host from another.

## Install, reinstall and update

Requirements: Bash, `python3`, Git, and either `sha256sum` or `shasum`. The
project must be a Git work tree.

One command installs, reinstalls or updates a project. The first time, run the
entry script from the project root. It installs release `2026.10.13.2`:

```bash
cd /path/to/project
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.10.13.2/agent-bootstrap/harness-kit-one-shot.sh | bash
```

The line above needs a release newer than `2026.10.13.2`; releases up to that
one ship only `harness-kit-one-shot-upgrade.sh` with the earlier flow. Until the
next tag, run the entry from a checkout of `main` with `--source-dir` (see
Other options below).

End the line with `| bash -s -- --to latest` to install the newest release
instead. The install adds `scripts/harness-kit.sh`, so later runs need no curl:

```bash
scripts/harness-kit.sh              # reinstall the installed version
scripts/harness-kit.sh --to latest  # update to the newest release
scripts/harness-kit.sh --plan       # preview a run; writes only local kit state
```

The entry fetches the release into `.harness-kit/v<ver>/` and runs that
version's `harness-kit-run.sh`. The run picks its mode from the installed lock:
install (no lock), reinstall (same version) or update (older version). A
downgrade is refused, and the run suggests `--rollback <STAMP>` instead. Each
run goes through preflight, stage, apply, migrate, verify and report. It
creates or switches no branch unless you pass `--branch feature/<slug>` or
`--branch bugfix/<slug>`, and it never overwrites a file you edited (see
[Safe generation and upgrades](#safe-generation-and-upgrades)).

After the first install, finish onboarding:

```bash
bash scripts/install-rtk.sh
scripts/agent-onboarding.sh next
```

Open an agent session and run `/project-onboarding`, then run the readiness
check, `scripts/agent-onboarding.sh check`.

rtk is intentionally hard-pinned to the bundle's audited version so projects
do not drift with an unreviewed upstream release.

### Read the result

The console summary has at most 12 lines: the mode and versions, one line per
phase, `RESULT: done | needs review | failed`, the exact next command for each
open item, and the report path. The full report is
`.tools/agent-state/upgrades/<STAMP>/report.json` (`harness-kit-run-report/v1`);
`--json` prints it instead of the summary. Exit codes: `0` done, `3` needs
review (a conflict or a pending decision), `1` refused or failed, `2` usage
error.

Run the next commands the summary prints. They take this form:

```bash
scripts/harness-kit.sh --resolved <path> --reason "<why>"  # keep your file; the kit output becomes its baseline
scripts/harness-kit.sh --take-kit <path>    # take the kit's file; yours is backed up
scripts/harness-kit.sh --keep-local <path>  # pin your file; later runs leave it alone
scripts/harness-kit.sh --accept <id>        # apply a pending migration decision
scripts/harness-kit.sh --decline <id>       # decline it until its facts change
scripts/harness-kit.sh --rollback <STAMP>   # undo the run recorded as STAMP
```

Other options:

- `--reset`: the kit output wins for every kit-owned file (with backups and
  rollback); the brief, the tech-stack contract, `seats.json` and USER overlays
  stay.
- `--knowledge`: print what the kit knows about the project, from
  `.tools/agent-state/project-knowledge.json`.
- `--workflow infra|full` (first install; default `full`) and
  `--ignore-target exclude|gitignore` (default `exclude`).
- `--project-verify` also runs the project's fast verification;
  `--skip-verify` skips the harness checks.
- `--source-dir DIR` copies the release from a local harness-kit checkout
  instead of fetching it. Offline, run
  `bash /path/to/harness-kit/agent-bootstrap/harness-kit-one-shot.sh --source-dir /path/to/harness-kit`
  for a first install, or `scripts/harness-kit.sh --source-dir /path/to/harness-kit --to latest`
  to update to the checkout's version.

Old options keep working and print a note: `--no-branch` and `--allow-dirty`
are now the defaults, `--dry-run` means `--plan`, `--apply-retirements`
accepts the retire-files decision, and `--apply-candidates` points to
`--take-kit` and `--resolved`. The old entry name
`harness-kit-one-shot-upgrade.sh` stays as an identical copy.

### Shell helpers

To keep a canonical kit copy and the shell helpers on a machine:

```bash
git clone https://github.com/PhanHug93/harness-kit.git
cd harness-kit
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc
source ~/.zshrc
```

In a project, `agent-upgrade` runs `scripts/harness-kit.sh --to latest` (or the
home's entry script when the project has none). `agent-init` runs the generator
of the project's kit copy in `.harness-kit/`, or the home's when there is none;
`agent-init --first-10` prints the first-run path. `agent-update --check`
compares the home with the latest release tag.

## Claude Desktop/Cowork setup

After a full bootstrap:

1. Open the generated target in Cowork.
2. In Cowork, copy the Folder Instructions from `.claude/README.md` once.
3. Give Claude the problem so it creates or resumes the task packet.
4. Use routed Codex for technical review, implementation, and final review.
5. Return to Claude for independent cross-review, then make the final decision
   as the user.

Do not assume Claude Code hooks run in Cowork. If Bash is unavailable, Claude
continues its analysis or cross-review role and records verification as blocked
or delegated with a reason.

The collaboration records are coordination and audit conventions, not security controls:
packet ownership and append-only history are conventions; host, model, and session independence are declarations rather than proof; and @gate authorization entries are audit declarations. Important durable decisions
belong in the project's tracked specification, plan, or memory rather than only
in the local task packet.

## Agent seats

Seats describe the work; their occupants are editable configuration.

| Seat | Default occupant | Fallback |
| --- | --- | --- |
| `@spec` | Claude | host-controlled |
| `@gate` | Codex `gpt-6-astra` @ `ultra` | `gpt-5.6-terra` @ `xhigh` |
| `@build` | Codex `gpt-5.6-luna` @ `xhigh` | `gpt-5.6-terra` @ `xhigh` |
| `@verify` | Codex `gpt-6-astra` @ `ultra` | `gpt-5.6-terra` @ `xhigh` |
| `@audit` | Claude | host-controlled |
| `@owner` | Human | — |

Use `scripts/agent-seats.sh show`, `wizard`, or
`set gate --host codex --model gpt-6-astra --effort ultra` in a generated
project. Assignments and model capabilities live in
`docs/agent-configs/seats.json`; `set` and `wizard` refresh the AGENTS roster.
`reset` explicitly restores bundle defaults. `validate` is read-only.

The launcher accepts a seat or the compatible `planning`, `coding`, `reviewing`
aliases. It launches only occupants configured with host `codex`.
`CODEX_MODEL_OVERRIDE`, mode-specific overrides, `CODEX_USE_FALLBACK`, and
`CODEX_REASONING_EFFORT` remain available. Explicit effort must be supported by
the effective model in the catalog. `CODEX_MODEL_PROFILE` is a warning no-op for
this compatibility release; configure seats instead.

## What the full workflow generates

- Entry guidance for Claude, Codex, Gemini, Cursor, and Windsurf.
- Canonical role, mode, handoff, context, and seat configuration under
  `docs/agent-configs/`.
- Routed Codex helpers and Claude command surfaces.
- Project-stack detection, onboarding, guard, local-only, rtk, and verification
  scripts.
- Project brief and tech-stack templates backed by source evidence.
- `agentmemory-mcp` and `doubt-driven` skills.
- A local-only ignore block, a versioned bootstrap lock, and a pre-push check
  that reports already-tracked local-only files (see the next section).

Running without `--workflow full` installs the smaller `infra` preset.

## What is pushed and what stays local

Local-only mode: what was done goes to Git, while work in progress and the
harness itself stay on the developer's machine. The local-only ignore block
goes to `.git/info/exclude` by default, so harness files never show in
`git status` and no tracked file changes; the entry script adds `/.harness-kit/`
and `/.tools/` there before it writes anything. `--ignore-target gitignore`
writes the block to `.gitignore` instead. A project that already has the block
in `.gitignore` keeps it there until it accepts the `ignore-block-to-exclude`
decision. The pre-push check (`scripts/agent-local-only-check.sh`, installed by
`scripts/install-git-hooks.sh`) names local files that are already tracked.

**Pushed:**

| Path | Content |
|---|---|
| Project files | Source, tests, build and project configuration; the kit does not change them. |
| `docs/superpowers/specs/<topic>/` | Specs of work that has started or shipped. |
| `docs/superpowers/plans/<topic>/journal.md` | Dated record of what was done, finished or not. |

**Local only:**

| Group | Paths |
|---|---|
| Agent entry files | `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules` |
| Agent configuration | `docs/agent-configs/`, `.agents/`, `.claude/`, `.codex/`, `.cursor/rules/`, `.windsurf/rules/` |
| Harness scripts | `scripts/agent-{tech-stack-lib,hook,guard,seats,onboarding,local-only-check}.sh`, `scripts/detect-agent-tech-stack.sh`, `scripts/verify-ai-deps.sh`, `scripts/install-{git-hooks,rtk}.sh`, `scripts/harness-kit.sh`, `scripts/rtk`, `scripts/githooks/` |
| Onboarding scaffolds | `docs/superpowers/specs/README.md`, `docs/superpowers/specs/project-tech-stack.{md,json}`, `docs/superpowers/plans/README.md` |
| Work in progress | Task packets in `.agents/tasks/<task-id>/` (`task.md`, `state.json`, reports, evidence); draft specs, analyses and plans in `docs/superpowers/plans/<topic>/`; `docs/superpowers/reviews/`, `archive/` and every other `docs/superpowers/` folder |
| Kit copies and candidates | `/.harness-kit/`, `/agent-bootstrap/`, the kit's `*.generated.*` candidates, and a `.gitignore` that contains the harness-kit block |
| Personal and machine state | `{AGENTS,CLAUDE,GEMINI}.local.md`, `docs/agent-configs/*.local.md`, `.claude/settings.local.json`, `.agents/{runtime,state,cache}/`, `.tools/`, `.codex-mode-lock`, `*.bak.*`, `.DS_Store` and other tool caches |

A spec starts as a draft in `docs/superpowers/plans/<topic>/` and moves to
`docs/superpowers/specs/<topic>/` in the first commit that implements it. The
generated `AGENTS.md` tells agents the same, overriding skill defaults that
write specs straight to `docs/superpowers/specs/`.

When local files are tracked, the run offers the `untrack-local-records`
decision: accept it with the printed `--accept` command and commit the removal
before pushing; the files stay on disk. By hand, run
`scripts/agent-local-only-check.sh status`, then `git rm --cached -- <path>`.

## Safe generation and upgrades

Local edits are never overwritten. A local-only baseline
(`.tools/agent-state/harness-baseline/`) keeps the last kit output of every
generated file, and each run puts every file in one class:

| Class | When | Action |
|---|---|---|
| create | the file is missing | write it |
| unchanged | the file equals the new kit output | none |
| update | you have not edited the file | write the new kit output |
| kept | the kit did not change the file, you did | keep yours |
| merge | both changed and the merge is clean | write the merged file |
| conflict | both changed and the merge fails, or the file is JSON | keep yours; the kit's goes to `<path>.generated.<STAMP>` |
| unsafe | a link or a path outside the project | skip and report |
| pinned | pinned with `--keep-local` (or the generator's `--keep`) | leave it alone; a pin edited since is reported as stale |

Filled project briefs, tech-stack evidence, `seats.json` and USER overlay
sections survive every run, including `--reset`. Projects generated before
2026.10.13.1 have no baseline yet, so their first update reports every changed
kit file as a conflict; `scripts/harness-kit.sh --take-kit all` takes the kit's
files and backs yours up.

The generator follows the same rules when you call it directly (`agent-init`
or `bootstrap-multi-agent-project.sh`). `--keep <path>` (repeatable) leaves a
file untouched: no write and no candidate. `agent-init --diff` previews the
candidates, and `agent-init --upgrade-plan --json` lists the action for each
file without writing anything. `agent-init --apply-candidates` promotes
reviewed candidates from the generated allowlist but keeps files with local
edits unless they are named with `--only <path>` (repeatable). Every generator
run prints an upgrade id; `--rollback <id>` restores the files that run changed
and removes what it created, keeping (and listing, exit 3) any file edited
since.

`agent-init --status --json` reports bundle version, installed version, drift,
and pending candidates for tooling or CI.

`--diff`, `--upgrade-plan` and `--status` generate into a temporary staging
directory that holds only the kit's outputs, the configuration the kit reads
back (lock, brief, tech-stack contract, `seats.json`, candidates) and, for the
upgrade plan, the baseline. Detection reads the project in place, so the
project is never copied and large checkouts take seconds. Personal and secret
files never reach the staging directory: `*.local.*` (such as
`.claude/settings.local.json`), signing certificates, provisioning profiles,
`*.xcconfig`, Firebase config files, `.netrc`, `.npmrc` and `.pypirc`.

### Retired harness files

Older releases generated a remote CI workflow, `.github/workflows/agent-guard.yml`,
and its template mirror. Upgrades never delete them: generation, `--force`,
`--diff`, `--upgrade-plan`, `--status`, `--apply-candidates`, the updater and a
plain `scripts/harness-kit.sh` run only show a read-only retirement plan.
Removal is a separate, explicit step: accept the `retire-files` decision with
the `--accept` command the run prints, or use the generator:

```bash
agent-init --retirement-plan            # read-only; add --json for a typed report
agent-init --apply-retirements          # exact 605-byte historical copies only
```

Only byte-exact copies are removed, each after a verified backup next to it
(`<path>.bak.retirement.<run-id>`). Edited files, links, special files and
`*.generated.*` candidates are always preserved for manual review. The default
scope is local-only (untracked and Git-ignored); tracked or non-Git copies need
`--retirement-scope all-matching`. Exit 3 means something was preserved for
review. `--status --json` stays v1 and does not report retirement; use
`--status --json --status-version 2` or `--retirement-status --json`. The
generated `docs/agent-configs/RECOVERY.md` has a safe restore recipe.

### Default model effort catalog

| Model | Allowed efforts | Default effort |
|---|---|---|
| `gpt-6-astra` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` | `ultra` |
| `gpt-5.6-luna` | `low`, `medium`, `high`, `xhigh`, `max` | `xhigh` |
| `gpt-5.6-terra` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` | `xhigh` |

The [default seats JSON](scripts/fixtures/agent-seats-default.json) records the
full roster. Release `2026.09.10.1` updates the catalog used for fresh `init`
and explicit `reset`; occupant assignments and default efforts stay the same.
Existing `seats.json` remains user-owned and is not rewritten by an upgrade.
To adopt these capabilities in an existing project, edit only the three
`catalog.models.<model>.efforts` arrays in that project's seats file, then run
`scripts/agent-seats.sh validate`. Preserve unrelated settings. Before removing
`none`, choose a supported value for any catalog default, primary effort or
fallback effort that currently uses `none`. `reset` replaces the whole
configuration and is not required for this catalog-only update.

### Configuration migration from older releases

Upgrades create `seats.json` only when it is missing. A customized legacy
`model-profiles.json` migrates its selected default profile's models, efforts
and fallbacks to `@gate`, `@build` and `@verify`. Unknown model ids and declared
efforts are retained in the catalog with a diagnostic note. The original legacy
file, including other named profiles, remains untouched for reference/recovery.
It is no longer the active configuration after seats exist.

A legacy profile exactly equal to the old bundle defaults, without route effort
overrides, adopts the new default occupants with a visible migration note.
Existing `seats.json` always wins and is kept byte-for-byte during generation,
candidate application and repeated upgrades. Neither seats nor the legacy
input are replaced by a generated candidate. A malformed or invalid active
configuration is reported for repair; the launcher refuses to start and the
upgrade does not silently replace it with defaults.

After upgrading, run `scripts/agent-seats.sh show`,
`scripts/agent-seats.sh validate`, and `.codex/codex-mode.sh status` to inspect
the effective configuration. Repair invalid input before retrying; use `reset`
only when you explicitly want default assignments. Filled briefs and USER
overlays continue through the existing preservation path.

## Verification and operational limits

The standard local close-out path is:

```bash
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
```

`pre-final --run-verify` takes its commands from `verification[]` in
`docs/superpowers/specs/project-tech-stack.json` (each entry may set
`scope: fast|full`); detector commands are used only when that list is empty.
Commands with placeholders never run, and discovery commands such as
`--version` or `--help` are not evidence. The report
(`agent-guard-verification/v2`) goes to `.agents/state/last-verify-report.json`.
When no command could run, the result is `unverified`, which is never a pass:
strict mode (the default) exits 4 and fails, advisory mode warns. Use
`--verify-scope full` only after reviewing heavier build commands.

`scripts/agent-guard.sh baseline` runs the fast contract commands on the
current commit before the first `@gate` round. The result is cached by commit,
`verification[]`, toolchain fingerprint (the output of the contract's
`toolchain[]` commands) and scope, so a repeat run on the same key runs
nothing. A red baseline is reported to the user before review starts. The
Claude Code Stop hook verifies only when the session changed files, and the
Codex `@build` seat runs pre-final once when its session ends. A later `@gate`
round reads its previous verdict and the specification sections changed since
then, not a git diff.

Agent Guard protects known files and detects stale context, but it is a thin
file-edit guardrail, not a security boundary for arbitrary Bash commands. Task
packets are ignored, ephemeral, and convention-controlled; Git does not protect
their append-only history.

`scripts/verify-ai-deps.sh` measures two estimated context budgets (the
`.codex/codex-mode.sh doctor` reports its numbers; `--json` adds
`context_budget`, and `--context-budget` runs only this check):

- core startup context: gate `4000`, amber above `3800`;
- full on-demand workflow context: gate `6200`, amber above `5900`.

The core estimate covers `AGENTS.md`, project context, and the project brief. It
excludes tool-specific wrappers such as `CLAUDE.md` and `GEMINI.md`. The
on-demand estimate adds what a working seat reads: mode contracts, handoff
schema, the handoff reference's `State values` section and its largest other
section, and the Karpathy and council workflows. Each estimate is split into
the kit's own text and project content (the project brief, the project agent
context, `<!-- BEGIN USER -->` regions and the
detector-filled managed blocks). Kit text above a gate fails the verifier; a
total above a gate only warns and names the largest project files, which are
the project's to shorten. Amber means the target still passes but
should be measured again before adding more guidance.

## Contracts, schemas, and repository layout

The verifier performs manual contract validation for the bootstrap lock, model
profiles, context policy, project tech-stack contract, schema catalog metadata,
and rtk provenance manifest. Published JSON schemas remain references for people
and external tooling; Harness Kit does not invoke a generic schema engine at
runtime.

- `agent-bootstrap/` is the complete copyable bundle. Keep its entrypoint and
  `lib/` directory together.
- `scripts/` contains repository wrappers and release/drift tests.
- `docs/agent-configs/bootstrap-multi-agent-project/` contains templates,
  schemas, provenance, and operator documentation.

One-off generation without installed shell helpers remains available:

```bash
bash /path/to/harness-kit/agent-bootstrap/bootstrap-multi-agent-project.sh \
  --target "$PWD" --workflow full
```

## Development and release gate

The [mandatory Git-flow rules](AGENTS.md#mandatory-git-flow-authorization)
apply to this repository and are emitted into downstream `AGENTS.md` in both
`full` and `infra` workflows. Work on a dedicated branch and use a PR/MR with a
target explicitly named by the user; stop the integration step if none is named.
Name feature branches `feature/<slug>` and fix branches `bugfix/<slug>`.
Do not use `codex/` or agent names as branch prefixes; this convention takes
precedence over host defaults.
Do not directly push or fast-forward the target, and do not merge without a
separate explicit user instruction. Never force-push `main`, `dev` or `develop`.

Prefer one commit per work branch. Ask the user before exceeding two commits,
or when a branch already has more than two; do not automatically rewrite history.
Creating or pushing a tag requires the user's explicit source branch and
authorization for that action. A release request does not select a branch or
authorize merging. Keep unreleased changes on the feature branch until that
release scope is supplied.

These are agent operating rules, not server-side branch protection. They do not
change the existing optional Git hook. Existing downstream projects receive the
updated instructions through a normal `scripts/harness-kit.sh` update.

Tests run in two tiers. On every edit run the fast tier,
`bash scripts/test-fast.sh` (about 5 minutes: syntax, release pins and mirrors,
release script, workspace guard, onboarding, retirement lifecycle, detector
fixtures, path policy, concurrent guard reads, local-only mode, verification
evidence, and the one-shot entry, knowledge, migrations, staging and runs). It
runs every check and lists all failures at the end; `--only <check>` reruns
one.

The full tier below runs in CI on Linux and macOS for every pull request,
push to `main` and release tag. Other branches are tested through their pull
request (or a manual `workflow_dispatch` run), so one commit is not tested
twice, and a newer push cancels the older run. Locally, run a full-tier
entrypoint only to reproduce a CI failure or when CI cannot run, and run it
once rather than after every edit; map its children once so that a campaign
does not repeat covered work:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
HARNESS_MIGRATION_HISTORICAL_SOURCE=tags bash scripts/test-one-shot-upgrade.sh
bash scripts/test-release.sh
```

The main test verifies canonical-home export, generated runtime mirrors,
manifest inventory, onboarding fixtures, model routing, non-destructive
migration, context budgets, and version pins.

Runtime snapshots in `agent-bootstrap/` are generator output: after editing a
runtime writer, run `bash scripts/sync-runtime-snapshots.sh` instead of copying
heredocs by hand (`--check` reports drift).

To prepare a release, write the notes under `## Unreleased` in `CHANGELOG.md`,
then run `bash scripts/release.sh <YYYY.MM.DD.N> --title "<summary>"`.
`agent-bootstrap/VERSION` is the single source: the script updates every
version pin, turns `## Unreleased` into the release heading, syncs the template
mirror and runtime snapshots, and verifies the result. It never commits, tags
or pushes. Before an authorized tag, run
`bash scripts/release.sh --check-tag v<version>`; CI repeats this check on
every tag push.

### Adding a migration

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
its own. A `decision` migration (tracked files, the index, project content or
deletions) runs only after `--accept <id>`; `--decline <id>` is remembered
until its facts change. Migrations use only git, POSIX tools and `python3`, and
never commit, push or switch branches. Name the id under `## Unreleased` in
`CHANGELOG.md` and add a case to `scripts/test-harness-migrations.sh`: needed,
apply, not needed, and a second apply that changes nothing.
`scripts/release.sh --check` checks the ids, versions, functions and changelog
entries.

### Workspace–Repository Guard

Generated instructions, launchers and execution preflight require original host
workspace metadata. Capture it at session entry, before changing cwd/workdir.
Host adapters supply `AGENT_HOST_SESSION_ID` and `AGENT_WORKSPACE_CONTEXT`:

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

`scripts/agent-guard.sh workspace-check` returns 0 plus a JSON identity report on
success, or 3 with a diagnostic on mismatch/missing metadata. Runtime preflight,
pre-edit, pre-final and launcher execution stop before writes when unverified.
Claude pre-tool and close-out hooks map this refusal to blocking exit code 2.
`check`/`doctor` remain installation diagnostics, not workspace authorization.
The launcher announces the target and injects the original session metadata into
child shells using per-launch `shell_environment_policy.set` overrides, retaining
`inherit = "none"`. See the [official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference). Every subagent handoff must carry the same origin, target,
source and authorization evidence and validate its actual checkout before writing.
No chat project is changed and no chat is created by this guard.

The host/agent must provide truthful session metadata; the kit cannot independently
authenticate a chat project or user message, or stop arbitrary commands that bypass
its entrypoints. Missing metadata is explicitly **unverified**, never a pass.

Run `python3 scripts/test-workspace-repository-guard.py` for real-repository,
symlink, worktree, stale-session, changed-workdir and generated-launcher/hook checks.

### Verification scope and command coverage

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

### Downstream feedback and kit releases

- One downstream report opens one task packet; later findings from the same
  report are added to that packet instead of opening new ones.
- The kit releases on its own cadence with `scripts/release.sh`. Downstream apps
  upgrade only to published release tags, never to unreleased kit branches, and
  app acceptance does not wait for unreleased kit work.
- A kit defect found downstream is fixed and released in the kit first; the app
  then picks it up through a normal reviewed upgrade.

Use the command graph below to prepare a campaign table with the exact command,
source/test/fixture fingerprints, environment mode, evidence paths, one verification
owner, and caps before execution. All temporary targets, fixtures and evidence
belong below a private campaign parent. Do not snapshot a shared system temp root.

| Parent command / group | Covered children / mode | Fixture / evidence |
| --- | --- | --- |
| `bash scripts/test-bootstrap-multi-agent-project.sh` | Onboarding; generator/detector/guard; seats and launcher with inherited PATH | Private target and fixtures; capture parent stdout/stderr/exit |
| `HARNESS_MIGRATION_HISTORICAL_SOURCE=tags bash scripts/test-one-shot-upgrade.sh` | One-shot; selector/negative archive probes; partial-auto selector; one full tags migration | Independent Git clone for ref mutations; source refs unchanged; migration summary/provenance |
| `python3 scripts/test-agent-seats-migration.py --historical-source fixtures` in a source copy with no `.git` | One full tagless fixture migration | Checked-in archives + manifest; migration summary/provenance |
| Seats and launcher with PATH removed from the process environment | Absent PATH only; use an absolute Python path and `SEATS_QA_BASH=/bin/bash` | Separate private generated target; seats JSON and launcher output |
| Linux descriptor probe from the release recipe | Descriptor resolution and external sentinel preservation | Trace + parser result + sentinel bytes/mode/inode |

Do not run onboarding again after a full bootstrap pass, or the same historical
migration after one-shot already covered it. Inherited PATH does not prove absent
PATH. Partial-auto uses the real selector/export/validation functions without a
third full migration. The Python migration module can be imported without parsing
arguments or starting a campaign; call `configure(argv)` explicitly for a selector
probe, or `main(argv)` for the full CLI campaign. CLI source mode overrides the
environment. Both full tags and tagless release migrations remain required.

### Campaign evidence and stopping rules

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

## License

MIT — see [`LICENSE`](LICENSE). The `doubt-driven` skill is adapted from
[`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) (MIT) —
see [`NOTICE`](NOTICE).
