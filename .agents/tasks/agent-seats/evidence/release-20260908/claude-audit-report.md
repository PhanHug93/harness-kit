**Verdict: 5 actionable findings, none blocking data preservation; 1 P2, 4 P3, plus 1 P4 note.** The seats runtime, migration precedence, atomic writes, stdout/stderr split, override precedence and primary-only conflict logic all check out against spec rev 3 in the current working tree. The R1, R2 and R3 fixes are already present there. The findings below are all source-proven unless marked otherwise.

## Findings

**F1, P2, source-proven. Doctor lost `--check-only`, so it now writes guard state and hides stale-pack failures.**
- Location: `/Users/admin/projects/agent-bootstrap/agent-bootstrap/lib/writers-docs.sh:2490`. The pre-change launcher called `codex-preflight --check-only`; the new call omits the flag.
- Trigger and result: `.codex/codex-mode.sh doctor`, or `scripts/agent-hook.sh doctor` which delegates to it at `agent-hook.sh:320-323`. Without the flag, `agent-hook.sh:311-315` runs `agent-guard.sh preflight`, which calls `write_context_pack` at `agent-guard.sh:827-831` and rewrites `.agents/state/context-pack.json`. The verifier still uses `--check-only` at `verify-ai-deps.sh:874`. Doctor therefore diverges from the verifier, is no longer read-only, and a stale context pack that `check_guard` would report is silently regenerated instead. The release plan states no guard or hook behavior changes.
- Smallest fix: insert `--check-only` before the route argument on that line. The launcher test stubs the hook, so add one assertion that doctor does not modify `.agents/state/context-pack.json`.

**F2, P3, source-proven. `status` exits 1 on a valid roster when the locked seat is host-controlled.**
- Location: `writers-docs.sh:2603-2609` calls `resolve_effective`, which returns 2 for any non-Codex occupant at `:2192-2195`.
- Trigger and result: run `scripts/agent-seats.sh set gate --host claude`, which validates cleanly, then run `status` with no lock file. The default locked seat is gate, so status prints the roster and then fails with "occupied by claude; open it in that host". The same happens for any seat reassigned to Claude, Gemini, Cursor or Windsurf after a launch persisted it. Spec line 238 expects status to report the locked seat, not refuse it.
- Smallest fix: in `run_status`, treat a return code of 2 from `resolve_effective` as informational. Print the host as the effective occupant and return 0. Keep rc 1 for invalid or unresolvable configurations.

**F3, P3, source-proven spec gap. Doctor no longer reports the locked seat's effective model and effort.**
- Location: `writers-docs.sh:2370-2382` only validates the file. Spec line 238 requires doctor to print the roster and the effective model and effort of the locked seat, which the previous launcher did.
- Smallest fix: move the `doctor_seat` computation from `:2489` above the seats block, then after `doctor_ok "seats.json is valid"` call `resolve_effective` for that seat and emit one `doctor_ok` line with tag, model, effort and source. Reuse the F2 handling for host-controlled seats.

**F4, P3, source-proven regression. Doctor dropped the unfilled project-brief warning.**
- Location: the diff removed the block at old `run_doctor` lines 1495-1500 in `audit-input.diff`; the current `run_doctor` at `writers-docs.sh:2362-2505` has no equivalent, only a file-exists check for the brief.
- Result: a project that skipped onboarding no longer sees "project brief is unfilled; run project onboarding before substantive work". No test in the repository references that string, so nothing caught the removal, and the changelog does not record it as intentional.
- Smallest fix: restore the six-line `grep -Fq '<!-- UNFILLED -->'` warn/ok block after the file loop, or document the removal if it was deliberate.

**F5, P3, source-proven. Bundle and mirror docs still say fresh targets receive `model-profiles.json`.**
- `/Users/admin/projects/agent-bootstrap/agent-bootstrap/README.md:30` describes `model-profiles/` as copied into generated targets.
- `agent-bootstrap/README.md:210-213` says model defaults are copied to `docs/agent-configs/model-profiles.json` and tells operators to update that catalog when model availability changes. That remedy is now wrong. The catalog lives in `seats.json`.
- `agent-bootstrap/README.md:217-218` and `/Users/admin/projects/agent-bootstrap/docs/agent-configs/bootstrap-multi-agent-project/README.md:251-253` say the verifier validates the model profile catalog. That check was removed in this diff.
- `docs/agent-configs/bootstrap-multi-agent-project/README.md:247` lists `model-profiles.json` under "What Bootstrap Generates".
- These contradict `MANIFEST.md:40` and the new migration sections in the same files. Smallest fix: reword those lines to name `seats.json` and describe the legacy file as migration input only.

