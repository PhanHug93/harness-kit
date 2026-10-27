# Tier tidy-up and stats — journal

Spec: `docs/superpowers/specs/2026-10-24-tier-tidy-stats-design.md`.
Branch `feature/tier-tidy-stats`, from main `f82fd6f` (release 2026.10.20.1).
The release bump ships in the same commit.

## 2026-10-24 — delivered in one commit

Why: a 20-task trial of 2026.10.20.1 (scripted tasks on a 1,625-file sample
project) found no missed risky change and no wrong block, but three kinds of
noisy warning. The next step is 2–4 weeks of real use, which needs numbers.

What shipped:

- The `--base` hint (pre-final's "Next:" line and the first `tier set` note)
  shows only when the task's start commit is not in the default branch's
  history, or when the default branch is unknown. `tier measure` reports it as
  `base_hint`.
- Binary files with an extension in `binary_asset_extensions` (images, fonts,
  audio, video, PDF; kit list in the context policy, project additions in
  `project-tech-stack.json`) count like any other file. Other binaries keep
  the medium reason.
- Pure moves (an old path, 0 counted lines, not binary) count for small →
  medium but not for the medium → large file check. The reason says how many
  files only moved.
- `tier suggest --handoff`: a large reason for a packet two or more agents
  share. AGENTS.md, `tier-medium.md` and the seat seeds list it.
- `tier stats [--since YYYY-MM-DD] [--json]` reads `tier.json` records and
  the `pre_final` events. The event and report tier block gain `committed`.

Owner decisions (2026-10-23): `--handoff` means large; images, fonts, media
and PDF count as ordinary files; pure moves never push a change to large.

Deviations from the design:

- The flags schema needed no change: `suggestion_inputs` is a free object.
- `tier stats` puts "raised after coding" on the Tier line, not inside the
  Suggestion line. The trial project showed "raised 0 (1 after coding)":
  the two counts compare different things (the last suggestion versus the
  tier coding started at), so one could not be part of the other.
- AGENTS.md needed a trim for `--handoff` (large kit 5,204 before the trim,
  5,202 of 5,203 after): "too unclear to test" became "vague request", and
  step 4 now reads "new scope mid-task: suggest again".
- A read-only review of the diff found no blocker; fixed from it:
  - the "0 counted lines" part of the pure-move rule had no test;
  - a project entry like `.` made every binary with no extension an asset:
    entries must look like extensions, the tier program warns and drops the
    others, the verifier rejects them;
  - a `.jar` renamed to `.png` counted as an asset: every path of a rename
    must be one;
  - `tier stats` crashed (exit 70) on odd records or events; it now skips
    them, and `--since` compares real times;
  - "--handoff (2+ agents)" could be read as any medium task (one agent
    codes, `@verify` reviews): AGENTS.md now says "(another agent codes)".
- `MANIFEST.md` lists `stats` among the tier commands.
- Not fixed, by choice: the review found that a task started on main and
  moved to a branch cut from another feature branch gets no hint. Judging
  HEAD at the move (its suggested fix) was tried and broke the usual rule-5
  case: start on main, branch off, commit, then `tier set` showed the hint
  for the task's own commits. Git cannot tell the two apart, so this stays a
  known limit (the user gives `--base`).

Verification:

- Mutation check: each of the five rules switched off in a copy of the tree
  (base hint, assets, pure moves, handoff, `committed`); the test suite failed
  every time at the new rows.
- Trial re-run on the same 20 tasks, compared with the run on `13d404d`:
  - the three `--base` lines that were noise are gone (t12, t16, t17);
  - t17 (logo swap) is small at the session and at push, with no warning;
  - t07 (20 files moved) measures medium, as the reviewer expected; the first
    suggestion is still large, since `tier suggest` gets paths, not moves;
  - session tier warnings 4 → 3 tasks (one noisy left: t16, an unstaged move
    the hint asks to `git add`); push warnings 3 → 2, both useful;
  - suggestions matching the expected tier: 16 of 20, unchanged; risky
    changes still caught; times unchanged (pre-final median 0.75 s, push with
    the hook 2.96 s).
- Local CI, all 10 steps in CI order, also with shellcheck 0.9: green after
  one fix. Shellcheck flagged `A && B || C` (SC2015) in a new test row, so
  the row became two checks.

Known limits:

- A binary moved unchanged still counts as edited (its lines are unknown).
- `tier stats` reads one machine's records; sharing them is part D.
- A task moved from main onto a branch cut from another branch gets no
  `--base` hint (see above).
- An asset extension missing from the list stays medium (noise, not a miss).

## 2026-10-27 — verifier false failures, folded into the same commit

Why: a gate report from a real iOS project (kit 2026.10.13.2) had
`verify-ai-deps.sh` exit 1 with two failures: "Claude PreToolUse does not use
shared agent hook" and "Codex helper doctor failed". Both had one cause. The
project's `.claude/settings.json` starts the hook path at
`"$CLAUDE_PROJECT_DIR"`; the verifier and the doctor looked for the exact text
`./scripts/agent-hook.sh claude-pretool`. Reproduced on 2026.10.24.1 by
changing only that line in a fresh target. The owner chose to fold the fix
into this commit (rewrite and force-push of the feature branch, authorized).

What shipped:

- The verifier and the Codex doctor accept the hook path from `./`,
  `$CLAUDE_PROJECT_DIR` or `${CLAUDE_PROJECT_DIR}`, quoted or not. Every form
  the old check accepted still passes; a hook in another directory or behind
  another variable still fails.
- A failing doctor's first `FAIL` line is part of the verifier's message.
- No "smoke test missing" warning: the kit never installs that test in a
  project, so every project carried the warning.

Not changed: the kit still writes `./scripts/...` in `.claude/settings.json`.
Writing `$CLAUDE_PROJECT_DIR` would change a managed file in every project
on upgrade, so it needs its own decision.

Verification: ten hook forms against a fresh target (seven accepted, among
them the kit's own and the iOS project's file; three rejected, and the
doctor names the reason); a
drift-test block that runs the verifier on three accepted forms and two
rejected ones; each of the four changes undone in a copy of the tree made
that block fail. Local CI, all 10 steps in CI order, also with shellcheck
0.9: green.

A read-only review found no blocker. From it, the drift test covers several
forms, not one: the verifier and the doctor each keep their own copy of the
check, and only the verifier's run reaches both. Kept as is: an unbalanced
quote or brace still passes (a typo the old check also let through; Claude
Code shows the hook's error when it runs), and a bare `scripts/...` path is
still rejected, as before.
