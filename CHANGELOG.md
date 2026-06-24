# Changelog

## 2026.06.24.2 — Harness Path B hardening

- **behavioral close-out hardening.** Claude Code targets now get a Stop hook
  that runs fast close-out verification through `scripts/agent-hook.sh close-out`
  when the tree has changes; non-Claude surfaces remain advisory and must run
  `scripts/agent-guard.sh pre-final --run-verify` manually.
- **Honest verification telemetry.** `agent-guard.sh` emits
  `agent-guard-event/v2` close-out events with separate `gate_status` and
  `verification.status`, including fail, warn, none, skipped, and error paths.
- **Safer verification runner.** Detected verification commands now run with
  `shell=False`, all-skipped runs warn instead of printing a false green, and a
  total wall-clock budget prevents interactive close-out from multiplying the
  per-command timeout across every detected command.
- **Maintainability rails.** Runtime snapshot drift is discovery-based, the
  schema catalog includes close-out events, and the extension guide maps the
  exact files/tests to touch when adding stacks, tool surfaces, or guard checks.

## 2026.06.24.1 — Harness closed-loop verification

- **Closed-loop pre-final verification.** `agent-guard.sh pre-final --run-verify`
  consumes detector JSON, runs concrete fast verification commands by default,
  records per-command results, and leaves full/build commands behind an explicit
  `--verify-scope full` opt-in.
- **Stack drift and telemetry.** `pre-final` now checks the live detector summary
  against the bootstrap lock and appends compact JSONL session events without
  reusing stale verification reports for no-verify invocations.
- **Tool-surface parity.** A shared managed tool contract is rendered into
  Claude, Gemini, Windsurf, and Cursor entrypoints, with a synced template
  catalog mirror and regression coverage.
- **Sandbox-safe hardening.** Verification reports work when state lives outside
  the project through `$AGENT_STATE_DIR` or TMPDIR fallback, and integration
  tests use a fixture-local `npm` shim instead of requiring npm on PATH.

## 2026.06.22.2 — Sandbox-safe upgrades, USER overlays, hygiene + git workflow

- **Sandbox-safe apply/guard/verify.** `agent-guard.sh` resolves a writable state
  directory (`$AGENT_STATE_DIR` → `.agents/state` → `$TMPDIR`) and degrades to
  advisory when none is writable; `--apply-candidates` skips read-only targets
  with guidance instead of aborting and backs up best-effort; the generated
  verifier downgrades a read-only-blocked Codex doctor candidate to a warning
  rather than a hard failure.
- **`apply_state` in the lock.** `agent-bootstrap.lock.json` records
  `complete` | `pending` | `blocked-readonly`; it is normalized out of the
  generated-file drift comparison.
- **USER overlays.** A keyed `<!-- BEGIN USER: <key> --> … <!-- END USER -->`
  engine (`lib/overlays.sh`) preserves project customizations across
  regeneration for `AGENTS.md`, `.codex/README.md`, and
  `agent-mode-contracts.md`; orphaned keys are parked, never dropped.
- **Upgrade hygiene.** New `--cleanup-backups` removes harness-stamped
  `.bak.<timestamp>`/`.generated.<timestamp>` leftovers; the verifier warns on
  stale harness-version references; the one-shot upgrader flags pre-overlay files
  to wrap in USER markers (retrofit).
- **Git Workflow conventions** in generated `AGENTS.md` (infra + full):
  one-branch-one-commit via `git commit --amend`; `feature/<slug>` and
  `bugfix/<slug>` branch naming off the latest default branch; Conventional
  Commits; no AI/agent identifiers or `Co-Authored-By` agent trailers in commits
  or branch names; `--force-with-lease`-only amended pushes on your own branch;
  and an explicit human-approval gate for commit/push/tag/merge.
- **Memory discipline gate.** The generated agentmemory skill now teaches
  type-first recall/save discipline and compact Memory Briefs; the task journal
  close-out records save decisions, evidence, and protected-path recall
  verification; `agent-guard.sh pre-final` validates the journal and fails
  protected-path changes that skip recall verification.

## 2026.06.21.2 — Journal clarity + budget headroom

- Made every generated mode contract, Claude command, Council/Karpathy
  procedure, task-journal doc, and Codex mode seed name the concrete per-task
  journal target (`docs/superpowers/plans/<topic>/journal.md`) while using
  `docs/agent-configs/task-journal.md` only as the schema/guidance document.
