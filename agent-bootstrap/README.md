# Agent Bootstrap Bundle

This directory is the copyable source bundle for portable agent infrastructure.
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
- `agent-hook.sh`, `detect-agent-tech-stack.sh`, `verify-ai-deps.sh`,
  `install-rtk.sh`, and `rtk` — full-workflow runtime snapshots generated into
  bootstrapped projects.

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
```

For a one-off copy, you can also copy this entire `agent-bootstrap/` directory
to another machine or project and run `install-agent-bootstrap-home.sh` from
inside the copied directory.

After changing this bundle, run:

```bash
scripts/test-bootstrap-multi-agent-project.sh
```

The test verifies that canonical home export matches this directory and that
the runtime snapshots still match generated `--workflow full` output.

Generated full-workflow projects keep startup context progressive: agents load
`AGENTS.md`, `project-agent-context.md`, a filled `project-brief.md` when
available, and detector output first; mode contracts, handoff schema, council
workflow, Karpathy workflow, and skills are read on demand. Generated doctor
and verifier commands report estimated token budgets so context drift is
visible before it becomes a recurring per-session cost.

The old compatibility entrypoints remain at:

```bash
scripts/bootstrap-multi-agent-project.sh
scripts/install-agent-bootstrap-home.sh
```

Those wrappers delegate to this bundle.
