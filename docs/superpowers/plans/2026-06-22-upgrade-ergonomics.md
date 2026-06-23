# Upgrade-ergonomics Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make harness upgrades non-destructive and sandbox-safe — preserve user customizations across regeneration, degrade gracefully under read-only dirs, and finish upgrades clean.

**Architecture:** Three independent-ish clusters on `feat/upgrade-ergonomics`, released as `2026.06.22.1`. (A) sandbox-safe apply/guard/verify + `apply_state`; (B) keyed inverse `USER` markers with a python3/awk extract-reinject engine; (C) hygiene (cleanup, stale-version scan, retrofit detect-and-warn). Spec: `docs/superpowers/specs/2026-06-22-upgrade-ergonomics-design.md`.

**Tech Stack:** POSIX/bash 3.2 (macOS), python3 (already a dependency for JSON/token math), the kit's `scripts/test-bootstrap-multi-agent-project.sh` (NOT parallel-safe — run single-threaded) and `scripts/test-one-shot-upgrade.sh` harnesses.

**Conventions:** route git through `rtk`; no `Co-Authored-By: Claude` trailer; one branch → one commit (squash at the end). Each task commits incrementally during dev; Phase D squashes.

---

## Phase A — Sandbox-safe apply / guard / verify

### Task A1: agent-guard writable-state fallback

**Files:**
- Modify: `agent-bootstrap/agent-guard.sh:5-9` (state vars) + `:478`, `:563-566` (mkdir sites) + `doctor`/`status` output
- Test: `scripts/test-bootstrap-multi-agent-project.sh` (guard section near `.agents/state` asserts ~955-1070)

- [ ] **Step 1: Write failing test** — append to the guard test block: with the generated target's `.agents/` made read-only, `scripts/agent-guard.sh preflight` must succeed and write the context pack under the fallback dir.

```bash
# in test-bootstrap-multi-agent-project.sh, after existing guard assertions
RO_GUARD_DIR="$TMP_DIR/ro-guard"
cp -R "$GUARD_DIR" "$RO_GUARD_DIR"
chmod -R a-w "$RO_GUARD_DIR/.agents"
AGENT_STATE_DIR="$RO_GUARD_DIR/.tools/agent-state" \
  bash "$RO_GUARD_DIR/scripts/agent-guard.sh" preflight >"$TMP_DIR/out/guard-ro.out" 2>&1 \
  || fail "agent-guard preflight must not hard-fail under read-only .agents"
[[ -f "$RO_GUARD_DIR/.tools/agent-state/context-pack.json" ]] \
  || fail "agent-guard must write context pack to fallback state dir"
chmod -R u+w "$RO_GUARD_DIR/.agents"
```

- [ ] **Step 2: Run to verify it fails** — `bash scripts/test-bootstrap-multi-agent-project.sh` → FAIL (preflight errors on read-only `.agents/state`).

- [ ] **Step 3: Implement** — in `agent-guard.sh`, replace the hard-coded state paths with a resolver. After `PROJECT_ROOT=...`:

```bash
resolve_state_dir() {
  local candidate
  for candidate in \
    "${AGENT_STATE_DIR:-}" \
    "$PROJECT_ROOT/.agents/state" \
    "${TMPDIR:-/tmp}/agent-bootstrap-state/$(printf '%s' "$PROJECT_ROOT" | cksum | tr -d ' \t')"; do
    [[ -n "$candidate" ]] || continue
    if mkdir -p "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then
      printf '%s\n' "$candidate"; return 0
    fi
  done
  return 1
}
if STATE_DIR="$(resolve_state_dir)"; then
  STATE_WRITABLE=true
else
  STATE_DIR="$PROJECT_ROOT/.agents/state"; STATE_WRITABLE=false
fi
CONTEXT_PACK="$STATE_DIR/context-pack.json"
ACK_LOG="$STATE_DIR/guard-ack.log"
```

In `write_context_pack` and the ACK writer, drop the now-redundant `mkdir -p` (resolver made it) but keep a guard: if `[[ "$STATE_WRITABLE" != true ]]`, `warn "state dir not writable; guard advisory-only"` and `return 0` instead of writing. In `check`/`pre-final` freshness, when `STATE_WRITABLE=false` emit an advisory warning and skip the fatal `fail`. `doctor`/`status` print `state dir: $STATE_DIR`.

