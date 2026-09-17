# HK-07: explicit retirement lifecycle

Date: 2026-09-12. Packet: `downstream-retirement-policy-HK-07`.
Status: proposed specification; ready for independent `@gate` review.

The owner approved separating HK-07 from the HK core packet and authorized
Codex to prepare the specification in place of the unavailable `@spec` seat.
That approval does not approve this proposed deletion policy or authorize an
implementation, deletion, release, commit, push, tag, or merge. This draft adds
no executable behavior. The core packet continues independently.

## 1. Evidence and selected approach

The received report's HK-07 describes obsolete generated CI surviving upgrade.
Attempt 1 F3 independently reproduced both obsolete paths and an old candidate
surviving while ordinary status reported no pending candidates and clean drift.
Those records remain unchanged:

- `.agents/tasks/downstream-migration-feedback-2026-09-08/evidence/downstream-feedback-2026-09-08.md`, section HK-07.
- `.agents/tasks/downstream-migration-feedback-2026-09-08/codex-review.md`, Attempt 1, F3.
- `.agents/tasks/downstream-retirement-policy-HK-07/task.md` and `state.json`.

The baseline for interface inspection is immutable `v2026.09.10.2`, commit
`fc33f1c7b20fb8f90bfcb01649544fa470e6200b`. Its internal bundle VERSION and
one-shot default ref remain `2026.09.10.1`; the tag name alone is not evidence
that those strings were changed. The HK core patch is proceeding separately;
implementation must consume its approved HK-01 root policy and rebase this
file-ownership inventory against the actual integration base before coding.

Three approaches were considered:

| Approach | Consequence | Decision |
| --- | --- | --- |
| Delete exact matches during generation | Makes the safe-default upgrade destructive and provides no explicit retirement review boundary | Reject |
| Add retired paths or textual tombstones to ordinary candidates | Can promote stale CI or replace executable YAML with review prose | Reject |
| Separate typed observation, plan and explicit apply | Preserves candidate semantics, exposes stale artifacts, permits conservative deletion with recovery | Select |

All policy choices below are proposed engineering defaults. No additional
owner choice is needed to make this draft technically complete. The independent
gate and owner's policy approval must precede implementation. A future release
number and PR target are delivery decisions, not implied by this specification.

## 2. Closed artifact inventory and provenance

Add `agent-bootstrap/policies/retired-artifacts-v1.json` as a bundled, reviewed
inventory. Its format is the closed object described here; unknown fields,
duplicate IDs/paths, path aliases, absolute paths, `..`, glob paths, extra entries,
invalid digest encodings and unsupported versions are fatal policy errors.
The implementation also pins the following two ID/path pairs so changing an
external JSON document cannot turn this feature into arbitrary file cleanup.
There is no CLI inventory/path/hash override and no policy downloaded at apply.

| ID | Exact target-relative path |
| --- | --- |
| `agent-guard-workflow` | `.github/workflows/agent-guard.yml` |
| `agent-guard-template` | `docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml` |

Both inventory entries have exactly one accepted historical fingerprint:

```json
{
  "source_ref": "v2026.08.10.1",
  "source_commit": "b1907f5fe7caf9d9e401606a93fa0815739b6df0",
  "source_path": "agent-bootstrap/templates/ci/agent-guard.yml",
  "size_bytes": 605,
  "sha256": "751c8c3f88fd1fc3bcc5c1ddff940e1280b1a5149c787d3110a4408a39810ebb"
}
```

The inventory object has required keys `schema` (constant
`agent-bootstrap-retired-artifacts/v1`), `policy_id` (constant
`hk07-agent-guard/v1`) and `artifacts` (exactly the two entries, workflow first).
Each entry has required `id`, `path`, `reason` (constant
`generated-remote-ci-retired`) and `fingerprints` (the singleton object above).
All objects reject additional properties. The source ref is descriptive; the
immutable commit and content digest are authoritative. Inventory changes need
their own review and policy version, not a new automatically accepted hash.

Draft verification exported the actual historical template blob through
`rtk git show <commit>:<path>` and confirmed 605 bytes and the digest above.
The historical repository's documentation template mirror has the identical
bytes. Its `lib/writers-runtime.sh` lists `ci/agent-guard.yml` in the template
catalog and copies the source template directly to the workflow path. The
workflow is generated output, not a file present at the old repository root;
tests must generate that output instead of claiming a nonexistent Git blob.

