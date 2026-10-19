# Agent Bootstrap Manifest

Version: `2026.10.19.1`
Channel: `stable`

This manifest defines the portable `agent-bootstrap/` bundle layout. Keep this
file and `VERSION` with the bundle whenever it is copied to another project.

## Versioning

This bundle carries two independent version stamps. Bump
`AGENT_TECH_STACK_LIB_VERSION` (in `agent-tech-stack-lib.sh` and the
`lib/detect.sh` emitter) only when detector logic changes. Bump
`AGENT_BOOTSTRAP_VERSION` (entrypoint) together with `VERSION` when preparing a
user-authorized release of any bundle change, including doc, generator, or
runtime-snapshot edits; `scripts/release.sh <version>` bumps every pin from
`VERSION` and `scripts/release.sh --check` reports drift. Runtime snapshots are
refreshed with `scripts/sync-runtime-snapshots.sh`, never edited by hand.
Unreleased feature branches retain the published pins; do not invent a release
tag or source branch to complete a feature PR.

## Source Roles

| File | Role | Drift Rule |
|---|---|---|
| `bootstrap-multi-agent-project.sh` | Bootstrap generator for target projects. | Source of truth for generated project files. |
| `harness-kit-one-shot.sh` | One-shot entry: fetches a kit release into `<project>/.harness-kit/v<version>/` and runs its `harness-kit-run.sh`; emitted into targets as `scripts/harness-kit.sh`. | Must match canonical home export and generated target `scripts/harness-kit.sh`. |
| `harness-kit-one-shot-upgrade.sh` | Old name of the one-shot entry, kept for existing links. | Must be byte-identical to `harness-kit-one-shot.sh` (`scripts/release.sh --check`). |
| `harness-kit-run.sh` | One-shot orchestrator: install, reinstall or update one project in phases (preflight, stage, apply, migrate, verify, report). | Must match canonical home export; never emitted into targets. |
| `agent-bootstrap-update.sh` | Git-backed updater for canonical home and target upgrade planning. | Must match canonical home export. |
| `install-agent-bootstrap-home.sh` | Exports this bundle into `$AGENT_BOOTSTRAP_HOME`. | Must copy every other file listed in this manifest; it does not copy itself. |
| `README.md` | Operator guide for the copyable bundle. | Must match canonical home export. |
| `VERSION` | Bundle version stamp. | Must match `bootstrap-multi-agent-project.sh --version`. |
| `MANIFEST.md` | Bundle inventory and ownership map. | Must match canonical home export. |
| `agent-tech-stack-lib.sh` | Runtime detector library snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-tech-stack-lib.sh`. |
| `agent-hook.sh` | Runtime hook snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-hook.sh`. |
| `agent-guard.sh` | Agent Guard Lite runtime snapshot for generated projects. | Must match `--workflow full` generated `scripts/agent-guard.sh`. |
| `agent-seats.sh` | Runtime seat assignment, migration, validation, and roster renderer for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-seats.sh`. |
| `agent-onboarding.sh` | Runtime onboarding readiness helper for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-onboarding.sh`. |
| `agent-local-only-check.sh` | Runtime Git hygiene checker that blocks harness-kit generated files from being pushed. | Must match generated target `scripts/agent-local-only-check.sh` and pre-push hook expectations. |
| `detect-agent-tech-stack.sh` | Runtime detector entrypoint snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/detect-agent-tech-stack.sh`. |
| `githooks/pre-push` | Optional portable git pre-push close-out gate copied into generated target `scripts/githooks/pre-push`. | Must match generated target hook and remain opt-in via `scripts/install-git-hooks.sh`. |
| `install-git-hooks.sh` | Optional installer that sets `core.hooksPath=scripts/githooks` without clobbering an existing hooks path unless `--force` is used. | Must match generated target `scripts/install-git-hooks.sh`. |
| `install-rtk.sh` | Runtime rtk installer snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/install-rtk.sh`. |
| `rtk` | Runtime rtk wrapper snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/rtk`. |
| `verify-ai-deps.sh` | Runtime verifier snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/verify-ai-deps.sh`. |
| `model-profiles/codex-model-profiles.json` | Legacy model profile catalog retained as one-release migration input; fresh targets do not receive `model-profiles.json`. | Must match canonical home export; used only when `seats.json` is missing. |
| `policies/agent-context-policy.json` | Source Agent Guard Lite context policy copied into generated target `docs/agent-configs/context-policy.json`. | Must match canonical home export and generated target context policy. |
| `policies/retired-artifacts-v1.json` | Closed HK-07 inventory of retired generated files with pinned historical size/SHA-256 provenance; read only by `lib/retirement.py`. | Must match canonical home export and the inventory pinned in `lib/retirement.py`; never emitted into targets. |
| `provenance/rtk-v0.37.2.sha256` | Pinned rtk release asset checksums used by generated installer verification. | Must match canonical home export and generated target provenance catalog. |
| `schemas/agent-context-policy-v1.schema.json` | JSON Schema for `policies/agent-context-policy.json` and generated `docs/agent-configs/context-policy.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-model-profiles-v1.schema.json` | JSON Schema for the legacy model profile migration input and its generated schema catalog copy. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-seats-v1.schema.json` | JSON Schema for generated `docs/agent-configs/seats.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-project-tech-stack-v1.schema.json` | JSON Schema for generated `docs/superpowers/specs/project-tech-stack.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-lock-v1.schema.json` | JSON Schema for `agent-bootstrap.lock.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-status-v1.schema.json` | JSON Schema for `--status --json` output. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-status-v2.schema.json` | JSON Schema for opt-in `--status --json --status-version 2` output (v1 fields plus the retirement report). | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-retirement-v1.schema.json` | JSON Schema for `--retirement-plan`, `--retirement-status` and `--apply-retirements` `--json` reports. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-verify-report-v1.schema.json` | JSON Schema for `scripts/verify-ai-deps.sh --json` output. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-guard-event-v2.schema.json` | JSON Schema for `agent-guard.sh` close-out telemetry events. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-guard-verification-v2.schema.json` | JSON Schema for the `agent-guard.sh pre-final --run-verify` verification report (`.agents/state/last-verify-report.json`). | Must match canonical home export and generated target schema catalog. |
| `schemas/harness-project-knowledge-v1.schema.json` | JSON Schema for `.tools/agent-state/project-knowledge.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/harness-kit-run-report-v1.schema.json` | JSON Schema for the one-shot run report `.tools/agent-state/upgrades/<STAMP>/report.json`. | Must match canonical home export and generated target schema catalog. |
| `templates/base/README.md` | Base generated template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/tool-contract/shared.md` | Shared managed tool contract rendered into CLAUDE/GEMINI/Windsurf/Cursor entrypoints. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/android_kotlin.md` | Android/Kotlin overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/generic.md` | Generic overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/ios_swift.md` | iOS/Swift overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/node_js.md` | Node/Web overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/python.md` | Python overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/skills/mobile-optimization/SKILL.md` | Mobile optimization skill entrypoint copied into selected Kotlin/Swift target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content. |
| `templates/skills/mobile-optimization/WRITER-INTEGRATION.md` | Writer-only integration notes for the mobile optimization skill. | Must match canonical home export and source docs template; must not be emitted into generated target projects. |
| `templates/skills/mobile-optimization/catalog.md` | Mobile optimization anti-pattern catalog copied into selected Kotlin/Swift target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content. |
| `templates/skills/mobile-optimization/fewshots/kotlin.md` | Kotlin mobile optimization few-shot copied only into Kotlin target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content when selected. |
| `templates/skills/mobile-optimization/fewshots/swift.md` | Swift mobile optimization few-shot copied only into Swift target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content when selected. |
| `templates/skills/mobile-optimization/overlays/kotlin.md` | Kotlin mobile optimization overlay copied only into Kotlin target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content when selected. |
| `templates/skills/mobile-optimization/overlays/swift.md` | Swift mobile optimization overlay copied only into Swift target projects. | Must match canonical home export, source docs template, generated target template, and emitted skill content when selected. |
| `templates/skills/mobile-optimization/pointers/claude.command.md` | Claude command pointer for on-demand mobile optimization. | Must match canonical home export and source docs template; generated command must reference the emitted skill entrypoint. |
| `templates/skills/mobile-optimization/pointers/cursor.rules.mdc` | Cursor glob pointer for on-demand mobile optimization. | Must match canonical home export and source docs template; generated pointer must substitute detected language globs. |
| `templates/skills/mobile-optimization/pointers/pointer-body.md` | Shared pointer body for mobile optimization surfaces. | Must match canonical home export and source docs template. |
| `templates/skills/mobile-optimization/pointers/windsurf.rules.md` | Windsurf glob pointer for on-demand mobile optimization. | Must match canonical home export and source docs template; generated pointer must substitute detected language globs. |
| `templates/skills/mobile-optimization/skill.manifest.json` | Schema-first manifest for mobile optimization stack selection, budget, and emitted surfaces. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/council/README.md` | Council workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/karpathy/README.md` | Karpathy workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/three-mode/README.md` | Three-mode workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `lib/core.sh` | Sourced utility/gating library for the generator. | Must match canonical home export. |
| `lib/detect.sh` | Sourced tech-stack detection library for the generator. | Must match canonical home export. |
| `lib/render.sh` | Sourced overlay/lock/gitignore rendering library. | Must match canonical home export. |
| `lib/writers-runtime.sh` | Sourced library that emits target `scripts/*` runtime files. | Must match canonical home export. |
| `lib/writers-docs.sh` | Sourced library that emits agent docs, tool entrypoints, and Codex files. | Must match canonical home export. |
| `lib/onboarding.sh` | Sourced library that emits the onboarding scaffold (full workflow). | Must match canonical home export. |
| `lib/overlays.sh` | Sourced USER-overlay engine; preserves keyed `<!-- BEGIN USER -->` regions across regeneration. | Must match canonical home export. |
| `lib/retirement.py` | HK-07 retired-artifact engine: read-only plan/status sections and the explicit `--apply-retirements` backup/delete path. | Must match canonical home export; never emitted into targets. |
| `lib/knowledge.py` | Project knowledge engine for `.tools/agent-state/project-knowledge.json` (pins, resolutions, decisions, runs). | Must match canonical home export; never emitted into targets. |
| `lib/migrations.sh` | Sourced migration runner used by `harness-kit-run.sh`. | Must match canonical home export; never emitted into targets. |
| `migrations/2026.10.19.1-ignore-block-to-exclude.sh` | Migration `next-ignore-block-to-exclude` (renamed to `<version>-…` by `scripts/release.sh <version>`). | Must match canonical home export; never emitted into targets. |
| `migrations/2026.10.19.1-retire-files.sh` | Migration `next-retire-files` (renamed to `<version>-…` by `scripts/release.sh <version>`). | Must match canonical home export; never emitted into targets. |
| `migrations/2026.10.19.1-untrack-local-records.sh` | Migration `next-untrack-local-records` (renamed to `<version>-…` by `scripts/release.sh <version>`). | Must match canonical home export; never emitted into targets. |

## Guardrail

Run `scripts/test-bootstrap-multi-agent-project.sh` after changing this bundle.
That test verifies canonical home export and generated runtime snapshot drift.

The repo utility `scripts/sync-template-catalog.sh` regenerates the docs template
mirror (`docs/agent-configs/bootstrap-multi-agent-project/templates`) from
`agent-bootstrap/templates`; its `--check` mode must pass in that integration test.
