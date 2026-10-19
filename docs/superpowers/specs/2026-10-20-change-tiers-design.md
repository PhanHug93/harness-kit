# Change tiers: pick the right amount of process for each change

Status: implemented 2026-10-20 in release 2026.10.20.1 (branch
`feature/change-tiers`). What shipped, deviations and known limits:
`docs/superpowers/plans/change-tiers/journal.md`.

## Goal

A small team (1–5 people) should not run five AI sessions for a one-line fix.
Every task gets a tier (small, medium or large) that decides which seats run.
The agent collects facts, a script turns them into a tier, the user confirms
it, and pre-final checks the real change against the same rules.

Example: "fix the misaligned Log out button" touches one file, so it is small:
one agent session, pre-final, PR review. "Add Momo payment" touches
`app/payment/`, so it is large: the full seat cycle.

## Why

An independent audit (2026-10-16) found that the full cycle does not fit a
small startup team. Every change needs at least three AI sessions and several
hand-offs, the docs give no fast path, and the gate verdict is only a
convention. This design is part A of the audit's four proposals:

- A: change tiers (this design);
- B: the launcher refuses `@build` without a gate `yes`;
- C: real review independence (different models by default; the launcher
  records the model that ran);
- D: evidence that leaves the laptop (CI or PR attachments).

B, C and D are separate designs.

## Owner decisions

- Target: small teams first.
- The agent proposes the tier, the user confirms it, and a script checks the
  result.
- Three tiers.
- Risk paths: kit defaults plus the project's own, both recorded at
  onboarding.
- Medium `@verify` may use the same vendor as the builder. It must be a fresh
  session, and the review records `same_vendor: yes|no`.
- Tier checkpoints after `@spec` and `@gate` (large) and after `task.md`
  (medium) **always** ask the user, even when the tier is unchanged. The answer
  costs one key.
- A missing tier only warns in this release.
- Changes that already exist at `tier set` count toward the task (see §3).
- A stale task (closed, other branch, base gone) only warns.
- Build the core first (§6). The release ships in the same single commit.
- The default thresholds are a trial; README says so.
- **Tier checks recommend, never block** (2026-10-20, after the review
  rounds). The scripts measure, warn and record; the user decides. Every
  seat still does its whole part: checkpoints ask, reviews run, and the
  warnings say what to do next. Verification failures still fail, as before
  tiers.

## 1. Tiers and rules

### What each tier runs

