# Release evidence index

See [the verification record](../../verification.md) for the final local verdict,
commands, migration guarantees and limitations. Selected summaries and review
reports are versioned; verbose stdout/stderr, disposable fixtures and intermediate
failed-run logs remain local. A named log in a historical report may therefore
not be part of a fresh clone.

Current primary records:

- `static-final/summary.json`: final production hashes, 44 checks and four budgets.
- `runtime-mutations/summary.json`: canonical 133-check baseline and nine caught mutations.
- `run-runtime-mutations.py`: reproduces those mutations from canonical sources.
- `launcher/verified-final.json`: eight launcher groups and three caught mutations.
- `migration-final-summary.json`: 46 historical public-upgrade assertions.
- `runtime-spec-review.md`: independent R1–R3 source review and exercised recheck.
- `claude-audit-report.md`, `claude-recheck-report.md`,
  `claude-final-delta-report.md`: independent source review and bounded rechecks.
- `infra-summary.json`: infra-only RED/GREEN result and permanent test binding.
- `runtime/f6-render-summary.json`: candidate/lock correction, including installer.

The production scripts under `scripts/test-agent-seats*.py` are the maintained
harnesses. Reference and earlier review artifacts record history; they are not
an alternative implementation to copy into new targets.
