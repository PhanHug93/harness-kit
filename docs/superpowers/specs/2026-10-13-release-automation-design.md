# One-command release and upgrade preset fixes

Date: 2026-10-13, Asia/Ho_Chi_Minh.
Branch: `feature/verification-feedback` (same single commit as the earlier
sub-projects).
Scope: P1 of the release-friction proposal plus the two small upgrade defects
from P3. Status: approved by the owner on 2026-10-13.

## Problem (verified)

- Tag `v2026.09.10.2` exists while its `agent-bootstrap/VERSION` is still
  `2026.09.10.1`; nothing checks VERSION against the tag.
- A release edits 14 version literals in 8 files by hand; only some are tested.
- Six runtime snapshots are heredoc output copied by hand into
  `agent-bootstrap/` (`install-rtk.sh`, `rtk`, `detect-agent-tech-stack.sh`,
  `agent-tech-stack-lib.sh`, `agent-hook.sh`, `verify-ai-deps.sh`).
- `agent-update --apply` reads `workflow_preset` from the lock top level, but
  the lock stores it under `templates`; a `full` project is regenerated as
  `infra`.
- The one-shot upgrader always runs `--workflow full` and defaults to branch
  `codex/upgrade-harness-kit`, against the branch-naming rule.

## Design

`agent-bootstrap/VERSION` is the single source. `scripts/release.sh` owns an
explicit list of pinned sites (file + pattern, each must match exactly once):
entrypoint `AGENT_BOOTSTRAP_VERSION`, manifest `Version:`, one-shot `DEFAULT_REF`
and its help text, the root README current release / upgrade heading / one-shot
URL / installed release, and the one-shot URL in both bundle READMEs.
Historical mentions (old release notes, specs) are not pins and never change.
`AGENT_TECH_STACK_LIB_VERSION` stays independent.

| Command | Effect |
|---|---|
| `scripts/release.sh --check` | Fails, listing every drift, unless all pins equal VERSION, CHANGELOG has a `## <VERSION>` heading, the template mirror and the runtime snapshots are in sync. |
| `scripts/release.sh <YYYY.MM.DD.N> [--title TEXT]` | Requires a newer version and a non-empty `## Unreleased` section. Rewrites VERSION and all pins, renames `## Unreleased` to `## <version> — <title>`, syncs templates and snapshots, then runs `--check`. Never commits, tags or pushes. |
| `scripts/release.sh --check-tag <tag>` | Fails unless `tag == v<VERSION>` and `--check` passes. CI runs it on every tag push. |

`scripts/sync-runtime-snapshots.sh [--check]` generates a `--workflow full`
target in a temp directory and copies (or compares) every bundle file marked
`# AGENT_BOOTSTRAP_GENERATED` from the generated `scripts/`. The generator stays
the source of truth; snapshots are never edited by hand.

Upgrade fixes:
- `agent-update` reads `templates.workflow_preset` (top-level fallback for old
  locks) and prints the workflow it applies.
- The one-shot upgrader gains `--workflow infra|full`; the default is the
  installed workflow from the lock, else `full` for pre-lock projects. Its
  default branch becomes `feature/upgrade-harness-kit`.

## Verification

- `scripts/test-release.sh` on a copy of the tracked tree: `--check` passes;
  pin drift and snapshot drift fail with the file named; a bump updates every
  pin, renames the changelog heading, keeps historical mentions and passes
  `--check`; bad format, non-increasing version and a missing `## Unreleased`
  are refused; `--check-tag` accepts only `v<VERSION>`.
- Bootstrap test: the hard-coded version assertion becomes `release.sh --check`;
  the updater lifecycle asserts a `full` target is applied as `full`.
- One-shot test: an installed `infra` target upgraded without `--workflow` or
  `--branch` stays `infra` and lands on `feature/upgrade-harness-kit`.
- CI runs `test-release.sh`, and `--check-tag` on tag pushes.