| Tier | Flow | AI sessions |
|---|---|---|
| small | agent → pre-final → PR review | 1 |
| medium | agent writes `task.md` and codes → fresh `@verify` (or the human PR review) → PR | 2 |
| large | `@spec` → `@gate` → `@build` → `@verify` → `@audit` (today's cycle) | 5 |

### Rules

The rules and lists live in one place:
- `docs/agent-configs/context-policy.json` (kit-owned): `tier_rules`,
  `risk_paths`, `risk_tokens`, `dependency_manifests`, `dependency_locks` and
  `test_patterns`;
- `docs/superpowers/specs/project-tech-stack.json` (user-owned): the
  project's `risk_paths[]`.

Docs never copy the numbers. `tier suggest` and pre-final print the reasons.

The first matching row wins:

| Tier | When |
|---|---|
| large | a path (old or new name) is risky; or more than 15 counted files; or more than 500 counted lines; or `--data`; or `--access` |
| medium | 4–15 counted files; 61–500 counted lines; a dependency manifest or lock file changed, or `--dependency`; a binary file or a submodule changed; `--unclear`; or no planned paths |
| small | everything else (at most 3 counted files, 60 counted lines, nothing risky) |

**Counting**
- Counted files are the changed paths minus the excluded ones.
- Counted lines: for each counted file, the larger of lines added and lines
  deleted, summed. Example: editing 40 lines counts 40, not 80.
- A rename counts only its changed lines. Its old and new paths are both
  matched against risk.
- Excluded from counts:
  - dependency lock files;
  - the project's `generated_files[]`;
  - test files, matched by whole segment. Directories: `test`, `tests`,
    `__tests__`, `spec`. Names: `*_test.*`, `*.test.*`, `*.spec.*`,
    `test_*.py`, `*Tests.swift`, `*Test.kt`, `*Test.java`. So `latest.ts` and
    `attestation.ts` are not tests. A name pattern with an upper-case letter
    is matched case-sensitively, so `Latest.kt` is not a test.
- Excluded files are still matched against risk paths. Pre-final prints how
  many files and lines it left out.

**Facts the agent declares** (pre-final takes the higher of declared and
measured):

| Flag | Meaning | Tier |
|---|---|---|
| `--data` | changes or removes an existing stored or sent field, adds an enum or status value, or adds a migration (a new optional field alone is not `--data`) | large |
| `--access` | changes who may do what: login, roles, payment, secrets | large |
| `--dependency` | adds or upgrades a library | medium |
| `--unclear` | the request is too unclear to write an acceptance test | medium |

### Path matching

There is one matcher, in Python, shared by `suggest` and pre-final. It works
like gitignore:
- `**/` means zero or more directories, so `**/auth/**` also matches
  `auth/x.ts` at the root;
- `*` and `?` stay inside one path segment;
- `dir/**` means everything under `dir`;
- a pattern without `/` matches a file or folder name in any directory;
- a pattern that matches a folder covers what is in it, so `app/ledger` also
  matches `app/ledger/post.py`.

Risk and test matching ignore case.

**Risk tokens**
- A path is also risky when any word of any path segment (directory or file
  name) equals a risk token, ignoring case.
- Segments are split on `-`, `_`, `.` and camelCase, and each pair of
  neighbouring words is also joined. Examples:
  - `AuthService.swift` gives `auth`, `service`;
  - `packages/auth-service/` gives `auth`;
  - `signIn.ts` also gives `signin`;
  - `author.ts` gives `author`, so it is not risky.
- `*.md` and `*.mdx` files are never risky.

**Defaults**
- Risk tokens: `auth`, `oauth`, `login`, `signin`, `session`, `sessions`,
  `permission`, `permissions`, `payment`, `payments`, `billing`, `checkout`,
  `secret`, `secrets`, `credential`, `credentials`, `authentication`,
  `authorization`, `authorize`, `password`, `passwords`, `jwt`.
- Risk paths:
  - data: `**/migrations/**`, `**/migrate/**`, `**/migration/**`, `**/*.sql`,
    `**/schema.*`;
  - secrets: `**/.env*`, `**/*.pem`, `**/*.key`;
  - delivery: `.github/workflows/**`, `**/Dockerfile`, `**/Dockerfile.*`,
    `**/*.dockerfile`, `**/*.tf`, `**/*.tfvars`.
- Dependency manifests: `package.json`, `Podfile`, `Package.swift`, `Gemfile`,
  `go.mod`, `Cargo.toml`, `requirements*.txt`, `pyproject.toml`, `Pipfile`,
  `pubspec.yaml`, `composer.json`, `build.gradle`, `build.gradle.kts`,
  `libs.versions.toml`, `.gitmodules`.
- Dependency locks: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
  `Podfile.lock`, `Package.resolved`, `Gemfile.lock`, `go.sum`, `Cargo.lock`,
  `poetry.lock`, `uv.lock`, `Pipfile.lock`, `pubspec.lock`, `composer.lock`.

Risk paths are a separate list from `protected_paths`. Protected paths drive
the pre-edit acknowledgement, and risk paths must never add that friction to
every `auth/` edit.

### How the agent collects the facts

The agent does not guess a tier. It collects facts, and the script decides.

1. **Find the files, in a few searches.**
   - Take the key words of the request: a screen name, a button label, an API
     name, an error text. Search the code with grep or codegraph.
   - Look one step out: who calls what will change. For example, "Log out
     button" → search `logout` → `SettingsView.swift`.
   - If the files are still unknown, pass no paths. The answer is then at
     least medium.
2. **Answer the four questions** (the flags above).
3. **Run** `scripts/agent-guard.sh tier suggest --paths <files> [flags]` and
   ask the user (§4).

### When the agent is wrong

| Mistake | Caught by |
|---|---|
| expected 1 file, changed 6 | pre-final counts the real change and recommends a raise or a split; the PR line shows it |
| did not know it touches `auth/`, or moved a file out of it | pre-final matches the old and new paths |
| said "no new library" but a manifest changed | pre-final sees the manifest |
| judged the request clear when it was not | only the user, at each checkpoint |
| suggested too high a tier | costs time only; the user lowers it with a reason |

## 2. What each tier reads, and the budget

| Tier | Reads | Estimate on a fresh target |
|---|---|---|
| small | core: `AGENTS.md`, project context, brief | ≈ 2.6k tokens |
| medium | core + `docs/agent-configs/tier-medium.md` (new, ≈ 400 tokens) | ≈ 3.0k |
| large | today's on-demand set | kit text ≤ 5,203 (measured at `796e12d` with `--project-name budget-fixture`; the project name counts as text) |

- `AGENTS.md` gets a short "Pick a tier" block (about 100 tokens): the steps,
  the four questions, the new-request rule and the commands. Its read list is
  grouped by tier.
- `verify-ai-deps.sh` adds `context_budget.tiers.{small,medium,large}` and
  keeps the `core` and `on_demand` keys. Gates:
  - small uses the core gate (3,800 amber / 4,000);
  - large uses the on-demand gate (5,900 / 6,200);
  - medium is reported only.

  As today, only kit text fails a gate.
- Large must not grow, and its headroom is 29 tokens today. The new rules for
  large (the `AGENTS.md` block, the checkpoint and lowering rules, the tier
  note in the handoff schema) cost about 200–250 tokens. Cut that much from the
  duplicate text in the mode contracts' "Claude–Codex Collaboration Protocol"
  (1,381 tokens). If that cannot be done without losing meaning, stop and ask
  the owner.

## 3. State, commands, measurement and pre-final

### Files

- `.agents/tasks/<id>/tier.json` (schema `harness-tier/v1`) is written only by
  the script. Agents never edit it. Fields:
  - `task_id`, `branch`, `base_ref` (optional), `start_commit`;
  - `declared`, `suggested`, `suggestion_inputs`, `reason`;
  - `status` (`open | closed`), `closed_at`, `closed_by`;
  - `history[]`: each entry has `at`, `event` (`suggest | set | checkpoint |
    close`), `tier`, `printed_by`, `recorded_by`, `host_session`, `answer`
    and `reason`.
    - `printed_by` is the seat whose output asked the question (`--by`,
      default `user`).
    - `recorded_by` is the seat that wrote the entry (`--recorded-by`, default
      the same as `printed_by`).
    - `host_session` comes from `AGENT_HOST_SESSION_ID` when it is set.
  - `coding_started_tier` and `coding_started_at` are recorded the first time
    `tier set`, `tier show` or pre-final sees a change since the base that is
    not only `*.md` or `*.mdx` files.
- `.agents/tasks/ACTIVE` is reused. `tier set` writes it and `tier close`
  clears it. There is no second pointer.
- `state.json`: when it is missing, `tier set` writes a minimal valid state
  (`task_id`, `phase`, `owner`, `status: open`) so resume never sees a
  malformed packet. Its top-level `base_commit` is the `tier.json`
  `start_commit`, as the handoff schema says. (A warning when the two differ
  is not built yet.)

### Commands

Users run the commands as `scripts/agent-guard.sh tier …`. The guard runs
its workspace check, then passes the command to `scripts/agent-tier.py`,
which holds all tier logic. In the kit, `agent-tier.py` sits at
`agent-bootstrap/agent-tier.py`; it uses only the Python standard library and
argparse. It is local-only and protected, like the other harness scripts.

Changed during Task 3: an earlier version kept the evaluator as a Python
heredoc inside the guard. It was moved out to stop the bash file from
growing by more than 1,000 lines, and to remove the rule that a heredoc
takes stdin.

| Command | Does |
|---|---|
| `tier suggest [--task <id>] [--by @seat] --paths <file...> [--lines N] [--data] [--access] [--dependency] [--unclear]` | Prints the tier and its reasons. `--lines` is the agent's estimate of **counted** lines (tests, lock and generated files left out); the per-file split is measured only at pre-final. With `--task`, it records the suggestion if the packet is writable; otherwise it prints "not recorded". |
| `tier set <small\|medium\|large> --task <id> [--reason TEXT] [--base <ref>] [--by @seat] [--recorded-by @seat] [--answer keep\|switch\|scope]` | Creates or updates `tier.json`, the minimal `state.json` and `ACTIVE`. Records `branch` and `start_commit` on the first set. With `--answer`, it records a `checkpoint` event holding the user's answer; without it, a `set` event. |
| `tier show [--task <id>] [--pr-line]` | Prints the tier, the reasons and the history. `--pr-line` prints one line for the PR body. |
| `tier close --task <id>` | Run only on the user's word ("done"). Sets `tier.json` `status: closed`, and sets `state.json` `phase: closed`, `status: closed` and `closed_by: user`, as the state contract requires. It clears `ACTIVE` only when `ACTIVE` names this task. In this release it checks no evidence (proposal B adds that). |

`tier set` rules:
- If the change since the base is already non-empty (committed on the branch
  or uncommitted), it prints, for example: "2 files are already changed; they
  count toward this task. Commit or stash them on another branch first if
  they belong to other work."
- It refuses a closed task id.
- A tier lower than the last recorded suggestion needs `--reason`.
- Lowering while any review in the packet has a negative latest attempt
  needs `--reason`, warns, and shows on the PR line (§4).
- `--base <ref>` is for stacked branches. It is never the current branch.

Example `--pr-line` output:
`Tier: small (suggested large: hotfix, prod down) · 2 files, 18 lines`.
It goes in the PR body, not a commit trailer. Tier records are local-only
until proposal D, and README says so.

### Measuring the change

- **Default branch:** two values.
  - `default_ref` is the ref used for `merge-base`: `origin/HEAD` resolved
    (for example `origin/main`), else `origin/main`, `origin/master`, `main`
    or `master`.
  - `default_name` is its short name (`main`), compared with the current
    branch.
  - If neither exists, use `start_commit`.
- **Base:**
  - on the task's own branch, which is not the default one:
    `merge-base(HEAD, <base_ref or default branch>)`;
  - on the default branch: `start_commit`, or `merge-base(HEAD, origin/<default>)`
    when that is newer: commits pulled from teammates after `tier set` are not
    the task's. Commits already pushed there are left out too (the pre-push
    hook measured them);
  - with no HEAD at `tier set`: the empty tree.
