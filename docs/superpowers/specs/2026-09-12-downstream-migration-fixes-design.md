# Downstream migration fixes — specification revision 3

Date: 2026-09-12, Asia/Ho_Chi_Minh.
Packet: `downstream-migration-feedback-2026-09-08`.
Branch: `feature/downstream-migration-fixes`.
Source anchor: `ca9c2e5c2b9805c3ff4fa7589d4d2e474b922009`, peeled `v2026.09.08.1`.
Implementation baseline: `fc33f1c7b20fb8f90bfcb01649544fa470e6200b`, `v2026.09.10.2`, internal bundle `2026.09.10.1`. The earlier source anchor remains the U0 reproduction reference. Bring the two intervening upstream commits into the work branch as a reviewable working-tree delta; do not rewrite history or commit implicitly.
Status: requested Flutter Harness refresh completed; owner now requests implementing both build-audit P2 findings and continuing HK fixes. Freeze this amendment and obtain independent `@gate` review before core implementation.
Author: Codex acting as `@spec` at the user's explicit request in the current conversation. This is a packet-scoped substitution; global seats are unchanged.

This document is the canonical revision for the bounded fixes. It addresses F1–F7 in `codex-review.md` Attempt 1. The received downstream report, U0 testimony, original seats design revision 3 and Attempt 1 remain historical evidence. A passing specification gate means the work is specified sufficiently to implement; it does not mean the defects are fixed or that a release is verified.

## 1. Scope and decisions

Included: HK-02 seats destination containment, HK-01 generator/detector read boundaries, HK-05B missing-PATH test portability, HK-06 historical test sources, HK-08 failure diagnostics, build-audit B04 Flutter/native verification paths, and the release metadata required for those changes. Build-audit B03 SDK metadata is a separate small patch in the Flutter application.

Owner decision on 2026-09-12: HK-07 retirement is a separate follow-up specification and does not block these fixes. The current patch contains no retirement deletion, retirement status schema, or retired-CI candidate promotion. The separate packet is `downstream-retirement-policy-HK-07`; its source is this packet's HK-07 finding. No deletion policy is implied by the split.

HK-03, HK-04 and HK-05A concern downstream Gradle extensions not present in the anchored kit. Request their actual diffs before proposing upstream integration. HK-05B is an upstream test defect even though the reported direct `environ["PATH"]` spelling is absent. HK-09 archive/acknowledge and HK-10 context breakdown remain deferred features.

Technical decisions carried forward from the gate review:

- No external write-through bypass for seats. An explicit target root selects the project; it does not waive destination checks.
- Preserve seats' in-root write-through, atomic per-file writes, directory flock and existing configuration-first roster error behavior.
- Harden the generator's ordinary symlink/read/copy boundaries now. Do not claim protection against adversarial path replacement races.
- Preserve both historical migration branches using immutable repository test fixtures; no missing-tags success skip in the final design.
- Diagnostic rows identify failed executions without echoing arbitrary arguments or captured logs.
- Prepare patch metadata `2026.09.12.1`, retaining all upstream changes through v2026.09.10.2. No publication, tag, merge, push or history rewrite is authorized by this specification. The PR target remains unspecified and must be named by the user before PR creation; the historical branch base is not an inferred PR target.

## 2. Preserved contracts

The seats design `2026-09-06-agent-seats-design.md` revision 3 remains authoritative for unaffected behavior: tags/occupants, catalog validation, migration precedence, lossless eight-line resolution, legacy coexistence warning, no-lock valid-init fast path, interactive PTY behavior, atomic write failure handling and roster byte preservation. Keep the 4000/6200 context limits and guard/hook deny+ACK behavior. Preserve existing user-owned briefs and USER regions whenever their source is eligible to read.

Normal generation creates reviewable candidates and preserves existing destinations. `--force` is explicit replacement, and `--apply-candidates` promotes allowlisted replacements. Neither becomes a retirement mechanism. Existing legacy input and seats remain user data, not generated candidates. Root application README/CHANGELOG files are not replaced with the kit's repository documents.

## 3. HK-02: explicit seats root and early containment

### 3.1 Interface

