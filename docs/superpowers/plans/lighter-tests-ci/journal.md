# Lighter tests, CI and generated scripts — journal

Spec: `docs/superpowers/specs/2026-11-04-lighter-tests-ci-design.md`.
Branch `feature/lighter-tests-ci`, from main `00aeab2` (release 2026.11.04.1).
Three plans, one commit at the end with the release bump.

## 2026-11-04 — why and what the owner chose

The owner found tests and CI too heavy and asked for a review of the
generated `.sh` files. Measured on 2026-11-04:

- **CI:** macOS 76 min and Ubuntu 35 min. The drift test took 75% of each job
  and reran 15 other suites at its end. The same tree ran three times per
  release (PR, push to main, tag).
- **Local:** fast tier 23 min, drift test 37 min, a full check about 73 min.
- **Claude hook,** before every Bash/Edit/Write call:
  - Bash: 75 `python3` and 16 `git` starts, about 4 s;
  - Edit: 89 and 24, about 3 s;
  - 54 of the Edit call's `python3` starts were `json_escape`.

**Owner decisions:**

- Do all three phases in this branch; the push to main or tag skips what
  already passed.
- Hook: merge the python calls, keep the bash structure.
- Small cleanups only.
- Python first; a Rust packet comes later, after real-project measurements.

**Seat work moves to its own branch after this one.** The owner later raised
three seat topics:

- @gate should plan instead of bouncing technical findings to @spec;
- modes give way to seat commands;
- seats should be arranged per packet.

They were designed (local draft `docs/superpowers/plans/seat-first-roles/design.md`)
and moved to a later branch. Part H is not yet approved.

## Plan 1 — drift test split and one runner

- **Drift test groups.** The drift test has six groups (`--group`,
  `--list-groups`): focus, install, inventory, contracts, prefinal, lifecycle.
  - Idempotent setup helpers prepare the home install, the smoke target, the
    guard target and the root-wrapper target.
  - Template probes run on a copy, and a `git status` guard proves the source
    tree is untouched.
  - The 15 tail reruns are gone.
  - Inventory was split into inventory and contracts: it took more than 1.5×
    the median of the other groups.
- **The focus group runs again.** Its four rc=1 expectations dated from before
  `796e12d`, which made the hook turn guard errors into exit 2. They now
  expect 2, and they check the guard's error text.
- **`scripts/test.sh`** holds one table (name, tier, CI group, mode, command)
  and runs the parallel rows through `xargs -P`, with serial rows after them.
  `test-fast.sh` is a wrapper. Two CI-only steps became scripts:
  `test-historical-fixtures.sh` and `test-seats-no-path.sh`.
- **Bug found by running the groups in parallel: `printf … | grep -q` under
  `pipefail`.**
  - With 8 parallel loops, about 20% of runs failed: `PIPESTATUS [141 0]`
    while the output was complete.
  - The verifier's no-scan check, the Codex doctor, `agent-local-only-check`,
    three migrations and `need_not_contains` in the tests were affected
    (`need_not_contains` passed wrongly).
  - Fixed with here-strings or process substitution at about 40 sites.
    `test-pipe-safety.sh` flags 50 sites on main and none now.
- **Bug found by the parallel harness: SIGINT ignored under `&`.**
  - Background jobs ignore SIGINT and children inherit it, so seats W10 hung.
  - The seats `pty_run` resets SIGINT for the wizard, and `scripts/test.sh`
    restarts itself through python when it inherits an ignored SIGINT.
  - A first fix (resending SIGINT) did not help and was reverted.
- **Mutations:**
  - template filter: caught;
  - source-tree write: caught;
  - runner: stdin, `-P 1`, serial first, summary rc and the SIGINT reset: all
    caught. The stdin one needed a serial stdin row, because `xargs` already
    gives batch rows `/dev/null`.
- **Result,** with -j 4 on an idle Mac:
  - fast tier 22/22 in 505 s (was 1,404 s sequential);
  - full tier 32/32 in 911 s (was about 73 min).

## Plan 2 — one source for runtime scripts, light hook

