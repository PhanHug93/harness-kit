# Runtime and generator evidence

## Coordinator F6 integration check

The first F6 patch used an approximate second path allowlist. A new public
generator probe reproduced a regression: an eligible
`scripts/install-git-hooks.sh.generated.*` candidate was counted by status but
the lock said complete. `f6-installer-red.log` records this failure.
The coordinator replaced that allowlist with the exact retired-legacy exclusion,
retaining the existing behavior for all other candidates. No retired file is
removed or modified. `f6-installer-green.log` and `f6-render-summary.json`
record **8/8** checks through the full generator, including installer candidates.
The bootstrap release suite now binds the installer case, and the historical
migration suite binds complete lock/zero pending with the legacy orphan retained.

Recorded on 2026-09-08 in `/Users/admin/projects/agent-bootstrap`, branch
`feature/simplify-task-relations`. Git reads used `GIT_OPTIONAL_LOCKS=0`.

## TDD remediation

- RED fresh generator assertion: `bash agent-bootstrap/bootstrap-multi-agent-project.sh --target "$target" --workflow full` returned rc 0, but `scripts/agent-seats.sh` was missing and the old generator emitted `model-profiles.json`.
- RED migration shape run: the copied harness reported `112 passed, 3 failed, 0 skipped`; the three failures were list, dict, and boolean `legacy.default_profile` values. List/dict produced `TypeError` tracebacks; boolean returned a generic error that lacked the required selector type diagnostic.
- GREEN remediation run: `SEATS_QA_BASH=/bin/bash SEATS_QA_BUNDLE_PROFILE="$PWD/agent-bootstrap/model-profiles/codex-model-profiles.json" python3 scripts/test-agent-seats.py "$target" "$PWD/agent-bootstrap/agent-seats.sh" "$target/qa-summary.json"` reported `115 passed, 0 failed, 0 skipped` as non-root uid 501. This is the approved 109 checks plus six new migration shape checks.

The production fix is a type guard before the legacy `profiles.get(default_profile)` lookup. The reviewed reference packet remains unchanged. The RED and GREEN JSON summaries are next to this file; the coordinator legacy-shape probe is retained at `../additional-shapes.json`.

## Focused generator checks

- Fresh full generation: copied script and schema hashes matched their canonical sources; `seats.json` was present and valid; `model-profiles.json` was absent.
- Dry-run: zero files before and after; the output contained the planned agent-seats operation.
- Existing configuration: `seats.json` hash `99f0aed2c9e0a0e2fb061611714a78a0e89cab1f1eac2ef4ee773283ae1b845a` and legacy hash `0ef039c3fd547caefe42bc4bdbe176f227142c0260d3c96b29cf25c549eb0218` stayed unchanged across normal generation, `--force`, `--skip-existing`, and `--apply-candidates`.
- Customized legacy migration: missing seats plus a valid custom legacy profile produced `@gate` model `custom-planner` at effort `low`; the legacy file hash stayed unchanged.
- Valid seats plus malformed inactive legacy: `agent-seats.sh show` rc 0, verifier rc 0, legacy bytes unchanged, and verifier output included both `seats.json is valid` and `inactive legacy model profile JSON is malformed; seats.json is authoritative`.

## Snapshot and static checks

- `/bin/bash -n` passed for the changed shell sources and snapshots.
- `shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-seats.sh agent-bootstrap/verify-ai-deps.sh` passed.
- Generated verifier and `agent-bootstrap/verify-ai-deps.sh` were byte-identical: hash `69feb5e88f9f49c10cf8962f8ecaf6e837a7aedb87fc28eff9338964d90e1dc0`.
- Canonical copied schema hash: `4fb92bd0b93a406bf90caf4d4e3072d0a9b5b76247d57ee6369716f870f2d7da`.
- Canonical seats script hash after the authorized legacy selector guard: `9c631e65c1835641824f0964a829b7eeadf1e9c968e67e6731c2edcf9466ef6b`; reviewed reference hash remains `7add6bb86720eca2d8e4aedf9d6aa418c2ece862a80a2b1c117ef8cd66b1cf0d`.
- Installer export copied `agent-seats.sh` and `schemas/agent-seats-v1.schema.json` with matching hashes.

The final integrated disposable full target also returned `seats validate` rc 0, verifier rc 0 (`99 pass, 5 warn, 0 fail`), and `agent-hook.sh doctor` rc 0. The generated AGENTS roster marker remains dependent on the separate writers-docs worker.

## Runtime spec review remediation (R1-R3)

- RED against the canonical script: the new regressions reported `117 passed, 16 failed, 0 skipped`. R1 reproduced the missing `gate.tag` `KeyError`, list-valued gate model `TypeError`, and list-valued build model repair `TypeError`; R2 reproduced accepted extra arguments and destructive `reset --not-an-option`/`reset --dry-run`; R3 identified the schema `uniqueItems` rejection.
- GREEN with the same copied harness under `/bin/bash`: `133 passed, 0 failed, 0 skipped`, as non-root uid 501. The new P1-P5 checks cover clean diagnostics and byte preservation for malformed fields, every command's invalid arity/flag path, reset dry-run preservation, and duplicate effort runtime/schema consistency.
- R1 now validates before roster rendering and conflict set insertion; repair mode uses a typed catalog default lookup. R2 preflights command arity/flags before any lock or mutation. R3 retains the runtime duplicate-effort warning while removing schema uniqueness enforcement.
- The historical reference remains unchanged at SHA-256 `7add6bb86720eca2d8e4aedf9d6aa418c2ece862a80a2b1c117ef8cd66b1cf0d`; only the canonical production script, copied harness, schema, and this evidence were changed for this remediation.
- Focused post-fix fixture under `/bin/bash` passed 8/8: missing tag, list-valued conflict/repair models, unknown reset flags including `--dry-run`, extra command arguments, and duplicate effort runtime/schema consistency.
- Post-remediation canonical hashes: `agent-seats.sh` `0182febcfefffd32d969fa97302d8bd51fa8f45882c99ee6ed97acfa3cebfaac`, schema `1fa8c6c556227f9f7042b423edada57e55cb0c0261284292a181036344c01317`, harness `4dab89954a885c4772e0670371eccfb6e3c2f7bf8fcb991dba9781835dd8ad06`.

## F6 apply-state eligibility remediation — superseded worker attempt

The following records the worker attempt. Its secondary allowlist was replaced
by the coordinator correction at the top of this file; only the exact retired
legacy path is excluded in the final source.

- F6 RED: a disposable target containing only `docs/agent-configs/model-profiles.json.generated.f6-retired` produced lock `apply_state=pending` even though status reported `pending_generated_candidates=0`.
- GREEN: `f6-render-check.sh` passed 6/6 under `/bin/bash` 3.2.57. Retired-only state is now `complete` with zero pending candidates; adding an eligible generated candidate changes both views to `pending`/`1`; the retired candidate's SHA-256 stays unchanged in both refreshes.
- `lib/render.sh` now applies the existing bootstrap generated-base eligibility rules without recursively invoking the allowlist generator, explicitly excludes retired `model-profiles.json`, ignores filled user-owned bases, and returns `complete` when the scan contains no eligible candidates. No retired file is removed or rewritten.
