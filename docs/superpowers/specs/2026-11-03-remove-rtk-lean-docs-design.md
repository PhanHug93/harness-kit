# Remove rtk and lean kit documentation

Branch `feature/remove-rtk-lean-docs`, from main `8c25425` (release
2026.10.24.1). Three parts, in this order, one commit at the end with the
release bump:

1. Remove rtk from the kit (implemented 2026-11-03).
2. Lean agent-read documentation (2A) and agentmemory for multi-agent work
   (2B), designed 2026-11-03 after part 1.
3. Rewrite README.md and the user and contributor documentation (designed
   last, so it describes the final state).

## Why

Packet `.agents/tasks/plugin-effectiveness-2026-11-03` measured rtk (Phase A:
30 days of logs; Phase B: the same commands raw and through rtk, and 32
headless agent runs with rtk on and off):

- Real saving ≈311K tokens in 30 days across all projects, once output is
  capped at Claude Code's own 30,000-character limit (rtk reports 3.35M).
- No accuracy gain; with rtk the agent used 2.2× tool output and 6% more cost.
- Filtered output kept in a file is wrong: `rtk git diff > x.patch` is not an
  applicable patch, and `rtk git show REV:<binary>` corrupts the bytes. The kit
  hook rewrites `git diff > file` to rtk silently.
- Agents work around it (956 `rtk proxy git` calls in 30 days).

The owner wants complete, raw data for agents: rtk leaves the kit.

## Owner decisions (2026-11-03)

- Scope: the kit and the owner's global `~/.claude/CLAUDE.md` rule. The
  Homebrew rtk stays installed (nothing will call it); the owner may
  `brew uninstall rtk` later.
- Downstream leftovers: removed automatically when unedited (with backups);
  edited ones are kept and named.
- Approach: one auto migration, not the retirement engine (it is pinned to the
  HK-07 CI files and is decision-only) and not a new file class in the core
  writer (larger blast radius).
- Parts 2 and 3 ride in the same branch and commit.

## Part 1 — what the kit stops doing

| Area | Change |
|---|---|
| Bundle | Drop `agent-bootstrap/rtk`, `agent-bootstrap/install-rtk.sh`, `agent-bootstrap/provenance/rtk-v0.37.2.sha256` (and the empty `provenance/`). Update `MANIFEST.md`, the home installer copy list and the drift test's canonical lists. |
| Generator (`lib/writers-runtime.sh`, `lib/render.sh`) | Stop writing `scripts/rtk`, `scripts/install-rtk.sh` and the provenance copy. Drop them from the local-only exclude block. The lock no longer writes `rtk`. |
| Claude hook (`agent-hook.sh` heredoc and snapshot) | No `rtk hook claude`: commands run as the agent wrote them. `is_tracked` uses `git` only. Drop `RTK` and `rtk_available`. |
| Agent text (`lib/writers-docs.sh`, `lib/onboarding.sh`, overlays and base README templates and their mirrors) | Replace every rtk line with one line in AGENTS.md: "Run git directly (`git ...`); the kit no longer uses rtk." Remove the install step from onboarding and from `--next`. Use `git rev-parse` where text showed `./scripts/rtk git rev-parse`. |
| Verifier (`verify-ai-deps.sh` heredoc and snapshot) | Drop rtk file, syntax, version and provenance checks, and the `lock.rtk` requirements. |
| Codex doctor (`codex-mode.sh` heredoc) | Drop the rtk exec, syntax and version checks. |
| Lock schema | `rtk` leaves `required` and `properties`; `additionalProperties` stays true, so locks written by older kits still validate. |
| Guard, local-only check, context policy | Drop `scripts/rtk` and `scripts/install-rtk.sh` from their kit-file lists. |
| Home installer | Stop copying the rtk files; `git init` uses `git`. Old copies in the home install: see below. |
| CI and helper scripts | `.github/workflows/test.yml` and `scripts/test-fast.sh` shellcheck lists, `scripts/sync-runtime-snapshots.sh` snapshot list. |
| Docs | Remove rtk mentions from README.md, `agent-bootstrap/README.md`, `docs/agent-configs/bootstrap-multi-agent-project/README.md`, `MANIFEST.md`. Part 3 rewrites them later. CHANGELOG gets the new release entry. |

