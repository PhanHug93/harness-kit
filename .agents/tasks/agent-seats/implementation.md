## Implementation attempt 1

Date: 2026-09-08. Route: `@build`, bounded implementation under the user's
combined release authorization in `user-decision.md` and `release-plan.md`.

Runtime/generator and launcher/prose workers were requested as
`gpt-5.6-luna`, effort `xhigh`. Their served model identity was not independently
attested. The Codex coordinator implemented historical migration regression,
release-suite integration, CI, operator documentation, and version pins;
the coordinator's exact served model identity is unavailable in this record.
Model source for the workers: explicit subagent model override authorized by
the user. No claim of account or host independence is made.

The canonical script is copied to targets, the schema is installed with the
bundle, and fresh targets initialize seats once. Existing seats remain
authoritative. Missing seats migrate the selected legacy default profile,
preserving customized primary/fallback models and efforts; legacy bytes,
USER overlays and filled brief are retained. Malformed active configuration
is refused without replacing it with defaults. Normal candidate application
and repeated upgrades do not promote stale legacy candidates or write seats.

The launcher consumes separate data/diagnostic streams, resolves five Codex
seats and route aliases, validates effective model/effort, computes primary
reviewer conflict after overrides, and emits `launch_model` provenance.
Generated prose uses fixed tags and compatible optional packet fields.

Production runtime integration exposed a malformed legacy selector shape;
the worker added six regression cases and fixed the typed lookup. Independent
runtime spec review then exposed malformed field tracebacks, ignored command
arguments (including destructive invalid reset), and duplicate-effort schema
inconsistency. All three were corrected in production with RED/GREEN evidence.
The historical reviewed reference was retained without these production edits.

Evidence to date: `evidence/release-20260908/runtime/README.md` records
133/133 Bash 3.2 checks with no skips and the focused remediation results.
`migration-attempt2/summary.json` records successful public upgrades from
v2026.08.10.1 and v2026.09.07.1; onboarding and one-shot suites passed their
first integration runs. `launcher/launcher-results.json` records seven groups
and three caught boundary mutations. Final stable-source verification,
context-budget remediation and independent cross-review are still pending;
these observations do not constitute a release verdict.

Deviation: the user explicitly combined the formerly separate stderr and
seats packets and authorized release/version work. Historical reference,
production guard/hook/policy behavior, detector version and unrelated
`Claude outputs/` remain outside the implementation write set.

## Final implementation and local acceptance

All three release suites passed. Canonical seats: 133/133, zero skips; all nine
runtime mutations caught. Launcher: eight groups and all three boundary
mutations caught. Historical public upgrades: 46 assertions from two release
tags. Static checks: 44 pass, including final source/generated lint, snapshots
and four budgets below unchanged limits. See [verification.md](verification.md).

The independent runtime review closed R1–R3. Claude source review identified
F1–F6 (doctor guard/read-only behavior, non-Codex diagnostics, effective model,
onboarding warning, stale docs, retired candidate lock); all were corrected
and the recheck found no remaining defect in scope. The final full suite exposed
an infra-only verifier requirement for an intentionally absent seats runtime;
the existing workflow predicate now scopes that check. A RED/GREEN fixture,
permanent full-suite assertions and a bounded Claude recheck cover this fix.

Prose compression retained scope/approval rules and child outcome/retry policy;
the existing 4000/6200 gates were not raised. Final static hashes cover this
source. Release publication and remote CI are subsequent steps under the same
user authorization; they are not asserted in this pre-commit record.
