# Council record — packet `agent-seats`, after `@gate` attempt 2

Convened by `@spec` (Claude) on the user's request: heavy council, two rounds,
three senior seats, then synthesis with the `@gate` verdict and a thorough fix.
Seats were fresh-context subagents with tool access, working on a read-only
repository snapshot and a disposable generated target; every position below
carries file:line evidence or a reproduced command (their artifacts are under
`evidence/council/`).

| Seat | Role | Focus |
|---|---|---|
| A | Dev Lead — architecture & lifecycle | generator ordering, migration, data-file semantics, upgrade path |
| B | QC — adversarial validation | validation holes, error handling, file handling, wizard input |
| C | Tester — evidence & portability | harness correctness, Bash 3.2 / macOS python audit, release checklist, decision risks |

## Question

Are `@gate` attempt-2 findings R1–R4 sufficient, and what else must change for
the seats reference + spec to be safe to hand to `@build` for a release?

## Round 1 — positions (condensed; full text in `evidence/council/round1-*.md`)

**A (lifecycle).** R1 confirmed and extended: the generator writes `AGENTS.md`
before runtime files and still emits the legacy `model-profiles.json`, so
`roster-block` fails and `init` migrates the generator's own Sol/xhigh defaults.
Proposed order: copy `agent-seats.sh` → `init` via the *bundle's* script with
env pointing at the target (skip on `--dry-run`, non-fatal) → `AGENTS.md`
writer embeds `roster-block` (fallback text when unavailable). Stop emitting
`model-profiles.json` on fresh targets; verifier/doctor sites become
conditional. Legacy acceptance = old-launcher parity (7 required keys, grammar,
effort set); a legacy file equal to the old generator default carries no user
decision → seat defaults. Also found: `scripts/agent-seats.sh` missing from the
gitignore/local-only lists; the harness's first check enshrined the Sol
migration; defaults were not warning-clean (Terra fallback shared).
Confidence high on ordering/emission; medium on the untouched-default rule.

**B (QC).** R2/R3/R4 confirmed. New: a failed in-place write truncates
`AGENTS.md`/`seats.json` (P1, reproduced with `ulimit -f`); no locking (9/40
lost updates); tracebacks on malformed shapes; `set` silently accepts unknown or
contradictory options; `set` cannot repair an invalid file; wizard crashes on
the spec's own example (no `duty`); Ctrl-D advances, Ctrl-C traces back; catalog
without a Codex model crashes; duplicate efforts / BOM. Delivered a patch:
`fullmatch` on every serialized field, `pick_number`, EOF/Ctrl-C handling,
`write_atomic` (temp + `os.replace`), directory `flock`, structural checks,
option whitelist, repair path, `duty` fallback.

**C (tester).** Harness race reproduced deterministically (EOF observed before
`waitpid`; suffix matching re-counted echoed prompts); fixed harness (reap after
EOF, prompt detection on the unprocessed buffer, transcript on failure) 38/38
×4 and 25/25 under load. Portability table: `read -r -d ''`, `python3 -c` with a
35 KB argument, `set -euo pipefail`, pathlib/re/json are safe on Bash 3.2 and
Python ≥3.6; caveats: `#!/usr/bin/env bash` picks Homebrew bash (tests must call
`/bin/bash`), the macOS `python3` stub, `input()` prompting on stderr. Release
checklist in order; decision risks: `gate_coding` sunset undated, auto-seed on
`status` mutates on a read, PTY tests need `/dev/ptmx`.

## Round 2 — cross-review (condensed; `evidence/council/round2-*.md`)

- A on B: `write_atomic` replaced symlinks with regular files (B fixed with
  `realpath`); a lock taken before the present-and-valid check made `init` and
  `render` wait behind an idle wizard (chair: `init` fast path, bounded NB wait
  elsewhere); `set` created a missing file (chair: fail closed). A re-ran
  fresh/upgrade/dry-run/apply-candidates with B's script in the patched bundle:
  no generator regression; migration regression persisted until A's hunks were
  composed in.