- **Stale task** (it is closed, the current branch is not the task's branch
  (see rule 5), or the base is unreachable after a shallow clone or gc):
  - status `stale`;
  - pre-final warns and prints the measured tier;
  - never `exceeded`.
- **Fallbacks when a full measure is impossible:**
  - No tier declared: base is `merge-base(HEAD, default_ref)` on a
    non-default branch, else `HEAD`, which covers uncommitted changes only.
  - No merge-base (shallow clone, unrelated history): base is `HEAD`.
  - The result is labelled `measured (partial: <cause>)`; above the tier it
    still recommends, with the cause. Rule 4 below lists the causes.
- **Changes:**
  - three sides against the base: the commits (`<base> HEAD`), the index
    (`--cached <base>`) and the working tree (`<base>`), each with
    `git diff --relative --raw --numstat -M -z`. A file counts once, with the
    largest count any side shows, and is binary when any side is. A file
    staged and then undone in the working tree still counts: it is pushed;
  - plus untracked files that are not ignored
    (`git ls-files --others --exclude-standard -z`);
  - `pre-final --committed` (the pre-push hook) counts the commits side alone:
    committed work, not draft files (HEAD, not the refs named in the push);
  - untracked text files count their line count; a file with a NUL byte in
    its first 8 KB on either side sets the binary flag, and a text file that
    `.gitattributes` marks `-diff` or binary counts its text lines;
  - a deleted tracked file and an untracked file with the same content
    (`git hash-object` equal) count as a rename (an unstaged `mv`); a binary
    file stays binary;
  - mode `160000` sets the submodule flag;
  - `--relative` keeps subdirectory installs right.
