# Change tiers — journal

Spec: `docs/superpowers/specs/2026-10-20-change-tiers-design.md`.
Branch `feature/change-tiers`, from main `796e12d` (PR #15 merged, not yet
released). Release 2026.10.20.1 ships in the same commit.

## 2026-10-20 — delivered in one commit

What shipped:

- Every task gets a tier:
  - small: one agent, pre-final, PR review;
  - medium: one agent and `task.md`, then a fresh `@verify` or the human PR
    review;
  - large: the full seat cycle.
- `scripts/agent-guard.sh tier suggest|set|show|close`. The logic lives in the
  new bundle file `agent-tier.py`, installed as `scripts/agent-tier.py`. The
  rules and lists are in `context-policy.json`; projects add their own
  `risk_paths` in the tech-stack contract.
- The rules use a gitignore-style matcher with whole-word risk tokens. Tests,
  lock files and generated files are not counted. Renames are checked on both
  their old and new paths.
- `pre-final` measures the real change:
  - on a feature branch, from the merge-base with the default branch;
  - committed and uncommitted work, unstaged moves, binaries and submodules.

  Strict mode exits 5 when the change is above the tier. Runner results 1, 2
  and 3 win, and advisory mode never exits 5. The report and the `pre_final`
  event carry a `tier` block, written once per run.
