# agent-bootstrap

Portable, self-testing multi-agent harness kit that generates agent runtime infrastructure (Claude, Codex,
Gemini, Cursor, Windsurf) into any project. One command stands up agent entry
docs, mode contracts, a tech-stack detector, runtime hooks, an onboarding
scaffold, Agent Guard Lite, and skills — adapting to the target project's stack.

Version: see [`agent-bootstrap/VERSION`](agent-bootstrap/VERSION) (currently `2026.06.18.3`).

## What it generates

Running `--workflow full` into a target project produces:

- Entry docs: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, `.cursor/rules/*`.
- `docs/agent-configs/`: `project-agent-context.md` (auto-detected stack), mode
  contracts, handoff schema, council workflow, Karpathy workflow, model profiles,
  context policy, schema catalog, and rtk provenance manifest.
- `.codex/` (config + mode helper + `/codex:*` bridge commands) and `.claude/commands/*`.
- `scripts/`: tech-stack detector, agent hook, Agent Guard Lite, onboarding readiness helper, rtk wrapper + installer, AI-deps verifier.
- Onboarding scaffold: `project-onboarding.md` + an empty `project-brief.md` + a
  `docs/superpowers/{specs,plans}` skeleton, including
  `docs/superpowers/specs/project-tech-stack.md` and
  `docs/superpowers/specs/project-tech-stack.json` for project-specific stack
  notes filled after an agent scans the target project.
- Skills: `agentmemory-mcp`, `doubt-driven`.
- A `.gitignore` block + `agent-bootstrap.lock.json` recording the detected stack + version.

`infra` (the default, i.e. no `--workflow`) installs the minimal core only.

## Quick start

One-time per machine — export the bundle to a canonical home + shell functions:

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc
source ~/.zshrc
```

Runtime requirements are intentionally ordinary: Bash, `python3`, Git, and a
SHA-256 tool (`sha256sum` or `shasum`). Installing `rtk` is handled by the
generated `scripts/install-rtk.sh`. rtk is intentionally hard-pinned to the
bundle's audited version so generated projects stay stable instead of drifting
with upstream latest releases.

Apply to a project:

```bash
cd /path/to/project
agent-init --workflow full        # bootstrap into the current dir
bash scripts/install-rtk.sh       # pinned git wrapper (required for the "ready" state)
scripts/agent-hook.sh doctor      # validate
scripts/agent-guard.sh preflight  # refresh local context pack
scripts/agent-onboarding.sh next  # print the current onboarding gap
# then open an agent session and run /project-onboarding
scripts/agent-onboarding.sh check # strict gate once onboarding is filled
```

The same guidance is available later with `agent-init --first-10` (or
`agent-init --next`) and in `docs/agent-configs/first-10-minutes.md`.

Inspect or upgrade an existing target:

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

One-shot safe upgrade from another machine/project:

```bash
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.06.18.3/agent-bootstrap/harness-kit-one-shot-upgrade.sh | bash
```

The one-shot path installs the pinned release into `$HOME/dev/agent-bootstrap`,
creates `codex/upgrade-harness-kit` in the target Git repo, generates
non-destructive `*.generated.*` candidates, and leaves candidate application to
review unless `--apply-candidates` is passed.

One-off without the shell function:

```bash
bash /path/to/agent-bootstrap/agent-bootstrap/bootstrap-multi-agent-project.sh \
  --target "$PWD" --workflow full
```

## Safety

Non-destructive by default: existing files are preserved; conflicts are written as
`*.generated.<timestamp>` candidates (kept **visible** in git status for review).
Use `--diff` to preview generated-file drift, and `--apply-candidates` to promote
reviewed bootstrap-generated candidates into place. Candidate promotion is
scoped to the bootstrap generated-file allowlist, so unrelated project files such
as `src/api.generated.ts` are left alone. `--skip-existing` skips existing files
entirely; `--force` overwrites (a `.bak` is kept unless `--no-backup`). The
generator never deletes target files outside explicit generated-candidate
promotion.

## Token economy

The generated startup context is progressive: agents read a small always-on core
first and load heavier docs/skills on demand. The generated `doctor` and verifier
report an estimated token budget for the always-on core (target ≤3000) so harness
context cost stays visible before it becomes a recurring per-session tax. The
reported core is `AGENTS.md`, `project-agent-context.md`, and the project brief;
it excludes tool-specific wrappers such as `CLAUDE.md` and `GEMINI.md`.

## Onboarding contract

Full-workflow targets include `scripts/agent-onboarding.sh`, a read-only
readiness helper that computes status from `project-brief.md` and
`project-tech-stack.json` instead of maintaining another state file. `status`
and `next` guide the first 10 minutes; `check` is the strict gate and exits
non-zero until the brief has no `UNFILLED` marker, required sections are filled,
the tech-stack Markdown spec is filled, source evidence paths point to existing
project files, and verification entries have non-empty command/purpose/source
fields.

## Agent Guard Lite

Generated projects include `docs/agent-configs/context-policy.json` and
`scripts/agent-guard.sh`. The guard is intentionally file-based: `preflight`
writes `.agents/state/context-pack.json`, `check` verifies contracts without
writing local state, `pre-edit <path>` blocks protected context/harness paths
until rerun with `--ack <reason>` and records the acknowledgement locally, and
`pre-final` catches stale context-pack or required-context drift before a
completion claim. Generated Claude hooks route `Edit`/`Write`/`MultiEdit`
through the same path-aware guard. It is a thin enforcement layer, not a daemon
or broker, and not a security boundary for arbitrary Bash commands.

## Contracts and schemas

Generated targets include a JSON schema catalog for humans and external tooling.
The built-in verifier performs manual contract validation for the bootstrap lock,
model profiles, context policy, project tech-stack contract, schema catalog
metadata, and rtk provenance manifest; it does not require or invoke a generic
JSON Schema engine at runtime.

Model defaults are data, not script edits: generated Codex helpers read
`docs/agent-configs/model-profiles.json`, while `CODEX_MODEL_OVERRIDE`,
mode-specific overrides, and `CODEX_MODEL_PROFILE` remain available for
one-shot capacity or migration handling.

## Repo layout

- `agent-bootstrap/` — the copyable bundle: thin entrypoint, updater, sourced `lib/*.sh`,
  runtime snapshots, templates, schemas, `VERSION`, `MANIFEST.md`. Copy this
  whole folder to apply the kit elsewhere; the entrypoint sources `lib/`, so
  never copy the script alone.
- `scripts/` — thin wrappers that delegate into `agent-bootstrap/`, plus the drift test.
- `docs/agent-configs/bootstrap-multi-agent-project/` — design doc + stack/workflow templates.

## Development

The drift test is the gate after any change to the bundle:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

It verifies the canonical home export, the generated runtime snapshots, and the
`MANIFEST.md`/installer/test inventory are all consistent, and that generated output
stays byte-identical. It also runs a small deterministic onboarding fixture eval
with filled source-backed `project-tech-stack.json` golden contracts, guards
source template drift, and prevents root `scripts/` from accumulating generated
runtime snapshots again. Bump
`agent-bootstrap/VERSION`, the entrypoint
`AGENT_BOOTSTRAP_VERSION`, and `MANIFEST.md` together for any bundle change.

## License

MIT — see [`LICENSE`](LICENSE). The `doubt-driven` skill is adapted from
[`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) (MIT) — see
[`NOTICE`](NOTICE).
