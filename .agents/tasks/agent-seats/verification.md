# Agent seats release verification — 2026-09-08

Release candidate: `2026.09.08.1`, branch `feature/simplify-task-relations`,
base `cf8f326`. The user authorized the combined seats/stderr release and safe
migration for projects on earlier versions. This record concerns local source
acceptance; remote CI and tag publication are recorded separately after commit.

## Verdict

PASS for local source acceptance. No remaining blocking technical finding in
the reviewed scope. Publication remains conditional on CI for the release commit.

## Observed verification

| Gate | Result | Evidence under `evidence/release-20260908/` |
|---|---|---|
| Bootstrap release suite | PASS (rc 0), current runtime and eight launcher groups | `bootstrap-final-green.log` |
| Onboarding suite | PASS; three golden fixtures | `onboarding-final.log` |
| One-shot upgrade suite | PASS | `one-shot-final.log` |
| Historical public upgrade | 46 assertions, 0 failures; v2026.08.10.1 and v2026.09.07.1 | `migration-final-summary.json` |
| Canonical seats runtime | 133/133, 0 skipped, non-root macOS Bash 3.2 | `runtime-mutations/summary.json` |
| Runtime mutation checks | All nine caught; in-place writes fail R7/R8 | `runtime-mutations/summary.json` |
| Launcher integration | Eight groups; all three boundary mutations caught | `launcher/verified-final.json` |
| Independent runtime specification recheck | R1–R3 closed; 15 focused checks | `runtime-spec-review.md` |
| Independent Claude source review | F1–F6 closed, no remaining defect in rechecked scope | `claude-recheck-report.md` |
| Final verifier/prose delta review | No new defect | `claude-final-delta-report.md` |
| Static/generated verification | 44 checks PASS | `static-final/summary.json` |
| Infra-only regression | RED verifier rc1 → GREEN rc0; workflow seats remain absent | `infra-red.log`, `infra-green.log`, bootstrap suite |

Static checks include source and generated shellcheck with CI exclusions,
Bash syntax, catalog sync, copied runtime/schema and verifier snapshot equality,
and Python 3.8 syntax parsing. Four generated fixture budgets remain below the
unchanged 4000/6200 gates: normal 2382/6088; long-name 2398/6104; Android
2474/6180; Android long-name 2488/6194 (core/full).

The launcher mutation record predates final prose-only compression. Launcher
logic was unchanged; the final full bootstrap suite reruns the current launcher
integration. The canonical runtime/schema/harness hashes match the mutation
record. The static record covers final production sources, including the
infra-only verifier correction.

## Migration contract verified

- Existing valid `seats.json` remains authoritative and byte-preserved, even
  when inactive legacy JSON is malformed. No seats candidate is generated.
- Missing seats migrate customized models, efforts and fallbacks from the
  selected legacy default profile; the entire legacy file remains unchanged.
- Exact old bundle defaults adopt the new defaults with a diagnostic note.
- Invalid active configuration fails without silently replacing it with defaults.
- Safe generation, reviewed candidate application, repeated upgrades and dry-run
  preserve filled brief content and USER overlays. Retired legacy candidates
  remain intact and do not keep the lock pending; eligible installer candidates
  still do. These are disposable historical-release fixtures, not live projects.

## Review and scope

Two disjoint implementation workers were requested as Luna xhigh. A separate
runtime reviewer exercised independent probes. Claude CLI performed read-only
source review and two bounded rechecks (reported served model
`claude-fable-5-1`); it did not run the coordinator's tests. See
`implementation.md` for provenance limitations and resolved technical findings.

No production guard, hook, context policy, detector implementation or detector
version changed from the base. Task relation enforcement remains a documented
convention. This release does not claim to solve the separate broad context
loading, local-only knowledge policy, or real host acceptance concerns.

Limitations: Codex launches use a capturing fake CLI, not paid model inference.
Python 3.8 compatibility was parsed, not executed on a Python 3.8 interpreter.
Budget figures describe the named fixtures, not arbitrary downstream briefs.
Remote Ubuntu/macOS CI and publication are not claimed by this pre-commit file.
