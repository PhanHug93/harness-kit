# Multi-Agent Harness Kit Bundle

This directory is the copyable source bundle for portable multi-agent harness
infrastructure.
Copy or sync this directory when applying the current agent config model to
other projects.

Bundle version: see `VERSION`.
Inventory and drift rules: see `MANIFEST.md`.

## Contents

- `VERSION` and `MANIFEST.md` — bundle version, inventory, and drift contract.
- `bootstrap-multi-agent-project.sh` — thin entrypoint that generates agent
  config into a target project or worktree.
- `harness-kit-one-shot.sh` — one-shot entry that fetches a release into
  `<project>/.harness-kit/v<version>/` and runs its `harness-kit-run.sh`;
  targets get it as `scripts/harness-kit.sh`. `harness-kit-one-shot-upgrade.sh`
  is an identical copy under the old name.
- `harness-kit-run.sh` — orchestrator that installs, reinstalls or updates one
  project; `migrations/` holds the migrations it runs.
- `agent-bootstrap-update.sh` — Git-backed updater for checking published tags,
  refreshing `$AGENT_BOOTSTRAP_HOME`, and delegating target upgrade plans.
- `lib/` — sourced libraries (`core`, `detect`, `render`, `writers-runtime`,
  `writers-docs`, `onboarding`) that the entrypoint sources at runtime. The
  entrypoint REQUIRES this directory beside it — copy the whole bundle, never
  the entrypoint script alone. `lib/retirement.py` is the bundled retired-file
  engine the entrypoint calls; it is never copied into targets.
- `install-agent-bootstrap-home.sh` — exports this bundle to a canonical
  `$AGENT_BOOTSTRAP_HOME` directory such as `$HOME/dev/agent-bootstrap`.
- `agent-tech-stack-lib.sh` — shared stack detector library used by the
  bootstrap script.
- `agent-hook.sh`, `agent-guard.sh`, `agent-seats.sh`, `agent-onboarding.sh`,
  `detect-agent-tech-stack.sh`, `verify-ai-deps.sh`,
  `install-rtk.sh`, and `rtk` — full-workflow runtime snapshots generated into
  bootstrapped projects.
- `agent-tier.py` — the change-tier program that `agent-guard.sh tier` runs;
  generated projects get it as `scripts/agent-tier.py`.
- `model-profiles/` — retained legacy defaults used to recognize older
  configurations during migration; fresh targets do not receive this file.
- `policies/` — Agent Guard Lite context policy copied into generated target
  projects as `docs/agent-configs/context-policy.json`, and the closed
  `retired-artifacts-v1.json` inventory read only by `lib/retirement.py`.
- `schemas/` — JSON Schema artifacts for generated lock/status (v1 and opt-in
  v2)/retirement/verifier report contracts, agent seats, legacy model profiles,
  project tech-stack, and context policy.
- `templates/` — base, stack overlay, and workflow templates copied into
  generated target projects.
- `provenance/` — pinned third-party runtime checksums, currently rtk release
  assets.

Only `harness-kit-one-shot.sh`, `bootstrap-multi-agent-project.sh` and
`install-agent-bootstrap-home.sh` are operator entrypoints from this folder. Runtime snapshots are kept here for
review and drift testing; target projects receive runnable copies under their
own `scripts/` directory.

## Usage

Export the bundle once:

```bash
bash agent-bootstrap/install-agent-bootstrap-home.sh \
  --home "$HOME/dev/agent-bootstrap"
```

Apply it to a target project:

```bash
cd /path/to/target-project
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" \
  --target "$PWD" \
  --workflow full
scripts/agent-onboarding.sh next
```

### Claude Desktop/Cowork collaboration

After a full bootstrap:

1. Open the generated target in Cowork.
2. In Cowork, copy the Folder Instructions from `.claude/README.md` once.
3. Give Claude the problem so it creates or resumes the task packet.
4. Use routed Codex for technical review, implementation, and final review.
5. Return to Claude for independent cross-review, then to the user for final
   resolution.

Do not assume Claude Code hooks run in Cowork. These collaboration records are coordination and audit conventions, not security controls: packet ownership and append-only history are conventions;
host, model, and session independence are declarations rather than proof; and
@gate authorization entries are audit declarations.

