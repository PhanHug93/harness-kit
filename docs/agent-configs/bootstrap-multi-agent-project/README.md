# Solo Multi-Agent Harness Kit Workflow

Goal: one-shot setup of Codex/Claude multi-agent harness infrastructure when
switching to any project, without maintaining a source template repo, build
step, base64 payload, or generated dist artifact.

## Decision

Use a repo-local source bundle plus one canonical home folder and shell
functions. The source bundle is copyable as one directory:

```text
agent-bootstrap/
├── README.md
├── VERSION
├── MANIFEST.md
├── bootstrap-multi-agent-project.sh
├── agent-bootstrap-update.sh
├── install-agent-bootstrap-home.sh
├── lib/
│   ├── core.sh
│   ├── detect.sh
│   ├── render.sh
│   ├── writers-runtime.sh
│   ├── writers-docs.sh
│   └── onboarding.sh
├── model-profiles/
│   └── codex-model-profiles.json
├── policies/
│   └── agent-context-policy.json
├── provenance/
│   └── rtk-v0.37.2.sha256
├── schemas/
│   ├── agent-context-policy-v1.schema.json
│   ├── agent-bootstrap-lock-v1.schema.json
│   ├── agent-bootstrap-status-v1.schema.json
│   ├── agent-bootstrap-verify-report-v1.schema.json
│   ├── agent-model-profiles-v1.schema.json
│   └── agent-project-tech-stack-v1.schema.json
├── templates/
│   ├── base/
│   ├── overlays/
│   └── workflows/
├── agent-tech-stack-lib.sh
├── agent-hook.sh
├── agent-guard.sh
├── agent-onboarding.sh
├── detect-agent-tech-stack.sh
├── install-rtk.sh
├── verify-ai-deps.sh
└── rtk
```

The canonical home folder receives the same files:

```text
$HOME/dev/agent-bootstrap/
├── README.md
├── VERSION
├── MANIFEST.md
├── bootstrap-multi-agent-project.sh
├── agent-bootstrap-update.sh
├── lib/
│   ├── core.sh
│   ├── detect.sh
│   ├── render.sh
│   ├── writers-runtime.sh
│   ├── writers-docs.sh
│   └── onboarding.sh
├── model-profiles/
├── policies/
├── provenance/
├── schemas/
├── templates/
├── agent-tech-stack-lib.sh
├── agent-hook.sh
├── agent-guard.sh
├── agent-onboarding.sh
├── detect-agent-tech-stack.sh
├── install-rtk.sh
├── verify-ai-deps.sh
└── rtk
```

Only `bootstrap-multi-agent-project.sh` is required for daily use. `VERSION`
and `MANIFEST.md` identify the copied bundle. The runtime scripts are kept as
full-workflow snapshots of what the bootstrap script generates into each target
project; `scripts/test-bootstrap-multi-agent-project.sh` guards that drift.
Run those runtime scripts from generated target projects, not from the
canonical home folder.

## One-Time Setup

From this repository:

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc
source ~/.zshrc
```

Default target:

```text
$HOME/dev/agent-bootstrap
```

Override target if needed:

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --home "$HOME/dev/agent-bootstrap" --write-zshrc
```

The installer:

- copies the portable bootstrap files into the canonical folder,
- backs up changed canonical files before replacing them,
- initializes local history through the repo-pinned `./scripts/rtk git` when rtk
  is available,
- installs an idempotent managed block in `~/.zshrc` only when `--write-zshrc`
  is provided.