Matching means byte-for-byte SHA-256 and size equality. Do not normalize YAML,
line endings, comments, whitespace, or encodings. A version lock, comment,
filename or historical-looking stamp cannot substitute for a known digest.
Do not extend the inventory to legacy model profiles, seats, root application
README/CHANGELOG, arbitrary workflows, unknown templates or other old files.

## 3. Observation, containment and ownership

Use one retirement engine in `agent-bootstrap/lib/retirement.py`, callable by
the Bash entrypoint and testable in isolation. Python3 is already required;
Bash orchestration remains compatible with Bash 3.2 on macOS and Linux. The
helper is bundled code, not a generated downstream executable or a general
cleanup API. Its inventory location is fixed relative to the bundle.

Canonicalize the caller's explicit target root once, accepting physical aliases
such as `/var` and `/private/var`. Within that root inspect each ancestor in
order with `lstat` before inspecting the next component. Reject every internal
symlink ancestor and every symlink leaf, including live in-root links and
dangling links, without resolving, opening, copying or printing their targets.
Reject non-directory ancestors, special leaves, and regular leaves with more
than one hard link. Read content only from an ordinary single-link regular leaf
under checked ordinary directories, with the HK-01 lexical/resolved exclusions
still enforced. A destructive action deliberately has stricter eligibility
than HK-01's permitted in-root reads; it does not alter HK-01 for other actions.

Open a checked regular leaf without following its final link, compare the open
file identity/type with the checked identity and check metadata again after
reading. Retain the identities of the checked ancestors for apply-boundary
comparisons as well as the leaf identity. A mismatch produces an error or an updated safe classification, never
an assumed exact match. Compare roots by path components, not string prefixes.
Do not recurse into directory links or read external data to explain a refusal.
This is bounded path hardening with deterministic rechecks, not a claim of a
sandbox against adversarial concurrent directory replacement or mount changes.

Current-state classification is independent of whether apply is permitted:

| Status | Meaning | Content inspection |
| --- | --- | --- |
| `absent` | A checked ordinary parent chain reaches a missing ancestor or missing leaf | None; dangling links are not absent |
| `eligible` | Safe regular leaf matches an inventory fingerprint | Checked bytes only |
| `modified` | Safe regular leaf has an unknown size or digest | A size mismatch need not be opened; otherwise checked bytes only |
| `unsafe-type` | Symlink, special leaf, multiple hard links, or unsafe ancestor | Metadata only; never inspect referents or children |
| `error` | I/O, identity consistency or required metadata inspection failed | Stop the failing inspection; do not treat unknown as absent |

Ownership is a separate observation. In a Git worktree, use literal-path,
read-only index/ignore queries with optional index refresh disabled. A path is
`local-only` only if untracked and ignored. Tracked files and untracked files
that are not ignored are `project-owned`. A target outside Git is
`project-owned`. An unexpected Git inspection failure is `ownership=error` and
the entry is `error`; it is not equivalent to an untracked file. Inspect Git
metadata only for otherwise safe existing files. These queries must not follow
a target-controlled `.git` symlink to obtain ownership: refuse such an ownership
inspection. Ordinary Git worktree gitfiles may name an external Git directory
as explicitly configured Git metadata; no retired-file content is read there.

Proposed apply scope is `local-only` by default. The explicit
`--retirement-scope all-matching` also permits exact matches classified as
project-owned. It never permits modified/unsafe/error entries. This prevents
the current kit's local-only convention from silently authorizing removal of
project CI already maintained or tracked by the owner. Retirement neither edits
the index nor acknowledges/untracks files, edits ignore rules, commits a
deletion, removes directories, changes hooks, or changes the existing local-only
checker. Root user-owned documents remain protected by the core policy.

## 4. Public CLI and activation boundary

The following names and combinations are normative new interfaces on
`bootstrap-multi-agent-project.sh`:

| Invocation | Behavior |
| --- | --- |
| `--retirement-plan [--json]` | Read current files and report typed proposed actions; no target writes |
| `--retirement-status [--json]` | Read current state and candidates; no target writes |
| `--apply-retirements [--json]` | Build a fresh plan and attempt permitted retirements, with mandatory backups |
| `--apply-retirements --dry-run [--json]` | Same read-only report as retirement plan, mode `plan`, `dry_run=true`; no backup or unlink |
| `--retirement-scope local-only\|all-matching` | Select which ownership classes a retirement plan/apply may include; default `local-only` |
| `--status --json --status-version 2` | Existing status plus the versioned retirement current-state report |

