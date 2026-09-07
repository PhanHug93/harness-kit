# Upgrade-ergonomics overhaul — design

- **Date:** 2026-06-22
- **Branch:** `feat/upgrade-ergonomics`
- **Target version:** `2026.06.22.1`
- **Status:** approved (scope + key forks), technical details delegated

## Problem

Real-world feedback from running `agent-bootstrap 2026.06.21.2` in two consuming
projects (`ESPL iOS` and `ESPL Android`) surfaced three recurring pain clusters
when **upgrading** an already-bootstrapped project. The kit bootstraps cleanly
the first time, but the upgrade/apply path is brittle.

### Evidence (audited 2026-06-21/22, read-only)

iOS (`/Users/admin/project/bap/challenge/iOS`, upgraded 2026.06.14.6 → 2026.06.21.2):
- `apply-candidates` failed backing up into read-only `.codex/`; 6 candidates left
  unapplied in `.codex/` + `.agents/skills/`.
- `agent-guard preflight` could not create `.agents/state` (read-only) → unusable.
- `verify-ai-deps` reported `Fail: 1` purely because the read-only `.codex`
  candidate was unapplied (the `.generated` doctor passes) — a false failure.
- `AGENTS.md` *"Scheme Access Policy"* and `.codex/README.md` *"Git Hygiene"* note
  had to be hand-merged/were lost on regeneration.
- 30+ `.bak.*` left in the tree; reconcile manifest stuck with open checklist.

Android (`/Users/admin/project/bap/challenge/android_2.0-main`, on 2026.06.18.3):
- Upgrade produced a 4-file manual merge conflict (`AGENTS.md`,
  `agent-mode-contracts.md`, `agent-bootstrap.lock.json`, `project-agent-context.md`).
- Custom verification commands inside a MANAGED region were at risk on refresh.
- Stale harness-version strings left in `README.md` / `project-tech-stack.json`.

Already fixed in `2026.06.21.2` (resolve on upgrade, **out of scope here**):
flavor/module-aware Gradle verification, `refresh-lock` preserving
`workflow_preset`, preserve-on-upgrade of filled context files, macOS diff
portability.

## Current mechanism (baseline)

- Generated docs already use harness-owned markers
  `<!-- BEGIN MANAGED: multi-agent-bootstrap:<key> --> … <!-- END MANAGED -->`
  (`lib/writers-docs.sh`), but there is **no in-place block surgery** — `write_file`
  (`lib/core.sh:123`) rewrites the whole file; on conflict it drops a
  `<path>.generated.<stamp>` candidate.
- `write_user_owned_file` (`lib/core.sh:113`) only **preserves whole file** for 4
  files (`project-agent-context.md`, `project-brief.md`,
  `project-tech-stack.md/.json`) — keeps custom but never gains template
  improvements; no merge.
- `backup_existing` (`lib/core.sh:38`) does `cp -p "$path" "$path.bak.$STAMP"`
  **into the same dir** → the read-only failure point.
- `apply-candidates` → `apply_generated_candidates` (`bootstrap-multi-agent-project.sh`).
- `agent-guard.sh:8-9` hard-codes state under `.agents/state`; `:566` `mkdir -p`.
- The one-shot upgrader (`harness-kit-one-shot-upgrade.sh`) generates the
  per-upgrade `docs/agent-configs/HARNESS-RECONCILE.md` manifest.

## Goals

1. Upgrades never lose user customizations in regenerated files (B).
2. Apply / guard / verify degrade gracefully under read-only/sandboxed dirs (A).
3. Upgrades finish clean: no false failures, no leftover clutter, clear state (C).
4. No regressions: existing tests + drift snapshots stay green; on-demand context
   budget stays ≤ 6100 tokens; backward compatible with bootstrapped projects.

## Non-goals

- Re-fixing items already shipped in `2026.06.21.2`.
- Auto-editing user files (retrofit is detect-and-warn only).
- Codex TTY delegation (separate subsystem; deferred).
- Switching the 4 whole-file-preserved context files to marker-merge (future).

---

## A. Sandbox-safe apply / guard / verify