Unchanged: past specs, plan journals, older CHANGELOG entries and the
historical fixtures (`scripts/fixtures/historical-bundles/`).

Global rule: the `## Git` section of `~/.claude/CLAUDE.md` becomes:

```markdown
## Git
Run git directly. Do not route git through rtk (removed from the kit, 2026-11).
```

## Part 1 — leftovers in projects: migration `next-remove-rtk` (kind `auto`)

Runs on `update` (any older kit) through the one-shot runner. Paths:

| Path | Removed when |
|---|---|
| `scripts/rtk` | bytes equal the harness baseline copy, or SHA-256 is one of the two versions in the repository's history (`f3ceb173…`, `d4442098…`) |
| `scripts/install-rtk.sh` | baseline copy, or one of the four versions in the history (`76879f8e…`, `aca3c45d…`, `24ab6986…`, `ec98b8c6…`) or the 2026.05 kit's installer (`3b856c46…`, byte-identical in two projects, predates the history) |
| `docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256` | baseline copy, or `3208557b…` |
| `.tools/rtk/` | it holds only `v<x.y.z>/` folders with the `rtk` binary and at most one pinned archive (`rtk-<target>.tar.gz`, one of the four asset names; the installer never deleted it) |
| `.tools/bin/rtk` | it is a symlink whose target is `../rtk/v<x.y.z>/rtk` |

Full fingerprints are in the migration file.

Rules:

- A file is kept, and named in the summary, when it was edited (no match), is
  a symlink or special file where a regular file is expected, or resolves
  outside the project.
- A file tracked by git is kept and named: the README rule says an `auto`
  migration touches only kit-owned local files, and removing a tracked file
  belongs in the project's own commit.
- `scripts/rtk` and `scripts/install-rtk.sh` are also kept when a tracked
  file other than Markdown references that path (`git grep -l -F <path>`, one
  search per path, `*.md`, `*.mdc` and `.gitignore` files excluded): a project
  CI or Makefile may still call them, while journals and packets only mention
  them and an old local-only block in a tracked `.gitignore` only lists them.
  The summary names the referencing files.
- `.tools/rtk/` and `.tools/bin/rtk` are kept when tracked, or while
  `scripts/rtk` is kept for any reason: a kept wrapper still runs the binary
  (example: a project Makefile runs `./scripts/rtk git diff`).
- A git error (exit above 1: not a repository, a broken index) fails the
  migration instead of reading as "untracked, unreferenced".
- Each removed path goes to `migration_backup` first
  (`.tools/agent-state/journal/<STAMP>/migrations/next-remove-rtk/`); its
  baseline copy under `.tools/agent-state/harness-baseline/files/` is removed
  too. Empty `provenance/` and `.tools/bin/` directories are removed.
- `--rollback` does not restore them (same as every migration); the summary
  gives the backup folder.
- `migration_needed` is true only when something is removable, so a kept,
  edited file is reported once, not on every run.
- `migration_describe` lists what will be removed and what is kept and why.

Example: the iOS project (2026.10.13.2) updates. Its unedited `scripts/rtk`,
`scripts/install-rtk.sh`, provenance file and `.tools/rtk/v0.37.2/rtk` are
removed and backed up; if `scripts/install-rtk.sh` had been edited, it stays
and the summary says so.

Projects that do not update keep working: their `scripts/rtk` uses their own
`.tools/rtk` binary, not the Homebrew one.

## Part 1 — the home install

`install-agent-bootstrap-home.sh` (the `~/dev/agent-bootstrap` install and
its `agent-update`): `rtk`, `install-rtk.sh` and
`provenance/rtk-v0.37.2.sha256` in the install directory are renamed to
`<file>.bak.<STAMP>` when they match the fingerprints above (as the installer
already backs up replaced files); edited ones stay, with a warning. The
`provenance/` folder then holds only that backup.

## Part 1 — testing

