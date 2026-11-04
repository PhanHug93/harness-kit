# Lighter tests, CI and generated scripts

Branch `feature/lighter-tests-ci`, from main `00aeab2` (release 2026.11.04.1).
Packet `.agents/tasks/lighter-tests-ci-2026-11-04` (findings, options and
evidence). One commit at the end, with the release bump.

Status: implemented in Plans 1–3 for release 2026.11.04.2. The results and the
deviations are in `docs/superpowers/plans/lighter-tests-ci/journal.md`.

## Why (measured 2026-11-04)

- **CI is long.** The macOS job takes 76 minutes and the Ubuntu job 35. The
  drift test is 75% of each job, and its 15 steps run one after another.
- **CI repeats work.**
  - The retirement suite runs twice.
  - Three steps generate the same `full` target.
  - The full historical migration campaign runs twice, once from tags and once
    from fixtures, over the same refs.
  - Each release tests the same tree three times: on the PR, on the push to
    main, and on the tag push.
- **Local checks are slow and duplicated.**
  - The fast tier runs its 20 suites one at a time (1,404 s).
  - The drift test (2,213 s) reruns 15 suites at its end (lines 4270-4307),
    so running both repeats about 1,264 s.
  - The drift test cannot run in parallel: it writes probe files into the
    source tree (lines 2222-2226).
- **The hook costs seconds on every tool call.** `claude-pretool` runs before
  every Claude Code Bash, Edit, Write and MultiEdit call. One Edit call starts
  88 `python3` and 12 `git` processes (about 2.7 s CPU). One Bash call starts
  74 and 8 (about 2.2 s). Of those, `json_escape` alone is 53–54 `python3`
  starts per call.
- **Duplicated kit sources.** Four runtime scripts exist twice in the kit, as a
  heredoc in a writer and as a committed snapshot: `agent-hook.sh`,
  `verify-ai-deps.sh`, `detect-agent-tech-stack.sh` and
  `agent-tech-stack-lib.sh` (about 2,900 lines). They are kept equal by
  `scripts/sync-runtime-snapshots.sh`.

## Owner decisions (2026-11-04)

- All three phases ship in this branch, as one commit.
- **CI.** The push to main and the tag push skip the heavy jobs when the same
  tree has already passed CI.
- **Hook.** Merge the `python3` calls but keep the bash structure. Commands,
  messages and exit codes stay the same.
- **Shared helpers.** Small cleanups only; no new shared runtime library.
- **Rust.** Not in this branch. A later packet may port the hot path to Rust
  after this release has been measured on real projects.

## Goals

| Measure | Now | Target |
|---|---|---|
| Hook, Edit call | 88 python3, 12 git | ≤ 6 python3, ≤ 6 git |
| Hook, Bash call | 74 python3, 8 git | ≤ 2 python3, ≤ 3 git |
| CI, pull request (wall time) | 76 min | about 15–20 min |
| CI, main or tag push of a tree already green | 76 min | about 1–2 min |
| Local fast tier, idle machine | 23 min | about 7–8 min |
| Local full check, idle machine | about 73 min | about 20–25 min |

Coverage stays the same: every behaviour tested today is still tested,
once per OS where the OS matters.

## Non-goals

- Tier logic (`agent-tier.py`, `tier_evaluate`): unchanged.
- A shared helper library for generated scripts (S3 full).
- Reusing a "golden" target instead of generating a fresh one (option D2).
  It could hide first-install bugs.
- The deliberate names `GEMINI.md`, `.windsurfrules`, Cursor and Windsurf in
  local-only, exclude and mobile-pointer lists: they stay (finding F4).
- Rust.
- Seat roles and modes (@gate writing the plan, removing `/planning`,
  `/coding` and `/reviewing`, per-packet seats). The owner moved them to a
  follow-up branch after this one: `docs/superpowers/plans/seat-first-roles/design.md` (local draft).
- `-I -S` for kit Python outside the hook path. It is a follow-up, recorded in
  the packet.

## Part A — hook hot path

### A1. One Python process for policy, required context and the pack

`agent-guard.sh` gets one internal helper, `policy_snapshot`, that runs
`python3 -I -S` once. It replaces these separate Python starts:

