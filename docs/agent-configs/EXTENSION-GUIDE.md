# Agent Bootstrap Extension Guide

This guide maps common harness changes to the exact source files and drift tests
that must move together. Keep changes small and update the guard test that proves
the generated target still matches the canonical bundle.

## Add a detected stack

- Edit the detector source of truth in `agent-bootstrap/lib/detect.sh`.
- Update the emitted runtime snapshot `agent-bootstrap/agent-tech-stack-lib.sh`.
  The emitted heredoc in `lib/detect.sh` and this snapshot must stay
  byte-identical; `scripts/test-bootstrap-multi-agent-project.sh` guards this
  with `need_same_file`.
- If the detector JSON contract changes, update the relevant schema under
  `agent-bootstrap/schemas/`, the generated schema catalog in
  `agent-bootstrap/lib/writers-runtime.sh`, and the validation copy in
  `agent-bootstrap/verify-ai-deps.sh`.
- Add fixture coverage in `scripts/test-bootstrap-multi-agent-project.sh` and,
  when onboarding output changes, in `scripts/test-onboarding-fixtures.sh`.
- Bump `AGENT_TECH_STACK_LIB_VERSION` only when detector behavior changes.

## Add a tool surface

- Add shared wording to `agent-bootstrap/templates/tool-contract/shared.md` when
  the rule applies to every agent entrypoint.
- Add tool-specific generated files in `agent-bootstrap/lib/writers-docs.sh`.
- If the surface needs runtime scripts, add them in
  `agent-bootstrap/lib/writers-runtime.sh` and list the canonical bundle copy in
  `agent-bootstrap/install-agent-bootstrap-home.sh`.
- Update `agent-bootstrap/MANIFEST.md` for every new bundle file.
- Run `scripts/sync-template-catalog.sh` when template files under
  `agent-bootstrap/templates/` change.
- Add generated-target assertions to `scripts/test-bootstrap-multi-agent-project.sh`.

## Add a guard check

- Put runtime policy checks in `agent-bootstrap/agent-guard.sh`; that file is
  copied wholesale to target projects.
- If a hook must call the guard, update both `agent-bootstrap/agent-hook.sh` and
  the `agent-hook.sh` heredoc in `agent-bootstrap/lib/writers-runtime.sh`.
- If generated docs or Claude settings change, update both infra and full
  branches in `agent-bootstrap/lib/writers-docs.sh`.
- If the check emits machine-readable state, add or update a schema under
  `agent-bootstrap/schemas/`, the schema catalog writer, and the generated
  verifier.
- Cover the behavior by running the generated artifact in
  `scripts/test-bootstrap-multi-agent-project.sh`; do not rely only on source
  text assertions.