- Slimmed generated methodology docs without removing close-out requirements,
  restoring full-workflow on-demand context headroom; the integration test now
  fails if the estimate regresses above 6100 tokens.
- Preserved filled onboarding/context files during harness upgrades:
  `project-agent-context.md`, `project-brief.md`, and project tech-stack docs no
  longer receive empty generated candidates once filled, and
  `--apply-candidates` skips stale empty candidates for those files.
- Made generated diff previews portable on macOS by using a `cp`/`find` copy
  path instead of depending on Apple `openrsync`; one-shot upgrades now treat
  diff preview failures as warnings and continue to generate candidates.
- Hardened generated verifier smoke checks for non-interactive runs: CI-style
  stdin skips the recursive bootstrap smoke, and interactive smoke uses
  `timeout` when available.
- Ignored `.bak.*` and `.generated.*` template leftovers in drift comparisons,
  raised the default core startup budget to 4000 tokens, and restored
  module-aware Gradle verification candidates for detected modules/flavors.

## 2026.06.21.1 — Operationalize methodology + unified task-journal

- Operationalized the three work-modes (Planning, Coding, Reviewing) and the
  Council and Karpathy methodologies into runnable procedures, each closing out
  by appending a structured entry to a durable, git-tracked task journal.
- Added the task-journal working-memory doc (`docs/agent-configs/task-journal.md`):
  a Layer 1, append-only, per-task record (`docs/superpowers/plans/<topic>/journal.md`)
  that survives context compaction, with a conditional bridge to Layer 2
  long-term memory (`memory_save`/`lesson_save`) at decided/done close-out.
- Added `/council` and `/karpathy` commands and per-mode "Output" close-out
  blocks in the mode contracts; documented the journal in the plans scaffold
  README and added an AGENTS.md resume pointer plus AGENTS.md/CLAUDE.md
  on-demand listings.
- Reached Codex parity: the journal step is seeded into all six `codex-mode.sh`
  mode prompts, and the journal doc plus the new commands are registered in the
  doctor budget and file lists.
- Added the task-journal doc to the recommended-context policy, an advisory
  journal reminder to `agent-guard.sh` pre-final, and reduced the vestigial
  council/karpathy/three-mode workflow template stubs to one-line pointers.

## 2026.06.16.5 — Semantic adversarial onboarding hardening

- Hardened `scripts/agent-onboarding.sh check` so `filled` cannot pass when
  source evidence paths are unsafe or missing, verification entries have empty
  fields, evidence claims are empty, or `project-tech-stack.md` still carries
  unfilled scaffold content.
- Tightened project tech-stack contract validation in the generated verifier so
  verification entries and source evidence entries must be non-empty and
  evidence paths must be safe project-relative files that exist in the checkout.
- Added adversarial onboarding fixture cases for missing evidence files, unsafe
  evidence paths, empty verification fields, empty evidence claims, and unfilled
  tech-stack Markdown, so these false-greens are regression-tested before the
  happy-path filled contracts pass.

## 2026.06.16.4 — First 10 Minutes and onboarding contract

- Added a generated `scripts/agent-onboarding.sh` readiness helper with
  `status`, `next`, and strict `check` commands. It computes readiness from
  `project-brief.md` and `project-tech-stack.json` each run instead of writing a
  stale-prone status file.
- Added `agent-init --first-10`/`--next`, generated
  `docs/agent-configs/first-10-minutes.md`, and post-generation guidance so a
  fresh full-workflow target has an executable path from bootstrap to onboarding
  readiness.
- Integrated onboarding readiness into `scripts/verify-ai-deps.sh`: fresh
  unfilled projects warn with a concrete next command, while invalid onboarding
  status is treated as a verifier failure.
- Extended `agent-init --status --json` with `onboarding_status` and updated the
  status schema, bundle inventory, canonical installer, README docs, and drift
  tests.

## 2026.06.16.3 — Post-council enforcement hardening

- Fixed post-council P1s before marking the guard release stable: unsafe
  dot-segment policy patterns are now rejected, Claude `Edit`/`Write`/
  `MultiEdit` hooks are path-aware, and protected edit acknowledgements are
  recorded under `.agents/state/guard-ack.log`.