- [ ] **Step 4: Run to verify pass** — `bash scripts/test-bootstrap-multi-agent-project.sh` → guard-ro assertion PASSes; existing guard assertions still pass.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(guard): writable-state fallback for read-only .agents"`

---

### Task A2: read-only-safe apply-candidates + best-effort backup

**Files:**
- Modify: `agent-bootstrap/lib/core.sh:38-43` (`backup_existing`) + `agent-bootstrap/bootstrap-multi-agent-project.sh:488` (`apply_generated_candidates`)
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — generate a target, create a `.codex/config.toml.generated.<stamp>` candidate, make `.codex` read-only, run apply-candidates; assert it exits 0, prints a `skipped (read-only)` line, and does not abort.

```bash
RO_APPLY_DIR="$TMP_DIR/ro-apply"
bash "$BOOTSTRAP" --target "$RO_APPLY_DIR" --workflow full >/dev/null
printf 'x\n' > "$RO_APPLY_DIR/.codex/config.toml.generated.20990101-000000"
chmod a-w "$RO_APPLY_DIR/.codex"
apply_ro_out="$(bash "$BOOTSTRAP" --target "$RO_APPLY_DIR" --apply-candidates 2>&1)" \
  || fail "apply-candidates must not abort on read-only dir"
need_contains "$apply_ro_out" "skipped (read-only)" "apply reports read-only skip"
chmod u+w "$RO_APPLY_DIR/.codex"
```

- [ ] **Step 2: Run to verify it fails** — apply aborts / errors on the read-only `cp` backup.

- [ ] **Step 3: Implement** — `backup_existing` best-effort:

```bash
backup_existing() {
  local path="$1"
  [[ -e "$path" && "$BACKUP" == "true" ]] || return 0
  local dir; dir="$(dirname "$path")"
  if [[ -w "$dir" ]] && cp -p "$path" "$path.bak.$STAMP" 2>/dev/null; then return 0; fi
  local fallback="${AGENT_STATE_DIR:-$TARGET_DIR/.tools/agent-state}/backups"
  if mkdir -p "$fallback" 2>/dev/null && cp -p "$path" "$fallback/$(basename "$path").bak.$STAMP" 2>/dev/null; then
    log "backup (fallback): $fallback/$(basename "$path").bak.$STAMP"; return 0
  fi
  log "warn: could not back up $path (read-only); proceeding"; return 0
}
```

In `apply_generated_candidates`, before promoting each candidate compute `target_dir="$(dirname "$base")"`; if `[[ ! -w "$target_dir" ]]`, `printf '  skipped (read-only): %s\n' "$rel_base"`, increment a `skipped` counter, and `continue`. Track `applied`/`skipped`; print `Applied $applied, skipped $skipped (read-only)` at the end. Always exit 0 when the only problem is read-only skips.

- [ ] **Step 4: Run to verify pass** — apply-ro assertion PASSes; existing apply assertions still pass.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(apply): read-only-safe candidate promotion + best-effort backup"`

---

### Task A3: verify Codex-doctor read-only/candidate awareness

**Files:**
- Modify: `agent-bootstrap/verify-ai-deps.sh:~857-865` (Codex doctor check) — note this is the generated verifier source; mirror into `agent-bootstrap/lib/writers-*.sh` only if the check is templated there (grep first).
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — in a generated target, create `.codex/codex-mode.sh.generated.<stamp>`, make `.codex` read-only, run `verify-ai-deps.sh`; assert the Codex-doctor line is a `warn` mentioning the blocked candidate, and the overall `Fail` count is 0.

```bash
RO_VERIFY_DIR="$TMP_DIR/ro-verify"
bash "$BOOTSTRAP" --target "$RO_VERIFY_DIR" --workflow full >/dev/null
cp "$RO_VERIFY_DIR/.codex/codex-mode.sh" "$RO_VERIFY_DIR/.codex/codex-mode.sh.generated.20990101-000000"
chmod a-w "$RO_VERIFY_DIR/.codex"
verify_ro="$(cd "$RO_VERIFY_DIR" && AGENT_BOOTSTRAP_SKIP_SMOKE=1 bash scripts/verify-ai-deps.sh 2>&1 || true)"
need_contains "$verify_ro" "Fail: 0" "read-only codex candidate is not a hard fail"
chmod u+w "$RO_VERIFY_DIR/.codex"
```

