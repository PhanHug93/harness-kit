# Solo Agent Bootstrap Workflow

Goal: one-shot setup of Codex/Claude agent infrastructure when switching to any
project, without maintaining a source template repo, build step, base64 payload,
or generated dist artifact.

## Decision

Use a repo-local source bundle plus one canonical home folder and shell
functions. The source bundle is copyable as one directory:

```text
agent-bootstrap/
├── README.md
├── VERSION
├── MANIFEST.md
├── bootstrap-multi-agent-project.sh
├── install-agent-bootstrap-home.sh
├── lib/
│   ├── core.sh
│   ├── detect.sh
│   ├── render.sh
│   ├── writers-runtime.sh
│   ├── writers-docs.sh
│   └── onboarding.sh
├── agent-tech-stack-lib.sh
├── agent-hook.sh
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
├── lib/
│   ├── core.sh
│   ├── detect.sh
│   ├── render.sh
│   ├── writers-runtime.sh
│   ├── writers-docs.sh
│   └── onboarding.sh
├── agent-tech-stack-lib.sh
├── agent-hook.sh
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
- `.claude/settings.json` and `.claude/README.md`.
- `scripts/detect-agent-tech-stack.sh`.
- `scripts/agent-tech-stack-lib.sh`.
- `scripts/agent-hook.sh`.
- `scripts/install-rtk.sh` and `scripts/rtk`.
- `scripts/verify-ai-deps.sh`.
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
- `docs/agent-configs/project-onboarding.md` + `.claude/commands/project-onboarding.md`
  (onboarding procedure and command).
- `docs/agent-configs/project-brief.md` (empty deep-context brief, filled by
  onboarding).
- `docs/superpowers/specs/README.md` + `docs/superpowers/plans/README.md`
  (specs/plans skeleton).

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
After bootstrap, install it in the target project:

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
scripts/verify-ai-deps.sh
```

When editing `agent-bootstrap/`, keep `VERSION` aligned with
`bootstrap-multi-agent-project.sh --version` and update `MANIFEST.md` if files
or drift rules change.

Validate a generated target project:

```bash
scripts/detect-agent-tech-stack.sh --summary
scripts/verify-ai-deps.sh
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
- load-bearing template extraction,
- CHANGELOG and multi-file docs split.

Those are valid for a public reusable framework. They are unnecessary overhead
for this solo workflow.