- Hardened verifier contract checks so context policy and project tech-stack
  contracts reject unexpected JSON properties and unsafe project-relative
  protected/generated path entries instead of producing schema false-greens.
- Scoped `--apply-candidates` to the bootstrap generated-file allowlist and made
  it resolve workflow from the installed lock, preventing project files such as
  `src/api.generated.ts` from being promoted accidentally.
- Added regression coverage for missing context packs, policy dot-segment
  patterns, Claude edit hook enforcement, schema extra-property failures,
  unsafe project tech-stack paths, project-pattern neighbor overmatch, and
  non-bootstrap `*.generated.*` source files.

## 2026.06.16.2 — Guard integrity hardening

- Added heavy-council regression coverage for Agent Guard false-green cases:
  required-context drift, path normalization bypass, glob overmatch, adapter
  control files, project-specific protected paths, compact policy JSON, policy
  path traversal, strict protected-edit acknowledgement, and verifier/doctor
  read-only behavior.
- Hardened `scripts/agent-guard.sh` with canonical project-relative path
  normalization, unsafe policy path rejection, project tech-stack protected path
  merging, strict `pre-edit` with `--ack`, read-only `check`, and `pre-final`
  validation of required-context hashes.
- Changed generated verifier and Codex doctor to use read-only guard checks
  instead of refreshing `.agents/state/context-pack.json`.
- Expanded the default context policy to protect agent adapter/control surfaces
  such as `.codex/**`, `.claude/settings.json`, `.cursor/**`, `GEMINI.md`, and
  `.windsurfrules`.
- Made Ubuntu CI install shellcheck deterministically and fixed infra-only docs
  so they no longer reference a full-workflow handoff schema that is not
  generated in the infra preset.

## 2026.06.16.1 — Multi-agent harness guard lite

- Repositioned the bundle as a multi-agent harness kit rather than only a
  bootstrap config generator.
- Added Agent Guard Lite: `docs/agent-configs/context-policy.json`,
  `scripts/agent-guard.sh`, and a context-policy JSON Schema.
- Integrated guard preflight into the shared agent hook, generated verifier, and
  Codex doctor so context-pack drift is checked by normal harness validation.
- Added regression coverage for generated policy/schema files, guard preflight,
  protected-path classification, canonical export, and infra-only generation.

## 2026.06.14.13 — Generated candidate lifecycle hardening

- Added `--apply-candidates` to promote the latest reviewed `*.generated.*`
  candidate for each generated path and remove older candidates for that path.
- Added `generated_file_drift` to `--status --json`, backed by the same
  regenerated-output comparison used by `--diff`, so stale generated docs are
  visible even when the lock file exists.
- Changed lock writes to honor `--skip-existing` instead of silently bumping
  `installed_version` while generated files remain stale.
- Fixed lifecycle diff/status coverage for the managed `.gitignore` block so a
  missing generated block is reported as generated-file drift.
- Made the generated `agentmemory-mcp` skill portable by removing author-machine
  paths and Android/iOS-specific defaults from its frontmatter and operational
  setup guidance.
- Tightened bundle inventory tests against the actual `agent-bootstrap/` tree
  and added temp cleanup traps for lifecycle preview/apply helpers.
- Updated the solo workflow design doc and added test guards so bundle
  directory docs, lifecycle commands, and onboarding validation stay aligned.

## 2026.06.14.12 — Lifecycle parser and eval hardening

- Replaced lifecycle lock-field reads with JSON parsing when `python3` is
  available, preserving escaped values such as quoted/backslash project names.
- Expanded CI shellcheck coverage to include the bundle entrypoint, libraries,
  runtime snapshots, and generated target scripts when shellcheck is available.
- Upgraded onboarding fixture evals from scaffold checks to filled golden
  `project-tech-stack.json` contracts with source evidence, then validates them
  through the generated verifier.

## 2026.06.14.11 — Project tech-stack contract and CI gates

- Added a lightweight `agent-project-tech-stack/v1` JSON contract beside the
  Markdown project tech-stack spec so onboarding remains source-backed and
  machine-checkable without increasing startup context.
- Extended generated verifier checks to validate the project tech-stack
  contract in full-workflow targets.
- Added CI steps for a generated-target verifier smoke and optional shellcheck
  when the runner has it installed.