- `policy_schema_value`
- the four `policy_values` calls
- the two `project_contract_values` calls
- the per-path `canonical_project_abspath` and `canonical_project_relpath`
  calls for required context
- every `json_escape`, `hash_file` and `hash_text` used to build the pack

**Inputs:**

- the project root;
- the policy and tech-stack file paths;
- a mode: `load`, or `pack` (load and refresh the pack);
- for `pack` mode, the pack path and the detector summary (an environment
  variable; bash runs the detector);
- optionally, one edit path to canonicalise.

**Output:** fixed records of three NUL-terminated fields, `kind`, `a`, `b`.

| `kind` | `a` | `b` |
|---|---|---|
| `required` | path | `present` or `missing` |
| `recommended` | path | (empty) |
| `protected` | pattern | reason |
| `instruction` | text | (empty) |
| `relpath` | canonical edit path | (empty) |
| `pack` | `written`, `unchanged` or `skipped` | (empty) |
| `error` | message | (empty) |

Bash fills the existing arrays from these records. The order is the same as
today: policy protected paths, then tech-stack protected paths, then
tech-stack generated files.

**Behaviour stays the same:**

- **Validation.** Every check in `validate_policy_path` and
  `is_safe_relative_path` keeps its exact `fail` text. The helper returns the
  failure as an `error` record, and bash passes that text to `fail`.
- **No python3.** When `python3` is missing, the current bash fallback still
  runs (defaults and the `sed` schema read).
- **Canonical paths.** The helper resolves symlinks inside the root and
  rejects paths outside it, matching `canonical_project_abspath`. A shared
  case table in the new test pins the edge cases: symlink inside the root,
  symlink out of the root, `..`, and a missing file.
- **Pack content.** The pack keeps the same keys in the same order:
  `schema`, `generated_at`, `policy_path`, `policy_sha256`,
  `agent_instructions_sha256`, `required_context`, `protected_paths`,
  `detector_summary`. It stays compact JSON with non-ASCII characters
  unescaped.
- **Pack writes.** The pack is written atomically (temporary file, then
  rename) only when it is missing, unreadable or different apart from
  `generated_at`. When nothing changed, the file and its `generated_at` stay
  as they are. No consumer reads `generated_at`, and freshness is checked by
  content (`check_context_pack_freshness`).
- **Read-only state directory.** It still means advisory-only: no pack, and
  the same warning.

### A2. Bash calls: workspace check only

For a Bash call, `claude_pretool` does three things:

1. Anchor the session and parse the input, in one Python process (A5).
2. Run one `workspace-check`.
3. Ask the user when the workspace check reports a repository mismatch.

It no longer runs `preflight` or `verify_detector_lock warn`. Neither one
could block a Bash call: Claude Code blocks only on exit 2, and these exited
with 1 or warned. Policy problems and detector drift still show up in other
places:

- an Edit call is blocked (A3);
- `pre-final` checks detector drift strictly;
- the Codex preflight runs `verify_detector_lock`;
- the session start refreshes the pack (A4).

### A3. Edit calls: one guard call

For an Edit, Write or MultiEdit call, the hook makes one guard call:
`pre-edit --strict --use-ack-log [--ack TEXT] --workspace-checked PATH`.

- **Pack refresh.** `pre-edit` now refreshes the pack (A1 `pack` mode) when
  the state directory is writable. It keeps everything the old `preflight`
  call guaranteed:
  - a missing policy or missing required context exits non-zero, and the hook
    turns that into exit 2, as today;
  - the pack is current after the call.
- **`--workspace-checked`.** This new `pre-edit` option skips the nested
  `workspace_check quiet`, because the hook already ran the workspace check.
  That nested check is advisory: its result never changes an exit code. An
  agent that passes the option itself gains nothing.
- **Edit path.** The edit path goes through the same `policy_snapshot` call as
  a `relpath` record, so it costs no extra Python start.
- **Ask on mismatch.** It is unchanged: the hook asks after the guard allows
  the edit.

### A4. Session start refreshes the pack

`claude-session-start` runs `agent-guard.sh preflight >/dev/null 2>&1 || true`
once. Bash calls no longer refresh the pack, so this keeps it fresh for a
session that never edits.