### A1 — agent-guard state fallback (`agent-guard.sh`)

Resolve the state directory once, in order:
1. `$AGENT_STATE_DIR` (new env override) if set and writable.
2. `$PROJECT_ROOT/.agents/state` (current default) if writable.
3. `${TMPDIR:-/tmp}/agent-bootstrap-state/<project-hash>` where `<project-hash>`
   is a stable short hash of the absolute project root (e.g. `cksum` of the path)
   so projects don't collide.

`CONTEXT_PACK` and `ACK_LOG` derive from the resolved dir. If none is writable,
agent-guard **degrades to advisory**: warn once, and state-dependent checks
(`preflight`, context-pack freshness in `check`/`pre-final`) become non-fatal
skips rather than errors. `doctor`/`status` report the resolved state dir.

### A2 — read-only-safe apply (`apply_generated_candidates` + `backup_existing`)

- Before promoting each candidate, **pre-check writability** of the target's
  parent dir. If not writable: **skip that candidate**, print an actionable line
  (`"skipped (read-only): .codex/config.toml — promote with write access or set
  perms"`), and continue (never abort the whole run).
- `backup_existing` becomes best-effort: try in-dir `.bak.$STAMP`; on failure try
  `<state-dir>/backups/<relpath>.bak.$STAMP`; if both fail, warn and proceed
  (the candidate is still on disk and git retains history).
- End-of-run summary: `Applied N, skipped M (read-only): <list>`. Exit status is
  success when the only issues are read-only skips (they are expected in
  sandboxes), so callers/CI don't treat them as hard failures.

### A3 — verify-ai-deps reclassification (`verify-ai-deps.sh`)

- A leftover `<file>.generated.*` candidate is no longer a hard `Fail`:
  - target dir **writable** → `Warn`: "upgrade not finished; run apply-candidates".
  - target dir **read-only** → `Warn`: "candidate blocked by read-only dir;
    promote with write access".
- The Codex doctor check distinguishes "doctor fails because a newer read-only
  `.codex/*.generated.*` candidate is unapplied" → `Warn` (with cause) instead of
  `Fail`. Genuine misconfiguration stays `Fail`.

### A4 — `apply_state` in lock.json (`write_agent_bootstrap_lock`)

Add `"apply_state"` with enum:
- `complete` — no `*.generated.*` candidates present.
- `pending` — candidates present in writable dirs (apply not run).
- `blocked-readonly` — candidates present, at least one in a read-only dir.

Computed by scanning for candidates + dir writability when the lock is written
(generate / refresh-lock / apply-candidates all refresh it). verify/doctor read
it to phrase guidance and to avoid the "version bumped but not really applied"
ambiguity.

---

## B. USER-overlay engine (preserve customizations across regeneration)

### B1 — convention (keyed inverse markers)

Mirror the MANAGED markers with keyed USER regions:

```
<!-- BEGIN USER: <key> -->
… user content, preserved verbatim …
<!-- END USER: <key> -->
```

Templates declare USER anchors with **stable keys** at defined spots; keying
(not free-floating) lets re-injection survive template reordering/restructuring,
consistent with how MANAGED regions are keyed. A fresh region carries a one-line
hint comment so users know where project-specific content goes and that it is
preserved across upgrades.

### B2 — engine (`lib/overlays.sh`, invoked from the render/`write_file` path)

For each overlay-enabled file:
1. If the target file exists, **extract** every `BEGIN USER:<key> … END USER:<key>`
   region from disk into a `key → body` map.
2. Render the new template (which contains USER anchors with default/empty bodies).
3. For each key present in **both** disk and template, replace the template
   region body with the preserved disk body (match by key).
4. **Orphans** (key on disk but absent from the new template): never dropped
   silently — appended under a clearly-marked `<!-- USER (orphaned) -->` trailer
   in the rendered file **and** listed in the reconcile manifest, with a warning.
5. Write through `write_file` so atomic write + candidate/backup-on-upgrade still
   apply.

**Parser:** use `python3` for robust extract/inject (the kit already depends on
python3 for JSON/token estimates). If python3 is absent, fall back to an
`awk`-based extractor as **best-effort** with a warning that overlay preservation
is degraded. Pure-bash marker parsing of arbitrary content is too brittle.

