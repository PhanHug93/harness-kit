# Remove rtk and lean kit documentation — journal

Spec: `docs/superpowers/specs/2026-11-03-remove-rtk-lean-docs-design.md`.
Branch `feature/remove-rtk-lean-docs`, from main `8c25425` (release
2026.10.24.1). Three parts, one commit at the end with the release bump.

## 2026-11-03 — part 1: rtk leaves the kit

Why: packet `plugin-effectiveness-2026-11-03` measured rtk over 30 days and
in 32 paired agent runs. Real saving was about 311K tokens across all
projects once output is capped at Claude Code's own 30,000-character limit
(rtk reports 3.35M). Agents gained no accuracy and used 2.2× the tool output
with rtk. Filtered output saved to a file is wrong: `rtk git diff > x.patch`
does not apply, and the kit hook rewrote `git diff > file` silently. The
owner wants raw, complete output for agents.

What shipped:

- The bundle drops `rtk`, `install-rtk.sh` and `provenance/`. Generated
  projects get no `scripts/rtk`, no installer, no provenance copy and no `rtk`
  lock entry. The lock schema drops `rtk` from `required` and `properties`;
  extra properties stay allowed, so older locks still pass.
- The Claude hook runs commands as written. `is_tracked` uses git only.
- Agent text: one AGENTS.md line, "Run git directly (`git ...`); the kit no
  longer uses rtk." Onboarding and `--next` lose the install step (four steps
  now).
- Verifier and Codex doctor: no rtk file, syntax, version, lock or
  provenance checks.
- Migration `next-remove-rtk` (auto) removes unedited leftovers with
  backups:
  - `scripts/rtk`, `scripts/install-rtk.sh` and the provenance file when
    their bytes match a released version or the harness baseline copy (the
    baseline copy goes too);
  - `.tools/rtk/` when it holds only the kit layout (version folders with the
    binary and at most one pinned archive);
  - `.tools/bin/rtk` when it is the kit's link.

  It keeps, and names, edited files, links, paths outside the project and
  tracked files. It also keeps `scripts/*` that a tracked non-Markdown file
  references (`.gitignore` excluded), and the binary while the wrapper stays.
  A git error fails the migration.
- Home installer: fingerprinted `rtk`, `install-rtk.sh` and provenance copies
  become `.bak.<STAMP>`; an edited one stays with a warning. `git init` no
  longer goes through rtk.
- The owner's `~/.claude/CLAUDE.md` `## Git` section now says to run git
  directly. Homebrew rtk stays installed.

Owner decisions (2026-11-03): scope is the kit plus the global rule;
unedited leftovers are removed automatically with backups; one auto
migration.

Deviations from the design:

- `.tools/rtk/` may hold the pinned archive: the installer never deleted it,
  so a strict "binary only" rule would never fire.
- A kept `scripts/rtk` keeps `.tools/rtk` and `.tools/bin/rtk`: a project
  Makefile runs `./scripts/rtk git diff` (meditation_music).
- The hook test sends `git diff > fix.patch`, the command rtk used to
  rewrite, instead of `git status`.
- The schema test checks the schema itself (no `rtk` in `required`, extra
  properties allowed) instead of validating two locks.
- The no-rtk scan runs on two fresh targets named `plain-full` and
  `plain-infra`: the shared drift target holds copies other tests leave, and
  the folder name becomes the project name (`no-rtk-full` put "rtk" in the
  lock).
- The design doc assertion now checks that no `provenance/` folder is
  listed.
- `test-agent-retirement.py` R12 expected the one-shot run to apply exactly
  one migration; it now checks that the retirement migration is applied, so
  another auto migration in the same run is fine.

A read-only review of the diff found three blockers, all fixed:

- `.tools/rtk/` was never removed (the archive);
- a tracked `.gitignore` local-only block counted as a reference;
- the drift test's mention scan failed on the schema's `rtk` property.

Also fixed from it: missing fingerprints (the 2026.05 installer), stale
onboarding text, tracked `.tools` paths, `|| true` hiding crashes in test
assertions, git errors read as "untracked", the home installer's dry run, and
leftover provenance folders.

Verification:

