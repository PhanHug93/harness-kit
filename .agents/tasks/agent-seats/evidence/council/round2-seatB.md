# Seat B — round 2 (cross-review)

## 1. Attacks on A and C

A's acceptance rule — holes found (run on A's script): optional per-route efforts were not fullmatched (`ensure()` used `.match`): customized legacy with `planning_reasoning_effort: "high\n"` → `init` rc 0, `validate` rc 0, `resolve gate` → 9 lines (R2 re-opened through migration); my `is_effort` helper in `ensure()` rejects it. My own patch kept the reference's route-skipping; A's required-keys check is right; combine. Untouched-default rule misfires: it compared only the 7 keys, so default models + `planning_reasoning_effort: "max"` → "no user customization", `max` discarded; a user who deliberately kept Sol gets Astra and `set gate --model gpt-5.6-sol` → `not in catalog`. Bound: also require no `*_reasoning_effort` keys, and apply only after legacy emission stops (upgrades only).

C's stderr claim — verified: wizard on a PTY with `stderr=file`: `host>` absent from the PTY, present in the file. Consequence: drivers merging all three fds are unaffected; `wizard 2>/dev/null` showed menus but no prompt. Amended `ask()`: `sys.stdout.write(prompt); flush; input()`.

C's `pending` detection — verified with C's driver: reference `99` at host/model/fallback → `rc 0 prompts=17 changed=True`; patched → `rc 1, prompts 1/3/5, changed=False`; harness answer set → exactly 16, all-Enter → 17. No over-count.

## 2. Empirical runs (final patch)

C's `seats-qa.fixed.py` ×3: 38/38 ×3 (`prompts=16 rc=0`). v1 harness: 38/38. `probes.sh` (R2a–e, R3a–d, R4, F1–F10, S1–S4, regression guards): 48/48; the reference scores 7/44 on the same set. Residual: none in scope. Not fixed by design: R1 (A's hunks), incomplete-legacy acceptance (adopt A's rule).

## 3. Self-critique (three real defects found and fixed)

- Symlinked AGENTS.md/seats.json: r1 `write_atomic` replaced the link with a regular file. Fixed via `os.path.realpath` before the sibling temp + `os.replace`.
- Lock file ownership: root-created `.seats.json.lock` 0644 → other user rc 1. Fixed: `flock` on the directory fd (no file).
- Blocking lock: wizard idle at a prompt hung a concurrent `set`. Fixed: `LOCK_EX|LOCK_NB` with 10 s bounded wait → rc 1; `ENOLCK/EOPNOTSUPP` (NFS) degrades to a warning.
- Remaining bounds: `fcntl.flock` stdlib on macOS/Linux; program parses with `ast feature_version=(3,6)`; imports only stdlib; temp is a sibling so `os.replace` never crosses filesystems; replace changes the inode owner and breaks hard links; a SIGKILL mid-write can leave `.AGENTS.md.<pid>.tmp`; read-only files honoured via `os.access` (root bypasses); Ctrl-C exits 130 (outside the documented 0–3 — document or map); duplicate efforts downgraded to a warning; `--model` on host-controlled hosts is rejected rather than written informationally — chair's call.
- Dispatcher change (C's caveat): `python3 -c 'import sys'` replaces `command -v`.

## 4. Conflicts and resolutions

1. Harness check 1 needs the generator's legacy (A) vs "assertions unchanged" (C): keep C's driver, adopt A's explicit customized fixture; run on a target without legacy.
2. Untouched-default rule (A) vs data loss: keep only with the extra-key guard and after legacy emission stops.
3. Migration validation: A's required keys + my fullmatch helpers.
4. Prompt stream: my `ask()` writes to stdout; harnesses unaffected.
5. Warning noise: warn only on write paths.
6. Adopt-as-is (handoff:95): all three seats agree it is not adoptable; apply my script patch + A's generator hunks + C's harness.
7. A's P3 fallback-sharing warning on defaults: spec change or defaults change — chair decides.

## 5. Final position

R2 fullmatch + all serialized fields (keep, P2); R3 wizard rejects out-of-set input (keep, P2); R4 → rc 2 with message (keep, P2); F1 non-atomic write destroys AGENTS.md (keep, symlink fix added, P1); F2 no lock (keep, amended to dir-flock, NB wait, P2); F3 tracebacks on malformed shapes (keep, P2); F4 silent/contradictory `set` options (keep, P2); F5 `set` cannot repair (keep, P2); F6 missing `duty` (keep, P2); F7 Ctrl-D/Ctrl-C (keep, P3); F8 wizard catalog edge cases (keep, P3); F9 OSError messages (keep, P3); F10 duplicate efforts / BOM (amend: warning / accept BOM, P3); new: prompt-on-stderr, python3 stub probe (P3).