- Drift test: full and infra targets hold no `*rtk*` file, and the word
  `rtk` appears in generated text only in the one AGENTS.md line;
  `claude-pretool` on `git status` returns no rewrite; the
  verifier and the Codex doctor print no rtk line; the bundle holds no rtk
  file and matches `MANIFEST.md`; a lock with an `rtk` object (older kit) and
  one without both pass the schema check.
- Migration test (a case in `scripts/test-harness-migrations.sh`, fixture
  generated by the v2026.09.07.1 historical bundle): unedited files removed
  with backups and baseline copies dropped; an edited `scripts/install-rtk.sh`
  kept and named; a tracked `scripts/rtk` kept; a `scripts/rtk` referenced by
  a tracked `Makefile` kept, one mentioned only in a tracked Markdown file
  removed; a `scripts/rtk` symlink pointing outside kept; an edited copy equal
  to its baseline removed; `.tools/rtk` and `.tools/bin/rtk` removed, an
  unexpected `.tools/rtk` layout kept; a fresh project does not select it; a
  second run changes nothing.
- README "Adding a migration": an `auto` migration may delete kit-owned local
  files that are byte-identical to what a kit wrote.
- Home installer: fingerprinted copies become `.bak.<STAMP>`, an edited one
  stays.
- One-shot tagged and tagless historical migrations still pass (they now also
  run the new migration).
- Mutation check: each rule switched off in a copy of the tree fails a test.
- Local CI, all 10 steps, also with shellcheck 0.9.

## Part 1 — out of scope

- Homebrew rtk on this machine.
- The kit hook's 1.8 s per call in a fresh target (packet finding; separate
  task).
- codegraph and agentmemory (the packet continues later).

## Part 1 — risks

- An agent, packet or memory that still says `./scripts/rtk git` gets
  "command not found" once; the AGENTS.md line tells it to run git.
- A project script that calls `scripts/rtk` without being tracked is not
  seen by the reference check; the summary lists every removed path and its
  backup.

## Part 2 — why

A fresh `full` target holds 47 agent-read files, about 10,175 words. Core
startup is 2,711 tokens (gate 4,000); on-demand is 5,845 (gate 6,200, amber
5,900). Exact duplication is small (about 600 words: one tool-contract block
copied into CLAUDE.md, GEMINI.md, the Cursor rule and a template). The bulk is
the same rule restated in other words across AGENTS.md, the mode contracts,
the handoff schema and reference, and RECOVERY.md, in dense jargon ("`@build`
may downgrade `yes` … but may never upgrade `no`").

The owner also found that agents use only agentmemory's Memories and never
Lessons, Actions or Profile. Causes found on 2026-11-03:

- The local server was 0.9.21 while `npx -y @agentmemory/mcp` had moved to
  0.9.31; the mismatched shim exposed 8 core tools, so action, profile and
  lesson-recall tools did not exist for agents.
- AGENTS.md frames agentmemory as "recall/save"; the kit skill uses Actions
  only on an explicit user request and Lessons only as a memory type; the
  owner's global skill named only save, search, sessions and file history.
- No seat step mentions lessons, actions or the profile.
- Profile is built from captured sessions; no capture hooks were installed.

## Part 2 — owner decisions (2026-11-03)

- Goal: short and clear. Each rule lives in one file and other files point to
  it; plain words; about 25–30% fewer words; a test proves no mandatory rule
  was lost.
- Approach: one source, many entrances. CLAUDE.md is the only wrapper left
  (Claude Code is the one host that does not read AGENTS.md); `.windsurfrules`,
  `GEMINI.md` and `.cursor/rules/agent-conventions.mdc` leave the kit, with an
  auto migration for the copies in projects. Every other path stays.
- The skill agentmemory-mcp is rewritten around Memories, Lessons, Actions and
  Profile (usage table below); the kit pins a tested agentmemory version and
  reminds, never installs.
- Done on the owner's machine (not kit changes; backups in
  `~/agentmemory-backup-20261103T083500Z/`): server 0.9.31 with all 433
  memories, server secret aligned with the Claude client, capture hooks for
  Claude Code and Codex, upstream skills `lesson`, `remember`, `recall` and
  `forget`, Codex pre-approval for the flow's tools, the global
  `~/.claude/skills/agentmemory` rewritten to the same flow.

## Part 2A — documents

