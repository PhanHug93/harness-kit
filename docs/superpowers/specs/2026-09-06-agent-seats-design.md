# Agent Seats Design

Date: 2026-09-06 (revision 1: 2026-09-07 after `@gate` attempt 1; revision 2: 2026-09-07 after `@gate` attempt 2 and a three-seat council, see packet `council-record.md`; revision 3: 2026-09-08 after `@gate` attempt 3, findings F1-F3)
Status: implemented and locally verified on 2026-09-08 for release 2026.09.08.1 after `@gate` attempt 4 (`sufficient/yes`). See packet `agent-seats/verification.md`; remote CI and publication follow the release commit.
Branch: `feature/simplify-task-relations`
Base: `main` at `cf8f326` (release 2026.09.07.1; the guard packet has landed; stderr isolation is included in the combined seats implementation).

## Decision

Separate the **seat** (a role in the collaboration protocol, identified by a
fixed tag) from the **occupant** (host, model, effort, fallback — dynamic,
changed at any time without regenerating the target). Generated contracts,
launcher seeds, commands, and READMEs name seats only by tag. Model and host
names live in one runtime-read file, `docs/agent-configs/seats.json`, managed
by a generated script, `scripts/agent-seats.sh`.

| Seat | Tag | Phase | Duty | Default occupant |
|---|---|---|---|---|
| spec | `@spec` | analysis | analysis and specification | claude |
| gate | `@gate` | technical_review | blocking adequacy verdict before coding | codex `gpt-6-astra` @ `ultra`, fallback `gpt-5.6-terra` @ `xhigh` |
| build | `@build` | implementation | bounded implementation | codex `gpt-5.6-luna` @ `xhigh`, fallback `gpt-5.6-terra` @ `xhigh` |
| verify | `@verify` | verification | final technical review | codex `gpt-6-astra` @ `ultra`, fallback `gpt-5.6-terra` @ `xhigh` |
| audit | `@audit` | cross_review | independent cross-review | claude |
| owner | `@owner` | resolution | final decision | human |

Tags and phases are protocol constants: the state machine, tests, and prose
depend on them. Users change occupants, never tags.

## Goals

1. Remove model and host names from every generated instruction surface so a
   model change is a data edit, not a prose-and-test change. "Role words" are
   `Sol`, `Luna`, `Astra` used as a role; model ids in `seats.json`, the
   rendered roster, and host integration names (`Claude`, `Codex`, `Gemini`,
   `Cursor`, `Windsurf`) are not role words.
2. Let the user assign any host or model to any seat at any time, validated
   against a capability catalog (which efforts each model supports).
3. Keep the launcher deterministic: seat → occupant → exact `--model` and
   `model_reasoning_effort`, with today's override precedence, and a lossless
   interface between the seats script and the launcher.
4. Keep existing packets, `state.json` v1, and legacy `model-profiles.json`
   targets working through one release, with an explicit configuration
   lifecycle (fresh, upgrade, existing, malformed, reset, regenerate).

## Non-goals and complexity budget

This change does not add:

- user-renamable tags or display labels for seats;
- launching non-Codex hosts from the launcher (Claude, Gemini, Cursor,
  Windsurf remain host-controlled);
- active-packet or phase resolution in the launcher (separate packet);
- tracking `seats.json` in Git (belongs to the local-only policy split);
- a second configuration file for models: `model-profiles.json` becomes a
  legacy migration input for one release and is then removed;
- automatic model discovery or availability probing;
- a runtime state-machine validator for packets (conventions stay conventions);
- a VERSION or MANIFEST version bump (release commit).

## Data model — `docs/agent-configs/seats.json` (`agent-seats/v1`)