- The tier is measured **before** verification commands run, because
  commands can create files.

### Pre-final

- Pre-final takes the `ACTIVE` task, or `--task <id>` (new pre-final option). It measures the change, then
  runs `run_detected_verification`, which returns 0 and leaves its result in
  `VERIFY_CODE`, so `set -e` cannot end the run before the tier is merged.
- **Tier checks recommend, never block** (owner decision, 2026-10-20). An
  `exceeded` tier (a size excess, or reviews still missing after a raise)
  warns with the reasons and the next steps, and is written to the report,
  the event and the PR line ("measured medium, above the tier", "@verify
  review still needed"); the exit code is the verification's. In a
  session the measure reads the working tree; `pre-final --committed`, which
  the pre-push hook runs, reads the commits of the checked-out branch. A push
  that only deletes branches skips the check.
  The pre-push hook is opt-in (`scripts/install-git-hooks.sh`). In a
  subdirectory install it points git at that subdirectory's
  `scripts/githooks`. A linked worktree has no kit files, so it has no push
  check.
- Exit codes: the verification's (0, 1, 2, 3, or 4 when nothing ran in
  strict mode). The tier status never changes them.
- **What is written:**
  - The report (`agent-guard-verification/v2`) gets a `tier` block when a
    tier is declared (the `pre_final` event gets it always, with status
    `none` when no tier is declared):
    task id, declared, suggested, measured, reasons, excluded counts, the base
    (sha, subject, commits since), status (`ok | below_suggested | exceeded |
    stale | none`), the override reason and `coding_started_tier`.
  - The same block goes into the `pre_final` event.
  - Without `--run-verify` there is no report; the status is printed and
    logged as an event.
- **Allowed tier:**
  - It is the declared tier.
  - When the user lowered below the suggestion with a reason, it is the
    suggestion that reason was given against (rule 1). The user accepted that
    risk on purpose, and only that one.
  - `exceeded` means the measured tier is above the allowed tier, on a result
    that is not stale (a partial one says so).
- **Output:**
  - `pre-final ok` is printed only on exit 0.
  - When a tier is declared, the last line is the `TIER:` summary, because
    the Codex close-out shows only the last line.
  - When no tier is declared, pre-final prints one warning on stderr and
    keeps its old last line. Projects that do not use tiers see no change.
- **Exceeded message**, with the summary line last:
  ```
  - 6 counted files (small allows 3); 2 test files not counted
  Next: ask the user to raise the tier (scripts/agent-guard.sh tier set medium --task fix-logout-button) or split the change.
  TIER: declared small, measured medium (recommended: raise the tier or split the change)
  ```
