# Independent post-review

reviewer_role: Sol
reviewer_model: gpt-5.6-sol
model_source: user_explicit
fresh_reviewer_session: true (procedural declaration only; not proof of host, account, or model independence)
reviewed_branch: feature/simplify-task-relations
baseline_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
reviewed_target: current uncommitted diff against baseline HEAD

## Verdicts

- Specification compliance: **reject** — 2 blocking B3 defects.
- Code quality: **not reached** because specification compliance did not pass; no separate quality-only finding is issued.

## Findings

### B3 blocker 1 — Claude hook corrupts LF-bearing paths before guard validation

Trigger: Claude sends Edit/Write JSON whose `file_path` contains an LF. The generated parser writes the raw path as a tab-separated physical line (`agent-bootstrap/lib/writers-runtime.sh:547-569`; snapshot `agent-bootstrap/agent-hook.sh:212-234`), and `claude_pretool` reads only the first physical line (`writers-runtime.sh:607-610`; snapshot `agent-hook.sh:272-275`). A trailing LF is also stripped by command substitution in `canonical_project_relpath` (`agent-bootstrap/agent-guard.sh:256-259`).

Impact: the guard validates and logs a truncated alias while Claude executes the original path. With `AGENT_GUARD_EDIT_ACK`, an LF-bearing protected edit can be allowed while a reusable ACK is appended for a different delimiter-free path, violating revision 1 B3's requirement that delimiter-bearing paths authorize only the current invocation and never append or reuse a record.

Evidence: a fresh probe using the production parser's print/read protocol produced `original=$'/project/docs/agent-configs/A\nB.md'`, `parsed=/project/docs/agent-configs/A`, `equal=false`. Internal CR and TAB survived that probe, but the same line protocol also strips a trailing IFS tab; B3 covers CR/LF/TAB as a class.

Required correction/test: transport the JSON path losslessly into the guard and preserve delimiter bytes through canonicalization. Add a generated-hook JSON regression for delimiter-bearing protected paths: explicit ACK permits that invocation, the ACK log bytes do not change, and retry without explicit ACK denies. Cover LF and trailing TAB at minimum, plus CR to bind the full stated contract. Regenerate and compare the hook snapshot.

### B3 blocker 2 — Injection test does not prove the escaped ACK row is reusable for A

Trigger: the injection case first seeds an independent fresh ACK row for A (`scripts/test-bootstrap-multi-agent-project.sh:248`), appends the injected ACK (`:250-255`), then checks only that B is denied (`:256-258`).

Impact: an implementation that appends one physical but malformed/non-reusable row for the injected ACK still passes. The required “A reuses correctly; B still denies” fixed-TSV contract is therefore not bound to the row produced by the writer.

Required correction/test: start the injection case with an empty ACK log, require the explicit ACK to add exactly one physical row, then invoke A without an explicit ACK and require rc 0 with `ack_source=log`; finally invoke B and require rc 2.

## Reviewed source hashes

| File | SHA-256 |
|---|---|
| `agent-bootstrap/agent-guard.sh` | `8d1074fbc12fa9028382676b985d652945eb1088424ef6e9d51b276268b6cb63` |
| `agent-bootstrap/agent-hook.sh` | `2d2d046b85db5249c671b62162172b05210f63444c3886da817ef0cab85db88c` |
| `agent-bootstrap/lib/writers-runtime.sh` | `9e6088647a35a15e7d40a7300491e1c9b7df837f3d3ad70398450c94b6d61bc5` |
| `agent-bootstrap/lib/writers-docs.sh` | `08f7b31e060ba50b9ddf9432d40fee0757ff2176b44a4f270d89bebf6d0131a2` |
| `scripts/test-bootstrap-multi-agent-project.sh` | `a5e2deb52aaaad601924acc9a78c1ff23dfdd88b7e2b75b47cb6c932912bf860` |
| `CHANGELOG.md` | `b9b56cc2484d83eca97d1bac6b8f66a078ead048dcf7e6e33c9975c582cf867e` |

The tracked diff contains exactly the six authorized files. `git diff --check HEAD` returned rc 0.

## Validation and pending evidence

- Fresh reviewer validation: the packet's original guard/hook shellcheck command returned rc 0 on the guard/hook hashes above. The LF transport probe above reproduced the first blocker. The focused runner was launched, but its final rc was not captured by the reviewer session, so no fresh focused-pass claim is made.
- Luna evidence at the unchanged guard/hook/runtime/test hashes records focused GREEN rc 0, snapshot comparison rc 0, generated doctor/verifier rc 0, required smoke rc values, and a structurally valid rc-translation mutation result (mutated hook rc 1 makes the exact rc 2 assertion fail).
- Coordinator Claude Code host acceptance passed: initial Edit denied, CLI ACK ran, retry succeeded. `claude-host-provenance.json` hashes exactly match the three reviewed production guard/hook/runtime hashes above. This is coordinator-executed evidence and was not rerun here.
- Release evidence: onboarding and one-shot suites record rc 0. The bootstrap suite records rc 1 because its generated on-demand context was 6,231 tokens, over the 6,200 gate. `writers-docs.sh` was then compacted to the hash above while preserving the general pre-edit guidance, exit 2, exact-path reuse, TTL variable, and one-hour default. A bootstrap-suite rerun and measured post-correction budget are still pending; the failed pre-correction result cannot verify the current docs hash.
- Broader shellcheck evidence contains only the established SC2016/SC2030/SC2031/SC2163 diagnostics in the test script; comparison to baseline changes line locations only.