- [ ] **Step 2: Run to verify it fails** — current check `fail`s when `.codex/codex-mode.sh doctor` fails.

- [ ] **Step 3: Implement** — wrap the Codex-doctor check: before running doctor, detect a pending codex candidate via the existing `pending_bootstrap_generated_candidate` (filter for `.codex/`). If one exists and its dir is not writable, `warn "Codex doctor skipped: read-only .codex candidate unapplied: <rel>"` and skip the `fail`. Otherwise keep current behavior (`ok` on pass; on fail, `warn` if any `.codex/*.generated.*` exists, else `fail`).

- [ ] **Step 4: Run to verify pass** — verify-ro assertion PASSes; existing verify assertions unchanged.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(verify): downgrade read-only-blocked Codex doctor to warn"`

---

### Task A4: `apply_state` in lock.json

**Files:**
- Modify: `agent-bootstrap/lib/render.sh:80` (`write_agent_bootstrap_lock`) + `agent-bootstrap/lib/detect.sh:455` if scan helper fits there; lock schema validation in `agent-bootstrap/lib/writers-runtime.sh:~872` (add `apply_state` to allowed keys)
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — fresh bootstrap → lock `apply_state` is `complete`; after planting a writable-dir candidate and refresh-lock → `pending`; after planting a read-only-dir candidate → `blocked-readonly`.

```bash
LOCK="$TMP_DIR/docs/agent-configs/agent-bootstrap.lock.json"
need_contains "$(cat "$LOCK")" '"apply_state": "complete"' "fresh lock apply_state complete"
printf 'x\n' > "$TMP_DIR/AGENTS.md.generated.20990101-000000"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TMP_DIR" --refresh-lock >/dev/null
need_contains "$(cat "$LOCK")" '"apply_state": "pending"' "writable candidate -> pending"
rm -f "$TMP_DIR/AGENTS.md.generated.20990101-000000"
```

- [ ] **Step 2: Run to verify it fails** — `apply_state` absent.

- [ ] **Step 3: Implement** — add a helper used by `write_agent_bootstrap_lock`:

```bash
compute_apply_state() {
  local found=false ro=false c d
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    found=true; d="$(dirname "${c%.generated.*}")"
    [[ -w "$d" ]] || ro=true
  done < <(find "$TARGET_DIR" -path "$TARGET_DIR/.git" -prune -o -name '*.generated.*' -print 2>/dev/null)
  if [[ "$found" != true ]]; then printf 'complete\n';
  elif [[ "$ro" == true ]]; then printf 'blocked-readonly\n';
  else printf 'pending\n'; fi
}
```

Emit `"apply_state": "<value>"` into the lock JSON. Add `apply_state` to the lock-schema allowed-keys check in `writers-runtime.sh` so the generated verifier accepts it.

- [ ] **Step 4: Run to verify pass** — apply_state assertions PASS; lock schema validation still passes.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(lock): record apply_state (complete|pending|blocked-readonly)"`

---

## Phase B — USER-overlay engine

### Task B1: `lib/overlays.sh` extract/inject engine

**Files:**
- Create: `agent-bootstrap/lib/overlays.sh`
- Test: `scripts/test-bootstrap-multi-agent-project.sh` (new overlay block)

- [ ] **Step 1: Write failing test** — call the engine directly: given an OLD file with a filled `USER:agents:extra` region and a NEW template with an empty same-key region, the merged output contains the old body; an OLD key absent from NEW is parked under `USER (orphaned)`.

```bash
. "$CANONICAL_DIR/agent-bootstrap/lib/overlays.sh"
old="$TMP_DIR/ov-old.md"; new="$TMP_DIR/ov-new.md"; out="$TMP_DIR/ov-out.md"
printf '<!-- BEGIN USER: agents:extra -->\nKEEP-ME\n<!-- END USER: agents:extra -->\n<!-- BEGIN USER: gone:key -->\nORPHAN-ME\n<!-- END USER: gone:key -->\n' > "$old"
printf 'top\n<!-- BEGIN USER: agents:extra -->\n<!-- hint -->\n<!-- END USER: agents:extra -->\nbottom\n' > "$new"
overlay_merge "$old" "$new" > "$out"
need_contains "$(cat "$out")" "KEEP-ME" "filled user region preserved"
need_contains "$(cat "$out")" "USER (orphaned)" "orphaned region parked"
need_contains "$(cat "$out")" "ORPHAN-ME" "orphaned body not lost"
```