- **Raising after coding.** A raise while the change since the base is
  non-empty counts as a raise after coding, even before the first pre-final.
  The status then stays `exceeded` until the reviews the new tier needs have a
  passing latest attempt:
  - medium: `verify-review.md` `verdict: pass`. A human review
    (`reviewer_model: human`) also needs `verdict: pass` and a `pr:` line with
    a link or a number; a PR link alone is not a pass;
  - large: also `@gate` `sufficient_for_coding_model: yes`, and `@audit`
    `verdict: pass`.
- **No tier declared:** "no tier declared; measured: medium (6 files); run
  scripts/agent-guard.sh tier suggest", with status `none`. Never a failure in
  this release.
- **Stop hook:** it reads `tier.status` from the report.
  - On a size `exceeded` it warns, and only when the session changed files.
    Its message is for the user: the reasons, "decide before pushing: raise the
    tier or split the change", and the partial cause when there is one; never
    "run tier set". Claude Code shows a hook's message only when the hook prints it as
    `systemMessage` JSON on stdout, so its warnings (the tier, and an
    unverified run) go there.
  - When the only problem is reviews still missing after a raise, it warns
    and does not block: "the tier was raised after coding, so @verify should
    review it". Pre-final's own message also tells the agent not to write
    review files itself. The coding session must be able to end so that
    the reviewer can run. Pre-final and pre-push keep the warning until the
    reviews pass.
  - The Codex `@build` close-out prints the summary line.
- **Coding start** ignores changes made only of `*.md` and `*.mdx` files, so a
  design written before coding does not turn a later raise into a raise after
  coding.

### Rules the checks keep

These came from the second audit and the review of its fixes (2026-10-20).
Each rule has a table of cases in `scripts/test-change-tiers.sh`.

