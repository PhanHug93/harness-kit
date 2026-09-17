# Test tiers, per-file candidate apply and downstream process

Date: 2026-10-13, Asia/Ho_Chi_Minh.
Branch: `feature/verification-feedback` (same single commit).
Scope: P2, P3 and P4 of the release-friction proposal, delivered within the
owner's one-hour budget. Status: approved by the owner on 2026-10-13.

## Delivered

- P2 fast tier: `scripts/test-fast.sh` runs syntax, release pins and mirrors,
  the release script test, the workspace guard, onboarding fixtures and the
  retirement lifecycle in about 4 minutes. Every check runs; the summary lists all failures; `--only <check>`
  reruns one. The full tier (bootstrap and one-shot suites) runs before a PR or
  release.
- P2 hygiene: `scripts/test-agent-seats-launcher.py` writes its results to the
  temp directory (or `SEATS_LAUNCHER_EVIDENCE_DIR`), never into the repository.
- P3 slice: `--apply-candidates --only <path>` (repeatable) promotes only the
  named reviewed candidates, reports names without a candidate, and is refused
  without `--apply-candidates`.
- P4: the root README states the process: one packet per downstream report,
  apps upgrade only to published release tags, kit defects are fixed and
  released in the kit first.

## P3 core (added 2026-10-13, second pass)

- Baseline: every generated, non-user-owned file's last kit output is stored
  under `.tools/agent-state/harness-baseline/files/` (local-only). The proposal
  put per-file hashes in the lock; a three-way merge needs the base content, so
  the baseline holds the content and the lock schema stays unchanged.
- `write_file` decisions for an existing file (default mode): equal to new kit
  output → up to date; equal to baseline → update in place (backup kept); new
  kit output equal to baseline → keep local edits; otherwise `git merge-file`
  → merged in place, or a candidate on conflict. Edited JSON files (the lock,
  settings) are never merged or kept line by line: they get a candidate as before. No baseline (older targets),
  `--skip-existing` and unsafe files keep the previous behaviour. The preset
  placeholder is resolved before comparing, so an unchanged hook is a no-op.
- Journal: each run records created/updated/merged/applied files and its
  candidates with pre-images and post hashes under `upgrades/<STAMP>/` (newest
  10 kept). `--rollback <STAMP>` restores files that still match their post
  hash, removes created files and candidates, restores the baseline, refuses a
  second rollback, and exits 3 when it kept edited files. Retirements (HK-07)
  are not journaled; they keep their own backups.
- `--upgrade-plan --json` (`agent-bootstrap-upgrade-plan/v1`) replays
  generation on a temporary copy with the baseline and reports create /
  unchanged / update / merge / kept / conflict / unsafe / preserved per file.
- Harness state paths refuse any linked component (`.tools/` is outside the
  content policy, so they have their own check).
- Retirement of removed kit files follows the approved HK-07 spec (explicit
  `--apply-retirements`; generation never deletes).
- Tests: `scripts/test-upgrade-merge.sh` (update, merge, conflict, kept, plan
  without writes, rollback full/partial/repeat/unknown, legacy candidate flow,
  applied candidate becomes baseline, linked baseline refused); two mutations
  (merge disabled, link check disabled) fail it. Four bootstrap assertions were
  updated to the new semantics.

## Deferred

- P2: splitting the 4,500-line bootstrap suite into independent groups with
  aggregated failures, and replacing exact-wording assertions with markers.

## Verification

`scripts/test-fast.sh` green; `--only` covered in the bootstrap suite (named
candidate promoted, unnamed candidate kept, absent name reported, refusal
without `--apply-candidates`); full bootstrap suite.
