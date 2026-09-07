# Agent seats implementation plan (`@build` handoff)

> `@build` executes this bounded plan with test-driven development after
> `@gate` records `sufficient_for_coding_model: yes` in `codex-review.md`.
> `@audit` (Claude) cross-reviews; `@owner` decides. Packet: `.agents/tasks/agent-seats/`.

**Goal:** seats are fixed protocol tags; occupants are dynamic data in
`docs/agent-configs/seats.json`; `scripts/agent-seats.sh` suggests, assigns,
validates, renders; the launcher resolves seats at run time; prose names tags only.

**Architecture:** one JSON document (catalog + seats) read by one script;
launcher and docs consume it; generator copies the script (no heredoc copy).

**Tech stack:** portable Bash 3.2 dispatcher, python3 for JSON, generated
temporary Git fixtures, shellcheck, fake `codex` binary from Task 3.

Worktree: `/Users/admin/.config/superpowers/worktrees/agent-bootstrap/simplify-task-relations`
Branch: `feature/simplify-task-relations`. Start only after `guard-hook-deny-ack`
and `codex-profile-stderr-isolation` are committed; record `base_commit` at
implementation entry.

Read, in order: `task.md`, `docs/superpowers/specs/2026-09-06-agent-seats-design.md`,
the latest pre-coding attempt in `codex-review.md`, `review-brief.md` decisions.
Reference implementation: `evidence/reference-agent-seats.sh` (behavior verified
on a fixture; adopt it as the canonical script after review, adding `efforts`
and auto-`render` after `set|wizard|reset`).

## Write boundaries

| Area | Files | Change |
|---|---|---|
| New runtime script | `agent-bootstrap/agent-seats.sh` (canonical) | from `evidence/reference-agent-seats.sh` + `efforts` + auto-render; `# AGENT_BOOTSTRAP_GENERATED` header |
| Generator wiring | `agent-bootstrap/lib/writers-runtime.sh` | `copy_bundle_file "agent-seats.sh" "$TARGET_DIR/scripts/agent-seats.sh"` + `make_executable` next to the `agent-guard.sh` copy (~:135); schema copy loop (~:225-246) adds `schemas/agent-seats-v1.schema.json`; verifier heredoc (~:752): `need_executable`/`need_bash_syntax` for `scripts/agent-seats.sh`, seats validation (FAIL invalid, WARN missing, WARN legacy coexists), schema catalog `$id` map (~:1202), `agent-bootstrap.lock.json` untouched |
| Snapshot | `agent-bootstrap/verify-ai-deps.sh` | regenerate from a temp target, byte-identical to heredoc output |
| Seats default | `agent-bootstrap/lib/writers-docs.sh` or `writers-runtime.sh` | write `docs/agent-configs/seats.json` from bundle defaults on fresh generation (candidate path on existing targets); call `scripts/agent-seats.sh render` at the end of full-workflow generation |
| Schema | `agent-bootstrap/schemas/agent-seats-v1.schema.json` | JSON Schema for `agent-seats/v1` (catalog.models, seats, occupant); MANIFEST row; installer `copy_file`; test schema list (`test-bootstrap-multi-agent-project.sh` ~:1170) |
| Launcher | `agent-bootstrap/lib/writers-docs.sh` heredoc `.codex/codex-mode.sh` (~:1814) | remove `load_model_profile`/route tables; add `resolve_seat` (parses the `resolve` TSV with `IFS=$'\t' read -r -a`), `effort_for_launch`, explicit-effort validation via `efforts`, `SEAT LOCK` seeds, `gate_coding` audit, `status`/`doctor` roster; keep env override names and `CODEX_USE_FALLBACK`; `CODEX_MODEL_PROFILE` becomes a warning no-op for one release |
| Prose | `writers-docs.sh` | mode contracts, handoff schema, AGENTS.md roster block + sentence, CLAUDE.md, `.claude/README.md`, commands, `.codex/README.md`; remove the four `Config version:` lines (handoff, mode contracts, karpathy, council) |
| READMEs | `README.md`, `agent-bootstrap/README.md`, `docs/agent-configs/bootstrap-multi-agent-project/README.md` | seat table, flow by tag, limitation sentence with `@gate`, `agent-seats.sh` operator section |
| Tests | `scripts/test-bootstrap-multi-agent-project.sh`, `scripts/test-onboarding-fixtures.sh` | prose assertions → tags; Task 3 launches → seats; new seats block (AC1–AC10); migration fixture |
| Changelog | `CHANGELOG.md` | Unreleased: seats, tags, `gate_coding`, legacy profile deprecation, Config-version removal |

