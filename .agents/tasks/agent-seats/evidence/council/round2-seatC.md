## 1. Assumptions attacked

**B's `write_atomic` (patched.sh:311-334).** `os.replace`, `os.fsync`, `re.fullmatch`, `utf-8-sig`, `BlockingIOError`, `fcntl.flock` are all ≥3.3/3.4; AST scan at `feature_version=(3,8)` clean. Shell side adds only `python3 -c 'import sys'` (:791; 43→57 ms/call). Behaviour changes, reproduced as `nobody`:
- needs a *writable directory*: root dir 755 + AGENTS.md 666 → v2 rc 0, B rc 2; seats dir 555 + seats.json 666 → v2 rc 0 (wrote), B rc 1 "nothing written". Fail-closed, but a regression on hardened checkouts.
- new inode: owner root→nobody (v2 kept root); hard links break; macOS xattrs/ACLs lost. APFS/HFS+ rename atomic; on NFS/SMB/FUSE `fsync` may raise → save refuses (rc 1) rather than truncating — the safer side.

**B's `lock_for_write` (:579-600).** `flock` on a directory fd is valid on Linux/macOS, read-only fds included; macOS SMB/NFS may return ENOTSUP → warning path (:598). Verified: `resolve` unblocked; second writer waits 10.1 s → rc 1; 40 concurrent `set` pairs: v2 lost 14/40, B 0/40. Hole: `mkdir` (:587) precedes the lock outside `try` → traceback rc 1 on a read-only docs/.

**Exit codes vs spec:152-154.** rc 130 (:783-785) is new. Through a controlling PTY: Ctrl-C → 130, seats unchanged (v2: traceback, signal death); Ctrl-D → rc 1 "nothing written" (v2 treats EOF as Enter). Gap: Ctrl-C between save and render exits 130 without saying `seats.json` is effective. Amend the table: "1 also = refused (lock busy, EOF, unwritable)", "130 interrupted; if `seats.json written:` was printed, run render". Bash 3.2 propagation of 130: expected identical, unverified.

**A's "stop emitting `model-profiles.json`".** Verified with A's bundle on a fresh target: current verifier rc 1 (`FAIL missing file`), `codex-mode.sh status` rc 1, `agent-hook.sh doctor` rc 1. Consumers: writers-runtime.sh:212-216, 1092-1139, 1391-1441 (+ snapshot), launcher writers-docs.sh:1825-1964, 29 test refs, MANIFEST:39/43, installer:319/323 — not separable into an earlier packet. Upgrades matter more: existing targets already hold the generator-default legacy; only the default-equivalence rule (A's P2 #7, in A's composed script) keeps `@gate` on Astra — verified on an upgrade. That rule is P1.

**A's "bundle script for `init`".** `BUNDLE_DIR` is `pwd -P` of `BASH_SOURCE` (bootstrap:25), absolute everywhere; the one-shot upgrader runs the installer export (:214) whose `copy_file` list (installer:302-341) lacks `agent-seats.sh`; `copy_bundle_file` exits 1 on a missing file (core.sh:197-206) — verified: generation aborts, 0 files written. Fail-closed, and the inventory test (test-bootstrap:1217-1240) flags it: installer + MANIFEST + canonical-loop rows are same-change requirements. `--dry-run` on a committed target → porcelain empty (verified).

## 2. Empirical results (B's script)

- `seats-qa.fixed.py` ×3 on fresh copies: 38/38 ×3, `prompts=16`, no check changed.
- Mutations: program-on-stdin → 5 red; marker-balance removed → 3 red (orphan, duplicate, partial failure) — same as the gate.
- `bash -n` ok; shellcheck (CI exclusions) rc 0; `py_compile` ok; `ast.parse(feature_version=(3,8))` ok.

## 3. Checklist delta

Add: (a) atomic-write — `ulimit -f` truncation keeps old bytes; read-only file → rc 1/2 with message; read-only dir + writable file → documented rc; symlink written through. (b) lock — concurrent `set` pairs = 0 lost; busy lock → rc 1 ≤ 10 s, `resolve` unblocked. (c) Ctrl-C → 130, Ctrl-D → 1, nothing written. (d) fresh target without legacy: `verify-ai-deps.sh`, `codex-mode.sh status`, `agent-hook.sh doctor` rc 0. (e) `--dry-run` → porcelain empty. (f) generation from the installer export + inventory test. (g) pristine-target upgrade → `@gate` Astra + note; `--apply-candidates` roster live, overlay intact.
Riskier, not safer: emission removal without (d); `except Exception → rc 2` (:446) hides bugs — print the class, traceback behind `AGENT_SEATS_DEBUG=1`; hard-coded `LEGACY_BUNDLE_DEFAULT` drifts if the bundle file changes — test equality.

## 4. Conflicts

1. Legacy emission — A: stop now; C: seed only when it differs. Resolution: A's removal in the same change as launcher + verifier + tests, gated by 3(d); keep the equivalence rule regardless.
2. Rule #7 priority — A: P2. Resolution: P1 (load-bearing on upgrade).
3. Exit codes — B widens 1, adds 130; spec lists four. Resolution: amend the spec table.
4. Atomic write vs permissive layouts. Resolution: keep, document "directory must be writable", add 3(a).
5. Auto-seed on first `status` (gate decision 2) vs A/C read-only `status`. Resolution: seed only on launch commands.

## 5. Final position

Keep: harness fix (38/38 ×7 across v2 and B; mutations 5/3) — high. Keep: portability table; amend the `input()` row (B writes prompts to stdout, :487-491) and the `command -v` row — high. Amend: decision-2 risk adds "upgrade path needs the equivalence rule" — high. Amend: checklist as above — medium-high. Drop: none.

Artifacts: `/tmp/council/targets/seatC/` (`B-run*.json`, `B-mut-*`, `ctl_probe.py`, `t{perm,own,ro,cc,A}-*`).