Edge case, accepted: an agent changes a required-context file through Bash
and then runs `pre-final` without any Edit call in between. `pre-final`
reports `stale required context: <path>` and tells the agent to rerun
`preflight`, which is the right outcome.

### A5. Fewer Python starts in the hook and the workspace check

- **Hook.** `claude_anchor_env` and `parse_claude_hook_input` become one
  `python3 -I -S` call. The output stays NUL-separated:
  1. minted flag
  2. session id
  3. workspace context
  4. tool name
  5. file path

  The `workspace_ask_reason` parse and `claude_ask` still run only on a
  mismatch.
- **Workspace check.** `workspace_check` caches `identity()` by resolved path
  within its process, so the four lookups of the project root and the current
  directory reach `git` once per distinct path. Nothing is passed through the
  environment.

### A6. Pure-bash `json_escape`

`json_escape` in `agent-guard.sh` drops its `python3` branch and becomes pure
bash. It produces the same output as `json.dumps(value, ensure_ascii=False)`
with the surrounding quotes removed, for valid UTF-8 input:

- `\` becomes `\\` and `"` becomes `\"`;
- `\b \f \n \r \t` use their short forms;
- every other character from U+0001 to U+001F becomes `\u00XX` (lowercase
  hex, as `json.dumps` writes it);
- everything else passes through unchanged, including DEL and non-ASCII.

The slower control-character pass runs only when the value contains one.
Invalid UTF-8 passes through byte for byte; this difference from Python is
documented. Bash strings cannot hold NUL.

### A7. `python3 -I -S` in the hook path

Every stdlib-only `python3` call in `agent-guard.sh` and `agent-hook.sh` runs
as `python3 -I -S`. (The plan greps the imports to confirm they are all
stdlib.) `-I` keeps the script directory and the current directory out of
`sys.path` and ignores `PYTHON*` variables. Today a `json.py` at a project's
root is imported by every guard call that runs `python3 - <<'PY'` there.
`agent-tier.py` keeps its current invocation; tiers are out of scope.

### A8. Tests

New suite `scripts/test-hook-hot-path.sh`, in the fast tier. It works on one
fresh `full` target.

- **Process budget.** `PATH` shims count `python3` and `git` starts for
  - an Edit of an unprotected path,
  - an Edit of a protected path (ack log), and
  - a Bash call.

  It fails above the caps in Goals, or above the measured value plus one when
  that is lower. It also checks each case's exit code and stdout/stderr
  classification.
- **`json_escape` parity.** It compares the bash `json_escape` with
  `json.dumps` over U+0001–U+001F, quotes, backslashes, mixed text and
  multi-byte UTF-8.
- **Planted `json.py`.** A target root with a `json.py` that writes a marker
  file. After `preflight`, an Edit hook call and a Bash hook call, the marker
  must not exist.
- **Pack rewrite.** Two `preflight` runs keep the same inode and the same
  `generated_at`. A change to required context rewrites the pack, and
  `check` passes afterwards.
- **Canonical paths.** The case table from A1.

Existing guard and hook suites must pass unchanged. Where one asserts output
of the removed Bash-path preflight, the plan updates that assertion and says
why.

## Part B — CI (`.github/workflows/test.yml`)

The workflow is renamed `tests`. Its triggers and concurrency stay the same.
The header comment changes to describe the tree gate. No branch protection or
ruleset refers to job names (checked 2026-11-04), so they can change.

| Job | Runs on | When | Does |
|---|---|---|---|
| `gate` | ubuntu | always | Prints `full=true` or `full=false`; on a tag, runs `release.sh --check-tag` |
| `lint` | ubuntu | always | `bash scripts/test.sh --group lint` |
| `tests` | matrix: os × group | `full == 'true'` | `bash scripts/test.sh --full --group <group>` |
| `record` | ubuntu | `full == 'true'` and every job passed | Uploads artifact `tested-tree-<tree sha>` (30 days) |

### B1. Gate rule (`scripts/ci-gate.sh`)