```json
{
  "schema": "agent-seats/v1",
  "catalog": {
    "models": {
      "gpt-6-astra":   { "host": "codex", "efforts": ["none", "low", "medium", "high", "xhigh", "ultra"], "default_effort": "ultra" },
      "gpt-5.6-luna":  { "host": "codex", "efforts": ["none", "low", "medium", "high", "xhigh", "max"],   "default_effort": "xhigh" },
      "gpt-5.6-terra": { "host": "codex", "efforts": ["none", "low", "medium", "high", "xhigh", "max"],   "default_effort": "xhigh" }
    }
  },
  "seats": {
    "gate":  { "tag": "@gate",  "phase": "technical_review",
               "occupant": { "host": "codex", "model": "gpt-6-astra", "effort": "ultra",
                             "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh" } },
    "spec":  { "tag": "@spec",  "phase": "analysis",   "occupant": { "host": "claude" } },
    "owner": { "tag": "@owner", "phase": "resolution", "occupant": { "host": "human" } }
  }
}
```

Rules:

- Grammar (B2): model ids match `^[A-Za-z0-9][A-Za-z0-9._:/-]*$`; efforts match
  `^[a-z][a-z0-9_-]*$`. Validation rejects anything else, so values can never
  carry whitespace or delimiters into launcher interfaces.
- `catalog.models[*].efforts` is the capability list; `default_effort` must be
  one of them. Adding a model or an effort is a JSON edit. Bundle defaults list
  the launcher's legacy effort set for `luna`/`terra` and `ultra` for `astra`.
- Hosts: `claude | codex | gemini | cursor | windsurf | human`. Only `codex`
  occupants are launchable; other hosts carry no model (a model there is
  informational and produces a warning).
- A `codex` occupant requires `model` and `effort` in the catalog; `fallback_*`
  is optional. Missing fallback is warned, and a `CODEX_USE_FALLBACK=1` launch
  for that seat is refused with an error (no launch).
- `@owner` must be `human`.
- Validation errors: grammar violation, unknown model, a catalog entry that is
  not an object, host mismatch between seat and catalog, effort not in the
  model's list, missing tag/phase constants, non-human owner. Warnings: `@gate`
  or `@verify` shares its **primary** model with `@build` (fallbacks are
  capacity substitutes, not the review authority: council decision 1, confirmed
  by `@gate` attempt 3). A hand-edited catalog may hold a string, list or
  boolean where a model object belongs; every command reports that as an error
  and keeps the file, never a traceback.
- `seats.json` is local-only under the current policy and may be edited by
  hand; the script is the supported path and re-renders the roster.

## Configuration lifecycle (B3, R1)

Legacy `model-profiles.json` is consulted **only when `seats.json` is
missing**. A valid `seats.json` is always the effective configuration.

| Situation | `suggest` | `wizard [--yes]` | `init` (generator, launcher auto-seed) | `set` | `reset` |
|---|---|---|---|---|---|
| no seats, no legacy | defaults | writes defaults | writes defaults | rc 1: run `init` | writes defaults |
| no seats, valid customized legacy | migrated proposal + notes | writes migrated | writes migrated (`created from legacy`) | rc 1: run `init` | writes defaults |
| no seats, legacy equal to the old generator default (no `*_reasoning_effort` keys) | defaults + note | writes defaults | writes defaults (`created from defaults`) | rc 1 | writes defaults |
| no seats, invalid legacy (missing v1 key, bad grammar, effort outside the old set) | rc 1, guidance | rc 1, nothing written | rc 1, nothing written | rc 1 | writes defaults |
| no seats, malformed legacy JSON | rc 1 | rc 1, nothing written | rc 1, nothing written | rc 1 | writes defaults |
| valid seats (legacy ignored, even malformed) | current roster | starts from current | keeps file; no lock, no write | changes one seat | writes defaults (explicit) |
| structurally sound but invalid seats | rc 1 | rc 1 | rc 1, no overwrite | may repair the seat; validates result | writes defaults |
| malformed seats JSON | rc 1: fix or `reset` | rc 1 | rc 1, no overwrite | rc 1 | writes defaults (explicit repair) |
| regenerate / `--apply-candidates` / `--force` / `--skip-existing` | — | — | `init` only: existing seats untouched | — | — |
| seats.json appears while `init` waits for the lock | — | — | recheck under the lock: valid → rc 0 no write; invalid or malformed → rc 1, bytes kept | — | — |

