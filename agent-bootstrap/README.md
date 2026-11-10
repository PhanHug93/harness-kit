# Harness Kit bundle

This folder is the whole Harness Kit as one copyable bundle. The version is in
`VERSION`; `MANIFEST.md` lists every file and its drift rule.

Install, reinstall or update a project from its root:

```bash
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.11.10.1/agent-bootstrap/harness-kit-one-shot.sh | bash
```

Offline, from a copy of this folder (`--source-dir` is the folder that holds
`agent-bootstrap/`, for example `$HOME/dev` for a home install):

```bash
cd /path/to/project
bash /path/to/agent-bootstrap/harness-kit-one-shot.sh --source-dir /path/to
```

To keep a home copy and the shell helpers (`agent-upgrade`, `agent-init`, …),
run `bash install-agent-bootstrap-home.sh --write-zshrc` from this folder.

## Contents

- `harness-kit-one-shot.sh`: the entry; fetches a release into
  `<project>/.harness-kit/v<version>/` and runs its `harness-kit-run.sh`.
  Projects get it as `scripts/harness-kit.sh`; `harness-kit-one-shot-upgrade.sh`
  is an identical copy under the old name.
- `harness-kit-run.sh`: installs, reinstalls or updates one project and runs
  `migrations/`.
- `bootstrap-multi-agent-project.sh`: the generator. It needs `lib/` beside it;
  copy the whole folder, never the script alone. `lib/retirement.py` and
  `lib/knowledge.py` stay in the bundle.
- `agent-bootstrap-update.sh` and `install-agent-bootstrap-home.sh`: the home
  install and its Git-backed updater.
- `agent-*.sh`, `agent-tier.py`, `detect-agent-tech-stack.sh`,
  `verify-ai-deps.sh`, `install-git-hooks.sh`, `githooks/`: the runtime
  scripts a project receives under `scripts/` (the writers copy them). Run
  them from a generated project.
- `policies/`, `schemas/`, `templates/`, `model-profiles/`: the context policy
  and retired-file inventory, the JSON schemas, the templates, and legacy
  model defaults read only during migration.

## Read more

- [README](https://github.com/PhanHug93/harness-kit/blob/main/README.md):
  using the kit.
- [Reference](https://github.com/PhanHug93/harness-kit/blob/main/docs/agent-configs/bootstrap-multi-agent-project/README.md):
  layout, commands, upgrade rules, budgets, schemas.
- [Contributing](https://github.com/PhanHug93/harness-kit/blob/main/CONTRIBUTING.md):
  changing, testing and releasing the kit.