- B on A/C: A's rule left optional `*_reasoning_effort` keys on `.match`
  (LF re-opened R2 through migration — fixed by `fullmatch` in `ensure`); the
  untouched-default rule discarded `planning_reasoning_effort: max` (chair: apply
  only when no extra effort keys exist); verified C's stderr claim and moved the
  wizard prompt to stdout; C's fixed harness ×3 on B's script: 38/38.
- C on A/B: `fcntl.flock`, `os.replace`, `os.fsync`, `utf-8-sig` all ≥3.4;
  atomic writes need a writable directory (documented); new inode changes owner
  and breaks hard links (accepted); `mkdir` before the lock could trace back on
  a read-only `docs/` (chair: wrapped); rc 130 is outside the spec table
  (chair: documented); stopping legacy emission breaks the verifier, launcher and
  ~29 test references unless done in the same change (chair: same change, gated
  by a fresh-target verifier run); `install-agent-bootstrap-home.sh` and MANIFEST
  must ship the script or generation aborts (fail-closed, inventory test flags it).

## Chair synthesis (`@spec`)

Approach: adopt B's final script composed with A's legacy acceptance hunks,
plus the chair amendments below; adopt C's harness mechanics and extend it with
B's probe set into one Python harness; adopt A's three generator hunks as the
reference for `@build`, with the verifier/installer/manifest/gitignore/test
sites listed in `build-handoff.md`.

Chair decisions (with the minority position preserved):

1. **Audit conflict and sharing warning use primary models only.** Fallbacks are
   capacity substitutes, not the review authority; defaults become
   warning-clean. Minority (A, P3): a fallback shared in both directions could
   still put the reviewing model on the coding seat; accepted as a documented
   limitation because the seed also records `launch_model`.
2. **Auto-seed only inside the launch boundary** (`planning|coding|reviewing|run`
   share `run_codex_with_mode`); `status`, `doctor`, verifier stay read-only.
   Amends `@gate` decision 2 ("first `status` seeds"): a read command must not
   mutate the tree. A and C concur.
3. **`init` has a lock-free fast path** when the file is present and valid, and
   never prompts; the lock is taken only to create. Other writers use a
   non-blocking lock with a 10 s bounded wait (rc 1 "another write in progress").
4. **`set` never creates `seats.json`** (run `init`); it may repair a
   structurally sound invalid file.
5. **Untouched-default rule** applies only when the legacy profile equals the
   old generator default *and* declares no `*_reasoning_effort` keys; `init`
   labels the result `defaults`. B's data-loss objection resolved by the guard.
6. **Exit codes** 0/1/2/3 kept; 1 also covers refusals (lock busy, end of
   input, unwritable); 130 = interrupted, with a message when `seats.json` was
   already written. Duplicate catalog efforts are a warning; BOM accepted.
7. **Legacy emission stops for fresh targets** in the same change as the
   launcher, verifier, installer, manifest, gitignore/local-only lists and the
   ~29 test references (C's list), gated by a fresh-target verifier run.
8. **Harness portability:** `SEATS_QA_BASH=/bin/bash` for macOS runs; exact
   prompt counts; transcripts on failure; permission cases skip under root.

Rejected: keeping `.seats.json.lock` files (ownership problems) — directory
`flock` instead; forced-TTY variable — real PTY only; `set` creating the file —
fail closed; conflict on fallback models — primary only.

Executor: `@spec` for the reference script, harness, spec revision 2 and the
handoff; `@build` for the production integration after `@gate` attempt 3.

Verification performed after the fixes (Linux, bash 5.2, python 3.11):
harness v2 103/103 ×3 as a non-root user and 103/103 (1 skip) as root; seven
mutations (program on stdin 14 red; marker balance 2; conflict boundary 1;
grammar `match` 3; legacy required keys 1; non-atomic write many; `set`
creating the file 1); `bash -n`, shellcheck with CI exclusions, AST parse at
feature_version 3.8 — all clean. Not run here: macOS `/bin/bash` 3.2 and the
generator integration (reference hunks only).

Stop conditions for `@gate` attempt 3: any harness check red on macOS bash 3.2;
any generator scenario (fresh, upgrade, dry-run, apply-candidates) contradicting
the lifecycle table; a mutation that survives.