Add `AGENT_SEATS_PROJECT_ROOT` to the seats runtime. If absent, derive it from the installed script's parent as today. If supplied, it must be a nonempty absolute existing directory; canonicalize it using Python path resolution or `pwd -P`, and pass the canonical result into the embedded Python program. Invalid root input returns rc1 before file operations. Existing file overrides retain their current relative-path interpretation against the process working directory; resolve that interpretation before containment checks.

`seats_program` in `lib/writers-runtime.sh` always passes its current `TARGET_DIR` as `AGENT_SEATS_PROJECT_ROOT`, alongside its three existing file overrides. This includes the temporary target during preview/allowlist generation. Do not validate a generated project's files against the bundle installation directory. The installed script retains ordinary default paths beneath its own project.

Use path-component containment: a canonical destination must be a strict descendant of the canonical root. String `startswith` is invalid (`/project-neighbor` is not inside `/project`). Resolve symlinked parents and existing link chains, and resolve the final intended path even when the final component is missing. Resolution loops/errors and a destination equal to root return rc1. `/var` and `/private/var` aliases compare by canonical identity.

### 3.2 Ordering and return codes

After command argument validation, `render`, `set`, `wizard`, `reset` and `init` check BOTH configured `seats.json` and `AGENTS.md` destinations before acquiring a lock, creating directories, reading configuration/proposals or writing files. This includes init's valid-existing-file fast path, which still takes no lock. Refusal names the configured path on stderr, escapes control characters, returns rc1 and leaves all project/external bytes and link identities unchanged; no parent directory or sibling temporary file is created.

Recheck destinations after obtaining the lock and immediately before each write. Preserve the existing save-then-render order for eligible destinations. If an external path is introduced after configuration was already saved, report the existing partial-success rc2 for set/wizard/reset and do not perform the unsafe roster write; no rollback transaction is introduced. The no-write rc1 guarantee applies to invalid destinations present at command preflight. These checks are bounded safeguards, not a race-free sandbox guarantee.

| Eligible in-root case | Result |
| --- | --- |
| Live symlink to seats or AGENTS regular file | Preserve link inode/target spelling, atomically replace resolved target; successful command rc0 |
| Missing/dangling seats link to an in-root destination | init/wizard/reset may create it under existing lifecycle; set/render requiring current seats return rc1 |
| Missing/dangling AGENTS in root | standalone render rc1; set/wizard/reset save valid seats then rc2; init does not render |
| Unbalanced AGENTS roster markers | standalone render rc3; set/wizard/reset save seats then rc2 |
| Roster unreadable/unwritable or write fails | standalone render rc1; set/wizard/reset follow existing configuration-first rc2 |
| Invalid existing seats during init, including appearing while lock is awaited | rc1, bytes preserved; no default overwrite |

An external dangling destination is refused at preflight. A leaf directory/special file is never read as JSON or roster content; existing invalid-file errors remain rc1 unless seats was already saved before the roster failure. Check the external destination policy independently of content validity, so malformed external content is not read first.

Read-only commands keep their output shape and do not render or create files. Generator integration uses only eligible in-root inputs; generic operator-supplied read-only overrides are not redefined by this seats write-boundary change. If the generator cannot seed seats because existing user configuration is invalid, retain its warning/non-overwrite behavior; do not synthesize valid defaults over invalid input.

## 4. HK-01: safe existing-content reads, preview and detection

### 4.1 Classification and scope

Use a shared generator classification policy in `lib/core.sh`, with equivalent self-contained predicates in the emitted detector library. Do not add a new bundle file merely to share a small predicate across independently installed runtimes. Python3 is already a prerequisite; Bash code remains compatible with `/bin/bash` 3.2 and may not depend on GNU `realpath`/`readlink -f`.

For a candidate content source, inspect entry metadata first, canonicalize the root and resolved source, and require an eligible regular file inside the intended root before opening content. Exclude sources beneath the generator/detector's existing pruned roots, and protect `.git`, `.tools`, `.agents/runtime`, `.agents/state`, `.agents/cache`, `node_modules`, `Pods`, `vendor`, `build`, `out`, `.gradle*` and private environment/key material (`.env*`, `local.properties`, `keystore.properties`, `*.jks`, `*.keystore`, `*.pem`, `*.p8`, `*.key`). Apply exclusions to both lexical relative path and resolved relative path. Existing metadata-only warnings for local/keystore properties remain possible without reading their bytes.

