# agent-bootstrap

Portable, self-testing kit that generates a multi-agent harness (Claude, Codex,
Gemini, Cursor, Windsurf) into any project. One command stands up agent entry
docs, mode contracts, a tech-stack detector, runtime hooks, an onboarding
scaffold, and skills — adapting to the target project's stack.

Version: see [`agent-bootstrap/VERSION`](agent-bootstrap/VERSION) (currently `2026.06.14.6`).

## What it generates

Running `--workflow full` into a target project produces:

- Entry docs: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`, `.cursor/rules/*`.
- `docs/agent-configs/`: `project-agent-context.md` (auto-detected stack), mode
  contracts, handoff schema, council workflow, Karpathy workflow.
- `.codex/` (config + mode helper + `/codex:*` bridge commands) and `.claude/commands/*`.
- `scripts/`: tech-stack detector, agent hook, rtk wrapper + installer, AI-deps verifier.
- Onboarding scaffold: `project-onboarding.md` + an empty `project-brief.md` + a
  `docs/superpowers/{specs,plans}` skeleton.
- Skills: `agentmemory-mcp`, `doubt-driven`.
- A `.gitignore` block + `agent-bootstrap.lock.json` recording the detected stack + version.

`infra` (the default, i.e. no `--workflow`) installs the minimal core only.

## Quick start

One-time per machine — export the bundle to a canonical home + shell functions:

```bash
agent-bootstrap/install-agent-bootstrap-home.sh --write-zshrc
source ~/.zshrc
```

Apply to a project:

```bash
cd /path/to/project
agent-init --workflow full        # bootstrap into the current dir
bash scripts/install-rtk.sh       # pinned git wrapper (required for the "ready" state)
scripts/agent-hook.sh doctor      # validate
# then open an agent session and run /project-onboarding to fill
# docs/agent-configs/project-brief.md with deep project context
```

One-off without the shell function:

```bash
bash /path/to/agent-bootstrap/agent-bootstrap/bootstrap-multi-agent-project.sh \
  --target "$PWD" --workflow full
```

## Safety

Non-destructive by default: existing files are preserved; conflicts are written as
`*.generated.<timestamp>` candidates (kept **visible** in git status for review).
`--skip-existing` skips existing files entirely; `--force` overwrites (a `.bak` is
kept unless `--no-backup`). The generator never deletes target files.

## Token economy

The generated startup context is progressive: agents read a small always-on core
first and load heavier docs/skills on demand. The generated `doctor` and verifier
report an estimated token budget for the always-on core (target ≤3000) so harness
context cost stays visible before it becomes a recurring per-session tax.

## Repo layout

- `agent-bootstrap/` — the copyable bundle: thin entrypoint, sourced `lib/*.sh`,
  runtime snapshots, `VERSION`, `MANIFEST.md`. Copy this whole folder to apply the
  kit elsewhere; the entrypoint sources `lib/`, so never copy the script alone.
- `scripts/` — thin wrappers that delegate into `agent-bootstrap/`, plus the drift test.
- `docs/agent-configs/bootstrap-multi-agent-project/` — design doc + stack/workflow templates.

## Development

The drift test is the gate after any change to the bundle:

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
```

It verifies the canonical home export, the generated runtime snapshots, and the
`MANIFEST.md`/installer/test inventory are all consistent, and that generated output
stays byte-identical. Bump `agent-bootstrap/VERSION`, the entrypoint
`AGENT_BOOTSTRAP_VERSION`, and `MANIFEST.md` together for any bundle change.

## License

MIT — see [`LICENSE`](LICENSE). The `doubt-driven` skill is adapted from
[`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) (MIT) — see
[`NOTICE`](NOTICE).