Runtime requirements are Bash, `python3`, Git, and a SHA-256 tool
(`sha256sum` or `shasum`). The generated `scripts/install-rtk.sh` handles the
pinned `rtk` download and checksum verification. The rtk version is hard-pinned
on purpose so the kit stays reproducible across machines and future upstream
releases.

### Agent seats and configuration migration

The protocol uses `@spec` → `@gate` → `@build` → `@verify` → `@audit` →
`@owner`. Defaults are Claude for spec/audit, Codex `gpt-6-astra` at `ultra`
for gate/verify, Codex `gpt-5.6-luna` at `xhigh` for build, and human for owner.
Codex defaults have `gpt-5.6-terra` at `xhigh` as fallback.

In a generated project, use `scripts/agent-seats.sh show`, `wizard`,
`set build --effort high`, and `validate`. Assignments and the capability
catalog live in `docs/agent-configs/seats.json`. The launcher accepts seat tags
and legacy route aliases; only Codex occupants launch through it. Override
efforts are validated against the selected model's catalog entry.

Upgrade creates seats only when missing. Customized legacy default-profile
models, efforts and fallbacks migrate; the original `model-profiles.json` stays
untouched. An exact old bundle default adopts the new occupants with a note.
Existing seats always win, even if an inactive legacy file is malformed, and
remain byte-identical across regeneration and candidate application. Invalid
active input is reported without resetting it; fix the input and retry.
`reset` is an explicit operator action, never an upgrade repair. USER overlays
and filled project briefs stay on the existing preservation path.

After upgrade, inspect `scripts/agent-seats.sh show`, run `validate`, and check
`.codex/codex-mode.sh status` before launching. `CODEX_MODEL_PROFILE` is a
warning no-op for this compatibility release; change seats instead.

### Closed-loop pre-final

The detector emits verification candidates as structured JSON. The standard local close-out path is:

```bash
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
```

`pre-final --run-verify` runs the fast commands from `verification[]` in the
tech-stack contract (detector commands only when it is empty) and never runs
placeholders such as `xcodebuild ... <scheme>`. When no command could run, the
result is `unverified`, never a pass: strict mode exits 4, advisory mode warns.
With a declared change tier (`scripts/agent-guard.sh tier`), a change above
that tier gets a recommendation, never a failure; see the root README, "Pick a
tier for each change".
`scripts/agent-guard.sh baseline` checks the current commit and caches the
result. Review the commands before using `--verify-scope full` to include
build/full commands. Results are written to
`.agents/state/last-verify-report.json` (`agent-guard-verification/v2`), and an
`agent-guard-event/v2` event with separate `gate_status` and
`verification.status` is appended to `.agents/state/session-events.jsonl`.
Generated Claude Code settings also register a Stop hook that runs fast
close-out verification when the session changed files; Gemini, Cursor, and Windsurf
remain advisory and should run the pre-final command manually.
The kit does not install or enforce remote checks. Every harness gate is local
and opt-in: run `scripts/agent-guard.sh` directly or install the provided
pre-push hook with `scripts/install-git-hooks.sh`.

Install, reinstall or update a project with one command. The first time, from
the project root:

```bash
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.10.20.1/agent-bootstrap/harness-kit-one-shot.sh | bash
```

Use `| bash -s -- --to latest` for the newest release. Later runs use the
project's copy: `scripts/harness-kit.sh` reinstalls the installed version and
`scripts/harness-kit.sh --to latest` updates. The entry fetches the release
into `.harness-kit/v<version>/` (or copies it with `--source-dir DIR`, offline)
and runs that version's `harness-kit-run.sh`. A downgrade is refused. The run
goes through preflight, stage, apply, migrate, verify and report, creates no
branch without `--branch feature/<slug>|bugfix/<slug>`, and writes the
local-only ignore block to `.git/info/exclude` unless
`--ignore-target gitignore` is given.

