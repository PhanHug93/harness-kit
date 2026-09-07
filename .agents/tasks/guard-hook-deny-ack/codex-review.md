## Pre-coding technical review

### Attempt 1

reviewer_model: gpt-5.6-sol
model_source: user_explicit
session_provenance: current user-invoked Codex review task; no fresh-session, host, account, or model-independence attestation
reviewed_branch: feature/simplify-task-relations
reviewed_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
spec_sufficiency: partially_sufficient
sufficient_for_coding_model: no
adequacy: no
blocker_count: 4
blocking_gaps: B1 stderr contract contradiction; B2 positive-TTL expiry and invalid-TTL behavior unbound; B3 TSV record-boundary/path-field ambiguity; B4 rc=1, Bash, and unwritable-state adapter branches unbound

#### Findings

**B1 — Blocker: the proposed deny path violates its own stderr limit.** Trigger: a protected edit without an ack calls the proposed guard `deny()`, which emits one stderr line, then the proposed hook adapter emits three more (`.agents/tasks/guard-hook-deny-ack/task.md:43-44`, `:77-78`, `:107-110`; the current error helper also emits directly at `agent-bootstrap/agent-guard.sh:71-74`). Impact: Luna can implement the supplied pseudocode exactly and produce four stderr lines, failing AC1 while the proposed test still passes because it checks only substrings. The specification must choose one end-to-end message envelope of at most three lines, require a shell-runnable command with the canonical path safely quoted, and bind both the exact hook rc and stderr line count.

**B2 — Blocker: `TTL=0` does not test expiration.** Trigger: AC4 promises that an ack older than a positive TTL is rejected, but the only proposed case disables log lookup with `AGENT_GUARD_ACK_TTL_SECONDS=0` (`.agents/tasks/guard-hook-deny-ack/task.md:48-49`, `:142`). Impact: an implementation that accepts every matching log row whenever TTL is positive would pass all listed cases. Add a valid, deliberately old log row with a positive TTL and assert hook rc 2; also define non-integer TTL behavior and bind it (recommended: guard configuration error rc 1, propagated unchanged by the hook). Keep the existing zero/negative kill-switch case as a separate check.

**B3 — Blocker: the TSV lookup rule is ambiguous and unsafe against record/field injection.** Trigger: the current writer appends raw `ack` text into a TSV row (`agent-bootstrap/agent-guard.sh:540-555`), while the proposal says to find a matching `path=` field and claims tabs/newlines in reason or ack can be ignored (`.agents/tasks/guard-hook-deny-ack/task.md:79-85`, `:153-154`). A tab can introduce a second `path=` field and a newline can introduce a forged physical row. Impact: a CLI ack for path A can be interpreted as an ack for path B, contradicting AC3. The revision must define an unambiguous record grammar: the canonical path is accepted only from the fixed second field, and CR/LF/TAB in appended values must be escaped/sanitized before writing or explicitly rejected; add a focused cross-path injection regression. Also state that canonical paths containing TSV delimiters are ineligible for log reuse unless encoded, because the unchanged legacy format cannot represent them safely.

**B4 — Blocker: important adapter exit branches have no truthful binding.** Trigger: AC7 requires non-denial guard failures to remain rc 1, and the selected unwritable-state behavior changes a protected edit to rc 0; however the seven proposed cases cover only guard denial rc 3 and hook rc 0/2 (`.agents/tasks/guard-hook-deny-ack/task.md:53-55`, `:137-147`). The cited “Bash-input” tests at `scripts/test-bootstrap-multi-agent-project.sh:978` and `:2055` invoke the hook with no JSON input, so they do not exercise the Bash parsing/dispatch branch. Impact: a refactor that maps all guard failures to hook rc 2, blocks Bash unexpectedly, or hard-denies when no state backend is writable can pass the listed tests. Add focused generated-fixture cases asserting: a representative guard error is propagated as hook rc 1; actual Bash JSON preserves the existing detector/rtk path and never returns 2 from edit guarding; and the fully exhausted state-directory fallback returns 0 with `ack_source=advisory` after normal policy/context/path validation succeeds.

#### Decisions on open questions