Treat an external/unresolvable/dangling symlink as unavailable content. Never classify unreadable/unsafe user-owned knowledge as an empty or unfilled template. Protect the four user-owned brief/context/tech-stack destinations even when content cannot be inspected: preserve the existing entry and warn, rather than overwrite it or offer an automatic replacement.

Scope is the generator/detector data paths described here, including preview and allowlist calculation. It does not make arbitrary installed scripts, explicit external state-directory overrides, user shell commands or adversarial concurrent filesystem mutation safe. Do not present the patch as an authorization boundary.

### 4.2 Reads, candidates and backups

Guard before existing-content `cmp`, USER overlay extraction, filled/unfilled detection, placeholder equality, old lock field reads, diff sanitization and optional-skill/lock metadata reads reachable in the generator's public actions. Reject/omit unsafe reads before helpers open content. Implement the overlay guard in its caller in `core.sh`; `overlays.sh`'s USER transformation semantics remain unchanged.

`append_gitignore_block` in `lib/render.sh` is also an owned direct read/write sink: apply the policy before its `touch`, marker `grep`, backup or append. An external/dangling/unresolvable/special `.gitignore` entry is preserved with an escaped path diagnostic; a mutating action requiring that update returns nonzero, including under `--force`. Do not replace that user-owned entry or create a replacement candidate. Eligible regular files and live in-root links retain the existing managed-block append/skip/idempotence behavior; resolve and check the write destination and parent before appending, preserving eligible link identity. A missing ordinary file may be created only beneath an eligible parent. Earlier safe generation writes may remain. Preview/status may omit unsafe `.gitignore` content, must warn and report stale drift, and must leave the live entry untouched.

For an ordinary generated destination with an external leaf symlink and an eligible in-root parent, default generation preserves that link and may create a fresh ordinary candidate beside it, without carrying the external USER content. `--skip-existing` preserves it without a candidate. `--force` and explicit candidate application may replace the leaf link itself with generated regular content; they never write the referent. Backup a leaf symlink with `cp -Pp`, including the existing fallback-backup branch; test with `-L` as well as existence so a dangling link can be backed up. Do not dereference a candidate symlink; only regular candidate entries are eligible for promotion. Preserve existing candidate allowlist and ordinary error/readonly handling.

Before creating directories, writing a candidate/temp/backup or replacing a destination, verify its parent resolves within the target and outside excluded roots. An escaped parent is an error: skip no unsafe write, name it, return nonzero from the public mutating action. `--force` does not bypass this. Earlier safe writes from generation may remain; no whole-generator transaction is promised. Existing explicit `AGENT_STATE_DIR` fallback semantics are retained, but copied backup content must preserve symlink identity rather than open its referent.

For read-only `--diff`/`--status`, unsafe old content produces an escaped path/omission warning on stderr and an empty old-side representation for ordinary generated files; never show the referent or print raw link target text. Preserve machine-readable stdout shape. Do not report drift as clean when an expected generated destination could not be compared; use the existing `generated_file_drift=stale` value. Do not add a status schema field in this patch. User-owned protected knowledge stays out of replacement diffs as today.

### 4.3 Disposable preview representation

`copy_target_for_diff` and every caller used by diff/drift/allowlist share the same safe snapshot rules. Walk without following directory symlinks; do not copy links that can later resolve back into the live project or into outside data. Regular eligible files are copied with modes. For an in-root leaf link to an eligible regular file, materialize its checked bytes as a regular file at the corresponding snapshot path. This preserves configured seats/USER values in preview while leaving the original link untouched. External/broken/special entries are omitted with metadata-only diagnostics.

An in-root directory link is not recursively traversed. If it supplies a generated configuration parent or detector root used by this operation, mirror the specific required regular files under that lexical parent into ordinary snapshot directories after individual containment checks; never leave an absolute link pointing at the live target. If such required configuration cannot be represented safely, fail preview with a path diagnostic instead of silently initializing defaults. In particular, an omitted existing seats/legacy configuration must not be mistaken for a fresh project; fail preview rather than claim an authoritative default roster. Optional unrelated symlink directories may be omitted.

