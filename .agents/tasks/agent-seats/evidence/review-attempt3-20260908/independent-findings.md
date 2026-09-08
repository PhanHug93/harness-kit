# Independent pass — Attempt 3

Recorded before reading `council-record.md` or `evidence/council/*`.
Target: `/Users/admin/projects/agent-bootstrap`, branch
`feature/simplify-task-relations`, HEAD `cf8f326b61788ed3ed8577eb12511613303dc44a`.
The former worktree was removed; the packet now lives in this checkout.

## Scope and results

Production seats integration is absent. The branch ships design/reference v3,
harness v2 and generator hunks, and still requests a pre-coding gate. There is
no canonical `agent-bootstrap/agent-seats.sh` or seats launcher implementation.

The unmodified harness run as uid 501 with `SEATS_QA_BASH=/bin/bash` 3.2.57:
**101 passed, 2 failed, 0 skipped**. Syntax and shellcheck pass. Old attempt-2
probes now reject invalid wizard inputs and newline transport fields, reject
incomplete legacy, and return rc 2 on a read-only roster with config committed.

Applied only the supplied generator patch plus the canonical reference copy
in a disposable kit: fresh default Astra/ultra, no fresh legacy file,
upgrade/apply-candidates with USER overlay preserved, and fresh dry-run with
no files written pass. Fresh verifier and legacy launcher status return 1:
their seats integration is explicitly still a follow-up in the build handoff.
This is an incomplete integration, not an undisclosed failure of the hunks.

## F1 — P1: init's under-lock recheck can overwrite a newly appeared file

Reference `main/init`: after waiting for the lock, parsed JSON returns 0
without validation; any parse/read error falls through to save defaults.
Probe: hold config-directory flock, start init with missing seats, publish
malformed bytes while init waits, release the lock. Init returns 0 and
overwrites those bytes. With parsed but schema-invalid JSON it returns 0 and
preserves the invalid document. Both contradict never-overwrite/validate init.
Only a second result of `missing` may reach creation. For present valid JSON,
validate before returning; for read/parse errors, refuse and preserve bytes.
Test these interleavings with an explicit held lock, including valid JSON.

Evidence: `edge-summary.json`, `init-after-lock-*.stdout`/`.stderr`.

## F2 — P2: malformed catalog entries still cause tracebacks

`validate` detects a non-object `catalog.models[id]` but the occupant walk
later calls `spec.get` on that same scalar/list. Values string/list/bool for
the referenced Astra catalog entry each produce rc 1 with AttributeError
tracebacks. Existing M1 cases mutate the outer catalog or models collection,
not an individual model object. Validate entry shape before dereferencing
it in every consumer; preserve clear errors and unchanged files.

Evidence: `model-shape-*.stderr`, `edge-summary.json`.

## F3 — P2: atomic failure tests fail before their intended boundary on Bash 3.2

R7/R8 apply `ulimit -f` before starting the shell that loads the embedded
Python via heredoc. On Bash 3.2 the temporary heredoc is subject to that limit;
the process reaches `SEATS_PY: unbound variable`, never `write_atomic`.
Do not interpret this as evidence that atomic writes themselves are broken.
Independent probes apply RLIMIT_FSIZE inside Python after code loading:
4096 bytes -> rc 2, changed config, intact AGENTS; 1024 bytes -> rc 1, both
files intact. Both expected contracts pass. Port the failure injection to the
actual write boundary, keep assertions, and retain the non-atomic mutation.

Evidence: `qa-summary.json`, `atomic-python-limit-*.stderr`, `edge-summary.json`.

## Provisional design judgment before council reconciliation

The new primary-only conflict boundary is coherent as an audit of configured
review authority, not evidence of which fallback actually performed a review.
Read-only status/doctor and auto-init only at launch are preferable to the
earlier first-status mutation. Set requiring an existing file is consistent
with explicit init. A legacy profile matching bundle defaults is a value
comparison, not proof of absence of user intent; explain the migration rule
without presenting inferred history as fact.

Verdict before reconciliation: partially_sufficient/no, fix F1-F3 before
adopting the reference and portable harness. No production edits or commit.