Acceptance of a legacy profile mirrors the old launcher: object with
`schema: agent-model-profiles/v1`, a `default_profile` naming an object, all
seven v1 keys present as non-empty strings, six model ids in the model grammar,
`reasoning_effort` in `none low medium high xhigh max`, optional
`<route>_reasoning_effort` / `<route>_fallback_reasoning_effort` in the effort
grammar. Migration never writes an invalid document: an unknown model is added
to the catalog (`host: codex`, efforts = the old set, default = the declared
effort); a declared effort missing from a known model's list is appended with
a note. Every write path validates before writing; `reset` uses bundle
defaults only.

Generator integration (reference hunks in `evidence/reference-generator-hunks.patch`):

1. `write_agent_seats` copies the script (`copy_bundle_file`, executable).
2. `seed_agent_seats` runs the **bundle's** `agent-seats.sh init` with
   `AGENT_SEATS_FILE`, `AGENT_SEATS_LEGACY_PROFILES`, `AGENT_SEATS_AGENTS_MD`
   pointing at the target; skipped on `--dry-run`; non-fatal (a warning names
   the remedy). `init` never prompts and takes no lock when the file exists.
3. The `AGENTS.md` writer embeds `roster-block` output (fallback text when the
   roster is unavailable), so candidates carry the roster and the generator
   never calls `render`.
4. The generator stops emitting `model-profiles.json`; a fresh target has no
   legacy file. Verifier and doctor treat the legacy file as optional (validate
   and warn `seats.json is authoritative` when present). `seats.json` is user
   data: never a generated file, never a candidate, never in the write log.
5. `scripts/agent-seats.sh` joins the gitignore block and the local-only list;
   installer `copy_file` and MANIFEST rows ship the script and schema.

## Script — `scripts/agent-seats.sh`

Generated runtime file (canonical source `agent-bootstrap/agent-seats.sh`,
copied with `copy_bundle_file` like `agent-guard.sh`; no heredoc copy).
Bash 3.2 dispatcher; one python3 program passed with `python3 -c` so the
process keeps the caller's stdin (B1: a real terminal stays interactive).

| Command | Behavior |
|---|---|
| `suggest` | Read-only proposal per the lifecycle table. |
| `wizard [--yes]` | Interactive on a TTY: per seat, show the suggestion, pick host and model by number, effort, fallback (`none` drops it); Enter keeps the suggestion; re-choosing the current host keeps the suggested model; an invalid choice exits 1 without writing. `--yes` or no TTY accepts every suggestion. Writes, then renders. |
| `set <seat\|route> --host … [--model … --effort …] [--fallback-model … --fallback-effort …] [--no-fallback]` | Non-interactive change; unknown, empty, contradictory or inapplicable options are refused (rc 1, nothing written); never creates the file; may repair a structurally sound invalid file; validates, writes, renders. |
| `init` | Create `seats.json` once (lifecycle table); never overwrites, never prompts, takes the lock only to create. The lock-free fast path and the recheck under the lock apply the **same** rules: only a `missing` result may create the file; a file that appeared during the wait is validated like any other, so valid means rc 0 and no write, invalid or malformed means rc 1 with its bytes kept (`@gate` attempt 3, F1). |
| `reset` | Bundle defaults; validates; writes; renders. |
| `show` / `validate` | Read-only roster plus warnings; `validate` exits 1 on errors. |
| `render` | Replace exactly one balanced roster block in `AGENTS.md` or append one (B6 contract below). |
| `roster-block` | Print the block text (for generators). |
| `resolve <seat\|route>` | Eight lines, one field per line, empty fields preserved: `seat`, `tag`, `phase`, `host`, `model`, `effort`, `fallback_model`, `fallback_effort`. Diagnostics on stderr only. |
| `model-info <model>` | Three lines: `host`, `default_effort`, `efforts` (space-separated); unknown model exits 1 with guidance. |
| `conflict <seat\|route> <effective-model>` | Prints `1` when the seat is `@build` and the effective model equals the **primary** model of a Codex `@gate` or `@verify`; else `0`. Fallback models are capacity substitutes, not the review authority (council decision 1). |

