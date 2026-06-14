# Changelog

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