- [ ] **Step 2: Run to verify it fails** — `overlay_merge` undefined.

- [ ] **Step 3: Implement** — `overlay_merge OLD NEW` prints merged NEW to stdout. python3 primary:

```bash
overlay_merge() {
  local old="$1" new="$2"
  if command -v python3 >/dev/null 2>&1; then
    OVERLAY_OLD="$old" OVERLAY_NEW="$new" python3 - <<'PY'
import os, re
old = open(os.environ["OVERLAY_OLD"], encoding="utf-8").read() if os.path.exists(os.environ["OVERLAY_OLD"]) else ""
new = open(os.environ["OVERLAY_NEW"], encoding="utf-8").read()
pat = re.compile(r"<!-- BEGIN USER: (?P<k>[^>]+?) -->\n(?P<b>.*?)\n?<!-- END USER: (?P=k) -->", re.S)
oldmap = {m.group("k"): m.group("b") for m in pat.finditer(old)}
used = set()
def repl(m):
    k = m.group("k")
    if k in oldmap:
        used.add(k)
        return f"<!-- BEGIN USER: {k} -->\n{oldmap[k]}\n<!-- END USER: {k} -->"
    return m.group(0)
merged = pat.sub(repl, new)
orphans = [k for k in oldmap if k not in used]
if orphans:
    merged = merged.rstrip("\n") + "\n\n<!-- USER (orphaned): re-home or delete -->\n"
    for k in orphans:
        merged += f"<!-- BEGIN USER: {k} -->\n{oldmap[k]}\n<!-- END USER: {k} -->\n"
print(merged, end="")
PY
  else
    log "warn: python3 missing; USER overlays preserved best-effort (no orphan recovery)"
    cat "$new"
  fi
}
```

- [ ] **Step 4: Run to verify pass** — overlay assertions PASS.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(overlays): keyed USER extract/inject engine"`

---

### Task B2: wire overlays into write path + add USER anchors

**Files:**
- Modify: `agent-bootstrap/lib/core.sh` (add `write_overlay_file`; source `overlays.sh`) + `agent-bootstrap/lib/writers-docs.sh:266,501` (AGENTS.md heredocs), `.codex/README.md` writer, `agent-mode-contracts.md` writer
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — bootstrap a target; insert custom text in `AGENTS.md`'s `USER:agents:extra` region; re-run bootstrap with `--force`; assert the custom text survives.

```bash
OV_DIR="$TMP_DIR/ov-agents"
bash "$BOOTSTRAP" --target "$OV_DIR" --workflow full >/dev/null
perl -0pi -e 's/(<!-- BEGIN USER: agents:extra -->\n)/$1## Scheme Access Policy\nCUSTOM-KEEP\n/' "$OV_DIR/AGENTS.md"
bash "$BOOTSTRAP" --target "$OV_DIR" --workflow full --force >/dev/null
need_contains "$(cat "$OV_DIR/AGENTS.md")" "CUSTOM-KEEP" "AGENTS.md USER region survives regeneration"
```

- [ ] **Step 2: Run to verify it fails** — no USER anchor yet; custom text lost on `--force`.

- [ ] **Step 3: Implement** — add to `core.sh`:

```bash
write_overlay_file() {
  local path="$1" tmp_new="${1}.tmpnew.$$"
  cat > "$tmp_new"
  if [[ -f "$path" && "$FORCE" == "true" ]]; then
    overlay_merge "$path" "$tmp_new" > "${tmp_new}.merged" && mv "${tmp_new}.merged" "$tmp_new"
  fi
  write_file "$path" < "$tmp_new"
  rm -f "$tmp_new"
}
```

Source `overlays.sh` where the other libs load. In `writers-docs.sh`, switch the AGENTS.md / `.codex/README.md` / `agent-mode-contracts.md` writers from `write_file` to `write_overlay_file`, and insert into each heredoc a keyed anchor (AGENTS.md: just before `## Priority On Conflict`):

```
<!-- BEGIN USER: agents:extra -->
<!-- Project-specific rules go here; preserved across harness upgrades. -->
<!-- END USER: agents:extra -->
```

(`.codex/README.md` → `codex-readme:notes`; `agent-mode-contracts.md` → `mode-contracts:overrides`.)

