# Guard deny and ACK implementation plan

> Agentic worker: Luna xhigh executes this bounded plan with test-driven development; the coordinator performs independent verification and review. This packet is the user-selected plan location.

**Goal:** Claude Edit/Write denies with rc 2 until an exact-path, time-limited CLI ACK exists, preserving other guard failures as rc 1.

**Architecture:** Guard owns classification, ACK log parsing/writing and denial rc 3. The generated Claude adapter translates only rc 3 to 2. Runtime snapshot and generator stay byte-identical.

**Tech stack:** portable Bash 3.2, Python 3, generated temporary Git fixtures, shellcheck.

Worktree: `/Users/admin/.config/superpowers/worktrees/agent-bootstrap/simplify-task-relations`
Branch: `feature/simplify-task-relations`; starting HEAD: `45585fad41724334cd9e93d8c489f8946d9ec8c6`.

Read `task.md` including Specification revision 1 and the latest pre-coding Attempt in `codex-review.md`. Do not start source edits until that attempt says sufficient/yes. The latest revision supersedes old pseudocode. Earlier review history is immutable.

## Write boundaries

- `agent-bootstrap/agent-guard.sh`: denied exit code, flag, ACK source, safe TSV writer and exact-path TTL lookup.
- `agent-bootstrap/lib/writers-runtime.sh`: only Claude edit-guard adapter heredoc.
- `agent-bootstrap/agent-hook.sh`: generated snapshot of that adapter.
- `agent-bootstrap/lib/writers-docs.sh`: only three explanatory passages identified in task.md.
- `scripts/test-bootstrap-multi-agent-project.sh`: focused regression cases/setup/helpers within this existing script.
- `CHANGELOG.md`: unreleased entry, no VERSION or manifest change.
- Packet: append `implementation.md`, link supporting focused test/evidence artifacts from task.md, update state only after recorded work. No source change elsewhere without presenting the concrete technical necessity to coordinator.

## Execution checklist

- [ ] Confirm branch/head/status. Preserve packet and unrelated files. At actual implementation entry set base_commit to current HEAD and phase implementation owner codex.
- [ ] Add isolated exact-rc regression cases and an executable focused runner as packet evidence (not a new production script). Use generated target and actual JSON Edit/Write/Bash calls. Capture `rc=0; command || rc=$?; [[ $rc -eq EXPECTED ]]` rather than truthiness.
- [ ] Observe the original adapter fail expected rc 2; record the failure before source edits. Keep targeted cases for all B1-B4 requirements in revision 1, including TTL-positive expiration, TSV cross-path regression and real read-only fallback.
- [ ] Implement the guard helpers and narrow adapter mapping. Preserve default strict CLI ACK writing and explicit env ACK. Use fixed-field TSV, no log mutation on reuse, canonical path comparison, and safe shell quoting.
- [ ] Regenerate snapshot from a temporary target and compare bytes. Update the three bounded docs passages and unreleased changelog.
- [ ] Run focused cases green. Mutate only the rc3-to-2 translation in an isolated generated copy to return 1; require the denial rc assertion to fail. Restore the fixture; leave production unchanged.
- [ ] Run release checks (logs in this packet evidence directory):
  `bash scripts/test-bootstrap-multi-agent-project.sh`
  `bash scripts/test-onboarding-fixtures.sh`
  `bash scripts/test-one-shot-upgrade.sh`
  `shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-guard.sh agent-bootstrap/agent-hook.sh agent-bootstrap/lib/writers-runtime.sh agent-bootstrap/lib/writers-docs.sh scripts/test-bootstrap-multi-agent-project.sh`
- [ ] Run generated `.codex/codex-mode.sh doctor`, `scripts/verify-ai-deps.sh`, snapshot comparison, and four required smoke actions. Record actual return codes and context budget; distinguish baseline warnings from failures.
- [ ] Append `## Implementation attempt 1` with truthful model/source, scope, files, red/green/mutation results, commands and log paths, deviations and any unavailable checks. End with phase verification owner codex and request independent review, not closed.

Keep long command logs in packet-linked evidence; final report should be concise. Do not self-certify live Claude Code acceptance. No commits, pushes, branch switches or release actions. Ask coordinator about a concrete technical blocker and continue independent safe work; do not invent approval.

## Baseline lint clarification

The original guard/hook shellcheck gate must pass with the original exclusions.
The broader five-file run has pre-existing SC2016, SC2030, SC2031 and SC2163
reports confined to the existing test script; baseline output is in
`evidence/baseline-shellcheck.log`. Compare the broader result against baseline
and introduce no new warnings. Do not rewrite unrelated tests or suppress new
findings to force a globally clean report. Report this baseline explicitly.

## Independent review correction 1

The coordinator accepted both B3 findings in `post-review.md` and returned them
to Luna for correction under the user's authorization to resolve technical
findings. The existing delimiter-path contract requires a narrow extension of
the hook write boundary: lossless JSON path transport through the Claude parser
and dispatch, plus delimiter-preserving guard canonicalization, are permitted
in the same files. Preserve matcher and Bash dispatch behavior; add no new
production files or policy changes.

Bind the behavior with generated-hook JSON tests for embedded and trailing LF,
trailing TAB, and CR: explicit ACK allows only that invocation, leaves the ACK
log byte-identical, and a retry without explicit ACK denies. Isolate the TSV
injection regression with an empty log; require exactly one physical row, reuse
for A with `ack_source=log`, and denial for B. Record RED before the correction.
Regenerate the snapshot and run final verification after runtime and docs are
stable. The coordinator will rerun actual Claude Code host acceptance against
the corrected runtime; the previous host result remains historical evidence.
