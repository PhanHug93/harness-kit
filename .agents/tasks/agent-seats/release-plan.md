# Agent seats and safe upgrade release implementation plan

> For agentic workers: use superpowers:subagent-driven-development or
> superpowers:executing-plans. Check off steps only with observed evidence.

Goal: ship the approved agent seats configuration and stderr isolation together,
including non-destructive migration for projects on older bundle versions.
Architecture: reviewed canonical seats script supplies one configuration and
lossless stdout interfaces; generator, launcher, verifier and installer consume
it together. Existing seats are never generated/candidate data. Existing legacy
files and USER knowledge remain untouched; legacy migration follows spec rev 3.
Tech stack: Bash 3.2, Python 3.8-compatible standard library, Git fixtures, PTYs.

## Authorization and starting state

User approved one continuous implementation-to-release pass on 2026-09-08,
explicitly requiring migration to preserve existing project configuration.
This supersedes the separate stderr-before-seats commit prerequisite and the
old packet's no-VERSION/no-commit boundary for final release preparation.
No intermediate commits. Do not rewrite existing released commit cf8f326.
Current checkout: /Users/admin/projects/agent-bootstrap; branch:
feature/simplify-task-relations. Base is captured in state.json on entry.
The existing spec revision 3 and gate attempt 4 are approved; retain their
contracts, including customized-legacy preservation and old-default migration
with a visible note. Release integration does not authorize setup on real
downstream projects; validate through disposable generated/old-release targets.

## Task 1 — Runtime and generator integration (Luna @build)

Write set: agent-bootstrap/agent-seats.sh, schemas/agent-seats-v1.schema.json,
lib/writers-runtime.sh, bootstrap-multi-agent-project.sh (wiring only),
verify-ai-deps.sh snapshot, install-agent-bootstrap-home.sh, lib/render.sh,
agent-local-only-check.sh, MANIFEST.md inventory, scripts/test-agent-seats.py.

- [x] Record a fresh-target RED assertion that scripts/agent-seats.sh exists.
- [x] Copy approved reference and harness, preserving K4/M3 and R7/R8.
- [x] Apply runtime/entrypoint generator hunks, schema and inventory wiring.
- [x] Verifier validates seats, optional legacy and schema; mirror its snapshot.
- [x] Generated fresh, customized legacy upgrade, existing seats and dry-run
      pass focused checks; run the copied harness on a disposable target.

## Task 2 — Launcher and generated prose (Luna @build)

Write set: agent-bootstrap/lib/writers-docs.sh only, plus
scripts/test-agent-seats-launcher.py for focused tests and an evidence report.

- [x] Record RED launch expectations with fake Codex on the old generator.
- [x] Embed the generator roster and implement eight-line resolve + three-line
      model-info; preserve empty fields and separate stderr at every call.
- [x] Implement five Codex seats/route aliases, precedence, per-model efforts,
      non-Codex refusal, primary conflict audit, read-only status/doctor, launch
      auto-init, no nested launch; preserve old mode/flow files and aliases.
- [x] Generated contracts and commands use tags and compatible packet fields.
- [x] Prove valid+warning launches correctly; Python/JSON/effort errors refuse
      launch with diagnostics, cleanup and caller trap preserved. Mutate the
      launcher data boundary to merge stderr, bypass conflict and skip explicit
      effort validation; each named regression must turn RED.

## Task 3 — Upgrade regression, suite and release integration (coordinator)

Write set: scripts/test-agent-seats-migration.py, existing release test scripts,
READMEs, CHANGELOG, version pins, CI, task bookkeeping. Do not overlap worker
write sets while they run. Parent handles final MANIFEST/entrypoint version
changes only after runtime worker returns.

- [x] Test the public upgrade/candidate path from previous released bundle(s):
      customized legacy model/effort/fallback, old defaults, existing customized
      seats, malformed config, existing USER overlays and project brief.
- [x] Assert source config bytes retained, effective migrated occupant values,
      second upgrade idempotency, dry-run no writes and fresh no legacy.
- [x] Port existing assertions to final seats interfaces (never weaken them);
      invoke focused suites from repository release checks.
- [x] Update operator migration documentation, default seats, changelog and
      all release version pins consistently.
- [x] Run bootstrap, onboarding, one-shot suites, catalog check, Bash 3.2,
      shellcheck, installer/snapshot checks and normal/long-name budgets.
- [x] Review requirements, then code quality independently; fix technical
      findings and rerun affected checks. Final review applies to production.
- [ ] Produce one reviewed release commit, check remote release/CI state and
      publish only the verified version; record unavailable external checks.

Evidence lives under .agents/tasks/agent-seats/evidence/release-20260908/.
All Git reads use GIT_OPTIONAL_LOCKS=0. Preserve pre-existing packet changes and
untracked Claude outputs. No production guard/hook/policy behavior changes.