Materialize eligible detector marker directories at their lexical snapshot paths even when they are empty or contain no eligible files. This includes ordinary directories and eligible in-root directory symlinks accepted as markers under section 4.4; create ordinary directories without recursively following those links. Preserve the detector's depth/prune rules. Live and snapshot detection must agree for an empty `Only.xcodeproj`, an empty `.xcworkspace`, and the direct directory-style signals; neither an outside marker nor a broken marker link becomes snapshot evidence.

Snapshot creation and all preview subprocesses must leave the live tree's bytes, modes and link identities unchanged, including in-root absolute and relative symlink fixtures. Temporary generated candidates/configuration are confined to the disposable root.

### 4.4 Detector markers and content

Update `agent_has_file`, name/pattern lookup, package JSON reads, named-file content searches, Gradle module-file predicates and direct directory marker checks to apply the root policy before treating a marker as evidence or reading its bytes. Invalid name matches do not stop the search: continue until a valid marker is found within the existing search depth/prune constraints. Do not add traversal of arbitrary symlink directories.

File evidence (package/Gradle/Python files, `*.csproj`, `*.sln`, `*.swift`) requires an eligible regular file. Directory evidence (`*.xcodeproj`, `*.xcworkspace`, and existing directory-style signals such as wear/domain directories) requires an eligible in-root directory. Preserve legitimate Xcode bundle-directory detection; a blanket `-type f` replacement is incorrect. Broken/outside `*.csproj` and package links must not add stacks/verification commands. Keep deterministic output and existing stack/module depth semantics for ordinary projects.

`lib/detect.sh` owns emitted code; regenerate `agent-bootstrap/agent-tech-stack-lib.sh` byte-for-byte. Bump `AGENT_TECH_STACK_LIB_VERSION` in both to `2026.09.12.1`; install/refresh locks through the existing candidate lifecycle, not by accepting a stale detector hash.

### 4.5 Build-audit B04: runnable commands for nested Flutter platforms

Confirmed downstream evidence: `.agents/reviews/mobile-build-config-20260912/report.md` in the downstream Flutter app. Root-level `xcodebuild -list` exits 66; explicit `ios/Runner.xcworkspace` discovery and unsigned release build pass. The public guard executes parsed argv with `shell=False`, always from project root. Do not emit `cd`, parentheses, shell chaining, or rely on shell expansion.

For eligible Flutter roots, detect the nested `android/settings.gradle[.kts]` and module build/manifest signals under the same original-root read policy. Record its modules with their existing Gradle colon names, identify the Android Kotlin/Java stack from nested content (including `org.jetbrains.kotlin.jvm`/Kotlin source when the app plugin is supplied by Flutter), and explain in a warning that these module paths are relative to `android/`. Preserve standalone root Gradle semantics; do not create root settings/wrapper files or fabricate module names when settings are absent.

Gate both Android commands on eligible nested Android platform evidence: an eligible `android/` directory, its settings file and Android module build/manifest signals under the original project root policy. Only for that platform emit `flutter build appbundle --release` after Flutter test/analyze, then emit `./android/gradlew -p android testDebugUnitTest` if its eligible wrapper also exists. A Dart/pubspec-only root, Flutter without Android, or an outside/broken/excluded Android platform adds neither command. Treat the nested-wrapper candidate as full scope so fast verification on a fresh checkout does not require a prior Flutter Android build to prepare the wrapper. Retain existing classification for standalone Gradle unit tests. These commands have separate existing report rows; no report schema or execution-cwd field is needed.

For Xcode discovery, select an eligible workspace before a project, deterministically by relative path within current depth bounds. Exclude the internal `*.xcodeproj/project.xcworkspace` from workspace selection; never select excluded/external/broken markers. Emit `xcodebuild -list -workspace <quoted-relative-path>` or `-project <quoted-relative-path>`. Quote with POSIX shlex-compatible tokens, including spaces and apostrophes; Bash ANSI-C quoting is not compatible with the guard parser. Warn on multiple eligible containers and state which was selected; do not imply a discovered scheme.

For an eligible Flutter `ios/Runner.xcodeproj` or `ios/Runner.xcworkspace`, additionally emit `flutter build ios --release --no-codesign` and omit the generic unresolved Xcode test placeholder. The report describes native compilation only; project-specific RunnerTests build/execution remains an explicit verification command in the project docs. For other Xcode roots retain an explicitly unresolved scheme test candidate and its warning, now with the same concrete container arguments. Never claim the placeholder passed. Do not invoke Xcode during detection or inspect signing/SDK-machine files.