Preview without writing:

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --dry-run
```

Compatibility wrappers remain at:

```bash
scripts/install-agent-bootstrap-home.sh
scripts/bootstrap-multi-agent-project.sh
```

They delegate to the `agent-bootstrap/` bundle so existing commands keep
working.

## Installed Shell Functions

The managed shell block is:

```bash
export AGENT_BOOTSTRAP_HOME="$HOME/dev/agent-bootstrap"
agent-init()    { bash "$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target "$PWD" "$@"; }
agent-doctor()  { ./scripts/agent-hook.sh doctor; }
agent-refresh() { agent-init --refresh-lock; }
agent-update()  { bash "$AGENT_BOOTSTRAP_HOME/agent-bootstrap-update.sh" --home "$AGENT_BOOTSTRAP_HOME" "$@"; }
agent-upgrade() { agent-update --target "$PWD" --plan "$@"; }
```

## Daily Workflow

```bash
cd /path/to/new-project
agent-init --workflow full
agent-doctor
```

For infra-only projects:

```bash
agent-init
agent-doctor
```

Refresh lock after intentional stack/module changes:

```bash
agent-refresh
```

Lifecycle inspection and upgrade preview:

```bash
agent-update --check
agent-update --self-update
agent-upgrade --plan
agent-init --status
agent-init --status --json
agent-init --first-10
agent-init --diff
agent-init --upgrade-plan
agent-init --apply-candidates
```

One-shot safe upgrade for an old project on another machine:

```bash
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.06.24.1/agent-bootstrap/harness-kit-one-shot-upgrade.sh | bash
```

That script installs the pinned harness release, creates
`codex/upgrade-harness-kit`, runs the generator without `--force`, and leaves
`*.generated.*` candidates visible for review.

`--diff` materializes a temporary copy of the target, regenerates harness files
there, normalizes volatile timestamps and temp paths, and prints generated-file
diffs without mutating the real target.
`--apply-candidates` promotes the latest reviewed `*.generated.*` candidate for
each generated path and removes older candidates for that same path.

## Optional Symlink

If you want a target project to always execute the canonical bootstrap script
instead of copying it:

```bash
mkdir -p scripts
ln -sf "$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" scripts/bootstrap-multi-agent-project.sh
```

This is optional. Normal generated projects are self-contained after
`agent-init` runs.

## What Bootstrap Generates

Core infra, installed by default:

- `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, Cursor pointer rules.
- `docs/agent-configs/project-agent-context.md`.
- `docs/agent-configs/agent-bootstrap.lock.json`.
- `docs/agent-configs/model-profiles.json`.
- `docs/agent-configs/context-policy.json`.
- `docs/agent-configs/bootstrap-multi-agent-project/schemas/*.schema.json`.
- `docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256`.
- `scripts/verify-ai-deps.sh`, which performs manual contract validation for the
  bootstrap lock, model profile catalog, context policy, schema catalog metadata,
  Agent Guard Lite, and rtk provenance manifest.
- `.claude/settings.json` and `.claude/README.md`.
- `scripts/detect-agent-tech-stack.sh`.
- `scripts/agent-tech-stack-lib.sh`.
- `scripts/agent-hook.sh`.
- `scripts/agent-guard.sh`.
- `scripts/install-rtk.sh` and `scripts/rtk`.
- local-only `.gitignore` block for agent/runtime state.

With `--workflow full`, it also installs:

- `docs/agent-configs/agent-mode-contracts.md`.
- `docs/agent-configs/agent-handoff-schema.md`.
- `docs/agent-configs/karpathy-llm-coding-agent-config.md`.
- `docs/agent-configs/llm-council-agent-workflow.md`.
- `.codex/config.toml`, `.codex/codex-mode.sh`, `.codex/README.md`.
- `.claude/commands/*.md` for planning/coding/reviewing modes, plus
  `/codex:setup`, `/codex:rescue`, and `/codex:status` bridge commands.
- `.agents/skills/doubt-driven/SKILL.md` (generic adversarial-review skill).
- `docs/agent-configs/first-10-minutes.md` (operator path from generation to
  onboarding readiness).
- `docs/agent-configs/project-onboarding.md` + `.claude/commands/project-onboarding.md`
  (onboarding procedure and command).
- `docs/agent-configs/project-brief.md` (empty deep-context brief, filled by
  onboarding).
- `docs/superpowers/specs/project-tech-stack.md` and
  `docs/superpowers/specs/project-tech-stack.json` (empty project-specific
  tech-stack spec plus lightweight machine contract, filled by onboarding).
- `docs/superpowers/specs/README.md` + `docs/superpowers/plans/README.md`
  (specs/plans skeleton).
- `scripts/agent-onboarding.sh` (read-only readiness helper with
  `status`, `next`, and strict `check`).

## Runtime Detection

Bootstrap detects the target stack during generation and installs a runtime
detector:

```bash
scripts/detect-agent-tech-stack.sh --summary
scripts/detect-agent-tech-stack.sh --markdown
```

Agents should run the detector at the start of substantive work. The generated
hook compares detector output against `docs/agent-configs/agent-bootstrap.lock.json`
so stack/module drift becomes explicit.

## Project Onboarding Output

`--workflow full` intentionally generates empty, source-backed context files
instead of guessing project-specific rules. After bootstrap, an agent should run
project onboarding to scan the target project and fill:

- `docs/agent-configs/project-brief.md` for durable architecture/domain context,
- `docs/agent-configs/project-agent-context.md` for project-specific tech-stack
  overrides, protected paths, generated files, commands, and release constraints,
- `docs/superpowers/specs/project-tech-stack.md` and
  `docs/superpowers/specs/project-tech-stack.json` for the verified
  stack/module map, conventions, source evidence, ownership, and verification
  matrix,
- additional `docs/superpowers/specs/<topic>/` files when the scan discovers
  durable domain, architecture, or workflow decisions.

The readiness contract is computed, not duplicated. `scripts/agent-onboarding.sh
status` and `next` read the brief plus `project-tech-stack.json` and report what
is missing; `scripts/agent-onboarding.sh check` exits non-zero until the brief
has no `UNFILLED` marker, the tech-stack Markdown spec is filled, evidence paths
point to existing project files, and verification entries have non-empty
command/purpose/source fields. This gives agents a gate without adding a stale
status file.

## Token-Economy Contract

Generated full-workflow projects use progressive disclosure:

- Startup context is limited to `AGENTS.md`,
  `docs/agent-configs/project-agent-context.md`, a filled
  `docs/agent-configs/project-brief.md` when available, and detector output.
- Workflow docs such as mode contracts, handoff schema, Karpathy workflow, and
  council workflow are read on demand for the task or mode that needs them.
- Skills under `.agents/skills/` are loaded only when their descriptions match
  the current task.

`scripts/verify-ai-deps.sh` and `.codex/codex-mode.sh doctor` report estimated
core startup tokens and on-demand full-workflow tokens. The core startup budget
is 3k estimated tokens; the full-workflow on-demand budget is 6.5k estimated
tokens. Estimates use a portable heuristic: max(chars/4, words*1.3).

## Closed-loop pre-final

The detector emits verification candidates as structured JSON. The standard local close-out path is:

```bash
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
```

`pre-final --run-verify` runs concrete fast detector commands and skips placeholders such as `xcodebuild ... <scheme>` with a warning. Review the detected commands before using `--verify-scope full` to include build/full commands. Results are written to `.agents/state/last-verify-report.json` and a compact event is appended to `.agents/state/session-events.jsonl`.

## Agent Guard Lite

The harness includes a file-based guardrail instead of a daemon, database, or
MCP broker:

- `docs/agent-configs/context-policy.json` tracks required context,
  recommended context, protected path patterns, and the change protocol.
- `scripts/agent-guard.sh preflight` validates required context and writes
  `.agents/state/context-pack.json`.
- `scripts/agent-guard.sh check` validates the same contracts without writing
  local state; verifier and doctor use this read-only path.
- `scripts/agent-guard.sh pre-edit <path>` classifies protected context,
  harness, CI, release, and generated-runtime paths before edits. Protected
  paths exit non-zero unless the agent reruns with `--ack <reason>`; acknowledged
  protected edits are logged under `.agents/state/guard-ack.log`.
- `scripts/agent-guard.sh pre-final` checks that the context pack still matches
  the current policy and required-context file hashes before an agent claims
  completion.
- Generated Claude `Edit`, `Write`, and `MultiEdit` hooks route file paths
  through the same strict `pre-edit` guard.

The layer does not prevent all agent drift. It creates a small, trackable
context rail so drift is easier to detect, review, and roll back. It is not a
security boundary for arbitrary Bash commands.

## Safety

Default behavior is non-destructive:

- Existing target files are preserved.
- Generated candidates are written as `*.generated.<timestamp>` and intentionally
  remain visible in normal git/status review. Review, apply, or delete them
  before considering a harness upgrade complete.
- `--skip-existing` leaves existing target files untouched, including an
  existing `.gitignore`; it still creates missing files.
- `--force` is required to overwrite intentionally.
- Backups are still created unless `--no-backup` is also supplied. Backup files
  are ignored by the managed local-state block.

RTK is required for the harness "ready" state and for token-efficient git
inspection. Freshly bootstrapped projects may run with warnings before RTK is
installed, but `doctor` will keep reporting that the pinned wrapper is missing.
The RTK version is intentionally hard-pinned for stable, reproducible kit
behavior. The generated installer reads expected asset checksums from the
generated provenance manifest and rejects checksum drift. After bootstrap,
install it in the target project:

```bash
bash scripts/install-rtk.sh
```

## Validation

Validate the source scripts in this repository:

```bash
bash -n scripts/bootstrap-multi-agent-project.sh
bash -n scripts/install-agent-bootstrap-home.sh
bash -n agent-bootstrap/bootstrap-multi-agent-project.sh
bash -n agent-bootstrap/install-agent-bootstrap-home.sh
scripts/test-bootstrap-multi-agent-project.sh
scripts/test-onboarding-fixtures.sh
```

When editing `agent-bootstrap/`, keep `VERSION` aligned with
`bootstrap-multi-agent-project.sh --version` and update `MANIFEST.md` if files
or drift rules change.

Validate a generated target project:

```bash
scripts/detect-agent-tech-stack.sh --summary
scripts/agent-guard.sh preflight
scripts/agent-onboarding.sh status
scripts/agent-onboarding.sh check
scripts/verify-ai-deps.sh
scripts/verify-ai-deps.sh --json
scripts/agent-hook.sh doctor
```

For `--workflow full` projects:

```bash
.codex/codex-mode.sh doctor
```

## Explicitly Not In Scope

For the solo workflow, these are intentionally skipped:

- build step and base64 self-extract payload,
- `dist/` artifact management,
- manifest YAML or per-template manifest generation,
- lock v2 and per-template versioning,
- load-bearing template extraction beyond the copyable shell bundle.

Those are valid for a public reusable framework. They are unnecessary overhead
for this solo workflow.