Only `--apply-retirements` without `--dry-run` activates deletion, and only
after this proposal has been approved and implemented. No saved plan is an
executable input: JSON reports are review output. Normal generation,
`--force`, `--skip-existing`, `--refresh-lock`, `--apply-candidates`, `--diff`,
`--upgrade-plan`, `--cleanup-backups`, updater `--apply`, and normal one-shot
upgrade do not implicitly authorize retirement.

The three dedicated retirement actions are mutually exclusive. Reject mixing
one with another primary action, including `--apply-candidates`, regardless of
argument order. Reject `--force`, `--skip-existing` and `--no-backup` with any
dedicated retirement action, including dry-run, with exit 2 before any write.
They cannot bypass a preservation or mandatory backup. `--dry-run` on
retirement plan/status is allowed and has no mutating effect. `--json` is valid
for dedicated actions as well as existing status; do not add it to generation.

`--status-version` accepts only `1` or `2` and only with `--status --json`.
Omitted version means `1`. Retirement scope is accepted with dedicated actions,
generation, diff, upgrade plan, human status, or status v2; reject it on JSON
status v1 because that response cannot represent it. Reject malformed new
arguments before dispatch; do not silently use the last conflicting action.
Existing combinations unrelated to retirement keep their current contract.

Normal generation and generation dry-run append a human retirement-plan
section without writing a tombstone, `.generated` hint, plan cache or ledger.
`--diff` and `--upgrade-plan` also show this typed section. Compute it against
the live declared target using the read-only engine, never against a generated
snapshot where obsolete files may have been omitted. Internal preview and
allowlist generation suppress nested retirement reporting and never apply.
Eligible/project-owned/modified/unsafe entries and stale candidates produce
clear preservation/review diagnostics, not a misleading overall clean message.
Read-only plans may use process memory and existing generic preview temporary
directories; they may not create target files, backups, locks or a Git branch.

## 5. JSON contracts and exits

Keep `agent-bootstrap-status/v1`, its schema, field meanings and default JSON
selection unchanged. Its generated drift and pending count remain scoped to
active generated files. A retirement warning may be written to stderr, but no
retirement field or extra text may be appended to v1 JSON stdout. Legacy v1
exit behavior remains unchanged; v1 consumers need the new endpoint or explicit
v2 to obtain retirement truth. Document this limitation beside the old command.

Add `schemas/agent-bootstrap-status-v2.schema.json`: exactly all v1 required
fields/properties, except `schema=agent-bootstrap-status/v2`, plus required
`retirement` containing the report below in `mode=status`. Retain all old
enumerations and meanings, including the original generated drift/count.
Reject additional properties. Human `--status` appends the same retirement
section without a schema switch. Do not infer historical removal from absence.

Add `schemas/agent-bootstrap-retirement-v1.schema.json` (JSON Schema 2020-12).
The following table defines its complete required object properties. Every
listed object has `additionalProperties=false`; no field is optional unless
its type explicitly permits null. Counts are nonnegative integers, digests are
lowercase 64-hex strings, paths are escaped by the JSON encoder, and entries are
always the two policy rows in inventory order. No link target or file content
is included. Schema validation is a contract test, not a substitute for runtime
inventory/path checks.

| Object | Required properties and types |
| --- | --- |
| Report | `schema`: constant `agent-bootstrap-retirement/v1`; `policy_id`: constant `hk07-agent-guard/v1`; `policy_sha256`: digest or null if inventory unreadable; `target`: canonical absolute string; `mode`: `plan\|status\|apply`; `dry_run`: boolean; `scope`: `local-only\|all-matching`; `run_id`: string or null; `entries`: two Entry objects; `summary`: Summary; `errors`: array of Error |
| Entry | `id`, `path`: the exact matching inventory pair; `observed`: Observation; `action`: `retire\|preserve\|none`; `result`: `planned\|retired\|preserved\|unchanged\|error\|not-attempted`; `after`: Observation or null; `backup`: target-relative string or null; `stale_candidates`: array of Candidate; `candidate_scan`: `complete\|unsafe-parent\|error` |
| Observation | `status`: `absent\|eligible\|modified\|unsafe-type\|error`; `reason`: Reason below; `file_type`: `absent\|regular\|symlink\|directory\|other\|unknown`; `size_bytes`: integer or null; `sha256`: digest or null; `ownership`: `local-only\|project-owned\|error` or null |
| Candidate | `path`: target-relative string with the entry's exact path plus `.generated.` and a nonempty suffix; `file_type`: `regular\|symlink\|directory\|other\|unknown` |
| Summary | `states`: StateCounts; `results`: ResultCounts; `stale_candidate_count`: integer; `incomplete_candidate_scans`: integer; `attention_required`: boolean |
| StateCounts | `absent`, `eligible`, `modified`, `unsafe-type`, `error`: integer each |
| ResultCounts | `planned`, `retired`, `preserved`, `unchanged`, `error`, `not-attempted`: integer each |
| Error | `code`: ErrorCode below; `path`: target-relative string or null for a root/policy error; `message`: escaped, single-line, metadata-only string |

