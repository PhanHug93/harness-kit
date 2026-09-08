## User decision — 2026-09-06T18:16:04Z

- Action: authorize Claude (`@spec`) to resolve `@gate` findings B1–B6 by
  revising the design spec, task.md, build-handoff.md, and the packet's
  reference script and QA harness. Scope excludes production source under
  `agent-bootstrap/` and `scripts/`; `@build` implements after
  `sufficient_for_coding_model: yes`.
- Authorization: user message in the Cowork session ("mình muốn bạn triển
  khai và hậu kiểm chất lượng cải tiến").
- Alternatives considered: return the findings to `@build` without a spec
  revision (rejected: the findings are contract gaps, not implementation bugs).

## User decision — 2026-09-06T20:18:35Z

- Action: run a heavy council (two rounds, three senior seats), synthesize with
  the `@gate` attempt-2 verdict, and let Claude (`@spec`) fix the reference
  script, harness, spec and handoff thoroughly toward a release-safe version.
- Authorization: user message in the Cowork session ("Tiến hành tự council
  heavy với 2 vòng và 3 ghế senior … fix triệt để nhằm cho mình 1 version an
  toàn để release").
- Scope: packet artifacts and the tracked design spec; production source under
  `agent-bootstrap/` and `scripts/` remains `@build`'s after `@gate`
  records sufficient/yes.

## User decision — 2026-09-08, combined release

User approved continuous implementation and release of guard + stderr isolation + agent seats, explicitly requiring migration for older project versions without losing configuration. Implement stderr semantics in the final seats launcher, without requiring a separate legacy-parser commit. Preserve existing seats and customized legacy settings, USER overlays and brief; verify disposable upgrades before release. See release-plan.md.
