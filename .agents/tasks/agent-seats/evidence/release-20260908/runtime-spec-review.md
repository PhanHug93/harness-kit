# Runtime/generator spec review — 2026-09-08

**Result: three concrete spec violations; runtime is not fully compliant.** Production was read-only. Only this report was written in the repository; reproductions used automatically removed temporary directories. No commits, real downstream project runs, full harness reruns, or mutation runs.

Scope: working tree on `feature/simplify-task-relations`, base `cf8f326`; approved `docs/superpowers/specs/2026-09-06-agent-seats-design.md` rev3. Reviewed the requested canonical runtime, schema, runtime writers, generator wiring, verifier snapshot, installer, local-only/render registration, MANIFEST inventory, and focused harness. CodeGraph's stated shell-index limitation justified direct reads. Agentmemory recall was advisory only.

## Findings

### R1 — P2: malformed seat fields still produce Python tracebacks

**Contract:** malformed/mis-shaped documents must produce `ERROR:` and rc 1 without tracebacks; `set` may repair structurally sound invalid seats but must validate the result.

**Locations:** [show dispatch](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:718), [roster field access](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:333), [conflict model insertion](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:794), [model lookup](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:224), [set default-effort lookup](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:828).

Starting from freshly initialized defaults, each of these independent malformed edits reproduced the violation under `/bin/bash`:

| Edit to seats.json | Command | Observed |
| --- | --- | --- |
| Delete `seats.gate.tag` | `show` | rc 1; stdout `Seats:`; traceback ending `KeyError: 'tag'`; no clean `ERROR:` diagnostic |
| Set `seats.gate.occupant.model` to `["gpt-6-astra"]` | `conflict build gpt-6-astra` | rc 1; traceback ending `TypeError: unhashable type: 'list'` |
| Set `seats.build.occupant.model` to `["gpt-5.6-luna"]` and delete its `effort` | `set build --fallback-effort high` | current-document warnings followed by traceback ending `TypeError: unhashable type: 'list'` |

Seats and AGENTS bytes remained unchanged in all three cases. Root cause: structural checks admit these field shapes; `show` renders before reporting validation errors, `conflict` inserts an unchecked model into a set, and repair-mode `set` passes an unchecked model to dictionary lookup. The harness's M1–M3 cases cover container/catalog shapes but omit these field-level cases.

**Fix needed:** report validation errors before unsafe roster access; validate conflict input before set insertion; guard model identifiers before dictionary lookup, including repair paths, while retaining supported seat repair. Add these narrow malformed-field regressions.

### R2 — P2: unknown reset options overwrite customized configuration

**Contract:** unknown options/usage return rc 1 with nothing written.

**Location:** [main reset branch](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:662); arguments reach it without command-specific validation at [dispatch](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:653).

**Trigger/evidence:** initialize a disposable config, change `seats.build.occupant.effort` to `high`, then run `reset --not-an-option`. Observed rc 0, no stderr, `seats.json reset to bundle defaults`, and both seats and AGENTS bytes changed. The customized effort became `xhigh`. The reset branch ignores `args`; only `set` has an option parser, and wizard only tests whether `--yes` appears.

**Fix needed:** enforce each command's allowed arguments before lock acquisition or writes. `reset` accepts no arguments; unsupported flags must return a clean rc 1 and preserve both files. Cover this destructive invalid-invocation case explicitly.

### R3 — P2: shipped schema rejects contract-permitted duplicate efforts

**Contract:** “Duplicate catalog efforts are a warning”; existing files remain usable.

**Location:** [catalogModel.efforts.uniqueItems](/Users/admin/projects/agent-bootstrap/agent-bootstrap/schemas/agent-seats-v1.schema.json:54).

**Trigger/evidence:** append another `ultra` to `catalog.models.gpt-6-astra.efforts`. Runtime `validate` returned rc 0 with `catalog model gpt-6-astra: efforts lists duplicates` and preserved bytes, as required. The shipped JSON Schema declares `uniqueItems: true`, which makes that same array invalid for a schema consumer. This is a direct schema/contract mismatch, not a runtime-validator failure. `jsonschema` was unavailable in the review interpreter, so the schema rejection is established from the explicit keyword, not a claimed validator execution.