Exit codes: 0 ok; 1 invalid input, refused (lock busy, end of input,
unwritable, unknown option) or usage — nothing written; 2 `seats.json` written
but the roster was not rendered (message names the cause); 3 roster markers
unbalanced, nothing written; 130 interrupted (the message says whether
`seats.json` was already written; then run `render`).

Writes are atomic: a sibling temporary file, `fsync`, then `os.replace` onto
the real path (symlinks are written through). A failed write leaves the old
bytes. Writers take a non-blocking `flock` on the configuration directory with
a 10 s bounded wait (rc 1 `another agent-seats write is in progress`); readers
never block; filesystems without `flock` degrade to a warning. Malformed or
mis-shaped documents produce an `ERROR:` line and rc 1, never a traceback.
Duplicate catalog efforts are a warning; a UTF-8 BOM is accepted.

Route aliases `planning`, `coding`, `reviewing` map to `@gate`, `@build`,
`@verify` for backward compatibility.

## Roster rendering contract (B6)

- `AGENTS.md` is processed as bytes; the file's newline convention (`\r\n`
  when present) is used for the block; every byte outside the block is
  preserved.
- Exactly one `BEGIN`/`END` pair with `BEGIN` before `END` is replaced. Zero
  markers: append `## Seat Roster` and the block after the existing content
  without altering it. Any other count or order: exit 3, file untouched, with
  a message to repair the markers by hand.
- `set`, `wizard`, `reset` write `seats.json` first; if rendering fails for
  any reason (markers, permissions, disk) they exit 2 and say that the
  configuration is effective but the roster is stale.
- Rendering is idempotent.

## Launcher — generated `.codex/codex-mode.sh`

- Accepts any seat (`@spec @gate @build @verify @audit`) or route alias whose
  occupant host is `codex`; `@owner` is never launchable. A non-Codex occupant
  exits 2 with `seat @gate is occupied by claude; open it in that host`.
- Reads `resolve` with a line reader (`while IFS= read -r`) and checks that
  exactly eight lines arrived; any other count is an interface error (no launch).
- Model precedence is unchanged: `CODEX_MODEL_OVERRIDE` → route-named override
  (`CODEX_PLANNING_MODEL_OVERRIDE` etc., kept for compatibility) →
  `CODEX_USE_FALLBACK=1` → `occupant.model`. `CODEX_USE_FALLBACK=1` on a seat
  without a fallback is an error.
- Effort: explicit `CODEX_REASONING_EFFORT` wins and must appear in the
  effective model's `model-info` efforts (otherwise an error naming the
  supported efforts and the catalog remedy); default launch uses
  `occupant.effort`; fallback uses `occupant.fallback_effort`; a model
  override uses the `default_effort` from `model-info` (a model outside the
  catalog is an error).
- Audit (B5): after precedence, the launcher asks
  `conflict <seat> <effective-model>` (primary models of `@gate`/`@verify`); `1` adds
  `policy_exception=gate_coding authorization=user_session` to seed and
  summary. `authorization=user_session` is the declaration that the user
  opened this session knowingly; the flag proves nothing by itself. Readers
  accept the legacy value `sol_coding` for one release; history is not rewritten.
- Seed: `SEAT LOCK: @build · phase implementation · launch_model=<effective>
  model_source=<default|CODEX_USE_FALLBACK|override-variable>`. The seed never
  labels a value `actual_model`; the served model is host-confirmed only.
