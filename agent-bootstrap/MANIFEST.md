# Agent Bootstrap Manifest

Version: `2026.06.21.2`
Channel: `stable`

This manifest defines the portable `agent-bootstrap/` bundle layout. Keep this
file and `VERSION` with the bundle whenever it is copied to another project.

## Versioning

This bundle carries two independent version stamps. Bump
`AGENT_TECH_STACK_LIB_VERSION` (in `agent-tech-stack-lib.sh` and the
`lib/detect.sh` emitter) only when detector logic changes. Bump
`AGENT_BOOTSTRAP_VERSION` (entrypoint) together with `VERSION` for any bundle
change, including doc, generator, or runtime-snapshot edits.

## Source Roles

| File | Role | Drift Rule |
|---|---|---|
| `bootstrap-multi-agent-project.sh` | Bootstrap generator for target projects. | Source of truth for generated project files. |
| `harness-kit-one-shot-upgrade.sh` | One-shot safe installer/upgrader for old projects on another machine. | Must match canonical home export. |
| `agent-bootstrap-update.sh` | Git-backed updater for canonical home and target upgrade planning. | Must match canonical home export. |
| `install-agent-bootstrap-home.sh` | Exports this bundle into `$AGENT_BOOTSTRAP_HOME`. | Must copy every other file listed in this manifest; it does not copy itself. |
| `README.md` | Operator guide for the copyable bundle. | Must match canonical home export. |
| `VERSION` | Bundle version stamp. | Must match `bootstrap-multi-agent-project.sh --version`. |
| `MANIFEST.md` | Bundle inventory and ownership map. | Must match canonical home export. |
| `agent-tech-stack-lib.sh` | Runtime detector library snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-tech-stack-lib.sh`. |
| `agent-hook.sh` | Runtime hook snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-hook.sh`. |
| `agent-guard.sh` | Agent Guard Lite runtime snapshot for generated projects. | Must match `--workflow full` generated `scripts/agent-guard.sh`. |
| `agent-onboarding.sh` | Runtime onboarding readiness helper for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-onboarding.sh`. |
| `detect-agent-tech-stack.sh` | Runtime detector entrypoint snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/detect-agent-tech-stack.sh`. |
| `install-rtk.sh` | Runtime rtk installer snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/install-rtk.sh`. |
| `rtk` | Runtime rtk wrapper snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/rtk`. |
| `verify-ai-deps.sh` | Runtime verifier snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/verify-ai-deps.sh`. |
| `model-profiles/codex-model-profiles.json` | Source model profile catalog copied into generated target `docs/agent-configs/model-profiles.json`. | Must match canonical home export and generated target model profile catalog. |
| `policies/agent-context-policy.json` | Source Agent Guard Lite context policy copied into generated target `docs/agent-configs/context-policy.json`. | Must match canonical home export and generated target context policy. |
| `provenance/rtk-v0.37.2.sha256` | Pinned rtk release asset checksums used by generated installer verification. | Must match canonical home export and generated target provenance catalog. |
| `schemas/agent-context-policy-v1.schema.json` | JSON Schema for `policies/agent-context-policy.json` and generated `docs/agent-configs/context-policy.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-model-profiles-v1.schema.json` | JSON Schema for `model-profiles/codex-model-profiles.json` and generated `docs/agent-configs/model-profiles.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-project-tech-stack-v1.schema.json` | JSON Schema for generated `docs/superpowers/specs/project-tech-stack.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-lock-v1.schema.json` | JSON Schema for `agent-bootstrap.lock.json`. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-status-v1.schema.json` | JSON Schema for `--status --json` output. | Must match canonical home export and generated target schema catalog. |
| `schemas/agent-bootstrap-verify-report-v1.schema.json` | JSON Schema for `scripts/verify-ai-deps.sh --json` output. | Must match canonical home export and generated target schema catalog. |
| `templates/base/README.md` | Base generated template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/android_kotlin.md` | Android/Kotlin overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/generic.md` | Generic overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/ios_swift.md` | iOS/Swift overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/node_js.md` | Node/Web overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/overlays/python.md` | Python overlay template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/council/README.md` | Council workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/karpathy/README.md` | Karpathy workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `templates/workflows/three-mode/README.md` | Three-mode workflow template copied into target projects. | Must match canonical home export, source docs template, and generated target template. |
| `lib/core.sh` | Sourced utility/gating library for the generator. | Must match canonical home export. |
| `lib/detect.sh` | Sourced tech-stack detection library for the generator. | Must match canonical home export. |
| `lib/render.sh` | Sourced overlay/lock/gitignore rendering library. | Must match canonical home export. |
| `lib/writers-runtime.sh` | Sourced library that emits target `scripts/*` runtime files. | Must match canonical home export. |
| `lib/writers-docs.sh` | Sourced library that emits agent docs, tool entrypoints, and Codex files. | Must match canonical home export. |
| `lib/onboarding.sh` | Sourced library that emits the onboarding scaffold (full workflow). | Must match canonical home export. |

## Guardrail

Run `scripts/test-bootstrap-multi-agent-project.sh` after changing this bundle.
That test verifies canonical home export and generated runtime snapshot drift.