1. **Lowering.** A `tier set T` lowers the tier when `T` is below the higher
   of the declared tier and the current suggestion. This includes the first
   set and a checkpoint "keep". While any latest review is negative, a
   lowering needs `--reason`, warns, and the PR line says "lowered despite a
   negative @gate review". With no negative review, a tier below the
   suggestion also needs `--reason`.
   Example: declared small, the new scope suggests large, `@gate` says no:
   `tier set small --answer keep` asks for a reason; with one, it warns and
   the PR line shows it.

   A `--reason` covers only the suggestion it was given against: the
   suggestion in force at the `tier set` that gave it. Pre-final allows at
   most that tier. A later, higher suggestion is not allowed until the user
   confirms again, and pre-final warns until then. A later, lower suggestion
   does not take the allowance away.
   Example: suggested medium, `set small --reason hotfix`, then a new request
   suggests large: a large change gets the exceeded warning ("ask the
   user").
2. **A move keeps every path.** Pairing a plain `mv` with the file it moved
   counts the file once, but the entry keeps every path it had in the
   measured snapshots: the commits, the index and the working tree in
   pre-final, or the commits alone with `--committed`. The risk check reads
   all of them.
   Example: add `app/payment/new.ts`, stage it, `mv` it to `src/new.ts`: still
   large.

   A staged `git mv` (or a plain `mv` followed by `git add`) of a file the
   commits already have is the same move: git's rename from the commits to
   the index links the two paths, and the file counts once with the larger
   line count.
   Example: commit a new 40-line `a.ts`, then `git mv a.ts b.ts`: 1 file,
   40 lines.

   A plain `mv` with edits that is not staged yet is not paired (the content
   differs). It can count twice, so in a session it only warns; once staged
   or committed, git's rename detection pairs it.
3. **Review states.** Each review is absent, pending, negative or passed.
   - In one file, the latest attempt with a verdict decides: negative, or
     passed when it is also the newest attempt. A newer attempt with no
     verdict yet makes a pass pending; it does not cancel a negative.
   - The seat's own file decides once it has an attempt. The older file
     (`codex-review.md`, `claude-review.md`) counts while the own file is
     absent. A pending own file never borrows the older file's pass, and does
     not cancel its negative for lowering.
   - A human `@verify` needs a `pr:` link or number. At push (`--committed`)
     `pr: pending` also counts, because the PR needs the push; in a session
     it does not, so the link must be filled in after the push.
4. **Partial needs a cause.** A measure is partial only when git shows the
   full scope cannot be known, and the result names the cause. A partial
   measure still recommends: above the tier it is `exceeded`, and the
   warning and the next steps carry "(partial: <cause>)", because the count
   may be off. It never changes an exit code; nothing does. The
   causes:
   - no tier declared;
   - no shared history with the default branch (a shallow clone or unrelated
     history), or the base commit is not here: uncommitted changes only;
   - on the default branch, the start commit is no longer in its history
     after a rebase or reset;
   - on the default branch, commits from before the task were merged with
     pulled commits;
   - the `--base` ref is gone (for example a merged parent branch after
     `git fetch --prune`): measured since `tier set`;
   - a branch with `--base` took in default-branch commits that its base does
     not have (a merge of main while the parent is not merged);
   - the default branch is unknown (no `origin/HEAD`, `main` or `master`,
     for example a `dev` default after `git init`): measured since
     `tier set`, and the cause says that `git remote set-head origin --auto`
     sets it.

   With `--base`, the base is the newer of the merge-base with the `--base`
   ref and the merge-base with the default branch, when one holds the other.
   So once the parent is merged and the branch is rebased onto, or merged
   with, the default branch, only the branch's own work counts.

   A branch that does not start from the default branch (a forgotten
   `--base`, or a git-flow branch cut from `develop`) can get its base later:
   `tier set <tier> --task <id> --base <branch>` on any set changes it, and
   the history records it. While a review is negative it warns. The
   "already changed" note of the first set and the next step of an exceeded
   tier both name `--base`.

   For the two default-branch causes, the measure starts at the merge-base
   with the remote branch, so pulled commits are never counted. Any other git
   failure is an error ("tier check skipped"), not partial.
5. **A task follows its branch when the user says so.** A task started on
   the default branch is stale on any other branch, as before. When that
   branch's history holds the start commit, pre-final says how to move the
   task: run `tier set` on the branch. That set records the branch and says
   so; from then on it is measured like a feature branch.
   Example: `tier set small` on main, then `git switch -c feature/x`: stale,
   with the hint; `tier set small --task <id>` there moves the task.
   The same holds after `git branch -m`: when the task's branch ref is gone
   and the current branch holds the start commit.

## 4. Checkpoints: always ask, one key

| Tier | Checkpoint |
|---|---|
| large | the end of `@spec`'s output; the end of `@gate`'s output |
| medium | after `task.md` is written, before coding |
| small | none fixed. The new-request rule applies at every tier: a new request mid-task means `tier suggest` again before work goes on. |

The seat runs `tier suggest --task <id> --by @<seat>` with its own file list
and answers. It then ends its output with one question, even when nothing
changed:

```
Tier check (@spec): large (unchanged) - 5 planned files; app/auth/ is risky
Enter = keep large · m = medium · s = small · + = add scope
```

- In Claude Code the question uses the host's option list, with "keep" first.
- If the user named a tier in the request ("small: fix the Log out button"),
  the first checkpoint shows it and Enter accepts it. That counts as the first
  confirmation.
- A seat that cannot write (Codex with `--supervised`, `--read-only` or
  `--standard`; the default `full_flow` can write) prints the question and
  "not recorded". The next writable seat asks the same question first and
  records it with `--by @<seat>`. History keeps `printed_by` and `recorded_by`
  apart.
- **Add scope:**
  - from `@spec` or `task.md`: write a spec or task revision, then run
    `tier suggest` again;
  - at `@gate`: send it back to `@spec`, because `@gate` never rewrites the
    spec. If `@gate` already approved, the revised sections go back to
    `@gate`.
- **Lowering** (below the higher of the declared tier and the current
  suggestion; see "Rules the checks keep") needs `--reason`, warns and shows
  on the PR line while the latest attempt of any review file in the packet
  is negative:
  - `gate-review.md`: `sufficient_for_coding_model: no`;
  - `verify-review.md`: `verdict: changes_required | blocked`;
  - `audit-review.md`: `verdict: changes_required` (a new field);
  - in older packets, the two sections of `codex-review.md` (`@gate`,
    `@verify`) and `claude-review.md` (`@audit`).

  The script reads the files, never the recorded answers. This replaces "only
  seats that have not run can be dropped".
- **Raising** to the suggestion or above is always allowed (rule 1). After
  coding, §3 applies.

## 5. Contracts, docs and existing projects

### Contracts

- **Coding rule** (mode contracts "Gates and authority", and `coding.md`):
  a small or medium tier the user confirmed (in `tier.json` history) is the
  user's decision for the active seat to implement. The `@gate` rules apply
  to large only.
- **Transitions by tier:**
  - small: `analysis → implementation → resolution`;
  - medium: `analysis → implementation → verification → resolution`;
  - large: unchanged.
- **Review formats:**
  - medium reuses the `verify-review.md` format (`verdict: pass |
    changes_required | blocked`) and adds `same_vendor: yes|no`. For medium,
    `reviewer_model: human` with a PR link is allowed;
  - `audit-review.md` gains `verdict: pass | changes_required`.

### Docs

Every new text follows the plain-output rule: short, plain words, an example
instead of jargon.

| File | Change |
|---|---|
| `AGENTS.md` | The "Pick a tier" block and a read list grouped by tier |
| `tier-medium.md` (new generated doc, added to the inventory and the budget list) | A short `task.md` template that replaces the 12-heading list for medium; how to write `verify-review.md`; the medium checkpoint; a lower effort for medium `@verify`, e.g. `CODEX_REASONING_EFFORT=high .codex/codex-mode.sh @verify` |
| Mode contracts | The coding rule, transitions by tier, the checkpoint line, the lowering rule. Trim duplicates (§2) |
| Handoff schema | `tier.json` and its owner; minimal small state; `base_commit` equals `start_commit`; the audit verdict field |
| `context-policy.json` and its schema | The rule lists from §1 |
| Tech-stack contract and schema | Optional `risk_paths[]`. The onboarding guide tells the agent to fill it in `project-tech-stack.json` from the user's answer under "Protected / sensitive areas", so the question is asked once. `agent-onboarding.sh next` prints a hint when it is missing. There is no automatic prose parser |
| Seat commands and Codex launcher prompts | One line each: run the checkpoint, or read the tier |
| `README.md` | "Pick a tier for each change" with three examples (Log out button, Momo payment, "make the app faster"); the thresholds are a trial; tier records are local-only |

### Existing projects

- No data migration.
- `context-policy.json` is kit-owned and arrives with a normal update.
- The tech-stack contract is never rewritten. Without project `risk_paths`,
  only the kit defaults apply, and `agent-onboarding.sh next` suggests adding
  them.
- Existing packets without a tier get the "no tier declared" warning.
- The runtime verifier's exact-key checks (`require_exact_keys` in
  `lib/writers-runtime.sh`, around lines 1804 and 1963) must accept the new
  optional keys. Without this, an updated project fails the verifier even
  though its files match the schema.