Tests must cover: ordinary and space/apostrophe root/container names; nested Flutter Android Kotlin with modules and correct wrapper `-p` argv; Dart/pubspec-only, Flutter-without-Android and unsafe/outside/broken Android platforms emitting neither Android command; Flutter iOS avoiding root-only discovery and the generic placeholder; root native Android unchanged; generic Xcode fallback retaining unresolved scheme; deterministic multiple-container warning; internal workspace exclusion; outside/broken container rejection; fast/full classification. A generated guard fixture uses executable stubs that assert argv and cwd, rather than invoking a shell. Mutation oracles remove `-workspace/-project`, nested `-p`, or full classification independently and must fail the corresponding assertion. Validate on the real Flutter project with full guard, Android AAB, iOS unsigned build and explicit native test compilation; do not equate build-for-testing with executed XCTest.

## 5. HK-05B: missing PATH in test shims

At `scripts/test-agent-seats-launcher.py:base_env` and `scripts/test-agent-seats.py:fsize_limited_run`, use `os.defpath` only when `PATH` is absent; prepend the shim directory as before. Preserve an explicitly supplied PATH, including intentionally empty PATH. Do not change production launcher routing or Gradle execution.

Add a no-PATH orchestration case that removes PATH from a copied environment and invokes the test with an absolute Python executable. Guard against recursive self-invocation of the orchestration case. The full eight launcher groups must run; the fsize probes must reach the intended Python write boundary and assert old bytes remain, rather than passing on an unrelated missing-tool error. Keep a paired inherited-PATH run and preserve all existing assertions.

## 6. HK-06: two historical sources with explicit selection

### 6.1 Interface and behavior

Add `--historical-source auto|tags|fixtures` to `scripts/test-agent-seats-migration.py`. Default `auto`; CLI wins over optional environment `HARNESS_MIGRATION_HISTORICAL_SOURCE` of the same enum. Invalid enum returns usage error before fixtures are created. `scripts/test-one-shot-upgrade.sh` forwards the environment selection to its child; CI may use the environment to run the whole suite in tags mode. Existing `--source-dir` still selects NEW code only; old history comes from the test repository ROOT or packaged fixtures, never by guessing the new source's repository.

- `auto`: for each requested ref, use the local real tag if present and trusted, otherwise its packaged fixture. No network fetch.
- `tags`: require all requested historical refs locally and verify their commits; absent or unexpected history fails.
- `fixtures`: use packaged fixtures even if tags exist, proving standalone operation.
- Retain `--legacy-ref`; the accepted set for this packet is exactly the two pinned refs below. Reject other explicit refs with guidance rather than silently using a default. Duplicate requested refs are deduplicated in input order. No-ref input means both defaults in the current order.
- A tag present at an unexpected commit, an export error after successful resolution, malformed archive or corrupted/missing fixture fails. Auto does not mask those errors as absent history.

Print `HISTORICAL ref=<tag> source=<tags|fixtures> commit=<sha>` once per branch. Add equivalent source/provenance fields to the migration test's own evidence summary; this is not the installed guard report schema. Existing migration assertion labels/results remain, and all post-loop/fresh-target cases continue to run against explicitly selected fixture variables rather than depending on an accidentally skipped loop.

### 6.2 Packaged format and provenance

Create repository-only `scripts/fixtures/historical-bundles/README.md`, `manifest.json`, `v2026.08.10.1.tar`, `v2026.09.07.1.tar`. Each tar is the complete regular-file/directory tree returned by `git archive --format=tar <pinned-commit> agent-bootstrap`; preserve file modes and bytes. No fixture is installed into canonical home or generated targets. Do not edit old default profiles or embedded historical versions to match current catalogs.

| Ref | Peeled commit | Regular files | Export size | Archive SHA-256 observed on 2026-09-12 |
| --- | --- | --- | --- | --- |
| v2026.08.10.1 | b1907f5fe7caf9d9e401606a93fa0815739b6df0 | 58 | 542720 bytes | dfe80d08e59f8113e7eec22c3b010b7a1d0e771beb2b766ba04fe8a8dc8af715 |
| v2026.09.07.1 | cf8f326b61788ed3ed8577eb12511613303dc44a | 57 | 542720 bytes | 7d7ec787b69da3e6fc6797cc4eaa98a8e75fa7f3a070f75a83f7dabbd7d054e6 |