**F6, P4, source-proven, low impact. Retired legacy candidates linger silently after upgrade.**
- A 2026.09.07.1 upgrade of a customized project left `docs/agent-configs/model-profiles.json.generated.<stamp>`, per that release's changelog entry. In this release `apply_generated_candidates` at `bootstrap-multi-agent-project.sh:867-869` skips it without a message, `pending_generated_candidate_count` excludes it, but `compute_apply_state` at `lib/render.sh:80-94` still writes `apply_state: pending` into the lock whenever any candidate file exists.
- Result: `--status --json` reports zero pending while the lock says pending indefinitely, and the orphan is never cleaned or mentioned. The migration test only asserts the orphan's bytes are untouched.
- Smallest fix: one `printf` before the `continue` at `:868` naming the skipped retired candidate, or make `compute_apply_state` consult the same allowlist.

## Verified areas with no additional findings

- Canonical script `agent-bootstrap/agent-seats.sh`: per-command argument validation exists at `:551-582`, so R2 is fixed. Catalog and occupant shapes are type-guarded and `show` validates before rendering, so R1 is fixed. The schema no longer carries `uniqueItems`, so R3 is fixed. Data commands write only values to stdout and all diagnostics go to stderr. Legacy is consulted only when `seats.json` is missing. The old-default comparison matches the shipped `codex-model-profiles.json` byte for byte.
- Launcher: override precedence, catalog default effort on override, explicit-effort validation against the effective model, fallback refusal, `@owner` refusal, non-Codex exit 2, conflict evaluated on the effective model for `@build` only, and temp cleanup before `exec` all match the spec. Older lock files without a `seat=` line fall back to the mode.
- Generator and upgrade path: `seats.json` is never written through `write_file`, so it is never a candidate or in the allowlist. `copy_target_for_diff` copies `seats.json`, so the allowlist and drift generation render the same roster as the target. Existing valid seats take the lock-free path in `init`. USER overlays go through `overlay_merge`. `docs/agent-configs/` is wholly gitignored and local-only.
- Tests reach production: the seats harness copies the bundle script into the fixture, the launcher suite generates through the production entrypoint and checks drift against the canonical file, and CI now runs all three shell suites with full history.

## Attestation, scope and evidence limits

- fresh_session_attestation: yes. Fresh CLI session, read-only, no shell commands, no delegation, no files written.
- Reviewer model: claude-fable-5-1, as reported by this session's runtime.
- Base and scope: branch `feature/simplify-task-relations`, base `cf8f326` per `starting-state.json`. Reviewed the full `audit-input.diff`, the untracked `agent-seats.sh` and `agent-seats-v1.schema.json`, current `writers-docs.sh` launcher heredoc, `writers-runtime.sh` seats wiring, `verify-ai-deps.sh`, `core.sh`, `render.sh`, `agent-hook.sh`, `agent-guard.sh` preflight, the bootstrap entrypoint candidate logic, the three Python suites, the three shell suites in the diff, CI workflow, root and bundle READMEs, MANIFEST, CHANGELOG and the docs mirror.
- The audit-input hash for `agent-seats.sh` differs from the runtime-review hash, and I could not compute hashes. Findings reference the working tree as read this session.
- No tests were executed. Launcher mutation evidence exists in `launcher-results.json`, but the suite invocation in the bootstrap test omits `--mutations`, so CI does not re-run them.
- The migration test needs tags `v2026.08.10.1` and `v2026.09.07.1`. Both exist locally. Whether they are on the remote for CI was not verified.
- Not reported as new: the `$BASH_SOURCE` spelling at `writers-docs.sh:1863`, `@owner` prose, and multiword effort handling, per the known in-progress list.
