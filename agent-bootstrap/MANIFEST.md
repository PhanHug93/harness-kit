# Agent Bootstrap Manifest

Version: `2026.06.14.6`
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
| `install-agent-bootstrap-home.sh` | Exports this bundle into `$AGENT_BOOTSTRAP_HOME`. | Must copy every other file listed in this manifest; it does not copy itself. |
| `README.md` | Operator guide for the copyable bundle. | Must match canonical home export. |
| `VERSION` | Bundle version stamp. | Must match `bootstrap-multi-agent-project.sh --version`. |
| `MANIFEST.md` | Bundle inventory and ownership map. | Must match canonical home export. |
| `agent-tech-stack-lib.sh` | Runtime detector library snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-tech-stack-lib.sh`. |
| `agent-hook.sh` | Runtime hook snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/agent-hook.sh`. |
| `detect-agent-tech-stack.sh` | Runtime detector entrypoint snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/detect-agent-tech-stack.sh`. |
| `install-rtk.sh` | Runtime rtk installer snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/install-rtk.sh`. |
| `rtk` | Runtime rtk wrapper snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/rtk`. |
| `verify-ai-deps.sh` | Runtime verifier snapshot for generated full-workflow projects. | Must match `--workflow full` generated `scripts/verify-ai-deps.sh`. |
| `lib/core.sh` | Sourced utility/gating library for the generator. | Must match canonical home export. |
| `lib/detect.sh` | Sourced tech-stack detection library for the generator. | Must match canonical home export. |
| `lib/render.sh` | Sourced overlay/lock/gitignore rendering library. | Must match canonical home export. |
| `lib/writers-runtime.sh` | Sourced library that emits target `scripts/*` runtime files. | Must match canonical home export. |
| `lib/writers-docs.sh` | Sourced library that emits agent docs, tool entrypoints, and Codex files. | Must match canonical home export. |
| `lib/onboarding.sh` | Sourced library that emits the onboarding scaffold (full workflow). | Must match canonical home export. |

## Guardrail

Run `scripts/test-bootstrap-multi-agent-project.sh` after changing this bundle.
That test verifies canonical home export and generated runtime snapshot drift.