**Fix needed:** remove the uniqueness rejection from this schema array and retain the runtime warning; add a schema/runtime consistency case for duplicate efforts.

## Verified compliant areas and evidence limits

Focused calls sourced only `lib/core.sh`, `lib/render.sh`, and `lib/writers-runtime.sh`, with all target paths redirected into disposable directories. They exercised `write_agent_seats`, `seed_agent_seats`, schema copying, and verifier generation without invoking launcher/prose writers.

- Fresh seeding created defaults, copied an executable canonical script, emitted no legacy profile, and put neither seats.json nor a seats candidate into the write log/candidate paths.
- Generated `agent-seats.sh`, seats schema, and full-workflow `verify-ai-deps.sh` matched bundle bytes exactly. Canonical seats differed from the reviewed reference only by the added legacy `default_profile` string guard.
- Re-seeding existing valid seats with malformed inactive legacy, including `FORCE=true`, preserved seats, legacy, and AGENTS bytes exactly.
- Custom migration preserved `team/planner`/`ultra`, `team/fallback`/`high`, build effort `low`, and reviewing fallback effort `medium`; original legacy bytes and roster-less AGENTS USER knowledge were unchanged. A subsequent runtime `render` preserved the entire old CRLF USER prefix.
- Invalid active seats remained unchanged; invalid active legacy created no seats. Generator init failures remained nonfatal with a warning. Focused copy/init dry-run wrote no target files.
- Executing the verifier's isolated seats/legacy decision block produced WARN for missing seats, FAIL for invalid seats, and PASS for valid seats with only WARNs from malformed inactive legacy. This was not a full verifier run.
- Source inspection confirms fixed tags/phases/default occupants, eight-line resolve, three-line model-info, primary-only conflict semantics, validation before save, sibling-temp/fsync/replace writes, bounded directory flock, and the same init precheck before and after locking. Those concurrency, fault-injection, PTY, and transport cases were not rerun; coordinator-reported 115/115 is external evidence, and the nine runtime mutations were still assigned elsewhere.
- Generator wiring calls the bundle script through all three `AGENT_SEATS_*` overrides before documentation generation. Installer and MANIFEST register script/schema; gitignore and local-only lists register the script. `/bin/bash -n` passed for all seven reviewed shell files.

**Unfinished launcher integration is separate:** no findings were raised against `writers-docs.sh`, README/prose, version pins, launcher behavior, or unfinished `test-bootstrap` expectations. End-to-end older-release upgrade/apply-candidates and generated AGENTS roster integration were not certified here; the evidence above establishes the runtime migration/render preservation behavior only. The three findings above are independently reproduced runtime defects or a direct schema mismatch, not consequences of unfinished launcher work.

Reviewed-source SHA-256 (working-tree content):

```text
agent-bootstrap/agent-seats.sh                       9c631e65c1835641824f0964a829b7eeadf1e9c968e67e6731c2edcf9466ef6b
agent-bootstrap/schemas/agent-seats-v1.schema.json   4fb92bd0b93a406bf90caf4d4e3072d0a9b5b76247d57ee6369716f870f2d7da
agent-bootstrap/lib/writers-runtime.sh              6df4a45225fd22e5e5536a632ca3821c36aed259dc556ec239d8968bf67534c1
agent-bootstrap/verify-ai-deps.sh                    69feb5e88f9f49c10cf8962f8ecaf6e837a7aedb87fc28eff9338964d90e1dc0
```

---

## Attempt 2 — bounded remediation recheck, 2026-09-08

**Verdict: R1, R2, and R3 are closed at the hashes below. No outstanding violation found in this bounded recheck of those findings and repair/usage preservation.** This verdict supersedes the attempt 1 finding statuses; it does not certify the entire release.