- **E2.** The writers copy the bundle's `agent-hook.sh`, `verify-ai-deps.sh`,
  `detect-agent-tech-stack.sh` and `agent-tech-stack-lib.sh`. The hook and the
  verifier go through `copy_bundle_preset_file`: their `WORKFLOW_PRESET="full"`
  line becomes the placeholder that `write_file` fills.
  - 2,919 heredoc lines and `sync-runtime-snapshots.sh` are gone.
  - **Proof:** `full` and `infra` targets generated before and after are
    byte-identical, after normalising the lock stamps and the
    `project-agent-context.md` stamp.
  - The baseline was taken after Plan 1, which had changed the verifier.
  - `release.sh --check` no longer generates a target, so the release-script
    suite went from about 80 s to 2 s.
- **A.** The hook path changed in five ways:
  - `POLICY_SNAPSHOT_PY`, one `python3 -I -S` run, loads the policy and the
    tech-stack contract, checks required context, canonicalises the edit
    path, and rewrites the context pack only when its content changed. Its
    packs are byte-identical to the old ones except `generated_at`.
  - `json_escape` is pure bash: 0 mismatches against `json.dumps` in 39 values
    on bash 3.2.
  - `identity()` is cached.
  - `pre-edit --workspace-checked` skips the nested advisory check.
  - The hook parses its input in one python run. A Bash call makes one
    workspace check. Edit calls go through `pre-edit`, which refreshes the
    pack. Session start runs preflight once.
- **Result per hook call:**

  | Call | python3 | git | Wall time (warm) |
  |---|---|---|---|
  | Bash | 2 | 2 | about 0.09 s |
  | Edit | 3 | 2 | about 0.16 s |

  `scripts/test-hook-hot-path.sh` holds the budgets.
- **Mutations:** json_escape tab, `-I -S`, pack rewrite, hook preflight: all
  caught.
- **Full tier:** 33/33 in 755 s. No suite needed its assertions changed.

## Plan 3 — CI, guard-local-state, docs

- **`guard-local-state`:** one `git ls-files` for every pattern (2 git starts,
  was 52). It names the pattern on a hit, as before. Mutation caught.
- **`scripts/ci-gate.sh`:** `full=false` only for a push whose tree a
  successful run of `test.yml` in this repository recorded in an unexpired
  `tested-tree-<tree>` artifact. `test-ci-gate.sh` covers 10 cases with a stub
  API; three mutations were caught.
- **Workflow:** `gate`, `lint` (Linux), `tests` (os × ci-1..ci-4) and `record`.
  The tags campaign runs on Linux; the tagless fixtures run on macOS
  (`ONE_SHOT_HISTORICAL_CAMPAIGN=skip` there).
  `scripts/test.sh --check-ci` keeps the matrix equal to the table's groups.
- **Lint rows:** release pins, pipe safety, shellcheck (the old list plus the
  new scripts, with `CI=true` required), CI groups and the gate test.

- **First PR run (#20, run 41837842585).**

  | Job | Time |
  |---|---|
  | gate | 4 s |
  | lint | 35 s |
  | Ubuntu ci-1..ci-4 | 282, 274, 184, 250 s |
  | macOS ci-1..ci-3 | 497, 645, 566 s |

  The longest job took about 11 min (macOS 76 min before).
- **macOS ci-4 failed.** The macOS branch first set
  `HARNESS_MIGRATION_HISTORICAL_SOURCE=skip`, and `test-agent-retirement.py`
  also reads that variable, with fixed choices (`auto|tags|fixtures`). The
  skip now has its own variable, `ONE_SHOT_HISTORICAL_CAMPAIGN=skip`, read
  only by `test-one-shot-upgrade.sh`.

## Deviations from the design

- **Six drift groups, not five** (inventory split, measured).
- **Dropped: the doctor runs the verifier once.** A re-measure gave about
  0.5 s, not 7.4 s CPU.
- **The E2 proof** compares against the tree after Plan 1, not main.
- **Two bugs fixed outside the planned scope** (owner approved the first): the
  SIGPIPE + `pipefail` checks in kit and tests, and SIGINT ignored under `&`.

## Follow-ups

- **Rust hot-path packet**, after this release is measured on real projects.
  Today a hook call costs about 0.1–0.2 s.
- **`python3 -I -S` for the rest of the kit's python**, outside the guard and
  the hook.
- **The seat-first branch:** @gate writes the plan, seat commands replace the
  modes, and per-packet seats (Part H awaits approval).