- [ ] **Step 4: Run to verify pass** — overlay-agents assertion PASSes.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(overlays): USER anchors in AGENTS.md/.codex README/mode-contracts"`

---

### Task B3: idempotency + drift snapshot refresh

**Files:**
- Modify: `agent-bootstrap/` runtime snapshots + `docs/agent-configs/bootstrap-multi-agent-project/templates/**` mirrors (whatever the drift test compares)
- Test: existing drift assertions in `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — assert empty-USER render is idempotent:

```bash
ID_DIR="$TMP_DIR/ov-idem"
bash "$BOOTSTRAP" --target "$ID_DIR" --workflow full >/dev/null
cp "$ID_DIR/AGENTS.md" "$TMP_DIR/agents-1"
bash "$BOOTSTRAP" --target "$ID_DIR" --workflow full --force >/dev/null
diff "$TMP_DIR/agents-1" "$ID_DIR/AGENTS.md" || fail "empty USER render must be idempotent"
```

- [ ] **Step 2: Run to verify it fails/passes** — run the full suite; if drift snapshots now mismatch (new anchors in generated output), they must be refreshed.

- [ ] **Step 3: Implement** — refresh canonical/runtime snapshots via the documented refresh command (e.g. `bash agent-bootstrap/bootstrap-multi-agent-project.sh ... --refresh-lock` / snapshot regeneration the test expects); ensure new anchor lines are reflected.

- [ ] **Step 4: Run to verify pass** — `bash scripts/test-bootstrap-multi-agent-project.sh` green incl. drift + idempotency.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "test(overlays): idempotency + refreshed drift snapshots"`

---

## Phase C — Hygiene, retrofit, finalization

### Task C1: `--cleanup-backups` flag

**Files:**
- Modify: `agent-bootstrap/bootstrap-multi-agent-project.sh` (arg parse `:~97`, usage `:~52`, action dispatch `:~634`)
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test**

```bash
CB_DIR="$TMP_DIR/cleanup"
bash "$BOOTSTRAP" --target "$CB_DIR" --workflow full >/dev/null
touch "$CB_DIR/AGENTS.md.bak.20990101-000000" "$CB_DIR/AGENTS.md.generated.20990101-000000"
bash "$BOOTSTRAP" --target "$CB_DIR" --cleanup-backups >/dev/null
[[ -z "$(find "$CB_DIR" -name '*.bak.*' -print -quit)" ]] || fail "--cleanup-backups must remove .bak.* files"
```

- [ ] **Step 2: Run to verify it fails** — flag unknown.

- [ ] **Step 3: Implement** — add `--cleanup-backups)` arg setting `ACTION="cleanup-backups"`; a `cleanup_backups()` that `find "$TARGET_DIR" -path "$TARGET_DIR/.git" -prune -o \( -name '*.bak.*' -o -name '*.generated.*' \) -print` and removes them (respecting `DRY_RUN`); document in usage. Dispatch in the action `case`.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(cleanup): --cleanup-backups removes .bak/.generated leftovers"`

---

### Task C2: post-upgrade stale-version scan in verify

**Files:**
- Modify: `agent-bootstrap/verify-ai-deps.sh` (new check near the lock checks)
- Test: `scripts/test-bootstrap-multi-agent-project.sh`

- [ ] **Step 1: Write failing test** — plant a stale version string in README, assert verify WARNs (and `Fail: 0`).

```bash
SV_DIR="$TMP_DIR/staleversion"
bash "$BOOTSTRAP" --target "$SV_DIR" --workflow full >/dev/null
printf '\nharness version 2026.06.18.3\n' >> "$SV_DIR/README.md"
sv_out="$(cd "$SV_DIR" && AGENT_BOOTSTRAP_SKIP_SMOKE=1 bash scripts/verify-ai-deps.sh 2>&1 || true)"
need_contains "$sv_out" "stale harness version" "verify warns on stale version refs"
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — read lock `version`; `grep -nE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+'` in `README.md`, `docs/superpowers/specs/project-tech-stack.json`, `docs/agent-configs/project-brief.md`; for any match ≠ lock version, `warn "stale harness version <ref> in <file>; lock is <ver>"`. Never `fail`.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(verify): warn on stale harness-version references"`

---

### Task C3: retrofit detect-and-warn in one-shot upgrader

