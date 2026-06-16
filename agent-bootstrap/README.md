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
- `lib/` — sourced libraries (`core`, `detect`, `render`, `writers-runtime`,
  `writers-docs`, `onboarding`) that the entrypoint sources at runtime. The
  entrypoint REQUIRES this directory beside it — copy the whole bundle, never
  the entrypoint script alone.
- `install-agent-bootstrap-home.sh` — exports this bundle to a canonical
  `$AGENT_BOOTSTRAP_HOME` directory such as `$HOME/dev/agent-bootstrap`.
- `agent-tech-stack-lib.sh` — shared stack detector library used by the
  bootstrap script.
- `agent-hook.sh`, `agent-guard.sh`, `agent-onboarding.sh`,
  `detect-agent-tech-stack.sh`, `verify-ai-deps.sh`,
  `install-rtk.sh`, and `rtk` — full-workflow runtime snapshots generated into
  bootstrapped projects.
- `model-profiles/` — model defaults copied into generated target projects.
- `policies/` — Agent Guard Lite context policy copied into generated target
  projects as `docs/agent-configs/context-policy.json`.
- `schemas/` — JSON Schema artifacts for generated lock/status/verifier report
  contracts, model profiles, project tech-stack, and context policy.
- `templates/` — base, stack overlay, and workflow templates copied into
  generated target projects.
- `provenance/` — pinned third-party runtime checksums, currently rtk release
  assets.

Only `bootstrap-multi-agent-project.sh` and `install-agent-bootstrap-home.sh`
are operator entrypoints from this folder. Runtime snapshots are kept here for
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

Runtime requirements are Bash, `python3`, Git, and a SHA-256 tool
(`sha256sum` or `shasum`). The generated `scripts/install-rtk.sh` handles the
pinned `rtk` download and checksum verification.

Inspect an existing target before upgrading:

```bash
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --status
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --status --json
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --first-10
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --diff
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --upgrade-plan
bash "$HOME/dev/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$PWD" --apply-candidates
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

Generated full-workflow projects keep startup context progressive: agents load
`AGENTS.md`, `project-agent-context.md`, a filled `project-brief.md` when
available, and guard/detector output first. The guard reads
`context-policy.json` as a machine contract; `check` is read-only for doctor and
verifier, while `preflight` intentionally refreshes `.agents/state/context-pack.json`.
Protected `pre-edit --ack` decisions are logged under `.agents/state/`, and
generated Claude edit/write hooks route file edits through the same guard. Mode
contracts, handoff schema, council workflow, Karpathy workflow, and skills are
read on demand. Generated doctor
and verifier commands report estimated token budgets so context drift is
visible before it becomes a recurring per-session cost.
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

Model defaults are copied from `model-profiles/codex-model-profiles.json` into
generated target projects as `docs/agent-configs/model-profiles.json`. Update
that catalog instead of editing generated shell helpers when model availability
changes.

Schema and provenance artifacts are copied into generated targets under
`docs/agent-configs/bootstrap-multi-agent-project/{schemas,provenance}/`.
The generated verifier checks the bootstrap lock, model profile catalog,
schema catalog, and rtk checksum manifest as live contracts. The generated rtk
installer resolves expected release checksums from the provenance manifest
before extracting a downloaded asset.

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