1. **Choose advisory allow when no writable state backend remains.** A hard deny cannot be cleared by the documented CLI ack because there is nowhere durable to store it, creating the onboarding/edit deadlock the guard's existing fallback is designed to avoid (`agent-bootstrap/agent-guard.sh:9-43`, `:634-637`). Precedence must remain explicit: a current `--ack` reports `ack_source=ack`; otherwise a readable valid row may report `log`; `ack_source=advisory` is used only when neither is available and all state-directory candidates are unwritable, after ordinary validation has succeeded.
2. **Do not append `ack_reused`.** TTL must remain anchored to the latest explicit acknowledgement; appending a fresh reuse row would create a sliding lease and could keep access open indefinitely under repeated edits. `ack_source=log` supplies per-invocation observability without mutating the audit log.

#### Confirmed contracts and scope

- The current Claude Code hook reference confirms that PreToolUse exit 2 blocks the tool call, while exit 1 is non-blocking without a valid JSON decision; it also documents absolute `tool_input.file_path` for Edit/Write. Source checked 2026-09-06: https://code.claude.com/docs/en/hooks.
- The current adapter calls preflight first and dispatches only `Edit|Write|MultiEdit` into the edit guard (`agent-bootstrap/lib/writers-runtime.sh:589-620`); the proposed 0/3/other mapping is directionally correct once B1/B4 are resolved. Generator and snapshot remain the two required hook copies; matcher, JSON deny mode, NotebookEdit, Stop/local-only policy, VERSION/manifest, policy/schema, Codex/Gemini/Cursor/Windsurf behavior, and live host acceptance remain excluded.
- The actual CLI command was reproduced on a generated temporary full-workflow target: it returned rc 0 and appended `timestamp\tpath\tpattern\treason\tack`; the current hook returned rc 1 both before and after that CLI ack. This confirms the packet's root cause but is not implementation verification.

#### Validation limits

- Read `state.json` and `task.md` in full and verified branch `feature/simplify-task-relations` at exact HEAD `45585fad41724334cd9e93d8c489f8946d9ec8c6`. CodeGraph could not index this `.config` worktree as already recorded, so the review used bounded raw source reads; Agentmemory was advisory and supplied no controlling fact.
- No source was changed, no implementation was started, no Luna task was invoked, and no broad/release suite was run. The later live Claude Code edit/deny/ack acceptance is still pending for the user and is not claimed as passed.

### Attempt 2

reviewer_role: Sol
reviewer_model: unverified (exact served model identifier is not exposed in this resumed turn)
requested_model: gpt-5.6-sol
model_source: user_explicit
session_provenance: resumed current Codex task after a model-switch instruction; no fresh-session, host, account, or model-independence attestation
reviewed_branch: feature/simplify-task-relations
reviewed_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
reviewed_specification: task.md Specification revision 1 and linked luna-handoff.md
spec_sufficiency: sufficient
sufficient_for_coding_model: yes
adequacy: yes
blocker_count: 0
blocking_gaps: none

#### B1-B4 disposition

- **B1 resolved at specification level.** `task.md:219` makes guard denial a single two-line message, requires canonical-path shell quoting and `--`, and limits the adapter to forwarding streams plus rc 3 -> 2 translation. `task.md:231` binds the stderr limit and executes the printed ACK command against a quoted path before retrying its absolute spelling. This removes the duplicate-message contradiction and exercises the CLI-to-hook canonical-path boundary.
- **B2 resolved at specification level.** `task.md:238` defines decimal TTL parsing and invalid-input rc 1. `task.md:250` separates positive-TTL expiration from fresh, disabled, malformed, future, and unordered-row cases. Byte equality before/after reuse (`task.md:254`) binds the decision that reuse cannot renew the lease. The deliberately accepted future timestamp remains the packet's existing clock-skew policy.
- **B3 resolved at specification level.** `task.md:259` specifies exactly five fixed columns, timestamp/prefix/nonempty-ACK validation, and second-column-only path authority. Escaping non-path values before appending (`task.md:264`) prevents new explicit acknowledgements from creating extra fields or physical rows. Delimiter-bearing canonical paths cannot be appended or reused; ordinary paths remain literal. The A-to-B injection and physical-line-count regression (`task.md:273`) binds the original gap. Legacy well-formed rows remain accepted; this does not claim to authenticate historical records or turn the guardrail into a security boundary.
- **B4 resolved at specification level.** `task.md:280` preserves validation before acknowledgement handling and keeps manual strict/advisory behavior separate. `task.md:291` requires actual Bash JSON and dispatch evidence; `task.md:295` binds missing-context, malformed-policy and outside-root rc 1 plus the real exhausted-resolver advisory case. The latter must use actual permissions and report an unavailable environment honestly. These cases cover upstream preflight failures as well as the post-preflight edit-guard adapter path, so a blanket failure-to-2 mapping cannot satisfy the specification.