**Files:**
- Modify: `agent-bootstrap/harness-kit-one-shot-upgrade.sh` (manifest generation)
- Test: `scripts/test-one-shot-upgrade.sh`

- [ ] **Step 1: Write failing test** — when an overlay-enabled target file has content outside MANAGED/USER regions vs the template, the generated `HARNESS-RECONCILE.md` lists it with a `BEGIN USER:` suggestion. (Extend the existing one-shot fixture; assert manifest contains `wrap in <!-- BEGIN USER`.)

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — in the manifest writer, for each overlay-enabled file with a `.generated.*` candidate, if `diff` shows on-disk-only content not inside MANAGED/USER markers, append a manifest bullet: `` - `<file>`: likely custom content detected — wrap in `<!-- BEGIN USER: <file-key> -->` so it survives future upgrades. `` No file is edited.

- [ ] **Step 4: Run to verify pass** — `bash scripts/test-one-shot-upgrade.sh` green.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "feat(one-shot): reconcile manifest flags content to wrap in USER markers"`

---

## Phase D — Release

### Task D1: version bump + CHANGELOG

**Files:** `agent-bootstrap/VERSION`, `agent-bootstrap/MANIFEST.md`, `README.md`, `agent-bootstrap/README.md`, `docs/agent-configs/bootstrap-multi-agent-project/README.md`, `agent-bootstrap/harness-kit-one-shot-upgrade.sh` (`DEFAULT_REF` + README curl), `CHANGELOG.md`, lock fixtures/snapshots referencing the version.

- [ ] **Step 1:** `rg -n '2026\.06\.21\.2' --glob '!CHANGELOG.md'` to enumerate refs.
- [ ] **Step 2:** Set all to `2026.06.22.1`; `DEFAULT_REF=v2026.06.22.1`.
- [ ] **Step 3:** Prepend a `## 2026.06.22.1 — Sandbox-safe upgrades + USER overlays` CHANGELOG section (A/B/C bullets).
- [ ] **Step 4:** `rg -n '2026\.06\.21\.2'` → only CHANGELOG history remains.
- [ ] **Step 5:** `rtk git add -A && rtk git commit -m "release: agent-bootstrap 2026.06.22.1 — sandbox-safe upgrades + USER overlays"`

---

### Task D2: full verification

- [ ] **Step 1:** `bash scripts/test-bootstrap-multi-agent-project.sh` (single-threaded) → all green.
- [ ] **Step 2:** `bash scripts/test-one-shot-upgrade.sh` and `bash scripts/test-onboarding-fixtures.sh` → green.
- [ ] **Step 3:** `bash -n` on every changed `.sh`; `rtk git diff --check`.
- [ ] **Step 4:** Generate a full-workflow target and run its `scripts/verify-ai-deps.sh`; confirm `Fail: 0` and on-demand token estimate ≤ 6100.
- [ ] **Step 5:** If anything fails, fix and re-run before proceeding.

---

### Task D3: squash to one commit

- [ ] **Step 1:** `rtk git log --oneline 8eddbbf..HEAD` (review the Phase A–D commits).
- [ ] **Step 2:** `rtk git reset --soft 8eddbbf`
- [ ] **Step 3:** `rtk git commit -m "feat: sandbox-safe upgrades + USER overlays + hygiene (2026.06.22.1)"` (spec + plan + all code in one commit; no Claude trailer).
- [ ] **Step 4:** `rtk git log --oneline -1` → single commit over `main`.
- [ ] **Step 5:** Report to user; do not push unless asked.

---

## Self-review

- **Spec coverage:** A1–A4 = spec A; B1–B3 = spec B; C1–C3 = spec C (cleanup, stale-scan, retrofit); D = versioning/test/release. All spec sections mapped.
- **Type/name consistency:** `overlay_merge`, `write_overlay_file`, `resolve_state_dir`, `compute_apply_state`, `cleanup_backups`, `apply_state` enum (`complete|pending|blocked-readonly`), USER keys (`agents:extra`, `codex-readme:notes`, `mode-contracts:overrides`) used consistently across tasks.
- **No placeholders:** new functions and tests have concrete code; modifications name file:function + the exact change. Exact line anchors are re-confirmed against source at edit time (TDD drives the precise diff).
- **Risk:** `test-bootstrap-multi-agent-project.sh` is NOT parallel-safe — always run single-threaded.