The summary has at most 12 lines and prints the exact next command for each
open item; the report is `.tools/agent-state/upgrades/<STAMP>/report.json`.
Exit codes: 0 done, 3 needs review, 1 refused or failed, 2 usage error. The
main options are `--plan`, `--reset`, `--rollback STAMP`, `--knowledge`,
`--resolved PATH [--reason TEXT]`, `--take-kit PATH`, `--keep-local PATH`,
`--accept ID`, `--decline ID`, `--project-verify`, `--skip-verify` and
`--json`; `harness-kit-run.sh --help` lists them all. Old options
(`--no-branch`, `--allow-dirty`, `--dry-run`, `--apply-candidates`,
`--apply-retirements`) still work and print a note.

The generator itself keeps its lifecycle commands:

```bash
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --status --json
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --first-10
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --diff
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --upgrade-plan
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --apply-candidates
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --retirement-plan
```

For a one-off copy, you can also copy this entire `agent-bootstrap/` directory
to another machine or project and run `install-agent-bootstrap-home.sh` from
inside the copied directory.

After changing this bundle, run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

The test verifies that canonical home export matches this directory, runtime
snapshots still match generated `--workflow full` output, generated-target
verifier behavior stays healthy, and onboarding fixture output can be filled
into source-backed `project-tech-stack.json` golden contracts.

Lifecycle commands are explicit: `--status --json` reports generated-file drift,
`--diff` previews the regenerated output, and `--apply-candidates` promotes the
latest reviewed bootstrap candidate for each generated path while removing older
candidates for that same path. Candidate promotion is scoped to the generated-file
allowlist, so unrelated project files matching `*.generated.*` are not touched.
Plain `--apply-candidates` keeps files with local edits;
`--apply-candidates --only <path>` (repeatable) promotes only the named files,
and `--keep <path>` (repeatable) leaves a file untouched. Local edits are never
overwritten: a local-only baseline of the last kit output sorts each file as
create, unchanged, update, kept, merge, conflict (a
`<path>.generated.<STAMP>` candidate), unsafe or pinned;
`--upgrade-plan --json` previews this per file and `--rollback <upgrade-id>`
undoes a run. Previews generate into a staging directory that holds only kit
outputs, their configuration and the baseline; detection reads the project in
place, so the project is never copied and personal or secret files
(`*.local.*`, signing certificates, provisioning profiles, `*.xcconfig`,
Firebase config, `.netrc`, `.npmrc`, `.pypirc`) never reach it.
Harness files are local-only by policy; if a previous run already tracked them,
accept the `untrack-local-records` decision (or run
`scripts/agent-local-only-check.sh status` and `git rm --cached -- <path>`), and
commit the removal before pushing.
The Git-backed updater adds the upstream step: `agent-update --check` compares
the canonical home with the latest published `vYYYY.MM.DD.N` tag,
`agent-update --self-update` refreshes the canonical home from that tag, and
`agent-upgrade` runs `scripts/harness-kit.sh --to latest` (add `--plan` to
preview).

Retired generated files follow a separate explicit lifecycle (HK-07). The closed
inventory is two paths from `v2026.08.10.1`, `.github/workflows/agent-guard.yml`
and `docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml`,
each matched only by its exact 605-byte SHA-256; there is no inventory, path or
digest override.

- `--retirement-plan [--json]` and `--retirement-status [--json]` are read-only.
  Generation (including `--dry-run`, `--force`, `--skip-existing`), `--diff`,
  `--upgrade-plan`, human `--status`, `--apply-candidates` and
  `--cleanup-backups` append the same read-only section and never delete;
  neither do `agent-update --apply` and the one-shot defaults.
- `--apply-retirements [--json]` rebuilds the plan, rechecks each file before
  backup and again before unlink, writes a verified backup
  `<path>.bak.retirement.<run-id>` (mode and mtime kept), and removes only the
  exact checked file. `--apply-retirements --dry-run` reports the plan only.
- `--retirement-scope local-only` (default) retires untracked, Git-ignored
  copies; `all-matching` also retires tracked, unignored or non-Git copies.
  Modified bytes, symlinks (leaf or parent), special files, multi-link files and
  every `*.generated.*` candidate of a retired path are preserved and reported;
  retired paths never enter candidate promotion or `--cleanup-backups`.