#### Decisions and handoff consistency

Both Attempt 1 decisions stand: advisory allow only with log reuse enabled, normal validation successful, no explicit/readable valid ACK, and every existing state-directory candidate unwritable; do not append `ack_reused` or extend its timestamp. Explicit ACK remains first in precedence, and a missing or malformed log in writable state does not enable advisory mode (`task.md:284`).

Revision 1 explicitly supersedes conflicting original pseudocode while preserving history (`task.md:214`). Its six source/test/changelog boundaries match `luna-handoff.md:18`; packet-linked evidence and focused test helpers support those changes without expanding production scope. ACK fixture isolation is explicitly permitted (`task.md:306`). The focused rc-translation mutation is scoped to an isolated generated copy (`task.md:310`, `luna-handoff.md:33`). Snapshot equality means the generated `scripts/agent-hook.sh` against the bundled `agent-bootstrap/agent-hook.sh`, as established by the original packet.

The packet is adequate for coordinator-dispatched Luna xhigh implementation under Specification revision 1 and the linked checklist. State moves to `implementation/codex` as the routing decision only; `base_commit` stays null until actual implementation entry/dispatch. Luna's recorded work must proceed to coordinator verification, not closure. Existing matcher, other host behavior, preflight policy, Stop/local-only policy, schemas, release/version actions and branch/commit/push exclusions remain intact. Live Claude Code acceptance remains pending with the user.

#### Validation limits

This attempt reviewed only B1-B4 remediation and handoff scope/consistency. Branch and exact HEAD match; tracked source/index are clean, with expected untracked `.agents/`. The original 11,406-byte task prefix still hashes to `81739b5e6debb59331ae9efc40ae8c5e3a848e54e9116f849faf306a2b65ba55`. No new source investigation, reproduction, implementation or release suite was needed: unchanged-source evidence from Attempt 1 plus the explicit revision resolves these specification gaps. Approval is for coding adequacy, not passing implementation tests or host acceptance. No Luna task is dispatched by this review.

Coordinator clarification received during this attempt: the five-file shellcheck baseline reportedly exits 1 with existing informational diagnostics in the test script (including SC2016); `baseline-shellcheck.log` is coordinator-reported evidence, not a check executed here. For implementation verification, the original guard/hook shellcheck command must pass with its original exclusions; the expanded five-file check must introduce no new diagnostics against that recorded baseline. Do not rewrite unrelated intentional literals to clear baseline warnings. This explicit instruction governs the expanded-check wording in `task.md:315` and `luna-handoff.md:38`; the coordinator will mirror it into the handoff before dispatch. It preserves scope and does not change the sufficient/yes verdict.

## Final technical review

### Attempt 1

Specification compliance was **rejected** with two B3 blockers, and the code-quality stage was not reached. The hook's tab/newline transport truncated LF-bearing paths before guard validation, and the TSV-injection regression did not prove that the appended ACK row for A was itself reusable. The immutable report, triggers, impact, evidence, reviewed hashes, and required corrections are preserved in [post-review-attempt1.md](post-review-attempt1.md) (SHA-256 `0bf53ca27b180b51fed907ad391a72220b558704840f2a168160e246c5caf8f2`).

### Attempt 2

reviewer_role: Sol
requested_model: gpt-5.6-sol
reasoning_effort: xhigh
actual_model: unverified
model_source: user_explicit
fresh_reviewer_session: true (procedural declaration only; not proof of host, account, or served-model independence)
reviewed_branch: feature/simplify-task-relations
baseline_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
reviewed_specification: `task.md` Specification revision 1 plus `luna-handoff.md` Independent review correction 1

#### Specification compliance verdict

**Pass; blocker count 0.** NUL-framed hook transport and sentinel-based canonicalization preserve embedded/trailing LF, TAB, and CR while retaining canonicalization failures as rc 1. Delimiter-bearing paths can be explicitly acknowledged for only the current invocation, do not mutate the legacy TSV log, and deny on retry. The injection test now starts empty, appends one physical row, proves A reuse with `ack_source=log` and unchanged bytes, and proves B denial.