| File (generated) | Words now | Target | Change |
|---|---|---|---|
| `CLAUDE.md` | 332 | ≤ 200 | Starts with `@AGENTS.md` (Claude Code imports it); keeps only Claude's text: default seats and small/medium implementation, the command list, the Stop-hook close-out. |
| `GEMINI.md`, `.cursor/rules/agent-conventions.mdc`, `.windsurfrules` | ~490 | 0 | No longer generated (see below). |
| `templates/tool-contract/shared.md` (and mirror) | 197 | ≤ 80 | Renders only into CLAUDE.md; drops what AGENTS.md already says. AGENTS.md says once that a host without a close-out hook runs `scripts/agent-guard.sh pre-final --run-verify` itself. |
| `AGENTS.md` | 1,051 | ≤ 950 | Shorter sentences; the agentmemory section becomes three lines pointing to the skill. Core startup must not grow. |
| `agent-mode-contracts.md` | 783 | ≤ 600 | One plain sentence per rule; seat memory moments (2B). |
| `agent-handoff-schema.md` + `agent-handoff-reference.md` | 988 | ≤ 800 | Each rule in one of the two files; the other links to it. |
| `RECOVERY.md` | 681 | ≤ 450 | Each case: the symptom, then one command. |
| `.codex/README.md`, `.claude/README.md`, `templates/base/README.md` | 1,180 | ≤ 670 | Drop text that repeats AGENTS.md. |
| `.agents/skills/agentmemory-mcp/SKILL.md` | 1,340 | ≤ 500 | See 2B. |
| Other docs and `.claude/commands/*` | rest | trimmed where they repeat a rule owned elsewhere | |

Total for a fresh `full` target: ≤ 7,600 words. Kit on-demand tokens: ≤ 4,700
(now 5,180). Gates 4,000 and 6,200 stay.

Rule inventory: `scripts/rule-inventory.tsv`, one row per mandatory rule:

```text
id<TAB>preset<TAB>owner<TAB>single<TAB>phrase
git.force-push	both	AGENTS.md	yes	Never force-push main/dev/develop
```

- `preset` is `full`, `infra` or `both`; `owner` is the generated path that
  owns the rule; `phrase` is a short exact sentence fragment.
- A test generates fresh `full` and `infra` targets and checks each phrase is
  in its owner file; with `single` = `yes`, the phrase appears in no other
  generated agent doc.
- The inventory is built from the current text first (before any rewrite), so
  the diff of the inventory shows every rule that changed or left.
- Drift-test assertions that pin wording in a rewritten file move into the
  inventory; behaviour assertions stay where they are.
- A word-ceiling test: the generated agent docs of a fresh `full` target total
  ≤ 7,600 words (the file list lives with the test).

Unchanged: other file paths, USER regions, detected and managed blocks'
markers, the verifier's token gates. Existing projects get the new text
through `update`; a file the user edited becomes a candidate as usual.

Removed wrappers. Why: `.windsurfrules` came with the first extraction from
android_2.0-main (2026-06-14) and was never revisited. Windsurf reads
AGENTS.md and keeps its rules in `.windsurf/rules/`; Cursor reads AGENTS.md;
Gemini CLI closed for consumer accounts on 2026-06-18 (Google, 2026-05-19)
and its successor Antigravity CLI reads AGENTS.md, keeping GEMINI.md only for
backward compatibility. All three files only repeat AGENTS.md, and the owner
uses Claude and Codex. Seats keep the `gemini`, `cursor` and `windsurf`
hosts (they read AGENTS.md); the optional mobile-optimization pointers in
`.cursor/rules/` and `.windsurf/rules/` stay.

- Kit: stop writing the three files (full and infra presets); drop them from
  the guard, context-policy and verifier lists and from the tool-contract
  renderer. The local-only exclude block and the pre-push local-only check
  keep the three names, so a kept (edited) copy stays local and never shows
  in `git status`.