`manifest.json` schema identifier is `harness-historical-fixtures/v1`; top-level `fixtures` is a map keyed by those refs. Each entry contains `commit`, relative `archive`, `archive_sha256`, `archive_bytes`, `files` (sorted relative path → sha256 + octal mode string). The implementation generates and verifies every per-file record from the pinned export; no manually invented digest. The archive digests above identify the observed artifacts, while per-file content/mode comparison is the cross-Git-version equivalence oracle if tar header serialization differs.

Before extraction verify the packaged tar digest/size against the manifest. Reject absolute/traversal/duplicate member paths, links, special entries, members outside `agent-bootstrap/`, unexpected file count/content/modes, and any entry missing from inventory. Extract into a new disposable directory; do not use permissive `extractall`. Real-tag exports undergo the same path/type checks and content/mode comparison. Corruption is a failing test, never a skip or a regenerated fixture.

CI tags mode compares both pinned exports to packaged file bytes/modes; a separate fixture-mode invocation runs from a disposable tagless repository test tree containing scripts + fixtures + current bundle. Test partial tags, forced tags without history, forced fixtures, unknown refs and corrupt/missing fixtures. Preserve all substantive old-generator → public one-shot → candidate/apply → launcher/knowledge/idempotence assertions.

## 7. HK-08: safe per-execution failure lines

After an executed result is appended, emit exactly one new stderr line for status `fail`, `error` or `timeout`, in detector order:

`agent-guard: verify[<one-based detector index>] <escaped executable basename> · exit <integer> · timeout <yes|no> · log <escaped report log_path>`

Use the same parsed argv used for execution, strip its directory from argv[0], and omit all remaining arguments. The index disambiguates repeated executables and maps directly to the existing command/report/log. Escape backslash as `\\`; escape CR/LF/tab/ESC, other C0/C1 controls and Unicode line separators as literal `\uXXXX` (supplementary code points as `\UXXXXXXXX`), so each diagnostic is one physical line. Apply the same escape function to log paths. Do not truncate identifiers or use shell evaluation.

Use existing `exit_code`; timeout is yes only when status is timeout, which currently records 124. Start error records 127 and timeout no. Print neither raw exception payload nor argv values nor captured output. Do not add a label/timeout field to installed report JSON, and do not change telemetry, exit codes, duration/summary accounting, advisory behavior or aggregate messages.

Ordinary skipped entries have no exit/log and receive no new failure line. Keep their existing warnings distinct. Budget exhaustion remains its existing summary/warning path; do not manufacture an executed result. Test failure/start-error/timeout each mixed with a passing command, repeated executable identity, placeholder/full-scope skip, synthetic argument secrets/control characters, and escaped log paths. Pass and skip entries must never appear in the new failure-row format.

## 8. Release and exact ownership

Bundle version changes from baseline `2026.09.10.1` to `2026.09.12.1`; detector version changes independently to `2026.09.12.1`. Keep historical tags/archives unchanged. MANIFEST's version changes; its bundle inventory and installer file list stay unchanged because no new runtime file is introduced. Current operator pins change; historical changelog/spec entries are not rewritten. The upstream v2026.09.10.2 baseline already contains seat catalog, Git-policy and test-fixture changes; preserve them without counting them as new HK implementations.