The remaining B1-B4 contracts pass review: the guard alone emits the two-line `%q`-quoted denial and rc 3; the adapter maps only rc 3 to host rc 2. TTL grammar and boundaries, newest valid timestamp, future-clock behavior, exact second-column path authority, five-field validation, escaped non-path values, error rc preservation, manual strict/advisory behavior, and exhausted-state advisory precedence are implemented and bound. Matcher, Bash detector/rtk dispatch, and unrelated tools/policies remain unchanged. The release failure observed during review was confirmed as fixture contamination from a fresh same-path CLI ACK; the final test clears that state and asserts exact rc 2/0, and its rerun passes.

#### Code-quality verdict

**Pass; finding count 0.** The host-specific translation stays in the adapter, ACK policy stays in the guard, and lossless transport is confined to the parser/canonicalization boundary. The generated full-workflow hook and bundled snapshot are byte-identical. The test additions bind the corrected edge cases through generated artifacts without expanding production behavior. Documentation preserves the cross-tool guard instruction and accurately describes Claude denial and path-scoped TTL reuse.

#### Reviewed source hashes

| File | SHA-256 |
|---|---|
| `agent-bootstrap/agent-guard.sh` | `11d3f7480b2ed7a9a5a23ccb727c2d69e25b07f19847ac49f10ecb5a77c6d835` |
| `agent-bootstrap/agent-hook.sh` | `0644e13098d19161250fc2f2620ad3311bc1eea456c8c8c1e0af8ef065e66be0` |
| `agent-bootstrap/lib/writers-runtime.sh` | `90181d0ff0bf896306719c9ec30431270c36b9257772d39ae45bb2d43bcbd616` |
| `agent-bootstrap/lib/writers-docs.sh` | `8a36c497f220ca70fe803836df149307738956b6c9bf9e901c5086b9edd7e5d6` |
| `scripts/test-bootstrap-multi-agent-project.sh` | `d0b67e7d04a0931ad5e5fd795bb69ebaae5b929632b9a76a783bcca99ae39184` |
| `CHANGELOG.md` | `b9b56cc2484d83eca97d1bac6b8f66a078ead048dcf7e6e33c9975c582cf867e` |

#### Final evidence disposition

- Fresh Sol validation on these hashes: focused generated guard/hook regression rc 0; original guard/hook shellcheck rc 0; full-workflow writer/snapshot byte equality; exact six-file scope and `git diff --check HEAD` rc 0.
- Release evidence: bootstrap, onboarding, and one-shot `release-*-final-b3.log` files each terminate with `command-rc=0`. The post-isolation broad shellcheck returns the expected baseline rc 1. After normalizing only line-number headers and the trailing `command-rc` marker, its complete diagnostic output is byte-identical to `baseline-shellcheck.log`; the comparison command returns rc 0, proving the final test edit added or changed no warning.
- Coordinator post-B3 generated evidence in `evidence/coordinator-final-checks/summary.json`: source unchanged, snapshot equal before/after, doctor 0, verifier 0 with 97 pass/5 warn/0 fail, deny 2, CLI ACK 0, log reuse 0 with `ack_source=log` and byte-identical log, wrong-path 2, unprotected 0. The isolated rc-translation mutation returned hook 1 and caused the original exact-rc-2 assertion to fail, then the snapshot was restored and compared.
- Final real-host evidence in `evidence/claude-host-final/`: Claude Code 2.1.235 returned rc 0; initial Edit was denied, the model ran the CLI ACK, retry succeeded, the marker and ACK log exist, and production source remained unchanged. Provenance hashes match the four reviewed production files; the runner asserted generated guard/hook byte equality before launch.
- Budget results are fixture-specific. Luna's final target measured core 2,497/4,000 and on-demand 6,200/6,200; the coordinator's fresh generic target measured 2,397/4,000 and 6,100/6,200. Both doctor/verifier runs passed.

No release or host evidence remains pending. Luna's `implementation.md` is complete and `state.json` records `verification/codex` with passing verification; parent retains ownership of the subsequent resolution state and canonical final verification report.

#### Coordinator normalization of canonical review fields

The following aliases record the completed review above using the handoff
schema's canonical field names; they add no new review or identity attestation.

reviewer_model: unverified
model_source: user_explicit
fresh_session_attestation: yes (the reviewer's procedural declaration above; not proof of model, account, or host independence)
reviewed_base_commit: 45585fad41724334cd9e93d8c489f8946d9ec8c6
verdict: pass