- Migration `next-remove-legacy-entrypoints` (kind `auto`), same rules as
  `next-remove-rtk`: a file is removed, with `migration_backup` and its
  harness-baseline copy, when its bytes equal the baseline copy or a version a
  kit release wrote (fingerprints from every release tag, full and infra;
  the templates have no variables, so a version's bytes are fixed). It is kept
  and named when edited, tracked by git, a link or outside the project. An
  empty `.cursor/rules/` and `.cursor/` are removed. Example from the owner's
  projects: android and smart-cleaner (identical copies) are removed; ost_web
  tracks all three and keeps them.

## Part 2B — agentmemory

Kit version pin: the bundle records the agentmemory version it was tested
with (`0.9.31`); `scripts/release.sh` does not change it, a release that
tests a newer agentmemory does.

Version check, side-effect free:

- Find `agentmemory` on `PATH`; none → print nothing.
- Resolve the command's real path and walk up to the `package.json` whose
  name is `@agentmemory/agentmemory`; read `version`. Never run the command:
  before 0.9.24, `agentmemory --version` is not a version flag and may start
  the server.
- Older than the pin (or unreadable) → one line:
  `agentmemory 0.9.21 is older than the version this kit was tested with
  (0.9.31): stop it, npm install -g @agentmemory/agentmemory@0.9.31, start
  it, then re-run agentmemory connect claude-code --with-hooks and
  agentmemory connect codex --with-hooks.`
- Equal or newer → nothing.
- Shown at the end of the one-shot `update` report (`harness-kit-run.sh`) and
  by `.codex/codex-mode.sh doctor` (the Claude `/doctor` runs it). It never
  changes the exit status.

Skill `.agents/skills/agentmemory-mcp/SKILL.md` (≤ 500 words):

- The packet owns the current task's state; agentmemory keeps what outlives
  one task. Memory is advisory; never save secrets, repo-derivable facts or
  task state.
- Always pass `project` (repository folder name). Saves may add `agentId` =
  the seat; searches never pass `agentId` (it hides other seats' records).
- Start of a task, every seat: `memory_profile`, `memory_lesson_recall` (task
  type), `memory_smart_search`; `memory_file_history` before config, auth,
  build or release files; no task given: `memory_next`.
- While working: `memory_save` when a decision settles (reason, concepts,
  files); user correction → `memory_lesson_save` 0.7; a review finding worth
  not repeating → `memory_lesson_save` 0.5.
- Closing: out-of-scope follow-ups noted in the packet →
  `memory_action_create`; a finished follow-up → `memory_action_update`.
- Ask first: deletes, export, heal, reflect, consolidate, crystallize.
- Not used: leases, signals, checkpoints, sentinels, routines, sketches,
  team, mesh, slots, bridge sync, file compression.
- Setup line: the version check above, hooks for Profile, and the four
  upstream user skills (`lesson`, `remember`, `recall`, `forget`); stale
  facts (tool counts, CLIProxy ports) go.
- Supported hosts: Claude Code and Codex only, for now.

Seat moments, in `agent-mode-contracts.md`, one line: `@verify` and `@audit`
save a lesson for a defect worth not repeating; the seat recording closure
turns the packet's out-of-scope follow-ups into actions. AGENTS.md points to
the skill.

The full per-tool table (54 tools, 17 upstream skills) is the local draft
`agentmemory-usage.md`; the skill carries only the rules above.

## Part 2 — testing

- Rule inventory and word ceiling, as above (full and infra).
- Wrappers: `CLAUDE.md` starts with `@AGENTS.md` and does not repeat
  `scripts/agent-guard.sh preflight` or the workspace-check paragraph; fresh
  full and infra targets hold no `GEMINI.md`, `.windsurfrules` or
  `.cursor/rules/agent-conventions.mdc`, while the mobile-optimization
  pointers still install with `--add-skill mobile-optimization`.
- Migration `next-remove-legacy-entrypoints` (in
  `scripts/test-harness-migrations.sh`, fixture from a historical bundle):
  unedited copies removed with backups and baseline copies; an edited
  `GEMINI.md` kept and named; tracked copies kept; a symlinked
  `.windsurfrules` kept; `.cursor/` removed only when empty (a mobile pointer
  keeps it); a fresh project does not select it; a second run changes nothing;
  each rule switched off fails a test (mutation check).
- Version check: a fake package tree with `package.json` 0.9.21 prints the
  line; 0.9.31 and 0.9.40 print nothing; no `agentmemory` prints nothing; the
  fake `agentmemory` executable writes a marker if run, and the marker must
  not exist; the update and doctor exit codes are unchanged.
- Budgets: verifier core does not grow; kit on-demand ≤ 4,700.
- Existing suites (drift, migrations, one-shot tags and tagless, onboarding
  fixtures, local CI with shellcheck 0.9).
- One read-only review of the part-2 diff against the inventory.

## Part 2 — out of scope

- Project backfill for the 433 old memories (the built-in inference matched
  none).
- agentmemory leases, signals, team and mesh.
- The user-facing README (part 3).

## Part 2 — risks

- `@AGENTS.md` relies on Claude Code's documented import; the plan confirms
  it in a fresh session (AGENTS.md rules visible without a Read).
- A Gemini CLI enterprise user loses GEMINI.md; Gemini CLI can be pointed at
  AGENTS.md with its `context.fileName` setting (part 3 README notes it).
- Rewording can shift agent behaviour; the inventory catches lost rules, not
  changed nuance, so the review reads old and new text side by side.
- The MCP shim follows npm latest while the server follows the pin; a future
  shim may again expose fewer tools against an older server. The reminder
  keeps the server current, and the skill's setup line says: no action or
  profile tool → update the server and reconnect.

## Part 3 — README and contributor docs (designed 2026-11-03)

The owner asked for the README rewrite before part 2 is implemented. The new
text describes the branch's final state (no rtk, CLAUDE.md as the only
wrapper, the agentmemory flow and version reminder); all three parts ship in
one commit, so nothing describes a state that never ships.

Today three READMEs (10,048 words) mix users, operators and contributors and
repeat each other (seats, Cowork, pre-final, retirement, Superpowers policy).
New layout, each paragraph in one place:

| File | Reader | Content |
|---|---|---|
| `README.md` (≤ 2,200 words) | people using the kit | what it is and gives; requirements; install; update, read the result, undo; seats; tiers; checks before hand-off; Cowork; agentmemory (Claude Code and Codex only, for now); supported hosts; what is pushed and what stays local; limits; links |
| `CONTRIBUTING.md` (new) | people changing the kit | layout; Git-flow pointer to AGENTS.md; how to change the bundle (heredocs, snapshots, mirrors, MANIFEST, extension guide); tests (fast, full, CI, not parallel-safe); release; adding a migration; verification scope and downstream feedback; campaign evidence; development records; Superpowers policy |
| `docs/agent-configs/bootstrap-multi-agent-project/README.md` | reference | bundle and home layout; home install and shell functions; generator commands; how upgrades treat files; retired files; what the kit generates; detection; onboarding outputs; verification details; context budgets; Agent Guard Lite; Workspace–Repository Guard metadata; seats catalog and migration; contracts and schemas; validating a target; out of scope |
| `agent-bootstrap/README.md` | the home install | folder contents, the install line, links (absolute GitHub URLs: the home copy has no repo docs) |

Host support: Claude Code (CLAUDE.md imports AGENTS.md) and Codex (AGENTS.md,
seat launcher) are supported; Cursor, Windsurf and Antigravity read AGENTS.md;
Gemini CLI users set `context.fileName` to `AGENTS.md`.

Agentmemory section: supported for Claude Code and Codex only, for now; how to
install and upgrade to the pinned version, enable the capture hooks (approve
them once in the Codex TUI), add the four upstream user skills, and what the
seats do with Memories, Lessons, Actions and Profile.

Tests and pins that move with the text:

- `scripts/release.sh` pins: README keeps its three; the bundle README keeps
  the install URL; the reference drops it (pin list and `test-release.sh`
  loop updated).
- Drift-test wording pins follow their paragraph: Superpowers policy →
  CONTRIBUTING.md only; Cowork steps and `pre-final --run-verify` → README
  only; "manual contract validation" and "excludes tool-specific wrappers" →
  reference; the reference keeps its layout and lifecycle pins.
- `test-verification-evidence.sh`: "detector-filled managed blocks" only in
  the reference.
- Contributor `AGENTS.md`: "Read CONTRIBUTING.md for the affected verification
  commands".