Reason is exactly one of `missing`, `exact-match`, `size-mismatch`,
`digest-mismatch`, `symlink-leaf`, `symlink-ancestor`, `special-leaf`,
`non-directory-ancestor`, `multiple-hard-links`, `io-error`, `ownership-error`,
`identity-changed`, `invalid-policy`, `invalid-root`. ErrorCode is exactly one
of `policy-invalid`, `root-invalid`, `inspection-failed`, `candidate-scan-failed`,
`ownership-failed`, `changed-before-delete`, `backup-failed`, `delete-failed`,
`interrupted`. Error messages do not include raw file contents or link targets.

Additional invariants are normative: `eligible` has the inventory size/hash,
regular type and known ownership; `absent` has null size/hash/ownership;
`unsafe-type` has null hash/ownership; a size-mismatched `modified` may have a
null hash. Metadata available safely may populate size for other states.
Plan/status have `run_id=null`, `after=null`, `backup=null`, and result `planned`
for every entry. Action is `none` for absent, `retire` only for eligible entries
within scope, and `preserve` otherwise. Apply retains its fresh initial action
and observation, and records its result plus final safe observation in `after`.
Apply has `dry_run=false` and a non-null run ID; report run IDs use the format
defined in section 6. An action with no eligible files may allocate that ID in
memory but creates no artifact. Encode the enumerations, ID/path pairing,
mode constraints and state-dependent nullability in the schemas and their
contract tests, rather than allowing ambiguous report variants.
Unattempted entries after a failure have `result=not-attempted`, `after=null`.
An absent entry has apply result `unchanged`. Preserved entries have
`result=preserved`. A created backup remains reported even if deletion fails.

Summary states use `after` when present, otherwise `observed`; results count
the result field. Each state/result count set sums to two. Candidate count is
the number actually listed, not a claim that incomplete scans contain zero.
Attention is true for any remaining eligible/modified/unsafe/error state,
candidate presence, incomplete scan or report error. Thus a successful apply
can still need manual candidate review. `retired` is an operation result only;
afterward the current state is `absent`, never a fabricated historical state.

In JSON mode stdout is exactly one object and newline, including operational
failure reports when the root can be identified. Syntax errors may have empty
stdout with stderr diagnostics. Do not mix shell progress with JSON. Human
mode prints policy/scope, per-path current state and proposed/result action,
preservation reason, backup names and explicit candidate-scan omissions.

| Command result | Exit |
| --- | --- |
| Complete plan/status inspection, including eligible, modified or unsafe states | 0; these are observations requiring review, not inspection failures |
| Plan/status operational or candidate-enumeration error | 1 |
| Apply completes: every in-scope eligible file retired, all others absent; preserved stale candidates alone are allowed | 0 |
| Apply completes but a live modified/unsafe/out-of-scope file is preserved | 3; report names all preserved entries |
| Apply inspection, backup, deletion or recheck error; remaining actions not attempted | 1, including partial completion |
| Invalid CLI combination or value | 2, before writes |
| Interrupted apply | Standard signal exit, 130 for INT or 143 for TERM; best-effort report and retained backups |

Standalone status v2 and human status use the retirement error exit when the
old status succeeded; retain any existing nonzero status failure. Generation,
diff and upgrade-plan keep normal failures and return nonzero on retirement
inspection errors; attention-only observations do not fail their safe default.
For ordinary `--apply-candidates` and `--cleanup-backups`, preserve an existing
ordinary-action failure; if that action succeeds, return 1 for a retirement
inspection or candidate-enumeration error and 0 for attention-only observations.
Completed ordinary writes are retained; an appended preservation summary never
implies rollback. These observers still do not authorize retirement.

## 6. Apply, backups, rechecks and recovery

Apply reads the trusted policy, validates options/root, and classifies both
entries before writing. An initial inspection error prevents all retirements.
Modified, unsafe or out-of-scope entries are preserved while eligible entries
may proceed. Process the workflow then the template in deterministic order.
The apply plan is always rebuilt now: an old preview is never authority.