- Schemas gain optional fields only, plus the new `harness-tier-v1`:
  - `agent-context-policy-v1`: the §1 lists;
  - `agent-project-tech-stack-v1`: `risk_paths`;
  - `agent-guard-verification-v2`: `tier`.

## 6. Build order: core first

Each phase ends with its tests green. Stop and ask the owner when a phase
cannot go green, or when the budget trim fails.

1. **Core.**
   - The matcher and rules evaluator.
   - `tier suggest`, `set`, `show --pr-line` and `close`, with `tier.json`,
     `ACTIVE` and the minimal state.
   - Measuring: base rule, stale, renames, exclusions, untracked, binary and
     submodules, `--relative`.
   - Pre-final wiring, report, event and exit order; the Stop hook.
   - The coding rule and transitions by tier.
   - The `AGENTS.md` block and the budget trim; README.
2. **Workflow.**
   - Checkpoints, including read-only seats.
   - The lowering rule from review files, and raising after coding.
   - `tier-medium.md` and the review formats.
   - Onboarding's project risk paths; budget reporting by tier.
3. **Release.**
   - The release-agnostic test fixes carried from PR #16.
   - `release.sh` also rewrites a renamed migration's MANIFEST description.
   - Change-tiers notes under `## Unreleased`, then
     `scripts/release.sh <YYYY.MM.DD.N> --title "..."`, plus removal of the
     README pre-release note.
   - The journal; this design moves to `specs/`; one commit.

## 7. Tests

New `scripts/test-change-tiers.sh` in the fast tier, table-driven:

**Rules and matching**
1. Glob table: root files (`Dockerfile`, `auth.ts`, `schema.sql`),
   `**/x/**`, case (`App/Auth/LoginView.swift`) and negatives (`author.ts`,
   `docs/oauth-notes.md`, `schema-docs.md`). `suggest` and pre-final give the
   same answer.
2. Token splitting: `useAuth.ts` and `AuthService.swift` are risky;
   `author.ts` is not; `latest.ts` is not a test file.
3. Counting:
   - a 3,000-line lock file plus `package.json` gives medium;
   - an `.aar` file or a submodule bump gives at least medium;
   - 40 edited lines count 40;
   - the excluded counts are printed.
4. Renames: a file moved out of `auth/` gives large. A pure move of a
   600-line file does not count 600 lines.

**State and base**

5. Work made before `tier set` is counted, and `tier set` lists it. A second
   `set` keeps `start_commit`. `set` on a closed id is refused.
6. On a feature branch, a merge or rebase of main adds no upstream files.
   `--base` cannot be the current branch.
7. A branch switch gives `stale` plus the measured tier, never `exceeded`. So
   does a closed task. An unreachable base warns.
8. No HEAD: `tier set` and pre-final work.
9. `suggest` without `--task`, or from a read-only seat, writes nothing.

