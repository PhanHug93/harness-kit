# One-shot install and update — journal

Spec: `docs/superpowers/specs/2026-10-15-oneshot-install-update-design.md`.
Branch `feature/improve_update_version`, from main `428a377`.

## 2026-10-16 — delivered in one commit

What shipped:

- One command installs, reinstalls or updates a project:
  `harness-kit-one-shot.sh` (also emitted as `scripts/harness-kit.sh`) fetches a
  release into `.harness-kit/v<version>/` and runs its `harness-kit-run.sh`.
  Phases preflight, stage, apply, migrate, verify, report; exit 0/3/1/2;
  `report.json` (`harness-kit-run-report/v1`) and project knowledge
  (`harness-project-knowledge/v1`).
- Staging no longer copies the project: detection reads the real tree, staging
  holds only kit outputs and the baseline.
- No overwrite: `--keep` pins, plain `--apply-candidates` keeps edited files,
  plan JSON carries baseline/local/new hashes; `--take-kit`, `--resolved`,
  `--keep-local`.
- Migrations framework with three decisions (`next-untrack-local-records`,
  `next-ignore-block-to-exclude`, `next-retire-files`), renamed at release.
- The local-only ignore block goes to `.git/info/exclude` by default and is
  refreshed when the kit adds entries.
- Verification evidence: contract-first pre-final, `unverified` is never a pass,
  report v2, `agent-guard.sh baseline`, session-scoped Stop hook, `@build`
  close-out, delta review for later `@gate` rounds.
- Seat rules: the 31 findings of the seat audit are fixed.
- Context budget counts what seats read; only kit text fails the gate.

Results:

- Full tier once before the commit: the bootstrap suite (27 minutes, with the
  new verification-evidence, entry, knowledge, migrations, staging, one-shot
  and matrix tests), the one-shot upgrade test with tagged history, the
  tagless fixture migration, seats and launcher without `PATH`, the generated
  target verifier, the release, guard and retirement tests and the CI
  shellcheck list all pass. The first two suite runs failed on defects fixed
  before the commit: a normal upgrade sent the lock down the overwrite path,
  and one fixture committed a `.gitignore` holding the local-only block.
- Fresh full-workflow target: kit core 1,914 tokens, kit on-demand 5,195
  (6,793 before trimming); with project content 2,557 / 5,863. Gate 6,200,
  amber above 5,900.
- 50,003 committed files plus 5,000 ignored: old v2026.10.13.2 one-shot 241 s
  (236 s on a second run); new install 13.7 s with no staging seed; new `--plan`
  7.6 s with 81 seeded files.

Deviations from the spec:

- Migrations ship as `next-<slug>.sh` and `scripts/release.sh <version>` renames
  them (and their inventory rows).
- The staging cache (generate once per key) is not built; a run generates
  three times (inventory, stage, apply).
- Additions: `--ref` alias in the entry, `--take-kit all`, migration status
  `failed` and retry, run lock, failure report on errors and interrupts,
  `AGENT_BOOTSTRAP_STAMP` so one run shares one journal, the lock file is
  always rewritten, a stale `.gitignore` block is left alone and the current
  block goes to the exclude file.
- Plain `--apply-candidates` also keeps files that have no baseline.
- Not every task was written test-first; reviews found real defects in the
  staging, orchestrator and generator code before commit (a cleanup that could
  remove the working directory, `--take-kit` bypassing the protected-branch
  check, a lock takeover race, failed migrations never retried).

Known limits:

- Projects without a harness baseline (older than the baseline feature) see
  every changed kit file as a conflict on their first update; `--take-kit all`
  resolves them with backups.
- Strict `pre-final` now fails projects that declare no runnable command.
- Pins cover files the generator writes; the ignore blocks and seats seeding
  ignore them.
- A stale `.gitignore` block prints a warning until
  `ignore-block-to-exclude` is accepted.