For each initially permitted entry:

1. Recheck ancestors, identity, type, size, hash and ownership/scope immediately
   before preparing a backup. If it became absent, report unchanged. If it
   became modified/unsafe/out-of-scope, preserve it and continue with exit 3
   unless the inspection itself failed. A new I/O/identity-consistency error
   stops further actions and returns 1.
2. Create an adjacent backup named `<exact-path>.bak.retirement.<run-id>` using
   exclusive creation. Run ID is UTC `YYYYMMDDTHHMMSSZ-` plus 16 lowercase random
   hex characters; use one ID per apply. Do not overwrite a backup or follow a
   conflicting link. Retry a colliding fresh run ID before any backup is made;
   collision after work has started is an error, leaving prior results intact.
3. Copy only the just-verified regular file to the exclusive backup. Preserve
   its permission bits and mtime, validate backup size/digest, flush and close
   it successfully. Source metadata/identity must remain consistent. A copy,
   metadata, digest, flush or close failure preserves the original and stops
   the run. A partial backup remains named in the error for manual inspection;
   it is never claimed to be usable recovery material.
4. Recheck the live parent chain, leaf identity, type, current bytes and scope
   after backup and immediately before unlinking the live leaf. A changed leaf
   or changed scope is preserved, the backup retained, and the run returns 1
   with `changed-before-delete`; do not remove the new entry based on old bytes.
5. Unlink only the exact checked leaf. Never unlink a link or recurse. Verify
   absence and report `retired`, `after.status=absent` and the usable backup.
   If the pathname already disappeared, retain backup and report unchanged.
   Other deletion/verification errors stop the run with exit 1. Do not retry
   removal against a different current inode. Flush the containing directory
   after unlinking on the supported macOS/Linux platforms. A directory flush
   error sets the result to `error`, preserves a known `after.status=absent`
   when established, retains the backup and returns 1; it must not falsely
   report that the original remains present or silently claim durable success.

There is no multi-file transaction and no automatic rollback. If the first
file is retired and the second fails, keep the first backup, report the exact
partial outcome, and leave later work unattempted. Do not restore automatically
over a user edit. SIGINT/SIGTERM handlers only report/close owned resources;
they never remove the originals, completed backups or partial backups as
cleanup. Abrupt termination may prevent the final report; deterministic backup
names allow recovery inspection. No guarantee against power loss or hostile
concurrent mutation is claimed. Tests must still exercise ordinary I/O failure
and deterministic changes between preview/backup/delete.

Backups are mandatory even with an explicit all-matching scope. They remain
outside candidate promotion and ordinary `--cleanup-backups` because their
base paths are retired, not active. Neither command removes them. HK-07 adds
no backup-retention or generic garbage-collection action.

The generated recovery runbook must document an exclusive-create recovery
procedure for each of these two paths: inspect the backup's checked ordinary
parent/leaf without links, verify its 605-byte known hash, verify that the
original path is absent under safe parents, then copy using exclusive creation,
preserve mode/mtime and verify the restored bytes. If the original is present
or any check fails, stop without overwriting either entry. Keep the backup for
manual audit. Supply a runnable bounded recipe implementing these checks; do
not document a plain overwrite-capable `cp` as recovery. No public restore CLI
or history ledger is added by this packet. Status never reads backups to infer
past actions. A recovery intentionally makes the current file eligible again;
only a later explicit apply can retire it again.

Repeated normal generation, plan, status and dry-run remain non-destructive.
Repeated apply when both paths are absent creates no backups or other files,
reports two unchanged results, and exits 0 even if preserved stale candidates
still require review. Existing backup files alone are not drift or evidence
that an absent file was retired by this tool.

## 7. Stale candidates and public-action integration

For each safe ordinary parent, enumerate only direct sibling names with exact
prefix `<retired basename>.generated.` and a nonempty suffix. List entry names
and metadata types without reading content, hashing, following links or
descending into matching directories. Include old stamps, unknown suffixes,
symlinks, broken links and special entries. If an ancestor is unsafe, set
`candidate_scan=unsafe-parent`, list none, and explicitly say the scan was not
performed. A directory enumeration failure is `candidate_scan=error` and an
operational error. Never present an incomplete scan as clean.

Retired candidates are preserved byte-for-byte and by entry/link identity in
every action, including successful apply, `--apply-candidates` and
`--cleanup-backups`. The two retired base paths must never enter the normal
write-log allowlist, generated replacement diff or promotion set. An old
candidate may not restore deleted CI, even with force or a newer stamp.
Other unknown `*.generated.*` project files retain their existing ownership.
Provide a manual review instruction naming each candidate; do not put that
instruction into executable YAML or a promotable candidate.

