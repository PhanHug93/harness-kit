# Harness Kit

Harness Kit is a portable, self-testing multi-agent harness kit for adding a
predictable AI-assisted workflow to an existing project. It generates local
instructions, configurable agent seats, onboarding helpers, runtime checks, and
handoff guidance without replacing the project's application code.

Current release: [`2026.09.10.1`](agent-bootstrap/VERSION)

## What changes for the user

The full workflow gives each participant a clear responsibility:

1. `@spec` analyzes the problem and prepares the specification.
2. `@gate` checks whether the specification is complete enough to implement.
3. `@build` implements the approved, bounded change.
4. A fresh `@verify` review checks the result and its verification evidence.
5. `@audit` performs an independent cross-review.
6. `@owner` accepts, revises, escalates, or closes the task.

Coding cannot start until the technical review records that the task is ready
for the configured coding model. The coding pass may send an apparently ready
task back for clarification, but it cannot turn a blocking verdict into an
approval. After two unsuccessful remediation returns, the user decides whether
another bounded pass is worth its cost.

This is a coordination protocol, not an autonomous agent runner. The user opens
each host session; Harness Kit does not launch one AI host from another.

## Install on a new machine

Requirements: Bash, `python3`, Git, and either `sha256sum` or `shasum`.

Export the bundle to its canonical home and install the shell helpers:

```bash
git clone https://github.com/PhanHug93/harness-kit.git
cd harness-kit
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc
source ~/.zshrc
```

Apply the full workflow to a project:

```bash
cd /path/to/project
agent-init --workflow full
bash scripts/install-rtk.sh
scripts/agent-hook.sh doctor
scripts/agent-guard.sh preflight
scripts/agent-onboarding.sh next
```

Open an agent session and run `/project-onboarding`, then finish the readiness
check:

```bash
scripts/agent-onboarding.sh check
```

The same first-run guidance remains available through `agent-init --first-10`
or `agent-init --next`.

rtk is intentionally hard-pinned to the bundle's audited version so projects
do not drift with an unreviewed upstream release.

## Upgrade an existing project to 2026.09.10.1

### Option A: one-shot pinned upgrade

Use this when upgrading from another machine or when the canonical Harness Kit
home is missing or stale.

1. Start in the target project's Git repository with important work committed.
2. Run the pinned release upgrader:

   ```bash
   cd /path/to/project
   curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.09.10.1/agent-bootstrap/harness-kit-one-shot-upgrade.sh | bash
   ```

3. The upgrader installs release `2026.09.10.1` into
   `$HOME/dev/agent-bootstrap`, creates an upgrade branch, and generates
   reviewable candidates instead of overwriting existing managed files.
4. Inspect the result before accepting candidates:

   ```bash
   agent-init --status
   agent-init --status --json
   agent-init --diff
   agent-init --upgrade-plan
   ```

5. Apply only after reviewing the generated differences:

   ```bash
   agent-init --apply-candidates
   ```

6. Refresh local tools and verify the upgraded target:

   ```bash
   bash scripts/install-rtk.sh
   scripts/agent-hook.sh doctor
   scripts/agent-guard.sh preflight
   scripts/agent-guard.sh pre-final --run-verify
   scripts/verify-ai-deps.sh --json
   ```

7. Review `git status` before committing project-owned changes. Generated
   harness files are local-only by default and should not be pushed accidentally.

### Option B: update an existing canonical installation

Use this when the `agent-update`, `agent-upgrade`, and `agent-init` shell helpers
are already available:

```bash
cd /path/to/project
agent-update --check
agent-update --self-update
agent-upgrade --plan
agent-init --status
agent-init --diff
agent-init --apply-candidates
scripts/agent-hook.sh doctor
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
scripts/verify-ai-deps.sh --json
```

The safe order is always:

> check → update the bundle → plan → inspect differences → apply candidates → verify

Do not use `--force` as a routine upgrade path. It is an explicit overwrite
mode; normal upgrades preserve existing managed files and propose changes beside
them as `*.generated.<timestamp>` candidates.

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
- A local-only `.gitignore` block, a versioned bootstrap lock, and a pre-push
  check for harness files that were already tracked.

Running without `--workflow full` installs the smaller `infra` preset.

## Safe generation and upgrades

Existing files are preserved by default. Conflicts become visible
`*.generated.<timestamp>` candidates, and `agent-init --diff` previews them.
`agent-init --apply-candidates` promotes only reviewed paths from the generated
allowlist, leaving unrelated generated files alone. Filled project briefs,
tech-stack evidence, and USER overlay sections survive regeneration.

`agent-init --status --json` reports bundle version, installed version, drift,
and pending candidates for tooling or CI.

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

`pre-final --run-verify` runs concrete fast verification commands and records
the real report at `.agents/state/last-verify-report.json`. Placeholder commands
are warned about rather than reported as successful. Use
`--verify-scope full` only after reviewing heavier build commands.

Agent Guard protects known files and detects stale context, but it is a thin
file-edit guardrail, not a security boundary for arbitrary Bash commands. Task
packets are ignored, ephemeral, and convention-controlled; Git does not protect
their append-only history.

Generated doctor and verifier commands report two estimated context budgets:

- core startup context: gate `4000`, amber above `3800`;
- full on-demand workflow context: gate `6200`, amber above `5900`.

The core estimate covers `AGENTS.md`, project context, and the project brief. It
excludes tool-specific wrappers such as `CLAUDE.md` and `GEMINI.md`. Amber means
the target still passes but should be measured again before adding more always-on
guidance.

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
updated instructions through the normal reviewed upgrade/candidate flow.

Run all affected entrypoints before publishing bundle changes:

```bash
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-one-shot-upgrade.sh
bash scripts/test-bootstrap-multi-agent-project.sh
```

The main test verifies canonical-home export, generated runtime mirrors,
manifest inventory, onboarding fixtures, model routing, non-destructive
migration, context budgets, and version pins. Bump `agent-bootstrap/VERSION`,
the entrypoint version, manifest version, one-shot defaults, documentation pins,
and changelog together.

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

A `v5.1.0` match was reported from a separate environment comparison, not from
this repository; reverify it before any update.

## License

MIT — see [`LICENSE`](LICENSE). The `doubt-driven` skill is adapted from
[`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) (MIT) —
see [`NOTICE`](NOTICE).