| Owned path | Permitted change |
| --- | --- |
| agent-bootstrap/agent-seats.sh | Target-root interface, containment and command ordering only |
| agent-bootstrap/lib/writers-runtime.sh | seats_program target root; no unrelated runtime/verification rewrite |
| agent-bootstrap/bootstrap-multi-agent-project.sh | Safe snapshot/diff/status/allowlist/candidate reads and parents; bundle version |
| agent-bootstrap/lib/core.sh | Path/read predicates, user-owned/overlay/equality guards, link-preserving backup |
| agent-bootstrap/lib/render.sh | Guard generator lock/metadata reads and append_gitignore_block direct read/write sink; preserve eligible lock/candidate/managed-block semantics |
| agent-bootstrap/lib/detect.sh | Canonical detector predicates/version and section 4.5 nested Flutter/platform commands |
| agent-bootstrap/agent-tech-stack-lib.sh | Exact emitted detector snapshot |
| agent-bootstrap/agent-guard.sh | Per-execution stderr diagnostics and section 4.5 full-scope classification of nested Flutter wrapper command; execution/report schema unchanged |
| scripts/test-agent-seats.py | Boundary matrix and fsize missing-PATH case |
| scripts/test-agent-seats-launcher.py | Missing-PATH pair and generated target-root integration |
| scripts/test-agent-seats-migration.py | Historical source selector, safe fixtures/provenance, existing migration assertions |
| scripts/test-one-shot-upgrade.sh | Source-mode forwarding/coverage; preserve public upgrade assertions |
| scripts/test-bootstrap-multi-agent-project.sh | Generator/detector/diagnostic regression cases, release pins and mirrors |
| scripts/fixtures/historical-bundles/{README.md,manifest.json,v2026.08.10.1.tar,v2026.09.07.1.tar} | Immutable repository test data and provenance |
| .github/workflows/test.yml | Both OS jobs, explicit tags and tagless fixtures, missing-PATH and Linux read-boundary coverage |
| agent-bootstrap/VERSION; agent-bootstrap/MANIFEST.md | Synchronized patch version, inventory unchanged |
| agent-bootstrap/harness-kit-one-shot-upgrade.sh | Default/help ref pin only; no retirement or unrelated upgrade behavior |
| README.md; agent-bootstrap/README.md; docs/agent-configs/bootstrap-multi-agent-project/README.md | Current pins and operators' boundary/fixture/diagnostic guidance |
| CHANGELOG.md | New patch entry; previous entries unchanged |
| This spec; selected packet task.md/review-brief.md/user-decision.md/state.json | Scope, traceability, authority and handoff |

`overlays.sh`, `writers-docs.sh`, installed runtime snapshots unrelated to detection, schema catalogs, installer inventory, global seats configuration, dependency versions and downstream application code remain outside implementation ownership. If an additional source read boundary requires another file, return the precise call site for a bounded spec amendment rather than silently broadening ownership. No root `scripts/agent-tech-stack-lib.sh` is created. No generated target is committed.

## 9. Acceptance matrix and mutation oracles

Each acceptance ID is mandatory for the included scope. Reuse existing test files; preserve existing assertions and labels. The mutation descriptions name the production boundary that must make the new test fail, not a fake that mirrors the intended result.

