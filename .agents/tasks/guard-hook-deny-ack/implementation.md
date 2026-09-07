## Implementation attempt 1

Model/source: the current Codex implementation worker executed the user-authorized
Luna xhigh handoff against `feature/simplify-task-relations` at base commit
`45585fad41724334cd9e93d8c489f8946d9ec8c6`. The final B3 correction followed
`luna-handoff.md` section `Independent review correction 1` and the accepted
findings in `post-review.md`.

The six-file source scope is complete:

- `agent-bootstrap/agent-guard.sh`: fixed TSV ACK writing and validation, exact
  path matching and TTL lookup, denial rc 3, and NUL-delimited canonical path
  capture through both canonicalization boundaries. Delimiter-bearing paths can
  authorize the current invocation but are never appended or reused.
- `agent-bootstrap/lib/writers-runtime.sh` and generated
  `agent-bootstrap/agent-hook.sh`: Claude JSON fields now travel through a
  NUL-delimited parser/dispatch stream, preserving embedded and trailing control
  bytes before the guard sees the path. The adapter still translates only guard
  rc 3 to hook rc 2.
- `agent-bootstrap/lib/writers-docs.sh`: retained the general cross-tool
  pre-edit guidance and added concise Claude deny, per-path reuse, and TTL text
  within the measured full-workflow budget.
- `scripts/test-bootstrap-multi-agent-project.sh`: focused B3 cases cover
  embedded LF, trailing LF, trailing TAB, CR, fixed-TSV injection reuse from an
  empty log, explicit rc contracts, generated JSON hook behavior, and isolated
  full-suite ACK state.
- `CHANGELOG.md`: unreleased Claude protected-edit denial entry.

The first focused regression against the original source recorded expected hook
rc 2 versus actual rc 1 in
[`evidence/focused-red.log`](evidence/focused-red.log). After adding the B3
correction cases but before the transport fix, the new RED run failed because an
embedded LF ACK changed the log (`focused-b3-red-command-rc=1`) in
[`evidence/focused-b3-red.log`](evidence/focused-b3-red.log).

The corrected focused runner passed rc 0 in
[`evidence/focused-green-b3-final.log`](evidence/focused-green-b3-final.log).
It verifies explicit ACK rc 0 with byte-identical ACK logs and no-ACK retry rc 2
for embedded LF, trailing LF, trailing TAB, and CR paths. Its injection case
starts with an empty log, requires exactly one physical row, reuses A with
`ack_source=log`, and denies B. The full bootstrap suite then passed rc 0 in
[`evidence/release-bootstrap-final-b3.log`](evidence/release-bootstrap-final-b3.log);
onboarding and one-shot passed rc 0 in
[`evidence/release-onboarding-final-b3.log`](evidence/release-onboarding-final-b3.log)
and [`evidence/release-one-shot-final-b3.log`](evidence/release-one-shot-final-b3.log).

The bootstrap failure before the final rerun was a test fixture contamination:
the suite's earlier explicit `--ack reviewed AGENTS.md` correctly left a reusable
ACK row, so the later missing-ACK hook assertion was allowing a valid log reuse.
The test now clears that ACK log immediately before the missing-ACK scenario and
asserts denial rc 2 plus explicit allow rc 0. The prior CLI audit assertion is
preserved.

Strict guard/hook shellcheck passed rc 0 in
[`evidence/shellcheck-strict-final-b3.log`](evidence/shellcheck-strict-final-b3.log).
The broader run returned rc 1 only for the established test-script baseline
diagnostics SC2016, SC2030, SC2031, and SC2163, recorded in
[`evidence/shellcheck-broad-final-b3.log`](evidence/shellcheck-broad-final-b3.log);
no new warning code was introduced.

Coordinator-owned post-B3 generated checks passed in
[`evidence/coordinator-final-checks/summary.json`](evidence/coordinator-final-checks/summary.json):
doctor rc 0, verifier rc 0 with full context at 6,100/6,200 tokens, snapshot
equality, smoke deny rc 2, CLI ACK rc 0, reuse allow rc 0, wrong-path rc 2,
unprotected allow rc 0, and the isolated rc-translation mutation failed its
exact rc 2 assertion as required. The coordinator's final worktree check records
the exact six-file scope, unchanged index, diff check rc 0, and matching source
hashes in [`evidence/final-worktree-check.json`](evidence/final-worktree-check.json).

Coordinator-executed Claude Code 2.1.235 acceptance passed against the corrected
runtime: initial Edit denied, CLI ACK executed, retry succeeded, marker and ACK
log exist. Current host evidence is in
[`evidence/claude-host-final/claude-host-summary.json`](evidence/claude-host-final/claude-host-summary.json)
and [`evidence/claude-host-final/claude-host-provenance.json`](evidence/claude-host-final/claude-host-provenance.json).
The host runner was not executed by this worker; the earlier historical host
evidence remains preserved.

No commit, stage, push, branch switch, or new production file was made. Phase is
`verification`, owner is `codex`, and an independent Sol rereview is requested.