Independent verification used the canonical script through `/bin/bash` **3.2.57(1)-release**, with all data paths redirected by `AGENT_SEATS_*` into an automatically removed disposable directory. **15 focused checks passed, 0 failed**; one check contains 14 invalid invocations. Production remained read-only; only this appendix was written in the repository. Git reads used `GIT_OPTIONAL_LOCKS=0`.

| Finding | Current implementation and fresh evidence | Status |
| --- | --- | --- |
| R1: malformed-field tracebacks | [show](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:767) and [conflict](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:830) validate before unsafe access; [typed repair lookup](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:228) guards model IDs. Repeated all three original triggers: missing gate tag, list reviewer model, and list build model with missing effort. Every command returned rc 1, an `ERROR:` diagnostic, empty stdout, no traceback, and unchanged seats/AGENTS/legacy bytes. Missing phase and dictionary-valued fallback with missing effort also refused cleanly. | Closed |
| R2: unknown reset options overwrite config | [command argument validation](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:551) runs [before locking](/Users/admin/projects/agent-bootstrap/agent-bootstrap/agent-seats.sh:705). Fourteen invalid invocations, including `reset --not-an-option`, `reset --dry-run`, extra arguments across commands, missing set seat, and unknown set option, all returned rc 1 with clean diagnostics and unchanged fixture bytes. These ran while the config directory flock was held and completed within each 3-second subprocess timeout. Rejected reset usage against a missing config parent created no directory. | Closed |
| R3: schema rejects duplicate efforts | [efforts schema](/Users/admin/projects/agent-bootstrap/agent-bootstrap/schemas/agent-seats-v1.schema.json:50) no longer declares `uniqueItems`. Adding a duplicate `ultra` yielded runtime rc 0 and the duplicate warning, preserving all fixture bytes. Schema allowance was checked directly from its array definition; no external JSON Schema validator was executed. | Closed |

Repair and valid-usage preservation checks also passed:

- Explicitly repairing the malformed primary through the `coding` alias, and repairing the malformed fallback, each returned rc 0 and then validated successfully. Only the requested occupant fields changed; the rest of the configuration, original legacy bytes, and CRLF USER prefix were preserved.
- A change to build while another seat remained invalid returned rc 1 with no write or fallback/default reset.
- Valid `wizard --yes` preserved custom assignments despite malformed inactive legacy. Valid explicit `reset` restored defaults while preserving USER and legacy bytes.
- Valid `show`, `resolve coding`, `model-info`, `conflict`, and `roster-block` remained usable. Resolve emitted eight lines, model-info three, and a build/Astra conflict emitted exactly `1\n`.
- Canonical Bash syntax and harness Python compilation passed without writing bytecode. Inspection confirms [P1–P5 regression coverage](/Users/admin/projects/agent-bootstrap/scripts/test-agent-seats.py:460) was added.

The [runtime evidence README](/Users/admin/projects/agent-bootstrap/.agents/tasks/agent-seats/evidence/release-20260908/runtime/README.md:33) reports 133 passed / 0 failed / 0 skipped, and its focused summary reports 8/8. Those are worker evidence, distinct from this independent focused recheck. No full suites, source mutation tests, generator/upgrade runs, or launcher review were performed in attempt 2. Prior generator evidence was not rerun.

Current SHA-256 values, verified unchanged during this recheck and immediately before appending:

```text
agent-bootstrap/agent-seats.sh                         0182febcfefffd32d969fa97302d8bd51fa8f45882c99ee6ed97acfa3cebfaac
agent-bootstrap/schemas/agent-seats-v1.schema.json     1fa8c6c556227f9f7042b423edada57e55cb0c0261284292a181036344c01317
scripts/test-agent-seats.py                            4dab89954a885c4772e0670371eccfb6e3c2f7bf8fcb991dba9781835dd8ad06
agent-bootstrap/lib/writers-runtime.sh                 6df4a45225fd22e5e5536a632ca3821c36aed259dc556ec239d8968bf67534c1
agent-bootstrap/verify-ai-deps.sh                      69feb5e88f9f49c10cf8962f8ecaf6e837a7aedb87fc28eff9338964d90e1dc0
```