- Missing `seats.json` (decision 2, amended by the council): only the launch
  commands (`planning|coding|reviewing|run`, which share one launch boundary)
  run `init` once with a notice and continue; `status`, `doctor` and the
  verifier are read-only (WARN when missing, FAIL when invalid, WARN when a
  legacy profile coexists: `seats.json is authoritative`). When migration
  fails, the launch fails with guidance.
- `status` and `doctor` print the roster and the effective model/effort of
  the locked seat. `CODEX_MODEL_PROFILE` becomes a warning no-op for one release.
- The python program in the seats script writes only data to stdout;
  diagnostics stay on stderr (the stderr-isolation requirement of packet
  `codex-profile-stderr-isolation` holds here by construction).

## Packet mapping (B4)

- `seat` (tag) is derived from `phase` when absent (`analysis→@spec`,
  `technical_review→@gate`, `implementation→@build`, `verification→@verify`,
  `cross_review→@audit`, `resolution→@owner`); packets without `seat` stay valid.
- `owner` keeps its v1 values and gains one: `claude | codex | user | agent`.
  It is the host class of the seat's occupant: `claude`→`claude`,
  `codex`→`codex`, `human`→`user`, any other host→`agent`. When `owner` is
  `agent`, the packet records `"occupant": {"host": "gemini"}` beside it.
- `verification.runner` gains `agent` the same way, with `runner_host` when
  `agent`. `none`, `claude`, `codex` keep their meaning.
- Review artifacts add `seat:` and keep `reviewer_model` / `model_source`;
  `launch_model` from the seed may be recorded as the requested model.
- Transitions are by seat and unchanged; the launcher supports exactly the
  Codex occupants of `@spec`, `@gate`, `@build`, `@verify`, `@audit`.

Examples (`state.json` fragments):

```json
{"phase": "technical_review", "seat": "@gate", "owner": "codex"}
{"phase": "analysis", "seat": "@spec", "owner": "codex"}
{"phase": "technical_review", "seat": "@gate", "owner": "claude"}
{"phase": "technical_review", "seat": "@gate", "owner": "agent", "occupant": {"host": "gemini"}}
{"phase": "verification", "seat": "@verify", "owner": "agent", "occupant": {"host": "cursor"},
 "verification": {"runner": "agent", "runner_host": "cursor", "status": "pass", "reason": null, "report": "…"}}
```

## Documentation and prose

- `agent-mode-contracts.md`: transitions and gates by tag; escalation "the
  user must open a new session for the `@gate` occupant to code"; token
  `gate_coding` (legacy `sol_coding` read as alias for one release).
- `agent-handoff-schema.md`: `seat`, `owner: agent`, `occupant`,
  `verification.runner: agent`, `runner_host`, derivation rule, examples above.
- `AGENTS.md`: `## Seat Roster` managed block (core budget) plus one sentence
  pointing at `scripts/agent-seats.sh` and `docs/agent-configs/seats.json`.
- `CLAUDE.md`, `.claude/README.md`, `.claude/commands/{coding,codex/*}.md`:
  "Claude occupies `@spec` and `@audit` by default (see roster)".
- READMEs (root, bundle, docs mirror): six-step flow by tag with default
  occupants in parentheses; the routing table becomes a seat table; the
  limitation sentence becomes "`@gate` authorization entries are audit
  declarations"; an `agent-seats.sh` operator section.
- Dated specs under `docs/superpowers/specs/` are historical and keep their
  wording.
- Budget: the roster adds roughly 110 estimated tokens to core (currently
  ~2.4k of 4k); on-demand must not grow — the four `Config version:` lines are
  removed from the on-demand documents (−60 measured).

## Interactive channel and tests (B1, decision 3)

