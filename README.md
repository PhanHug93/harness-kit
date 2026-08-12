# Harness Kit

Harness Kit is a portable, self-testing multi-agent harness kit for adding a
predictable AI-assisted workflow to an existing project. It generates local
instructions, routed model profiles, onboarding helpers, runtime checks, and
handoff guidance without replacing the project's application code.

Current release: [`2026.08.10.1`](agent-bootstrap/VERSION)

## What changes for the user

The full workflow gives each participant a clear responsibility:

1. Claude analyzes the problem and prepares the specification.
2. Codex Sol checks whether the specification is safe and complete enough to
   implement.
3. Codex Luna implements the approved, bounded change.
4. A fresh Codex Sol review checks the result and its verification evidence.
5. Claude performs an independent cross-review.
6. The user accepts, revises, escalates, or closes the task.

Coding cannot start until the technical review records that the task is ready
for the configured coding model. The coding pass may send an apparently ready
task back for clarification, but it cannot turn a blocking verdict into an
approval. An initial implementation may be followed by at most two remediation
rounds before the decision returns to the user.

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

## Upgrade an existing project to 2026.08.10.1

### Option A: one-shot pinned upgrade

Use this when upgrading from another machine or when the canonical Harness Kit
home is missing or stale.

1. Start in the target project's Git repository with important work committed.
2. Run the pinned release upgrader:

   ```bash
   cd /path/to/project
   curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.08.10.1/agent-bootstrap/harness-kit-one-shot-upgrade.sh | bash
   ```

3. The upgrader installs release `2026.08.10.1` into
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
packet ownership and append-only history are conventions; host, model, and session independence are declarations rather than proof; and Sol authorization entries are audit declarations. Important durable decisions
belong in the project's tracked specification, plan, or memory rather than only
in the local task packet.

## Model routing

The default profile uses three configurable Codex routes:

| Work | Default | Fallback |
| --- | --- | --- |
| Planning and specification review | `gpt-5.6-sol` | `gpt-5.6-terra` |
| Bounded implementation | `gpt-5.6-luna` | `gpt-5.6-terra` |
| Final technical review | `gpt-5.6-sol` | `gpt-5.6-terra` |

Defaults live in `docs/agent-configs/model-profiles.json` in a generated target.
`CODEX_MODEL_OVERRIDE`, the mode-specific override variables,
`CODEX_MODEL_PROFILE`, and `CODEX_REASONING_EFFORT` remain available for an
explicit operator choice. Claude cross-review is host behavior, not a fourth
Codex route.

## What the full workflow generates

- Entry guidance for Claude, Codex, Gemini, Cursor, and Windsurf.
- Canonical role, mode, handoff, context, and model-profile documents under
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
and pending candidates for tooling or CI. Existing model profiles are migrated
through the same candidate path rather than silently replaced.

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