- The Claude Code Stop hook blocks a size excess. When a tier was raised after
  coding and reviews are still missing, it only warns ("hand off to
  @verify").
- Lowering a tier is refused while a review's latest attempt is negative. A
  raise after coding needs the new tier's reviews.
- Contracts: a confirmed small or medium tier is the user's decision for the
  active seat to implement. Each tier has its own transitions.
- `@spec`, `@gate` and the medium coding seat end with a one-key tier
  checkpoint.
- New docs: `tier-medium.md` and the README section "Pick a tier for each
  change".
- Budgets are reported per tier.
- Generated `AGENTS.md` asks seats for short output in plain words.
- Release fixes:
  - tests no longer hard-code `next-*` migration ids or the version;
  - `release.sh` also rewrites the MANIFEST description of a renamed
    migration;
  - `__pycache__/` is ignored.

Results:

- Full tier, run locally once in CI order on the final tree:
  - release 79 s; guard 54 s; retirement 27 s;
  - bootstrap suite 2,086 s;
  - one-shot from tags 231 s; tagless fixture 172 s;
  - seats without PATH 105 s; generated-target verifier 18 s;
  - shellcheck 0.9 and 0.11, on the CI list and on a generated target.

  All passed. The first run failed twice:
  - a stray `agent-bootstrap/__pycache__` broke the bundle inventory check. A subagent compiled `agent-tier.py` without a cache prefix; the inventory now skips `__pycache__`, and the repo ignores it.
  - `test-agent-retirement.py` still hard-coded `next-retire-files`; it now finds the id by suffix.
- Fast tier at the phase 1 and phase 2 gates: 18/18 checks passed both times,
  in 19.5 and 20.8 minutes.
- Context budget on a fresh full target (`--project-name budget-fixture`):
  - large kit: 5,199 of the 5,203 ceiling;
  - small: 2,717;
  - medium: 3,051.
- Subagent tokens: about 3.35M in total.
  - Implementation: 1.83M.
  - Reviews: 0.99M.
  - Design: 0.53M (the startup-fit audit, and a three-seat council of two
    rounds).
  - An independent Codex review of the plan ran outside this count.

Deviations from the spec:

- The tier logic moved out of the guard, where the design had one Python
  block, into `agent-tier.py`. This kept the bash file from growing by more
  than 1,000 lines and removed the "heredoc takes stdin" trap.
- Policy changes made during review:
  - every path segment is split into words;
  - a lock-only change is medium;
  - `specs` is not a test directory;
  - `.md` and `.mdx` are never risky;
  - more tokens: authentication, password, jwt and others;
  - Dockerfile patterns narrowed.
- `--base` accepts only full refs or full commit ids. It refuses the branch's
  own upstream, and any relative ref.
- A tier summary line appears only when a tier is declared. Projects with no
  tier keep their old pre-final output, apart from one warning.
- The Stop hook warns instead of blocking when only reviews are missing, so
  the coding session can end and hand off.
- Coding start ignores changes made only of `*.md` and `*.mdx` files.
- To keep the large budget from growing, the checkpoint text lives in the
  seat commands and the Codex launcher seeds, not in counted docs.
- The release bump ran before the full tier, so the full tier tested the
  final tree.

Known limits:

- The large tier has only 4 tokens of headroom. The next doc addition there
  must trim first.
- The thresholds (3/15 files, 60/500 lines) are a guess and not yet tuned on
  real projects. History is recorded for later tuning.
- This catches mistakes, not intent:
  - a missing tier only warns;
  - non-Claude hosts can skip pre-final;
  - packets are local conventions, not access controls.
- Tier records and project risk paths stay local until proposal D.
- Proposals B (the launcher refuses `@build` without a gate yes), C
  (independence) and D (evidence that leaves the laptop) are not built.
- Not yet tried on a real downstream project.

## 2026-10-20 — fixes after two independent audits

Claude and Codex audited the commit in parallel. Codex found three faults the
Claude audit missed; both found the rest. Fixed in the same commit:

- Measure:
  - a file staged and then undone in the working tree, or committed and then
    undone, was missed. The measure now merges the commits, the index and the
    working tree, each file with its largest count;
  - an unstaged `mv` of a binary file lost the binary flag;
  - on the default branch, commits pulled from teammates counted toward the
    task. The base is now the newer of `start_commit` and the merge-base with
    the remote branch. Commits already pushed there are left out too, so each
    push is checked on its own, not the task as a whole;
  - the pre-push hook counted draft files. It now runs
    `pre-final --committed`, which counts only committed work (HEAD);
  - a project risk path like `app/ledger` did not cover the files inside it.
    It now does, as in `.gitignore`.
- Reviews:
  - the first `tier set` below the suggestion skipped the negative-review
    check;
  - older packets' `codex-review.md` (two sections) and `claude-review.md`
    were not read;
  - a human `@verify` with `pr: TBD` counted. It now needs a link or a
    number. A note in the findings that starts with `verdict:` no longer
    hides a pass.
- Checkpoints: the Codex seeds and `tier-medium.md` ran `tier suggest` with no
  `--paths`, which judged "files unknown" and wiped the facts on record. Every
  checkpoint now passes the files and flags it knows, and a suggest with no
  facts keeps the ones on record. The answer keys are the same everywhere.
- Docs:
  - `AGENTS.md` says when to run `tier close`;
  - the Outcome section asks the user again (lost in the budget trim);
  - the small `requested_action` no longer asks for `task.md`;
  - the README says where risky paths go and what an edited policy costs at
    update time.

  The large-tier kit text is 5,198 tokens, 5 under the ceiling, after three
  duplicate sentences were cut.
- A read-only review of these fixes found one regression, fixed too: a file
  added or renamed on the branch and then moved with a plain `mv` counted
  twice. Also from that review:
  - a newer verdict in the seat's own review file now replaces the one in an
    older file;
  - `pr:` accepts forms like `PR #12`;
  - `tier set` fills a null `base_commit`;
  - the index side is skipped when nothing is staged, and the new side of a
    binary file is no longer read.

Left for later:

- Updating a 2026.10.13.2 project ends "needs review" with three conflicts on
  project-owned files that still hold the old templates. Main before this
  change does the same; it is not from tiers.
- A stacked branch that forgot `--base` on the first set cannot add it later;
  the way out is a new task id.
- No "keep the tier with a reason" for a change that is large only because it
  deletes much code.
- No warning when `state.json` `base_commit` and `start_commit` differ.

## 2026-10-20 — rules first, after the second Codex audit

Codex audited `800d4ae` and found four faults. Two came from the fixes above;
two were fixes that did not go far enough:

- a checkpoint "keep" below a new, higher suggestion skipped the
  negative-review check;
- a new risky file, staged or committed, then moved with a plain `mv`, lost
  its risky path;
- a seat's own review file with no verdict yet borrowed the older file's pass;
- a local commit on main before the task, then a rebase pull, counted the
  teammates' files and exited 5.

Why they got through: each fix covered the reproduced case, not the rule
behind it, and the tests copied the cases. The review of the fixes was
limited to the changed lines, and the last fix round had no review at all.

This time the rules came first, in the spec ("Rules the checks keep"), each
with a table of cases in `scripts/test-change-tiers.sh`:

1. Lowering is below the higher of the declared tier and the current
   suggestion, also as a first set or a keep. A reason covers only the
   suggestion in force at the last set.
2. A move, plain or staged, counts the file once but keeps every path for
   the risk check.
3. A review is absent, pending, negative or passed. A pending own file never
   borrows an older pass and keeps an older negative.
4. Partial needs a cause from git, and pre-final names it; partial never
   exits 5.
5. A task started on the default branch follows a new branch made from its
   work.

A read-only review of the whole flow on the final code (not only the
changes) found four more faults in ordinary git use, from before this round:
a staged `git mv` counted twice, a reason widened to later suggestions, a
task set on main went stale on its new branch, and a gone `--base` ref
turned the check off with the wrong cause. They are covered by the rules
above (1, 2, 4 and 5), with test rows using 40-line files, so a double count
shows.

Each fault was run on `800d4ae` (wrong) and on the new code (right). Two
combined cases are in the tables: the scope grows, the keep is refused and
pre-push exits 5; and a local commit, the task and a rebase pull, where
pre-final warns and exits 0.

A second whole-flow review of the final code found three more false blocks in
ordinary git use: a stacked branch after its parent was merged, rule 5
taking over a branch that already held other work (from the fix above), and
an unstaged `mv` with an edit counted twice. Each review round kept finding
cases in the working-tree measure, which guesses intent from many git
states. The owner decided (2026-10-20) that the size check blocks only on the
commits: `pre-final --committed`, which the pre-push hook runs, exits 5; in a
session, pre-final and the Stop hook only warn. Missing reviews after a raise
still exit 5. With that:

- a stacked branch is measured from the newer of the merge-bases with its
  `--base` and with the default branch, or partial when neither holds the
  other;
- rule 5 now moves a task only when `tier set` runs on the new branch; until
  then the task is stale, with a hint;
- a reason covers the suggestion in force when it was given, so a later,
  lower suggestion keeps the allowance;
- a git error while reading the history is an error, not a partial measure.

Known limits: an unstaged `mv` with edits still counts twice in a session,
where it only warns; and a very large working tree can make the session
measure slower than its 30 s limit, which then skips the check with a
warning (the committed measure at push is much lighter).

A third whole-flow review, on the push path, found the last false blocks and
one missing check:

- with a default branch other than main or master and no `origin/HEAD`,
  pulled commits counted; the measure is now partial and names
  `git remote set-head origin --auto`;
- a branch cut from `develop`, or a stacked branch that forgot `--base`,
  could not be fixed in place; `--base` now works on any later set, and the
  exceeded next steps name it and the reviews a raise needs;
- in a subdirectory install git never ran the pre-push hook
  (`core.hooksPath` is relative to the top level); the installer now sets
  `app/scripts/githooks`, and the hook finds the project from its own path;
- after a raise, a human `@verify` could not pass before the PR existed;
  `pr: pending` counts at push;
- `git branch -m` left a task stale for good; `tier set` now moves it.

Each case was run on `800d4ae` (wrong) and the new code (right), including a
real `git push` to a bare remote with the hook armed in a subdirectory.

After a Codex review of the whole PR, the owner decided (2026-10-20) that
tier checks only recommend; they never block. Every seat still does its whole
part (checkpoints ask, reviews run, the Outcome asks the user), and the
warnings say what to do next. Concretely:

- pre-final, the Stop hook and the pre-push hook never exit 5; an exceeded
  tier (a size excess, or reviews still missing after a raise) warns with the
  reasons and the next steps, and the report, the event and the PR line keep
  it; failing tests still fail;
- a lowering while a review is negative needs `--reason`, warns, is recorded
  in the history (`overrode`), and the PR line says "lowered despite a
  negative @gate review";
- a later `--base` warns while a review is negative;
- a push that only deletes branches skips the check.

The Codex review also found that a committed code file moved to a `.md` name
no longer started coding, so a raise after it asked for no reviews; the
coding start now reads every path of a file, as the risk check does.

A review of the recommend-only code found that some recommendations reached
no one, now fixed:

- `tier show --pr-line` adds "measured medium, above the tier" and
  "@verify review still needed", so the PR reviewer, who now decides, sees
  them;
- the Stop hook's warnings (and its old "unverified" warning) went to stderr
  with exit 0, which Claude Code shows nowhere; they now also go out as
  `systemMessage` JSON, which Claude Code shows to the user (checked against
  the hooks reference);
- a partial measure above the tier was recorded as "ok"; it now recommends,
  with its cause next to each step;
- a plain `mv` with an edit adds the hint "git add them, so each move counts
  once";
- a start commit missing from the repo no longer makes the branch check fail.

The test suite caught one new fault while this was built: a renamed variable
had shadowed the move candidates, which crashed every working-tree measure
with untracked files.
