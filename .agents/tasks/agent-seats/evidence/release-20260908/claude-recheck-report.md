**Recheck verdict: all six findings are resolved in the current source. No remaining source-proven defect in the rechecked scope. Baseline launch-prompt restrictions and the severity rule are present verbatim.**

Status by finding, verified in the actual files, not only the excerpt:

- **F1 fixed.** `writers-docs.sh:2473` now calls `codex-preflight --check-only`. The bootstrap suite compares the real context-pack bytes around a doctor run at test lines 2350-2352 and asserts no pack is created at 2519-2522. The launcher suite also checks the flag and the bytes in `test_doctor_and_non_codex_status`.
- **F2 fixed.** `resolve_effective` returns 2 silently for a host-controlled occupant at `:2153`. `run_status` at `:2592-2597` prints the locked host and returns 0. Only `run_launch` at `:2616-2618` prints the refusal and exits 2. The new launcher group asserts rc 0, the host line, and no `ERROR:` on stderr for status and doctor.
- **F3 fixed.** Doctor at `:2339-2352` prints the roster through `show`, then one line with the locked seat's model, effort and source, or the host line for a non-Codex seat.
- **F4 fixed, and my earlier note corrected.** The unfilled-brief block is back at `:2401-2406`. The bootstrap suite did already assert that warning at test line 2368. My original grep missed it because of a malformed exclusion glob. The coverage claim in my first report was wrong.
- **F5 fixed.** Bundle README lines 30-31, 211-215 and 219-220 and the docs mirror lines 247-248 and 252-253 now describe `seats.json` as the catalog and the legacy file as migration input. A repo-wide search for the old wording matches only changelog history and my own report.
- **F6 addressed.** `lib/render.sh:89` excludes exactly the retired legacy base from `apply_state`, so the lock no longer reports pending for that orphan. Candidate counting and application were already allowlist-driven and are unchanged. The orphan file is still skipped without a message, which matches the coordinator's decision to keep existing behavior for every other candidate. I accept that as P4 by design.

Baseline prompt check, `writers-docs.sh:2304-2315`:

- All six route and flow prompts carry the pre-migration scope and approval sentences unchanged. Supervised flows say read-only and no mutation without an exact grant. Full flows require exact approval for external paths, installs, commits, pushes, force operations and local-only permission changes. Reviewing full flow keeps the mutating-git clause.
- Both reviewing prompts contain the severity rule and the verdict-first, no-preamble and hedging obligations word for word.
- One difference from baseline, informational only: the old coding seed appended a sentence telling the session to record `escalation_reason` in the implementation log when the audit token applied. The spec-defined seed does not include it, and the handoff prose still requires the reason, so I do not count it as a defect.

Prose and assertions: `need_contains` normalizes whitespace at test lines 40-50, so the shortened handoff text with wrapped lines still satisfies the single-line assertions. The handoff excerpt keeps the required fields, the five mapping examples marked as partial states, the linked-artifact allowance, the review gates and the `sol_coding` alias.

Provenance and limits:

- Reviewer model: claude-fable-5-1, taken from this session's runtime. This is a continuation of the same @audit session, so no fresh-session attestation is claimed. I authored the earlier findings, wrote no fixes, ran no commands and did not delegate. The implementation and its tests were written by the coordinator and workers.
- I could not compute the SHA256 values listed in the recheck input. Every line I relied on was read from the working tree directly and matches the excerpt.
- No tests were executed by me. The coordinator's suite counts and mutation results are reported evidence, not verified here.