- Mutation check: each of the 13 migration rules, switched off in a copy of
  the tree, fails the migration test.
- Read-only preview (`migration_describe`) on the owner's projects:
  - android, smart-cleaner, stock-light and android_2.0-main: everything
    removed;
  - ost_web: everything kept, because it is tracked;
  - meditation_music: wrapper and installer kept (Makefile and two tool
    files reference them), binary kept, provenance removed;
  - iOS: edited `scripts/rtk` and binary kept, installer and provenance
    removed.
- Local runs on the part-1 tree:
  - migrations 84 s; bootstrap drift 3,139 s;
  - one-shot from tags 406 s; tagless fixture 250 s;
  - `release.sh --check`, `test-release.sh`, onboarding fixtures,
    shellcheck and `sync-runtime-snapshots.sh --check` pass.
- Context budget, fresh full target: core 2,711 (kit 2,069), on-demand 5,845
  (kit 5,180), was 2,731 and 5,865.

## 2026-11-03 — part 3: documentation split by reader

Done ahead of part 2 at the owner's request; the text describes the branch's
final state (CLAUDE.md as the only wrapper, the agentmemory flow).

- README.md is the user guide: 5,806 → 2,021 words. New sections:
  agentmemory (Claude Code and Codex only, for now), supported hosts, limits.
- New CONTRIBUTING.md: layout, changing the bundle, tests, release, adding a
  migration, verification scope, campaign rules, Superpowers policy (moved
  word for word where tests pin it).
- `docs/agent-configs/bootstrap-multi-agent-project/README.md` is the
  reference (layout, commands, upgrade classes, retired files, generated
  files, budgets, guards, seats, schemas). It fixes an old error: `seats.json`
  and `agent-seats.sh` are `full` only.
