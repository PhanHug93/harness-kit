# Seat A — round 2 (cross-review)

## 1. Attacks on B and C (my area)

B `write_atomic` (patched:309-329). Real fix for B's truncation P1, but `os.replace` swaps the link, not the target. Probe: `AGENTS.md → AGENTS.real.md` and `seats.json → ~/shared-seats.json`, then `set build --effort high`: reference rc 0, both still symlinks, shared file updated; B rc 0, both replaced by regular files, shared file not updated. Candidate mode and `--apply-candidates` are unaffected (generator embeds, never calls `render`). Ownership: file owned by `nobody` → after `set`, owned by the caller (mode 600 preserved). Leftover `.AGENTS.md.<pid>.tmp` (SIGKILL between write and replace) is not gitignored; `.seats.json.<pid>.tmp` is.

B `flock` (patched:569-587). `.seats.json.lock` is ignored, never in the write log, invisible to `--diff/--status/--apply-candidates`; dry-run never runs `init`. Two regressions: (i) lock taken before the "present and valid" check — `init` and `render` hang while a `wizard` holds the lock; generator `seed_agent_seats` and launcher auto-seed both call `init`, so an open wizard silently hangs a generation or a Codex launch. (ii) Read-only `docs/agent-configs` with no lock file yet: B `init` rc 1 "cannot lock", B `render` rc 1 although AGENTS.md is writable.

B `proposal(repairing=True)`. Legacy still consulted only on `missing` → no conflict with the lifecycle table. The conflict is elsewhere: `set` on a missing file creates it (second silent creation path beside `init`), while B's patch keeps the route-skipping migration, so on a pristine target `set` migrates Sol.

C "seed only in `run`". Old launcher: `planning|coding|reviewing` and `run` share `run_codex_with_mode` after `require_model_profile`; `status` also calls it. Reconciled: seed once inside the shared launch boundary (`require_seats`, successor of `require_model_profile`, used by the four launch arms), read-only variant for `status`/`doctor`.

C `input()` → stderr. `init` has no `ask()`, so generation never blocks; `seed_agent_seats` keeps stderr attached and discards only stdout; `roster-block 2>/dev/null` is prompt-free. Required invariant: `init` must never call `input()`; a test should run `init </dev/null` under a PTY and assert no `>` prompt.

## 2. Empirical: B's script in my scratch bundle

Dry-run: rc 0, 0 files. Fresh: gate `gpt-6-astra`, roster embedded, `validate` 0, `render` "already current", write log contains only `scripts/agent-seats.sh`. Upgrade of pristine target: seats.json live, AGENTS.md preserved, candidate with roster + overlay; `--status`/`--diff` leave seats.json untouched; `--apply-candidates` → live roster, overlay intact, drift `clean`; `--force` after `set gate --host claude` → seats.json byte-identical, roster shows claude. No generator regression. Migration regression persists (gate `gpt-5.6-sol`) — B did not address R1's validation.

Composed script (B patch + my 3 legacy hunks): C's fixed harness 38/38; incomplete/`turbo` legacy → `init/suggest/wizard/set` rc 1, nothing written, `reset` rc 0; untouched default → Astra; generator fresh/upgrade/apply all green, legacy file absent on fresh.

## 3. Conflicts and resolutions

1. Atomic write vs symlink write-through → keep temp+replace, resolve symlinks first. P2.
2. B's lock vs generator/launcher `init` → fast path (read+validate) before locking; `LOCK_NB` with bounded wait and a named error; lock failure on an unwritable dir is a warning for read-only outcomes. P2.
3. `set` creating seats.json vs "init creates once" → `set` fails closed on a missing file. P3.
4. C "run only" vs my "launch commands" → same boundary (`run_codex_with_mode`); `status`/`doctor` read-only. Agreed.
5. Harness check 1 still passes on Sol and on the "defaults" path because it matches "created from legacy" → fixture must assert a custom model; `init` must label the untouched-default case `defaults`. P2.
6. B's `fullmatch` vs my acceptance rule → orthogonal, composed without edits.

## 4. Final position

| # | Proposal | Status | Severity |
|---|---|---|---|
| 1 | Entrypoint ordering (copy → init → docs) | keep, re-verified | P1 |
| 2 | Bundle-script `init`, dry-run skip, placeholder block | amend: `init` prompt-free, lock fast-path | P1 |
| 3 | Stop emitting `model-profiles.json`; verifier sites conditional | keep (C concurs) | P1 |
| 4 | gitignore/local-only lists + write-log `check-ignore` test | keep; add `.AGENTS.md.*.tmp` naming note | P1 |
| 5 | Legacy acceptance rule (old-launcher parity) | keep; composes with B | P1 |
| 6 | Untouched-default → seat defaults | keep; label source `defaults` | P2 |
| 7 | Harness fixture asserts custom model | keep | P2 |
| 8 | Spec/handoff text, `status` read-only, auto-seed boundary | keep; add `set` fail-closed | P2 |
| 9 | Default roster not warning-clean | keep | P3 |
| 10 | `init` warning leak into `--status/--diff` | keep | P3 |
| 11 | Orphan legacy candidates | keep | P3 |
| 12 | B `write_atomic` symlink | new | P2 |
| 13 | B lock hang / read-only dir | new | P2 |

Would not approve without: the real bundle wired as above with the three suites green; the launcher's `require_seats` boundary with `status`/`doctor` read-only; a PTY test proving `init` never prompts or blocks under a held lock; the fixture change in check 1; an owner decision on the Terra-fallback warning.