The wizard is exercised through a real pseudo-terminal using Python's
standard `pty` module (no `script`, no forced-TTY variable in production):
the harness sends choices that differ from the suggestion and asserts the
resulting JSON, plus Enter-keeps-suggestion, same-host-keeps-model, `none`
drops the fallback, and an invalid interactive effort exits 1 without writing.
The reference harness `evidence/seats-qa.py` (v2, 103 checks: lifecycle,
grammar/transport, conflict, `set` options, malformed shapes, renderer and
atomic writes, locking, wizard on a real PTY, `init` never prompts) is the
basis of the focused test block; it reaps the child after EOF, detects prompts
on the unprocessed buffer, asserts exact prompt counts, saves transcripts on
failure, skips permission cases under root, and takes `SEATS_QA_BASH=/bin/bash`
for macOS runs. The two write-failure cases apply `RLIMIT_FSIZE` to the
interpreter that runs the seats program (a shim earlier on `PATH`, `SIGXFSZ`
ignored so the write returns `EFBIG`), never `ulimit -f` around the shell:
Bash 3.2 spools a large heredoc through a temporary file, so a shell-level
limit fails before the program is loaded (`@gate` attempt 3, F3). Nine
mutations (program on stdin, marker balance, conflict boundary, `match`
instead of `fullmatch`, legacy required keys, non-atomic write, `set` creating
the file, `init` recheck without validation, catalog entry dereferenced
without a type guard) each make it fail; the non-atomic-write mutation is
caught by those two cases.

## Migration

- Fresh targets: `init` writes defaults; `AGENTS.md` carries the roster.
- Existing targets: script and schema arrive through the candidate path;
  `init` (from the generator or the first launch) migrates the legacy profile;
  the roster is rendered into the candidate or, after `--apply-candidates`,
  by `render`.
- `model-profiles.json` and its v1 schema remain in the bundle for one release
  as migration input only; a follow-up release removes them.
- `state.json` v1 packets stay valid; open packets are not rewritten.

## Enforcement

Seat assignment is a coordination convention: the launcher enforces only that
a Codex seat resolves to a catalog-valid model/effort pair and that a
conflicting `@build` launch carries the audit token. Nothing verifies that a
human opened the right host for a Claude or agent seat; roster and packet
declarations remain declarations, not proof.

## Generated-source boundaries

- New canonical bundle files: `agent-bootstrap/agent-seats.sh`,
  `agent-bootstrap/schemas/agent-seats-v1.schema.json`; MANIFEST rows (no
  manifest version bump), `install-agent-bootstrap-home.sh` `copy_file`
  entries, writers-runtime schema copy, verifier schema catalog metadata,
  drift test (`# AGENT_BOOTSTRAP_GENERATED` loop), test schema list.
- `writers-docs.sh` owns the launcher heredoc and all prose changes;
  `writers-runtime.sh` owns the verifier heredoc (snapshot mirrored) and the
  `init`/`roster-block` calls.
- The generated-file allowlist is derived from the write log, so the new
  generated script is covered without a manual list; `seats.json` is not a
  generated file.

## Acceptance criteria

1. `--workflow full` generates `scripts/agent-seats.sh` (copy), runs `init`
   (defaults), embeds the roster in `AGENTS.md`; `validate` returns 0; drift,
   manifest, installer, and catalog checks pass; `--dry-run` writes nothing.
2. Lifecycle table: every row is a test (fresh, legacy incl. unknown model and
   `low` effort, malformed legacy with and without seats, malformed seats,
   reset, regenerate with existing seats untouched).
3. Wizard through a real PTY: non-default choices land in JSON; Enter keeps;
   same host keeps model; `none` drops fallback; invalid effort exits 1
   without writing; `--yes`/no-TTY accepts suggestions.
4. `set` rejects unsupported effort, unknown model, grammar violations with
   exit 1 and a byte-identical file; a valid `set` re-renders only the block;
   broken markers give exit 2 with the configuration still written.