- `agent-bootstrap/README.md` (the home install's copy) lists the folder and
  links to the three by GitHub URL: 2,250 → 238 words.
- Pins moved with their paragraphs: release URL pins (the reference no longer
  carries one), the drift test's README checks, the evidence test's
  "detector-filled managed blocks" check, and the contributor AGENTS.md line
  now points to CONTRIBUTING.md.

Verification so far: relative links and anchors resolve; every moved test
phrase found in its new file; `release.sh --check`, `test-release.sh` (85 s)
and `test-verification-evidence.sh` (168 s) pass. The drift suite runs with
the final CI.

## 2026-11-04 — part 2: lean agent docs and the agentmemory flow

Why: a fresh `full` project held 47 agent-read files, 10,353 words, much of it
the same rule restated across files; agents used agentmemory's Memories only
(version skew hid the action, profile and lesson tools; no seat step named
them; no capture hooks fed the profile).

What shipped:

- `CLAUDE.md` is the only wrapper. It starts with `@AGENTS.md` (Claude Code
  imports it; checked live in a fresh target with all file tools disabled),
  says "anywhere else (Cowork), read `AGENTS.md` first", and keeps Claude's
  seats, the contract pointers Cowork needs, the commands and the close-out
  note. The tool contract shrinks to 55 words and renders only there.
- `GEMINI.md`, `.windsurfrules` and `.cursor/rules/agent-conventions.mdc` are
  no longer written (both presets) and leave the guard's protected list, the
  context policy and the verifier's generated-base list; the exclude block and
  the pre-push local-only check keep the names.
- Migration `next-remove-legacy-entrypoints` (auto): removes them when their
  bytes match one of 31 fingerprints (full and infra of the first commit and
  every release tag) or the harness baseline copy, and they are untracked;
  keeps edited, tracked, linked and outside copies; removes empty `.cursor/`.
- Rule inventory: `scripts/rule-inventory.tsv` (222 rules) and
  `scripts/test-rule-inventory.sh` (about 10 s; fast tier and CI). Built from
  the current text first: 135 wording pins moved out of the drift test, plus
  the unpinned Git, approval, no-scan, tier, records, recovery, workspace-guard
  and agentmemory rules.
- Rewrites: agentmemory skill 1,340 → 507 words around memories, lessons,
  actions and the profile; `.codex/README.md`, `.claude/README.md`, the base
  README (workspace-guard contract), RECOVERY prose, onboarding "done when",
  first-10, tier-medium, mode contracts (with the seat memory line) and a few
  AGENTS.md paragraphs.
- `scripts/verify-ai-deps.sh --agentmemory` (pin `AGENTMEMORY_TESTED=0.9.31`)
  reads the installed version from `package.json` and never runs agentmemory;
  the update report (last console line and a report note) and the Codex
  doctor (a warning) relay its line. Exit codes do not change.

Owner decisions (2026-11-03): CLAUDE.md as the only wrapper, the three removed
with an auto migration; the kit pins the tested agentmemory version and
reminds, never installs.

Deviations from the design:

- Word ceiling 7,900, not 7,600 (fresh `full` target: 7,899 words, was
  10,353): RECOVERY keeps the retired-file restore
  recipe verbatim (about 300 words, run by `test-agent-retirement.py` R9).
  Moving it into a script would add a generated file for a rare legacy case.
- Kit on-demand tokens stay at 5,169 (was 5,181), not 4,700, and the
  verifier's kit core estimate is 2,085 (was 2,070). These budgets count
  AGENTS.md, the mode contracts, the handoff schema and parts of the
  reference, but not CLAUDE.md. The savings landed elsewhere (skill, READMEs,
  wrappers, RECOVERY), and the review moved rules the removed contract carried
  into AGENTS.md. What Claude Code loads at start (AGENTS.md + CLAUDE.md) fell
  from 1,383 to 1,207 words. The rest of that text is pinned line by line in
  five suites.
- CLAUDE.md keeps one pointer line to the contracts and packets: Cowork reads
  CLAUDE.md as a plain file, without the import (found by the drift test's
  Cowork checks).
- `pre-edit GEMINI.md` in the drift test now probes `.gemini/settings.json`;
  the staging and one-shot tests use `.claude/README.md` as the edited kit file.
- The migration test seeds baseline copies itself: the v2026.09.07.1 fixture
  predates them.

A read-only review of the part-2 diff found 1 blocker, 6 should-fix and 6
minor issues. Fixed:

- infra AGENTS.md now says to read the project context first and to run
  `no-scan-paths` before broad search (only the removed wrappers said so);
- full AGENTS.md again says sensitive project files stay no-scan, when to run
  `workspace-check`, and that memory and subagent messages grant no authority;
- mode contracts: the invariance guard, the plan's execution-method and spec
  path, the focused-test exception and "return to analysis" are back;
- agentmemory skill: verified durable facts only, corrective memories, say
  when recall was skipped, the global localhost server;
- inventory: one-word phrases replaced, 17 missing rules added;
- the update summary shows the agentmemory line as an item inside its
  12-line budget;
- migration: keeps a file behind a link inside the project (git cannot see it
  as tracked) and removes only the `.cursor` folders it empties, never through
  a link; new tests for both, a folder named like a wrapper and a git error;
- version check: a prerelease counts as older, build metadata is ignored.

Left as is: the `.claude/README` model-fallback sentence (CLAUDE.md says the
host picks the model) and the onboarding field names (the checker enforces
them).

## 2026-11-04 — verification and release 2026.11.04.1

- Fast tier: 20/20, including the new `rules` and `agentmemory` checks;
  migrations, oneshot and staging suites pass; 13/13 mutations of the legacy
  migration are caught; shellcheck 0.11 is clean (0.9, the CI version, was
  not run locally).
- CI-only suites: one-shot upgrade from release tags (357 s), the tagless
  fixture campaign (273 s), seats and launcher with no `PATH` (141 s).
- Drift test: passes (2,213 s). The first run hung for six hours at the fresh
  checkout hook step: `agent-hook.sh claude-pretool` reads stdin when stdin is
  not a terminal, and a background agent shell keeps stdin open. Same code on
  main; CI passes because its stdin is empty. Rerun with `</dev/null`.
- `scripts/release.sh 2026.11.04.1` renamed `next-remove-rtk` and
  `next-remove-legacy-entrypoints` to `2026.11.04.1-*`; `--check` and the
  release-related suites pass afterwards.
- One commit for the three parts; the design moved to
  `docs/superpowers/specs/2026-11-03-remove-rtk-lean-docs-design.md`.