No VERSION/MANIFEST version bump. No change to `agent-guard.sh`, `agent-hook.sh`,
`agent-onboarding.sh`, policy JSON, or the guard packet's files.

## Execution checklist

- [ ] Confirm branch/head/status; both earlier packets committed. Set
      `base_commit`, phase `implementation`, owner `codex`, `seat: @build`.
- [ ] RED first: add the seats test block (fixture generation, `suggest`
      seeding from a customized legacy profile, `wizard --yes`, `set` valid and
      invalid with cksum guards, `render` idempotency, `resolve` matrix incl.
      `conflict`, launcher matrix with the Task 3 fake codex, non-Codex seat
      exit 2, explicit unsupported effort error, doctor/verifier states,
      migration fixture, `grep -w` for `Sol|Luna|Astra` role words = 0). Run
      the focused block against the current source and record the failures.
- [ ] Add `agent-bootstrap/agent-seats.sh` (+ `efforts`, auto-render), schema,
      MANIFEST row, installer entries, writers-runtime copy + schema copy +
      verifier checks; regenerate and mirror `verify-ai-deps.sh`.
- [ ] Rewrite the launcher heredoc: seat resolution, effort rules, seeds,
      `gate_coding`, status/doctor roster; keep stderr isolation (python in
      `resolve` prints TSV only to stdout; launcher never merges `2>&1`).
- [ ] Prose to tags (mode contracts, handoff schema, AGENTS.md roster block,
      CLAUDE.md, `.claude/README.md`, commands, `.codex/README.md`, READMEs);
      remove the four `Config version:` lines; update every prose assertion in
      the same commit (no loosening — each assertion changes to the new exact text).
- [ ] Focused block GREEN. Mutation: in an isolated generated copy make
      `resolve` report `conflict=0` always; the `gate_coding` assertion must
      fail. Second mutation: skip explicit-effort validation; the unsupported
      effort assertion must fail. Restore.
- [ ] Budget: doctor on the suite fixture and on a target named
      `very-long-project-name-for-budget-check`; record core/on-demand numbers.
- [ ] Release checks, logs under `evidence/`:
      `bash scripts/test-bootstrap-multi-agent-project.sh`
      `bash scripts/test-onboarding-fixtures.sh`
      `bash scripts/test-one-shot-upgrade.sh`
      `bash scripts/sync-template-catalog.sh --check`
      `shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-seats.sh agent-bootstrap/verify-ai-deps.sh <target>/.codex/codex-mode.sh`
      macOS: `/bin/bash --version | head -1 && /bin/bash <target>/scripts/agent-seats.sh show && /bin/bash <target>/.codex/codex-mode.sh status`
- [ ] Append `## Implementation attempt 1` with `seat: @build`, actual model and
      source, files, RED/GREEN/mutation results, budgets, commands and log
      paths, deviations, unavailable checks. Set phase `verification`, owner
      `codex`, `seat: @verify`; request the final technical review.

Keep long logs in `evidence/`; the report stays concise. No commits, pushes,
branch switches, or release actions. Ask `@owner` about a concrete technical
blocker and continue independent safe work; do not invent approval.

## Independent review correction 1

`@gate` attempt 1 returned B1–B6; the spec (revision 1) and the reference
script (`evidence/reference-agent-seats.sh`, sha256 in `evidence/seats-qa-summary.json`)
now resolve them. Changes to this plan:

- Adopt the v2 reference script as `agent-bootstrap/agent-seats.sh` as is
  (it already has `init`, `roster-block`, `model-info`, `conflict`, auto-render,
  exit codes 2/3). Do not reintroduce a heredoc-on-stdin invocation.
- Launcher reader: `while IFS= read -r` over the eight `resolve` lines with a
  line-count check; `model-info` for override efforts; `conflict <seat>
  <effective-model>` after precedence; seed `launch_model=`; refuse
  `CODEX_USE_FALLBACK=1` without a configured fallback.
- Generator: no `seats.json` emission; call `scripts/agent-seats.sh init`
  after runtime files exist (skip on `--dry-run`); `AGENTS.md` writer embeds
  `roster-block` output; never call `render` during generation.
- Packet contract: `seat`, `owner: agent` + `occupant`, `runner: agent` +
  `runner_host`, phase→seat derivation, five examples (spec "Packet mapping").
- Tests: port `evidence/seats-qa.py` into the repository as
  `scripts/test-agent-seats.py`, invoked by the bootstrap suite with the
  generated target path (Python is already a hard dependency); keep bash
  `need_*` assertions for prose, launcher, doctor/verifier, budget, and
  migration. Mutations: program-on-stdin, marker balance, launcher `conflict`
  boundary.
- Write boundaries add `agent-bootstrap/install-agent-bootstrap-home.sh`
  (`copy_file` for the script and schema) and `agent-bootstrap/MANIFEST.md`
  rows (no version bump).

## Independent review correction 2 (after `@gate` attempt 2 + council)

- Adopt reference **v3** (`evidence/reference-agent-seats.sh`, sha256 in
  `evidence/seats-qa-summary.json`) as `agent-bootstrap/agent-seats.sh`.
  Do not reintroduce: heredoc-on-stdin, single-line TSV, `.match`, lock files,
  in-place writes, `set` creating the file.
- Generator: apply `evidence/reference-generator-hunks.patch` (entrypoint
  order, `write_agent_seats`/`seats_program`/`seed_agent_seats`, roster in the
  `AGENTS.md` writer, legacy emission removed). Then, in the same change:
  verifier heredoc (`writers-runtime.sh` ~:1092–1139, :1397, :1418–1422, :1437)
  makes `model-profiles.json` optional (validate + WARN when present) and adds
  `agent-seats.sh` executable/syntax checks and seats validation; snapshot
  mirrored; launcher heredoc (`writers-docs.sh` ~:1825–1964) replaces
  `require_model_profile` with `require_seats` (auto-seed inside the shared
  launch boundary only; `status`/`doctor` read-only); `lib/render.sh` :231–240
  and `agent-local-only-check.sh` :68–78 add `scripts/agent-seats.sh`;
  `install-agent-bootstrap-home.sh` :302–341 and `MANIFEST.md` add the script
  and `schemas/agent-seats-v1.schema.json`; the ~29 test references to
  `model-profiles.json` (bootstrap test ~:1402, 1882, 2068, 2395, 3487–3518)
  move to fresh-target-without-legacy expectations plus an upgrade fixture
  with the old default profile.
- Tests: port `evidence/seats-qa.py` v2 as `scripts/test-agent-seats.py`
  (invoked by the bootstrap suite with the generated target; run with
  `SEATS_QA_BASH=/bin/bash` on macOS); keep bash `need_*` assertions for
  prose, launcher matrix, doctor/verifier, budget, migration. Mutations: the
  seven in the harness summary plus the launcher `conflict` call.
- Launcher conflict uses primary models only; seed records `launch_model=`.
- Release gate additions (seat C): fresh target without legacy → verifier,
  `codex-mode.sh status`, `agent-hook.sh doctor` rc 0; `--dry-run` porcelain
  empty; installer export + inventory test; atomic-write and lock cases;
  Ctrl-C 130 / Ctrl-D 1; upgrade of the old default profile → Astra + note.