Public default `--apply-candidates` and `--cleanup-backups` append the retirement
preservation summary and use the same safe metadata-only observation. Preserve
their active-path behavior. Existing updater `--plan` gets the plan through
bootstrap `--upgrade-plan`; updater `--apply` remains ordinary generation only.
Users invoke the dedicated bootstrap retirement action explicitly. No new
updater passthrough or meaning for its existing `--apply` is introduced.

One-shot adds `--apply-retirements` and
`--retirement-scope local-only|all-matching`. It always shows a retirement plan;
its defaults never delete. If requested, apply runs after generation and after
ordinary candidate application, if that was separately requested. It refreshes
the plan at the apply boundary. `--apply-candidates` alone still never deletes.
`--skip-verify`, `--allow-dirty`, `--no-branch` and scope selection never imply
retirement. After apply exit 3, continue existing verification/status, then
return 3 unless a verification failure requires exit 1. After retirement exit
1 stop further mutating actions, report partial outcome, and exit 1. Prior
generation/home/branch changes are not rolled back.

One-shot dry-run currently exits before source installation or generation. Move
only read-only target/source validation and retirement-plan execution before
that return. Prefer an explicitly supplied, locally validated `--source-dir`;
otherwise an existing cache checkout may be used only when already at the
requested ref/commit and version and containing this supported policy/helper.
Use the same source identity checks as the real run and show actual ref,
commit, bundle version and policy digest. Do not fetch, clone, checkout,
install, create home/cache directories, switch branches, generate or invoke
verification during dry-run. Resolve the target Git root read-only before
planning so a subdirectory invocation matches the real run's target.

If no suitable local source exists, print that the retirement plan is
unavailable, give a concrete `--source-dir` invocation, and exit 1 without
writing. Never fall back to a newer/older current-home policy, invent an empty
plan, or call the unknown remote release safe. A standalone downloaded
one-shot script therefore needs an already available supported source to
produce a complete offline dry-run. This conservative limitation avoids
duplicating the policy/engine inside the one-shot script. With
`--apply-retirements --dry-run`, output is still plan only and creates no backup.

## 8. Exact proposed ownership and packaging

This draft author owns only this new specification and its new
`proposed-spec.md` packet note. The following is proposed *future implementation*
ownership, not authorization to change these files now:

| File | Bounded reason |
| --- | --- |
| `agent-bootstrap/lib/retirement.py` (new) | One closed inventory classifier, typed renderer and backup/apply engine |
| `agent-bootstrap/policies/retired-artifacts-v1.json` (new) | Exact reviewed artifact provenance |
| `agent-bootstrap/schemas/agent-bootstrap-retirement-v1.schema.json` (new) | Dedicated report contract |
| `agent-bootstrap/schemas/agent-bootstrap-status-v2.schema.json` (new) | Opt-in combined status contract |
| `agent-bootstrap/bootstrap-multi-agent-project.sh` | New action parsing/dispatch, human integration, explicit v2, exclusion invariants |
| `agent-bootstrap/harness-kit-one-shot-upgrade.sh` | Explicit retirement flags, read-only source-backed dry-run, propagation of apply outcomes |
| `agent-bootstrap/install-agent-bootstrap-home.sh` | Explicit canonical export entries for the four new bundled files |
| `agent-bootstrap/lib/writers-runtime.sh` | Export the two new schemas in the generated schema catalog; extend `write_recovery_runbook` to emit the exclusive-create retirement recovery recipe in `docs/agent-configs/RECOVERY.md`; no retired CI writer |
| `agent-bootstrap/MANIFEST.md` | Exact source-role inventory for the four new bundled files |
| `agent-bootstrap/README.md` | CLI, compatibility, scope and recovery operator contracts |
| `README.md` | Kit-repository operator links/summary only; never downstream root replacement |
| `docs/agent-configs/bootstrap-multi-agent-project/README.md` | Maintained generated-catalog operator documentation |
| `scripts/test-agent-retirement.py` (new) | Behavior, schema, provenance, fault and mutation tests |
| `scripts/test-bootstrap-multi-agent-project.sh` | Invoke the new suite; exact installer/manifest/canonical inventory and public-action checks |
| `scripts/test-one-shot-upgrade.sh` | Default/explicit/dry-run retirement boundaries and failure propagation |

