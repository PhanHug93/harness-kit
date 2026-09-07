# Seat B (QC — adversarial validation) — round 1

## Confirmed gate findings
- R2 — model `custom\n` / effort `high\n` / claude-seat `model:"info\nmodel"` / orphan `fallback_effort:"high\nxhigh"` → validate rc 0; `resolve gate` → 9 lines. Claude seat with effort/fallback garbage → validate 0, `resolve spec` → 10 lines (non-codex keys never validated).
- R3 — PTY `99` at host → rc 0, "(unknown choice, keeping suggestion)", config written; model `99`, fallback `99`, fallback by name → rc 0 and write.
- R4 — `chmod 444 AGENTS.md; su nobody -c 'set build --effort high'` → PermissionError traceback, rc 1, seats.json changed, no "NOT rendered".

## New findings
1. P1 — in-place truncating writes destroy AGENTS.md / seats.json on write failure: `(ulimit -f 4; set build --effort high)` → OSError, rc 1, AGENTS.md cut 6482→4096 bytes (USER overlays gone); `ulimit -f 1` → seats.json truncated to 1024 bytes → every command "malformed JSON". (`render`, `save`)
2. P2 — no locking: 40 trials of concurrent `set spec --host gemini & set audit --host cursor` → 9 silent lost updates; readers see zero-length files (spurious malformed JSON 1/200). Launcher reads this file at every launch.
3. P2 — tracebacks on parseable-but-malformed documents: `catalog=["x"]` → AttributeError; `seats.gate="x"` / `occupant=[]` / `occupant=None` → AttributeError at the sharing check; top-level `[]` or missing seat → `show` TypeError/KeyError (roster printed before validation); `conflict build x` with gate missing → KeyError; `model-info` on `[]` → TypeError.
4. P2 — `set` silently accepts unknown/contradictory/inapplicable options and reports success: `--efort high` rc 0; `--host=claude` rc 0 host unchanged; `set spec --host claude --model X` drops model without warning; `--no-fallback --fallback-model X` drops fallback; `--fallback-effort max` with no fallback ignored; `--host ""` keeps previous host.
5. P2 — `set` cannot repair an invalid file; guidance circular (`set/reset` → `set` refuses; only `reset` works, discarding customizations).
6. P2 — wizard KeyError 'duty' on a seats.json shaped like the spec's own Data-model example (no `duty`).
7. P3 — wizard cannot be aborted: Ctrl-D = keep suggestion (17× Ctrl-D writes and renders); Ctrl-C → raw KeyboardInterrupt traceback.
8. P3 — catalog without a codex model + host `2` → IndexError; bundle default absent from catalog → offered anyway, Enter → rejected rc 1.
9. P3 — save/render OSErrors are tracebacks: seats.json is a directory → IsADirectoryError; unwritable dir → PermissionError; AGENTS.md is a directory → "is missing".
10. P3 — duplicate efforts accepted; UTF-8 BOM in hand-edited file → malformed JSON.

## Fix proposals (all applied in /tmp/council/targets/seatB/agent-seats.patched.sh, patch.diff; harness 38/38; every probe re-run fails closed)
- R2/#10: `fullmatch`; validate grammar for every occupant key for any host; reject `fallback_effort` without `fallback_model`; distinct efforts.
- R3/#7/#8: `pick_number()` + host check raise on non-empty out-of-set input; `ask` raises on EOF; `except KeyboardInterrupt` → message rc 130; no-codex-catalog error; seed from catalog when default absent.
- R4/#1/#9: `write_atomic()` (temp + `os.replace`, mode preserved) for save/render; save OSError → rc 1 "nothing written"; `write_and_render` catches Exception → rc 2.
- #2: `lock_for_write()` (`flock` on `.seats.json.lock`) for set/wizard/init/reset/render.
- #3: `structural_errors()`; validate guards types; `show` prints roster only when structure sound; `model-info`/`conflict` check structure.
- #4: `SET_OPTIONS` whitelist, non-empty values, conflicts, inapplicable options → rc 1.
- #5: `proposal(repairing=True)` in `set` accepts a structurally sound invalid file (errors as warnings) and validates the result.
- #6: `entry.get('duty') or SEAT_META[seat]['duty']`.

## Non-findings
TAB/CR in model, `codex\n` host, tag with TAB, non-string host/effort/default_effort, empty strings, unicode/space model via `set` → rc 1. `set @owner --host codex` rc 1. `@planning`/`@@gate` resolve (lenient); `GATE` rc 1. `conflict` unknown seat rc 1. AGENTS.md symlink written through and preserved; non-UTF-8 bytes preserved; 2 MB line OK; END-before-BEGIN rc 3; empty file OK; missing → render rc 1, reset rc 2. `init` with AGENTS.md missing rc 0; python3 absent → "python3 is required" rc 1; `LC_ALL=C` fine.
Notes: `set` on a target with no seats.json silently migrates the generator-created legacy (R1); `set` drops unknown occupant keys; `reset`/`wizard --yes` print no sharing warnings; `set spec --host human` allowed while wizard offers no `human`; fallback == primary accepted; script via symlink resolves the wrong project root.