- Added onboarding fixture eval coverage and weird target path coverage; fixed
  lifecycle status/diff to preserve custom `project_name` from lock and fixed
  generated hook detector invocation for paths containing spaces or shell
  metacharacters.
- Extracted the small base/overlay/workflow templates into the portable bundle
  and changed the generator to copy those files instead of maintaining duplicate
  heredocs.

## 2026.06.14.10 — Model-profile contract validation

- Added a dedicated JSON Schema artifact for `agent-model-profiles/v1` and
  generate it into target projects with the other bootstrap schemas.
- Extended the generated verifier with dependency-free Python contract checks
  for the bootstrap lock, model profile catalog, schema catalog, and rtk
  checksum provenance manifest.
- Updated drift tests so canonical exports, generated targets, and verifier
  output all cover the model-profile schema and contract validation path.

## 2026.06.14.9 — Model profiles, schemas, and provenance

- Added source and generated model profile catalog
  `docs/agent-configs/model-profiles.json` with schema
  `agent-model-profiles/v1`.
- Updated generated Codex helper to load model defaults and fallback models from
  the model profile catalog while preserving one-shot environment overrides.
- Added JSON Schema artifacts for lock, status, and verifier report outputs and
  generate them into target projects.
- Added rtk provenance checksum manifest and updated generated `install-rtk.sh`
  to resolve expected checksums from that manifest.
- Extended verifier and drift tests to validate model profile/schema/provenance
  presence and JSON parseability.

## 2026.06.14.8 — Lifecycle and verifier hardening

- Added target lifecycle commands to the bootstrap entrypoint:
  `--status`, `--status --json`, `--diff`, and `--upgrade-plan`.
- Added machine-readable generated verifier output via
  `scripts/verify-ai-deps.sh --json` with schema
  `agent-bootstrap-verify-report/v1`.
- Added schema-aware verifier checks for `agent-bootstrap-lock/v1` and valid
  `workflow_preset`.
- Added generated-file diff preview that materializes into a temp copy and
  normalizes volatile timestamps/temporary paths before comparison.
- Added drift-test coverage that source templates under `docs/.../templates/`
  stay byte-identical with generated target templates.

## 2026.06.14.7 — Standalone root cleanup and onboarding guidance

- Removed stale generated runtime snapshots from root `scripts/`; the root now
  keeps only bootstrap/install compatibility wrappers and the drift test.
- Added drift-test guardrails so stale root runtime scripts cannot be
  reintroduced silently.
- Added `docs/superpowers/specs/project-tech-stack.md` to generated
  full-workflow projects and strengthened onboarding instructions for scanning
  the target project before filling project-specific tech-stack/spec context.
- Removed stale `--workflow three-mode` wording; supported presets remain
  `infra` and `full`.

## 2026.06.14.6 — Initial standalone extraction

Extracted from the ESPL Android repo (`android_2.0-main`) into an independent,
self-testing repository. No behavior change vs the in-repo bundle at this version.

Capabilities at extraction:

- Modular generator: thin entrypoint + sourced `lib/{core,detect,render,writers-runtime,writers-docs,onboarding}.sh`.
- Stack overlays auto-detected: `android_kotlin`, `ios_swift`, `node_js`, `python`, `generic`.
- Workflow presets: `infra` and `full` (legacy phantom presets removed).
- Onboarding scaffold: procedure + empty `project-brief.md` (with `<!-- UNFILLED -->`
  marker) + `docs/superpowers/{specs,plans}` skeleton, plus a startup trigger in
  `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`.
- `doubt-driven` adversarial-review skill (adapted from addyosmani/agent-skills, MIT).
- Token economy: progressive startup-context disclosure + estimated token-budget
  reporting in the generated doctor/verifier (always-on core target ≤3000).
- Portability: bash 3.2 safe; `curl`/`wget` + `sha256sum`/`shasum` fallbacks; pure-bash
  placeholder substitution (no python3 dependency); atomic temp-then-rename writes.
- Detector-lock drift warns (non-blocking) in the generated Claude hook.
- Non-destructive: visible `*.generated.*` candidates + `--skip-existing`; backups
  ignored, candidates surfaced by the verifier.
- Drift test with a MANIFEST/installer/test inventory cross-check guard.