**Idempotency:** rendering twice with empty USER regions yields byte-identical
output; the canonical-export and runtime-snapshot drift tests must stay green.

### B3 — overlay-enabled files (initial set)

- `AGENTS.md` — anchor `agents:extra` (placed before *Priority On Conflict*).
- `.codex/README.md` — anchor `codex-readme:notes`.
- `docs/agent-configs/agent-mode-contracts.md` — anchor `mode-contracts:overrides`.

The 4 whole-file-preserved context files keep their current behavior. Final
anchor list/placement is fixed in the implementation plan.

---

## C. Upgrade hygiene, retrofit, finalization

### C1 — `--cleanup-backups` (opt-in, non-destructive)

New flag on `bootstrap-multi-agent-project.sh` (surfaced by the one-shot
upgrader). Removes `*.bak.*` and superseded `*.generated.*` leftovers. Off by
default; never runs automatically.

### C2 — post-upgrade stale-version scan (`verify-ai-deps.sh`)

Scan `README.md`, `docs/superpowers/specs/project-tech-stack.json`, and
`project-brief.md` for a harness-version string mismatching the lock version →
`Warn` listing each stale reference. No auto-fix (conservative, non-destructive).

### C3 — retrofit detect-and-warn (`harness-kit-one-shot-upgrade.sh`)

When generating an upgrade for an overlay-enabled file, detect content outside
both MANAGED and USER regions that diverges from the template default ("likely
custom"). List it in `HARNESS-RECONCILE.md` with a suggested
`<!-- BEGIN USER: <suggested-key> -->` wrapper. No file is auto-edited.

---

## Testing (kit is test-driven; extend existing suites)

`scripts/test-bootstrap-multi-agent-project.sh` (**run single-threaded** — it is
not parallel-safe):
- USER markers: filled region survives a second bootstrap/apply; empty render is
  idempotent; orphaned key is parked + warned, not lost.
- Read-only apply: `chmod` a generated `.codex`/`.agents` dir read-only; assert
  apply skips with guidance and does not fail the run; agent-guard uses the
  fallback state dir; verify emits `Warn` not `Fail`.
- `apply_state`: lock shows `complete` / `pending` / `blocked-readonly` correctly.
- `--cleanup-backups` removes `*.bak.*`.

`scripts/test-one-shot-upgrade.sh`:
- Reconcile manifest lists likely-custom content with a USER-wrapper suggestion.
- Cleanup path works end-to-end.

Budget/drift: on-demand context estimate stays ≤ 6100 tokens; canonical-export
and runtime-snapshot drift tests stay green; `bash -n` + `git diff --check` clean.

## Versioning & release

- Bump to `2026.06.22.1`; update every version reference together (VERSION,
  MANIFEST.md, README curl/version, one-shot `DEFAULT_REF` + README curl docs,
  drift snapshots, lock fixtures) — version-consistency tests will catch misses.
- One branch, one commit (squash before finishing). CHANGELOG entry. No
  `Co-Authored-By: Claude` trailer for this repo.

## Risks & mitigations

- **Marker engine corrupts user content** → python3 primary + byte-verbatim
  preservation + orphan parking + idempotency tests; awk fallback is best-effort
  with explicit warning.
- **Read-only skips masking real failures** → distinguish read-only (Warn) from
  writable-but-unapplied (Warn) from genuine misconfig (Fail); `apply_state`
  records the truth in the lock.
- **Scope creep** → context files stay whole-file-preserve; Codex TTY deferred;
  retrofit is detect-only.
- **Token budget regression** → new generated content is minimal (USER anchors +
  one-line hints); integration test enforces ≤ 6100.

## Rollout

Land on `feat/upgrade-ergonomics` as a single squashed commit at `2026.06.22.1`.
Existing projects benefit on next upgrade: USER anchors appear in regenerated
files, the reconcile manifest flags content to wrap, and sandboxed applies stop
failing. iOS is the natural validation target (re-run its upgrade post-release).