**Pre-final and hooks**

10. Exit order, strict and advisory, with and without `--run-verify`:
    - the exit code is the verification's (0, 1, 2, 3, or 4 when nothing
      ran in strict mode); an exceeded tier never changes it;
    - `pre-final ok` only on 0.
11. The Stop hook warns on `tier.status: exceeded` only when the session
    changed files, and never blocks on the tier. Its message says "ask the
    user". The pre-push hook warns on committed work above the tier, ignores
    a closed or stale task, and skips a push that only deletes branches.
12. Below-suggested with a reason passes with a warning, and `--pr-line`
    shows the reason.

**Workflow**

13. Lowering after a negative `@gate`, `@verify` or `@audit` latest attempt
    needs a reason, warns and shows on the PR line. Raising after coding stays
    `exceeded` (a warning) until the added reviews pass. A human review
    (`reviewer_model: human`, a `pr:` line, `verdict: pass`) satisfies medium.
14. No tier: a warning with the measured tier, and status `none`.

Additions to existing suites:
- the budget test checks `tiers` (small within the core gate, large kit text
  ≤ 5,203);
- doc assertions check the `AGENTS.md` block, the coding rule and the
  lowering rule;
- CI registration and the shellcheck list, checked with shellcheck 0.9 and
  0.11.

## Acceptance

- On a fresh full target:
  - `tier suggest --paths app/settings/SettingsView.swift` says small;
  - `--paths app/payment/Momo.kt` says large and names the risk;
  - `--paths src/author.ts` says small;
  - no paths says medium, with the reason "files unknown".
- On a feature branch, with a small task:
  - 2 files committed before `tier set` (counted, and listed at set);
  - then 3 files across 2 commits;
  - then 3 untracked files.

  Pre-final gives the exceeded warning and exits 0. With one failing
  verification command, it gives 1.
- After a merge of main into that branch, the measured counts are unchanged.
- The budget report shows `tiers`, and the large kit text is ≤ 5,203 tokens.

## Out of scope

- B, C and D above.
- `tier stats`: the history it needs is recorded from day one.
- Evidence checks on `tier close`.
- A special rule for docs-only changes.
- Scoring from git history; per-host budgets; a separate medium budget gate.

## Risks

- **Kit complexity grows**, roughly +500–700 lines in `agent-guard.sh`. The
  core-first order and table tests contain it.
- **The thresholds are guesses.** README calls them a trial, and the history
  allows tuning later.
- **Always asking can turn into rubber-stamping.** The real safety net is the
  real-diff check.
- **This catches mistakes, not intent.** A missing tier only warns, and
  non-Claude hosts can skip pre-final. Say so; do not call it enforcement.
- **Budget:** the large tier has 29 tokens of headroom and needs a cut of
  about 200–250 tokens. If the cut fails, stop and ask.
- **Local-only records:** risk paths and reasons stay per laptop until D.
- **The release rides with this work,** so a delay here delays shipping PR
  #15's work.
- **Warnings only:** tiers protect only as far as people read the
  warnings. The PR line carries the result to the reviewer, and the Stop
  hook shows it to the user.

## Council record (2026-10-19)

The council had three seats (architecture and enforcement; small-team
usability; adversary and test lead) and ran two rounds. All three ended at
"approve with changes". It cost about 0.72M subagent tokens.

Blockers fixed in this revision:
- the risk globs could not be matched by the existing matcher;
- the diff was not tied to a branch or task (a false exit 5 after a merge);
- no seat could code at small or medium under the current contracts.

Majors fixed:
- exit 5 is now wired to the Stop hook and survives `set -e`;
- the agent can no longer raise or lower a tier to escape review;
- counts no longer punish tests, lock files or renames;
- one `ACTIVE` pointer, and a script-owned `tier.json`;
- `--data` is narrower;
- the medium review is cheaper;
- "always ask" costs one key;
- a PR line.

Chair choices where the seats disagreed:
- count work made before `tier set`, and list it at set;
- a stale or unreachable base warns rather than exiting 2.

## Independent review (2026-10-19)

A single independent reviewer checked the revised design and the plan against
the code. Its verdict was "rework" of the plan steps; the design model held.
All nine of its main findings were verified and taken:

- the runtime verifier's exact-key checks;
- the evaluator must not read JSON from stdin under a heredoc;
- `close` also closes `state.json`, and clears `ACTIVE` only for its own task;
- "coding started" means the first non-empty change, not the first pre-final;
- a human review still needs `verdict: pass`;
- the measure fallbacks, and the split of `default_ref` from `default_name`;
- `--lines` means counted lines;
- the test fixture needs a tracked file and stays off the canonical list;
- the onboarding hint is text only, with no prose parser;
- the budget is measured with a fixed project name.