The new generated schema outputs are exactly
`docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-retirement-v1.schema.json`
and `docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v2.schema.json`
inside disposable or downstream generation targets. They do not reintroduce
the retired CI template mirror. Reuse the existing core HK-06 immutable
historical fixture packaging/selector for v2026.08.10.1; do not modify historical
fixture bytes. If integration reveals that packaging is not present, record a
specific dependency rather than silently using current output as history.

Do not edit `agent-bootstrap-status-v1.schema.json`, legacy profiles, seats,
HK core evidence, HK-01 shared policy, local-only checker, runtime detector,
current CI workflow definitions or normal candidate algorithms beyond the
bounded public integration/exclusion checks. Version/release metadata is a
later explicitly scoped delivery pass and must not label new bytes as an
already published release. Any extra implementation file requires a documented
ownership amendment and gate check before coding it.

## 9. Acceptance and observable mutation tests

Use disposable Git and non-Git targets on Ubuntu and macOS; exercise Bash 3.2
and Python3. Start historical cases from the actual immutable old bundle via
the core fixture/tag selector, generate both outputs and verify the recorded
size/hash. Also use a latest-source fresh target where both are absent. A
missing historical source is a failing required test with diagnostics, never
an all-green skip. Keep the existing bootstrap, seats and one-shot suites green.

For every no-write/preservation assertion record before/after tree metadata,
bytes and link identities, not only log text. Observe process invocations for
Git/home/cache/branch boundaries. On Linux use syscall tracing when available
to assert no external synthetic sentinel was opened; cross-platform tests also
assert no sentinel bytes appear in output/backups/candidates and external
bytes/metadata remain unchanged. These tests support the bounded no-follow
claim; do not claim adversarial TOCTOU coverage from ordinary link fixtures.
Compare modes, mtime, entry type and identity; ordinary successful content reads
may update filesystem access times, which are not target mutation assertions.

| Acceptance | Required public evidence | Mutation that must fail |
| --- | --- | --- |
| R1 — immutable closed inventory | Historical generated workflow and mirror are both 605 bytes with the exact digest; invalid/extra inventory entries stop before writes | Add third path, wrong digest, alias or arbitrary policy override |
| R2 — safe defaults | Generation, force, skip-existing, refresh-lock, plan, status, diff, apply-candidates, cleanup and one-shot default leave both exact old files untouched; retired paths absent from active allowlist | Invoke unlink from generation, force, updater apply or ordinary candidate promotion |
| R3 — explicit lifecycle | Default local-only scope retires ignored/untracked exact files only, mandatory verified backups exist, after status is absent; all-matching explicit apply also handles project-owned and non-Git exact files | Treat tracked/unignored as local-only, let scope flag alone delete, bypass hash or backup |
| R4 — modified/unknown preservation | Edit either bytes or line endings, truncate, empty, retain same size with changed bytes; explicit apply preserves it and returns 3 while another eligible entry may retire | Normalize before hashing, match by version/comment/size alone, let force remove it |
| R5 — path types and root | External/in-root/broken leaf links; external/in-root/broken parent links; FIFO, directory, socket where supported, multiple hard links, prefix-lookalike root, spaces and physical root aliases; no external reads/writes or link replacement | Follow leaf/ancestor, classify dangling link absent, use string-prefix containment, hash special file |
| R6 — stale candidates | Regular, old/new stamp, arbitrary nonempty suffix, symlink, broken link and directory candidates remain unchanged under every public action including repeat apply and cleanup; scans show unsafe/error omission | Add retired base to promotion allowlist, delete candidate after retirement, hide it from report |
| R7 — preview changes | After preview replace with modified/symlink/absent/project-owned entry and apply; no stale authorization, accurate result/exit | Reuse preview digest/state without fresh inspection |
| R8 — backup/delete boundary | Deterministic barrier after backup changes leaf bytes, inode, type or parent; no delete of new entry, backup retained and error 1 | Remove final recheck or verify only backup hash |
| R9 — failure/recovery | Permission/short-write/flush/close/backup collision/unlink failures; first succeeds then second fails; INT/TERM between stages; backups retained, untouched/unattempted paths proved; exercise the recipe emitted by `write_recovery_runbook` through the public generator and prove it restores only into an absent safe path | Ignore copy/unlink error, remove backup in trap, automatically rollback over edit, overwrite recovery destination |
| R10 — idempotence | After successful apply, repeat plan/status/generation/apply; no new backup, no delete, status absent, stale candidates preserved | Infer removed history from backups, generate fresh tombstone/backup for absent path |
| R11 — JSON and exits | Validate actual v1 unchanged and v2/dedicated reports against schemas for every status/result; exact stdout object, correct stderr and 0/1/2/3 exits; new mixed actions fail before write; for each ordinary apply-candidates/cleanup-backups public entrypoint, successful ordinary work plus failed retirement inspection/enumeration returns1 and retains completed writes, existing ordinary failure stays nonzero, and attention-only preservation returns0 | Add retirement to v1, conflate absent with retired, report failed scan as clean, ignore apply exit3, force observer exits0 or discard an ordinary failure |
| R12 — one-shot and exports | Installed canonical home has exact new files; default no delete; explicit flags independent; dry-run with local source plans at correct Git root without source/target writes; unavailable local source exits 1 with guidance | Return early with no plan, fetch/install/switch during dry-run, infer retirement from apply-candidates, stale source fallback |
| R13 — unrelated ownership | Root app README/CHANGELOG, custom/legacy profiles, seats, arbitrary workflows, unknown generated files and existing backups remain unchanged by dedicated actions | Treat HK-07 as generic cleanup or local-only untracking |
| R14 — read-only entrypoints | A probe observes engine paths reached through direct bundle, installed home, updater plan/apply and one-shot; JSON status v1 still parses; preserved candidate names are escaped | Test private classifier only while omitting a public dispatch path |

