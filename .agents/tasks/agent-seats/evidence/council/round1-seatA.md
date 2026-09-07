# Seat A (Dev Lead — architecture & lifecycle) — round 1

## Position

Order (full workflow), replacing entrypoint `:1069-1073`:
1. `write_agent_seats` — `copy_bundle_file agent-seats.sh` + `make_executable` (pattern of `write_agent_guard`, writers-runtime.sh:324-327). New file → live write; existing → candidate (core.sh:156-167).
2. `seed_agent_seats` — run the bundle's `$BUNDLE_DIR/agent-seats.sh init` with `AGENT_SEATS_FILE/_LEGACY_PROFILES/_AGENTS_MD` pointed at the target, never the target's live copy. Skip on `--dry-run`; on failure log guidance and continue. `seats.json` is user data: created once, never via `write_file`, so it never enters the write log/allowlist.
3. `write_agent_docs` — `roster="$(seats_program roster-block 2>/dev/null)" || roster=<generator-owned "roster unavailable" block>`; embed under `## Seat Roster`. Candidates carry the embedded MANAGED block; `render` is never called by the generator.
4. Everything else unchanged. Fresh: defaults (Astra/ultra). Upgrade: `seats.json` written live once; `AGENTS.md` preserved + candidate with roster; `--apply-candidates` runs no script; `--diff/--status` regenerate in a temp copy — `init` there is harmless. `--force/--skip-existing`: `seats.json` untouched.

Legacy file: a fresh target must NOT get `model-profiles.json`. Emitting it (writers-runtime.sh:212-216) either feeds `init` Sol/xhigh or, with `init` first, produces a permanent "legacy coexists" WARN on every fresh target. Bundle keeps `model-profiles/` + schema for one release; the verifier's four hard dependencies become conditional.

Valid legacy profile (one function shared by suggest/wizard/init/launcher auto-seed) = exactly what the old launcher accepted (writers-docs.sh:1938-1991): object, `schema` const, `default_profile` non-empty, `profiles[default_profile]` object, all 7 required keys present as non-empty strings, six model ids fullmatch the model grammar, `reasoning_effort ∈ {none,low,medium,high,xhigh,max}`. Optional `<route>_reasoning_effort` keys must fullmatch the effort grammar (catalog-appended with a note). Anything else is malformed: `init`/`suggest`/`wizard` exit 1 and write nothing; `reset` writes defaults; a valid `seats.json` never consults legacy. Additionally: a legacy profile equal to the bundle default carries no user decision → seat defaults + note.

## Evidence (short)
- Pristine fresh target + reference: `roster-block` → rc 1; `init` → `@gate gpt-5.6-sol @ xhigh`, catalog gains `gpt-5.6-sol`. Reproduces gate's `end-of-fresh-generation-init`.
- Incomplete legacy (`reasoning_effort` only): old launcher `status` → rc 1 `missing required field 'planning_model'`; reference `init` → rc 0 "created from legacy" with defaults.
- Patched scratch bundle (/tmp/council/targets/seatA/bundle, 3 hunks): `--dry-run` on empty dir → rc 0, 0 files; fresh → Astra/ultra, roster embedded, `validate` rc 0, `render` "already current", `seats.json` absent from write log; upgrade of pristine target → `seats.json` live, live `AGENTS.md` untouched, candidate has roster + overlay marker; `--status/--diff` create nothing live; `--apply-candidates` → roster live, overlay intact; `--force`/`--skip-existing` → `seats.json` byte-identical.
- Rule patch (40 lines): untouched default → Astra + note; customized (`custom-planner`, `low`) → migrated; fixtures test:2157/2162/2167 → rc 1, no file; `{oops` legacy does not block `set`.
- Verifier on a target without legacy: 5 FAIL lines (writers-runtime.sh:1092-1139, :1397, :1418-1422, :1437); `agent-hook.sh doctor` fails via the old launcher.
- `git check-ignore scripts/agent-seats.sh` → not ignored; lists at render.sh:231-240 and agent-local-only-check.sh:68-78 omit the script.
- Harness: 38/38 only on a pristine target (check 1 asserts "created from legacy" — migrating Sol); 37/38 on a target without legacy. The harness enshrines R1.
- Pure defaults: `validate` → 2 warnings (Terra fallback shared); `conflict build gpt-5.6-terra` → `1`.

## Proposed changes
1. P1 entrypoint `:1069-1073` — order above; add entrypoint to boundaries.
2. P1 writers-runtime — `write_agent_seats`, `seats_program` (bundle script + env), `seed_agent_seats` (dry-run skip, non-fatal).
3. P1 writers-docs `:746-748, 839-847` — embed `roster-block` with fallback text.
4. P1 writers-runtime `:212-216` remove legacy copy; verifier sites conditional (present → validate + WARN); update tests `:1402,1882,2068,2395,3487-3518`, MANIFEST:39.
5. P1 render.sh `:231-240`, agent-local-only-check.sh `:68-78` add `scripts/agent-seats.sh`.
6. P1 `migrate_legacy` — acceptance rule above (fullmatch, no route skipping).
7. P2 untouched-default rule; `init` labels source `defaults`.
8. P2 harness check 1 uses an explicit customized fixture.
9. P2 docs: spec "end of generation" → "before the AGENTS.md writer"; handoff:35 contradicts :102-104; AC11 "first status seeds" — keep `status` read-only, auto-seed only on launch commands.
10. P3 defaults not warning-clean (Terra fallback shared) → every `CODEX_USE_FALLBACK=1 @build` launch carries `gate_coding`. Decide (exclude fallback↔fallback or change defaults).
11. P3 `init` prints warnings on an existing valid file → leaks into `--status/--diff`; warn only when writing.

## Confidence
Ordering/dry-run/candidate/apply: high. Stop emitting legacy: high on necessity. Untouched-default rule: medium. Acceptance rule: high. Local-only omission: high. Warning-noise remedy: medium.