| ID | Observable acceptance | Negative/mutation oracle |
| --- | --- | --- |
| AC1 / F1 | Fresh bundle invocation targeting a different root seeds correct seats; installed invocation and temporary preview use their own roots; canonical path aliases succeed | Remove target-root transport: fresh-target test fails |
| AC2 / F1 | All five mutating commands refuse external seats or AGENTS, escaped parents/prefix-neighbor/dangling external paths, rc1 no preflight writes; eligible broken/internal cases retain section 3 codes | Move containment after save or omit one destination: byte/link/parent assertions fail |
| AC3 / F4 | Diff/status/generate/apply/skip/force never open external USER/package/lock/knowledge/.gitignore referents; unsafe .gitignore mutation refuses without altering link/referent; candidates omit outside sentinel; backups preserve link identity; escaped parents are refused | Restore overlay read/cmp/direct sanitize/backup dereference/.gitignore append individually: relevant sentinel/type/syscall assertion fails |
| AC4 / F4 | Preview preserves in-root seats/USER values and eligible empty detector marker directories without touching live absolute/relative link targets; unsafe required configuration fails rather than defaults | Restore link-copy into preview, silently drop existing seats or omit empty marker directory: live-tree/config/detector equivalence fails |
| AC5 / F4 | Outside/broken file and directory markers do not add stacks or commands; a valid second match is found; ordinary Xcode directory and Gradle/package cases still detect correctly; live/snapshot results agree for empty ordinary and eligible linked directory markers | Restore unchecked name/package/module/directory predicate: false-positive fixture fails; blanket file-only mutation loses Xcode fixture |
| AC6 / F2 | Missing-PATH launcher runs all eight groups and fsize checks reach intended writer; inherited PATH remains green; explicit PATH respected | Restore empty missing-PATH fallback: no-PATH test fails with missing bash/tool |
| AC7 / F5 | Both full historical migrations pass via tags and tagless fixtures; same config/USER/legacy/idempotence assertions; source logged accurately | Replace an old fixture with current defaults or change archive byte/mode: integrity/equivalence or migration assertion fails |
| AC8 / F5 | Partial tags fallback per ref; forced-tag missing, unknown ref, corrupt/missing fixture and export failure fail; no success skip | Broad catch-and-skip mutation must fail negative outcome assertions |
| AC9 / F6 | Exactly one correctly indexed safe line for each fail/error/timeout; matching existing report/log; pass/skip not mislabeled; argument sentinel absent | Remove one failure-class emitter or print raw argv: count/status/sanitization assertion fails |
| AC10 / F7 | Bundle/current pins synchronized at patch version; detector version updated; generated detector equals canonical emitter; inventory unchanged | Leave one current version/snapshot stale: existing drift/pin suite fails |
| AC11 / all | Three repository suites + focused seats/launcher cases green on non-root macOS Bash3.2 and Linux; full reports identify skips without counting them as pass | Run new regression cases against U0 first; each must fail at its intended boundary |
| AC12 / F2,F3 | Downstream reply corrects HK-05B attribution; HK-03/04/05A request diffs; HK-07 explicitly separate; no retired-file deletion included | Spec/review changed-file audit finds any retirement code or blanket HK05 exclusion |
| AC13 / B04 | Nested Flutter/native argv, scope and Xcode container behavior follow section 4.5; real Flutter full guard has no unresolved native placeholder or wrong-root discovery | Remove Xcode container, nested Gradle `-p`, quoting or full classification: generated executable-argv fixtures fail |

For Linux no-read evidence, use a synthetic outside directory and trace the generated public actions with child following and resolved descriptors (`strace -f -yy -e trace=open,openat,openat2`). Assert no successful descriptor resolves into that directory; tracing only path strings misses symlink dereference. Install/use strace in the Linux CI test job, not on the user's host. macOS uses output/hash/lstat/readlink and complete live-tree comparison as behavioral evidence; it is not represented as exhaustive syscall tracing. If strace is unavailable in a local run, record that check as not run, never passed; Linux CI remains required for implementation closure.

## 10. Verification commands and spec gate

At implementation/verification, run from a disposable review checkout or the dedicated work branch using existing repository wrappers for Git:

```text
/bin/bash scripts/test-onboarding-fixtures.sh
/bin/bash scripts/test-bootstrap-multi-agent-project.sh
HARNESS_MIGRATION_HISTORICAL_SOURCE=tags /bin/bash scripts/test-one-shot-upgrade.sh
python3 scripts/test-agent-seats-migration.py --historical-source fixtures --evidence-dir <fresh-output-directory>
```

The output-directory argument is supplied by the runner, not a literal placeholder passed to a shell. The tagless fixture-mode CI case must copy the repository test scripts, fixtures and new bundle into its own repository with no historical refs and invoke the same fixture-mode command there. Record actual commands, exit codes and log locations. These repository suites are isolated: they need no real Codex host, user-project upgrade, downstream Gradle build or global install. This isolation does not waive the separately authorized real-Flutter acceptance in section 4.5/AC13: after reviewing the source patch, apply it to meditation_music's project-local Harness and run the specified full guard/AAB/unsigned iOS/native-compilation checks there. Global runtime installation remains outside scope.

For this document-only gate revision, verify source anchor, archive provenance, owned path existence, input/history hashes, AC-to-finding coverage, internal consistency and the reviewer's independent adequacy verdict. Do not rerun lengthy unchanged runtime suites merely to claim the spec is fixed; the prior baseline remains dated evidence and no current implementation is certified.

After owner scope confirmation, `@spec` freezes the revision and a fresh `@gate` reviewer reads it without author-session history. Append Attempt 2 to the existing review; do not edit Attempt 1. A yes verdict must name the reviewed spec digest and any accepted limits. If no, amend the concrete gaps and re-review the revised digest. Keep `base_commit` null and implementation verification not_run until actual implementation begins. Closing the spec gate does not close the overall task or authorize implementation/publishing beyond the user's requested scope.
