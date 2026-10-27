# Tier tidy-up and stats: fewer noisy warnings, numbers from real use

Status: implemented 2026-10-24 in release 2026.10.24.1 (branch
`feature/tier-tidy-stats`, from main `f82fd6f`). What shipped, deviations and
known limits: `docs/superpowers/plans/tier-tidy-stats/journal.md`.

## Goal

Release 2026.10.20.1 shipped change tiers. A 20-task trial before release
found no missed risky change and no wrong block, but three kinds of noisy
warning. The next step is 2–4 weeks of real use, which needs numbers. This
change removes the noise and adds the numbers. It changes no thresholds.

## Owner decisions (2026-10-23)

- `--handoff` (two or more agents share the packet) suggests **large**: the
  full seat cycle, so every agent shares the same picture.
- Binary files: images, fonts, audio, video and PDF count as ordinary files;
  other binaries stay at least medium.
- Pure moves count toward medium but never push a change to large.

## 1. The `--base` hint only with evidence

Today pre-final adds "Next: if this branch starts from another branch, give
its base …" to every warning above the tier on a branch other than the
default one without `--base`. In the trial all three feature branches started
from main, so the line was noise each time.

Rule: show the hint only when the task's start commit (`start_commit`, the
HEAD at `tier set`) is not in the default branch's history. That means the
branch already held commits of its own when the task started: it came from
another branch, or work happened before `tier set`. Both are cases where
`--base` may matter.

- New branch from main, then `tier set`: no hint.
- Branch from `feature/login` with 5 commits, then `tier set`: hint.
- Default branch unknown: hint as today (cannot tell).
- Detached HEAD: no hint, as before.
- Known limit: a task started on main and moved by `tier set` (rule 5) to a
  branch cut from another feature branch gets no hint. Its start commit is on
  main, and git cannot tell the other branch's commits from the task's own
  commits made after branching off main (the usual rule-5 case). The user
  gives `--base` there.
- `tier set` prints its own hint when files are already changed at the first
  set. It follows the same rule, with HEAD as the start.

`tier measure` returns `base_hint: true|false`; the guard prints the line only
when it is true. No new git work beyond one `merge-base --is-ancestor`.

## 2. Binary assets count as ordinary files

Today any binary file adds "binary file changed" (medium). Replacing a logo
became medium in the trial; a reviewer picks small.

Rule: a binary file whose extension is in the asset list counts like any other
file. Other binaries (`.jar`, `.so`, `.dll`, `.aar`, `.zip`, unknown) keep the
medium reason, since they are usually prebuilt code.

- Kit list: `binary_asset_extensions` in `agent-context-policy.json`
  (schema updated): png, jpg, jpeg, gif, webp, avif, heic, bmp, tif, tiff, ico,
  icns, ttf, otf, woff, woff2, eot, mp3, wav, ogg, m4a, aac, flac, mp4, mov,
  webm, m4v, pdf. Matched case-insensitively on the last extension.
- Project list: optional `binary_asset_extensions` in
  `project-tech-stack.json`, merged like `risk_paths`; bad values warn and are
  ignored.
- Risky paths still win: a logo under a risky path is large.
- A rename counts as an asset only when every path it had is one: a `.jar`
  renamed to `.png` stays medium.
- Each entry must look like an extension (`png`, `.Weird`, `c++`); `.`,
  `*.psd` or `tar.gz` warn and are left out, and the verifier rejects them.

## 3. Pure moves never push to large

Today each moved file counts as one file; small allows 3 and medium 15, so
moving 20 files without edits is large. The trial's reviewer picks medium.

Rule: a pure move is a counted file entry with an old path (a rename or an
absorbed move), 0 counted lines and not binary. Pure moves count for the
small → medium check. The medium → large file check counts only the other
files.

- 20 pure moves: medium, "20 counted files, 20 only moved (small allows 3)".
- 20 pure moves and 16 edited files: large, "16 changed files, plus 20 only
  moved (medium allows 15)".