- Exits: 0 complete (plan/status, or apply with nothing left to retire), 1
  inspection/backup/delete error (later entries are not attempted, completed
  backups are kept), 2 invalid arguments before any write (including
  `--force`, `--skip-existing`, `--no-backup` or another action alongside a
  retirement action), 3 apply finished but preserved a file for review,
  130/143 interrupted. Ordinary observers keep their own failure; otherwise they
  return 1 only for a retirement inspection error.
- `--status --json` remains `agent-bootstrap-status/v1` and retirement-blind.
  `--status --json --status-version 2` adds the `retirement` report
  (`schemas/agent-bootstrap-status-v2.schema.json`); dedicated `--json`
  reports follow `schemas/agent-bootstrap-retirement-v1.schema.json`.
- Restore with the exclusive-create recipe in the generated
  `docs/agent-configs/RECOVERY.md`; it never overwrites an existing file.
- `scripts/harness-kit.sh` always shows the plan and deletes only when the
  `retire-files` decision is accepted (`--accept <id>`, or the old
  `--apply-retirements`).

Generated full-workflow projects keep startup context progressive: agents load
`AGENTS.md`, `project-agent-context.md`, a filled `project-brief.md` when
available, and guard/detector output first. The guard reads
`context-policy.json` as a machine contract; `check` is read-only for doctor and
verifier, while `preflight` intentionally refreshes `.agents/state/context-pack.json`.
Protected `pre-edit --ack` decisions are logged under `.agents/state/`, and
generated Claude edit/write hooks route file edits through the same guard. This
is a file-edit guardrail, not a security boundary for arbitrary Bash commands.
Mode contracts, handoff schema, council workflow, Karpathy workflow, and skills
are read on demand. The generated verifier measures estimated token budgets for
the core startup and on-demand context; kit text above a gate fails and project
content (brief, project context, USER regions and
detector-filled managed blocks) above a gate warns, so context drift is caught
before it becomes a recurring per-session cost.
The first 10 minutes path is executable: `--first-10` prints the operator path,
`scripts/agent-onboarding.sh next` prints the current missing onboarding pieces,
and `scripts/agent-onboarding.sh check` is the strict readiness gate. The strict
gate requires a filled brief, a filled tech-stack Markdown spec, existing
project-relative source evidence files, non-empty evidence claims, and
non-empty verification command/purpose/source fields.
Generated target verifiers also support machine-readable output:

```bash
scripts/verify-ai-deps.sh --json
```

Seat assignments and the capability catalog live in
`docs/agent-configs/seats.json`, initialized once by `scripts/agent-seats.sh`.
Update its `catalog.models` when adding model capabilities, and use `set` or
`wizard` to change assignments. An existing `model-profiles.json` is retained
as migration input only when seats are missing.

Schema and provenance artifacts are copied into generated targets under
`docs/agent-configs/bootstrap-multi-agent-project/{schemas,provenance}/`.
The generated verifier uses manual contract validation for the bootstrap lock,
active seats configuration, context policy, project tech-stack contract, schema
catalog metadata, and rtk checksum manifest. The schema files are published
reference schemas for external tooling rather than a generic runtime JSON Schema
engine. The generated rtk installer resolves expected release checksums from the
provenance manifest before extracting a downloaded asset.

Project onboarding is the intended second step after `--workflow full`: an
agent scans the target project, fills `docs/agent-configs/project-brief.md`,
updates project-specific tech-stack details in `project-agent-context.md`, and
fills `docs/superpowers/specs/project-tech-stack.md` plus its lightweight
`project-tech-stack.json` contract with source-backed stack, module,
convention, and verification notes. The onboarding helper computes readiness
from those files each time rather than writing a second status file.

The old compatibility entrypoints remain at:

```bash
scripts/bootstrap-multi-agent-project.sh
scripts/install-agent-bootstrap-home.sh
```

Those wrappers delegate to this bundle.

## Superpowers policy

Superpowers is an external upstream at <https://github.com/obra/superpowers>.
Harness-kit does not install, update, or synchronize it and adds no updater;
upstream already owns host-specific installation paths.

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