Fault injection belongs in test harness monkeypatches/subprocess wrappers or
deterministic barriers around the engine's own operations; do not ship an
environment variable that disables containment, hash checks or backup rules.
Mutation tests must execute the changed behavior through the applicable public
boundary and assert filesystem effects/exit/schema, not grep for a defense
string. Each removed defense must turn a previously passing case red for its
intended observable reason, not fail early on an unrelated missing command.

## 10. Gate handoff and limits

Independent `@gate` should assess completeness and the proposed conservative
scope, schema compatibility, no-follow bounds, failure/recovery procedure,
one-shot source limitation and exact packaging ownership against current
integration files. This document does not mark the packet sufficient or
implemented. Core HK fixes are not blocked by HK-07 review. No live retired
artifact is removed while this proposal is being prepared or reviewed.

Model declaration: requested seat `@spec`; executor Codex by owner-approved
substitution; this subagent was launched with inherited model settings and no
explicit model override. Session instructions identify the GPT-6 family. The
exact served-model identifier is not exposed to this runtime and is not claimed
from seat examples, launcher configuration or a model alias.


## Technical amendment — 2026-09-13

Independent technical review Attempt1 requested two bounded corrections: F1 now
assigns the generated recovery recipe to its actual `write_recovery_runbook`
source in writers-runtime, without moving or duplicating that writer; F2 now
defines error precedence and retained ordinary writes for apply-candidates and
cleanup-backups, with public-entrypoint acceptance and mutation cases. These
changes do not approve the proposed destructive policy or authorize deletion.
The proposal remains subject to independent delta review and owner policy choice.

## Implementation status — 2026-10-13

The owner approved this policy and its proposed defaults on 2026-10-13. It is
implemented as specified in `agent-bootstrap/lib/retirement.py`, the bundled
`policies/retired-artifacts-v1.json` inventory (also pinned in code), the
`agent-bootstrap-retirement-v1` and `agent-bootstrap-status-v2` schemas, the
bootstrap entrypoint (dedicated actions, argument validation, read-only
sections, allowlist exclusion, opt-in status v2), `write_recovery_runbook` and
the schema catalog in `lib/writers-runtime.sh`, the one-shot upgrader, the
installer export list and `MANIFEST.md`. Status JSON v1, its schema, the
updater, the local-only checker and normal candidate algorithms are unchanged.

`scripts/test-agent-retirement.py` covers R1–R14 through the public bootstrap,
installed-home, updater and one-shot entrypoints, starting from the HK-06
`v2026.08.10.1` selector, and runs mutation oracles for removed defenses. It
is wired into `scripts/test-fast.sh`, CI and the full bootstrap suite. Two
bounded clarifications: `fingerprints` is a one-element array; dedicated
actions also reject `--only`, and `--retirement-scope` is rejected (exit 2)
with `--refresh-lock`, `--first-10`, `--apply-candidates` and
`--cleanup-backups`, which are outside the accepted list in section 4. Real
one-shot upgrade cases form the suite's `--tier one-shot`, which
`scripts/test-one-shot-upgrade.sh` invokes; one-shot dry-run cases run in the
default fast tier. Version and release metadata are unchanged.