- A pure move in `app/payment/`: large (risky path, checked on old and new
  paths as today).
- A binary moved unchanged counts as edited (lines unknown). Known limit.
- `tier suggest` is unchanged: its paths carry no move facts.

## 4. `tier stats`

`scripts/agent-guard.sh tier stats [--since YYYY-MM-DD] [--json]` reads what is
already recorded:

- every `.agents/tasks/*/tier.json` (history: suggest, set, close; flags);
- `pre_final` events with a tier block in the session event log (the guard
  passes its path; it may live outside the repository).

Example:

```
Tasks: 18 (15 closed, 3 open) since 2026-10-23
Tier: small 9 · medium 6 · large 3 · handoff 4 · raised after coding 1
Suggestion: kept 14 · lowered with a reason 2 · raised 2
Warnings: pre-final 5 on 4 tasks · push 3 on 3 tasks
Time to close (median): small 0.6 h · medium 3.1 h · large 1.8 d
```

- A task counts when its first history entry is on or after `--since`.
- Tier: the declared tier (open tasks) or the tier at close.
- Kept: the declared tier equals the last suggestion. Lowered: declared below
  it (a reason is required, so all lowerings have one). Raised: above it. A
  task with no suggestion or no declared tier counts as "not compared".
- Raised after coding (on the Tier line): `coding_started_tier` is below the
  declared tier. It compares with a different tier than the suggestion, so it
  is not part of "raised".
- Warnings: events whose tier status is `exceeded`. The tier block gains
  `committed: true|false` (pre-push passes `--committed`), optional in the
  event schema, so push and pre-final warnings are told apart. Older events
  without it count as pre-final.
- Time to close: first history entry to the close entry, median per tier.
- Unreadable records are skipped with one warning line; stats never fails on
  bad data. No tasks: "No tier records yet."
- Limits: one laptop's numbers. Sharing them is part D.

## 5. `tier suggest --handoff`

A new fact flag like `--data`: "--handoff: the work passes between agents (one
plans, another codes)", a large reason. AGENTS.md says "(another agent
codes)", so a medium task (one agent codes, a fresh `@verify` reviews) does
not read as a hand-off. Recorded in `suggestion_inputs.flags` (a free
object in the schema, so no schema change), reused by a fact-less suggest,
counted by `tier stats`.

Docs: the flag list in AGENTS.md, the checkpoint seeds, README and the kit
README. The large budget has 6 tokens of headroom: trim first; if the trim
fails, stop and ask the owner.

## Testing

- `scripts/test-change-tiers.sh` tables: base hint shown/hidden (new branch
  from main, branch from a feature branch, unknown default, first-set hint);
  logo png vs jar; 20 pure moves, 20 moves + 16 edits, risky move, binary
  move; project asset extension; handoff large and reused; stats on fixture
  records and events (counts, since, json, bad record, no records);
  `committed` in the event.
- Re-run the 20-task trial (`scratchpad/trial/trial.py`): t07 and t17 match,
  the three `--base` lines are gone, risky changes still caught (7 of 7).
- Local CI in CI order, then PR CI.

## Out of scope

- `tier suggest --moved`; threshold changes (3/60, 15/500).
- Step 3 slimming (unstaged-mv guessing, one source per fact, legacy review
  files, onboarding) and part D (evidence on the PR).

## Risks

- **Budget:** `--handoff` in AGENTS.md needs a trim first.
- **Wrong asset list:** an extension missing from the list stays medium
  (noise, not a miss); a project can add it.
- **Pure-move rule hides a big restructure from large:** it still shows as
  medium with "N only moved", so a reviewer sees it.

## Delivery

One commit at the end with a release bump (`scripts/release.sh`). The spec
moves to `docs/superpowers/specs/` in that commit; the plan stays local; the
journal is committed. Ask the owner for the PR target before pushing.
Estimate: about 300 lines of code, 200 lines of tests, one CI hour.