5. `resolve` eight-line contract for every seat and alias, empty fields
   preserved, read back by the Bash line reader; `model-info`; `conflict`
   matrix (primary, fallback, non-build, reviewers on Claude).
6. Launcher: aliases resolve the same seat; default, fallback, override, and
   explicit-effort launches produce the pairs in the design; unsupported
   explicit effort is an error; fallback without a configured fallback is an
   error; non-Codex seat exits 2 without launching; `conflict=1` on the
   effective model emits `gate_coding` in seed and summary, in both directions
   (override into a reviewer model; configured overlap overridden away).
7. Doctor and verifier: fail on invalid `seats.json`, warn when missing, warn
   when a legacy profile coexists; neither writes.
8. No generated file contains a role word (`Sol`, `Luna`, `Astra` as roles);
   model ids, roster, and host names are excluded from the check; every prose
   assertion in the three suites uses tags; no assertion is loosened.
9. Core budget stays under 4,000 on the suite fixture and a long-name target;
   on-demand does not increase.
10. Migration fixture: legacy profile + roster-less `AGENTS.md` →
    `seats.json` seeded, roster appended, USER overlays intact.
11. Renderer: missing block, valid block, CRLF, orphan and duplicate markers,
    USER overlays, idempotency, prefix bytes.
12. Mutations: program on stdin (wizard), marker balance, conflict boundary,
    grammar `match`, legacy required keys, non-atomic write, `set` creating the
    file, `init` rechecking without validation, and a catalog entry
    dereferenced without a type guard each make the focused block fail; the
    launcher's own `conflict` call is mutated in the integration tests.
14. Fresh target has no `model-profiles.json`; verifier, `codex-mode.sh
    status` and `agent-hook.sh doctor` return 0 on it; `--dry-run` on a
    committed target leaves `git status --porcelain` empty; the installer
    export plus the inventory test cover `agent-seats.sh` and the schema.
15. Atomic writes and locking: a failing write (`RLIMIT_FSIZE` applied inside
    the interpreter) keeps the old bytes; a symlinked `AGENTS.md` is written
    through; twenty concurrent `set` pairs lose no update; a held lock makes
    `set` refuse after ~10 s while reads stay unblocked; a `seats.json` that
    appears while `init` waits for that lock is never overwritten (valid → rc 0,
    invalid or malformed → rc 1, bytes kept).
16. Upgrade fixture with the old generator default `model-profiles.json` →
    `@gate` Astra/ultra, catalog without `gpt-5.6-sol`, note printed; a
    customized legacy migrates; `init` under a PTY never prompts.
13. Snapshots byte-identical; shellcheck clean with CI exclusions; the three
    suites pass; `agent-seats.sh show|set|resolve|wizard --yes` and
    `codex-mode.sh status` run under macOS `/bin/bash` 3.2.

## Rejected alternatives

- Renaming roles to the current model (`Sol` → `Astra`): repeats the coupling
  that forces prose and test churn on every model change.
- Keeping `model-profiles.json` as the assignment source and adding seat
  fields to it: two documents describing one assignment.
- Heuristic effort compatibility (warn when `ultra` meets a non-Astra model):
  replaced by the catalog's per-model effort list.
- User-defined tags: contract prose and tests would need regeneration on every
  rename; a display label can be added later without changing the protocol.
- Tab-separated single-line transport for `resolve`: Bash readers collapse
  empty fields; one field per line is lossless on Bash 3.2.
- Forced-TTY environment variable for wizard tests: would leave a production
  code path that no terminal exercises; a real PTY is used instead.
- A lock file beside `seats.json`: ownership problems between users; the
  directory `flock` needs no file.
- `set` creating `seats.json`: a second silent creation path beside `init`.
- Conflict on fallback models: the default roster would warn on every fallback
  launch; the primary reviewing model is the audit boundary (minority view
  recorded in `council-record.md`).