- A `pull_request` or `workflow_dispatch` run is always `full=true`.
- A push to main or a `v*` tag:
  1. `T = git rev-parse HEAD^{tree}`.
  2. Look up the artifacts named `tested-tree-T` (`gh api`, token permission
     `actions: read`).
  3. For each one that has not expired, fetch its run.
  4. If the run's workflow path is `.github/workflows/test.yml`, its
     repository is this repository, and its conclusion is `success`, print
     `full=false`.
  5. Otherwise print `full=true`.
- Any API or parse error prints `full=true` with a note. When in doubt, run
  the tests.

**Why the artifact.** A pull-request run tests the merge commit, not the PR
head. The `record` job records the tree it actually tested, and the gate
compares trees, not commit SHAs: a rebase merge always creates new SHAs.

**Why it is safe.** The tree includes `.github/workflows/test.yml`. So a
matching run used the same workflow definition that main has now. A fork
cannot plant a match for a tree that does not exist on main.

### B2. What each group runs

- **`lint`, Ubuntu only:**
  - `release.sh --check`;
  - shellcheck on the kit file list (today's list plus the new scripts);
  - one generated `full` target, used for both the shellcheck pass and the
    verifier run (`verify-ai-deps.sh` and `--json`).

  This replaces two of the three generations of the same target. The
  `syntax` row (`bash -n`) is not in `lint`: it sits in a matrix group, so
  bash 3.2 on macOS parses every script too.
- **Matrix groups, about five, each on both OSes.** The plan builds them from
  measured macOS durations. The longest macOS group should take about 15
  minutes or less. (The free plan runs up to 5 macOS jobs at once.)
- **Single runs.**
  - The retirement suite runs once, from the table.
  - The full historical migration campaign runs once per OS: from tags on
    Ubuntu, from the tagless fixtures (today's separate step) on macOS. The
    other parts of `test-one-shot-upgrade.sh` run on both. The fixtures are
    pinned by sha256 to the tag contents, so each source is still covered.
- **Both OSes stay.**
  - Seats and launcher with no `PATH`: `/bin/bash` is 3.2 on macOS and 5 on
    Ubuntu.
  - The whole macOS matrix: it is the only coverage of bash 3.2 and the BSD
    tools.

### B3. Tests

New suite `scripts/test-ci-gate.sh`, in the fast tier. It runs `ci-gate.sh`
against a stub API command (`CI_GATE_API`) with fake responses for these
cases:

- a match;
- an expired artifact;
- a run from another workflow;
- a failed run;
- no artifact;
- an API error;
- a pull request;
- `workflow_dispatch`.

A check in `test.sh --check-ci` fails when the matrix group list in
`test.yml` differs from the set of groups in the runner table. That way no
suite can be dropped from CI without notice.

## Part C — local runner `scripts/test.sh`

One table lists every suite. Each row has a name, a tier (`fast` or `full`),
a CI group, a `serial` flag and a command.

- **Fast tier:** the 20 current checks plus `hook-hot-path` and `ci-gate`.
- **Full tier adds:**
  - the five drift groups (Part D);
  - `test-upgrade-merge.sh`;
  - `test-one-shot-upgrade.sh`;
  - the tagless fixture campaign;
  - seats with no `PATH`;
  - the lint group's shellcheck and verifier rows.

**Command-line options:**

```text
bash scripts/test.sh                  # fast tier, parallel
bash scripts/test.sh --full           # every row
bash scripts/test.sh --group G        # rows in group G (CI); repeatable
bash scripts/test.sh --only NAME      # repeatable
bash scripts/test.sh -j N             # default: min(4, CPU count); -j 1 = sequential
bash scripts/test.sh --list | --check-ci
```

**Running:**

- The parallel rows run through `xargs -P`, which works on bash 3.2 and with
  both BSD and GNU `xargs`.
- Each row gets `</dev/null` as stdin, its own log, and a `PASS`/`FAIL` line
  with its time. A failed row also shows the last lines of its log.
- The `serial` rows (`guard-race`, and any row the plan finds unsafe in
  parallel) run alone, after the parallel batch.
- The exit code and the final summary work as `test-fast.sh` does today.

**Fast-tier additions.** `runner` (the self-test) and `pipe-safety` (D3).

**Lint without shellcheck.** If shellcheck is missing, the shellcheck row is
skipped with a note locally and fails when `CI=true`.

**`test-fast.sh`** becomes a two-line wrapper: `exec bash scripts/test.sh "$@"`.

## Part D — drift test split

### D1. No writes into the source tree

The `.bak.test-$$` and `.generated.test-$$` probes move into a copy of the
two template trees under the test's campaign directory. They still prove that
the mirror checks ignore such files. The plan also searches the test for any
other write under `$ROOT_DIR` or `$BOOTSTRAP_BUNDLE` and moves those writes
too.

At exit, the test compares `git -C "$ROOT_DIR" status --porcelain
--untracked-files=all` with the snapshot it took at start, and fails if the
two differ.

### D2. Groups

There are six groups, not five: inventory took more than 1.5× the median of
the other groups (447 s against 213 s in one all-groups run on 2026-11-04), so
it was split at the mirror checks into `inventory` and `contracts`.

`test-bootstrap-multi-agent-project.sh` gains `--group NAME` (repeatable) and
`--list-groups`. With no `--group`, it runs every group in order, without the
end-of-file reruns.

| Group | Covers |
|---|---|
| `focus` | Guard and hook regressions (`run_guard_hook_focus`), revived |
| `install` | Home install and rtk leftovers, git-driven update, native-verification detector fixtures, linked-ancestor and core-boundary checks |
| `inventory` | CI and doc wording checks, bundle inventory cross-check, smoke target, Cowork, root wrapper, user-owned files |
| `contracts` | Template/runtime mirrors, agent docs and tool contracts, mobile skill, Codex modes, detector summaries, guard regressions, status and stats |
| `prefinal` | Journal-independent pre-final, verification runner and telemetry, stack drift and read-only guard |
| `lifecycle` | Overlay, cleanup, stale version, candidates, legacy-profile-to-seats migration, seats runtime and launcher on the migrated target |

The plan maps every top-level block of the file to exactly one group, so
nothing is dropped.

**Setup.** Shared helpers stay at the top of the file. Each group calls the
setup helpers it needs, for example `setup_canonical_home` and
`setup_main_target`. These helpers are idempotent within one process, so a
run of all groups prepares each thing once.

**Removed:**

- the 15 reruns at the end. Those suites run from the runner table;
  `test-upgrade-merge.sh` becomes its own row;
- the flags `BOOTSTRAP_GUARD_FOCUS_ONLY` and `P2_NATIVE_ONLY`. They are
  replaced by `--group`, and the docs that mention them are updated.

**The focus group.** It fails today when run on its own: "invalid TTL guard
error expected rc=1 actual rc=2". The plan debugs it first and decides, with
evidence, whether the test expectation or the guard is wrong, then fixes that
side.

### D3. Bugs that parallel runs exposed (fixed in this branch)

**`producer | grep -q` under `pipefail`.**

- **The failure.** `grep -q` exits on the first match and the producer gets
  SIGPIPE (141), so `pipefail` turns a match into a miss. It happens only on a
  busy machine.
- **Where it hit.** The verifier's no-scan check (and the same check in the
  Codex doctor) failed in about 20% of runs with 8 parallel loops, giving
  "no-scan guard paths are incomplete". `need_not_contains` in the tests
  passed wrongly.
- **The fix.** Here-strings or process substitution at every site in kit and
  test scripts: about 40 sites in 13 files, including three migrations and
  `agent-local-only-check.sh`.
- **The guard.** `scripts/test-pipe-safety.sh`, a fast-tier row. It flags any
  pipe into `grep -q` or `printf … | head`, and finds 50 sites on main.

**SIGINT ignored under `&`.**

- **The failure.** A shell job started with `&` ignores SIGINT, children
  inherit that, and the Ctrl-C checks hang: seats W10, retirement R9, and the
  Codex SIGINT check in verification-evidence.
- **The fix.**
  - The seats `pty_run` starts the wizard with SIGINT at the default.
  - `scripts/test.sh` restarts itself once through python when it inherits
    an ignored SIGINT.
  - A self-test case covers the runner.

## Part E — generated-script cleanup

### E1. `guard-local-state`: one `git ls-files`

`guard_local_state` (`agent-hook.sh`) asks `git ls-files` once for all
local-only paths, instead of one `is_tracked` per path (about 52 `git`
calls). It runs at every Codex launch. Its messages stay the same. When `git`
is unavailable, it keeps today's behaviour.

### E2. One source for the four runtime scripts

The bundle files become the source:

- `agent-bootstrap/agent-hook.sh`
- `agent-bootstrap/verify-ai-deps.sh`
- `agent-bootstrap/detect-agent-tech-stack.sh`
- `agent-bootstrap/agent-tech-stack-lib.sh`

Changes:

- **Writers.** They copy the bundle file. For the hook and the verifier, they
  then rewrite the single `WORKFLOW_PRESET="full"` line for the preset. The
  bundle file keeps `full`, so a `full` output is the file unchanged.
- **Tech-stack lib.** `emit_tech_stack_lib` (`lib/detect.sh`) prints the
  bundle file, and the generator still uses it during detection.
- **Removed:**
  - the four heredocs;
  - `scripts/sync-runtime-snapshots.sh`, together with its mentions in
    CONTRIBUTING, MANIFEST and the drift test.
- **Snapshot comparison.** The drift test's comparisons become one check
  that the generated file equals the bundle file after the preset line.
- **Home installer.** Its copy list is unchanged.
- **Proof.** Before the change, generate `full` and `infra` targets into a
  saved directory. After it, generate them again. The trees must be
  byte-identical, excluding the volatile lock fields (`generated_at`,
  `apply_state`). The comparison script and its result go to the packet
  evidence.

### E3. Small cleanups

- Fix the stale comment at `lib/writers-runtime.sh:1031`.
- After A2, the hook has no Bash-path detector check left. Its remaining
  detector check is the strict one in `codex_preflight`.
- Any `json_escape` copy in the hook path that A6 makes unused is removed.

### Dropped after re-measuring: doctor runs the verifier once

The analysis estimated that `codex-mode.sh doctor` spends about 7.4 s CPU in
two extra verifier calls. A re-measure on a fresh `full` target (2026-11-04,
load average 35–97) gave smaller numbers:

| Call | Wall time |
|---|---|
| `verify-ai-deps.sh --json --context-budget` | 0.45 s |
| `verify-ai-deps.sh --agentmemory` | 0.54 s |
| The whole doctor | 4.9 s |

Merging the two calls would need a new combined CLI mode on the verifier, to
save about 0.5 s in a command people run by hand. It is out of this branch.

## Part F — docs, release, follow-ups

- **CONTRIBUTING:**
  - the new runner (`test.sh`, tiers, groups, `-j`);
  - the CI jobs and the tree gate;
  - the drift test `--group`;
  - removal of the snapshot sync step.
- **MANIFEST:** removal of `sync-runtime-snapshots.sh` and the new scripts.
- **CHANGELOG:** the new release entry.
- **Migration:** none. The hook, the guard and the verifier are kit-managed
  files that update replaces. No user-owned file changes.
- **Release:** `scripts/release.sh` at the end of this branch, in the one
  commit.
- **Packet follow-ups:**
  - the Rust hot-path packet, after the release has been measured on real
    projects;
  - `-I -S` for the remaining kit Python;
  - the doctor merge, if it is ever worth doing.

## Order of work

1. **D1 and D2.** Making the drift test shard-safe first speeds up every later
   check.
2. **E2.** Generate the baseline `full` and `infra` targets from the untouched
   writers first, so the byte-identity proof compares against main. After E2,
   Part A edits one source per script instead of a heredoc and a snapshot.
3. **A,** then **C,** then **B.**
4. **E1 and E3,** then **F.**
5. **Verification:**
   - `bash scripts/test.sh --full -j 4` passes locally;
   - one PR CI run is green and its macOS times are recorded;
   - the process budgets are recorded.

## Risks

| Risk | Mitigation |
|---|---|
| `policy_snapshot` canonicalises a path differently from bash | Case table (A8); the existing path-policy and guard suites |
| A suite is not parallel-safe | Run the whole table with `-j`; mark any offender `serial` |
| A drift group needs state from an earlier group | Setup helpers are explicit and idempotent; each group also runs alone in CI |
| The gate skips a tree that was never tested | Only an artifact from `record`, which needs every job green; errors run in full |
| The Bash path no longer prints preflight problems | It could not block anyway; Edit blocks, and `pre-final` and the Codex preflight check |
