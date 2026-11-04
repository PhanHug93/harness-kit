#!/usr/bin/env bash
# agent-bootstrap/lib/writers-runtime.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits target scripts/* runtime files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

write_template_catalog() {
  local template
  for template in \
    base/README.md \
    tool-contract/shared.md \
    overlays/android_kotlin.md \
    overlays/generic.md \
    overlays/ios_swift.md \
    overlays/node_js.md \
    overlays/python.md \
    workflows/council/README.md \
    workflows/karpathy/README.md \
    workflows/three-mode/README.md; do
    copy_bundle_file \
      "templates/$template" \
      "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/$template"
  done
}

write_recovery_runbook() {
  write_file "$TARGET_DIR/docs/agent-configs/RECOVERY.md" <<'EOF'
# Agent Bootstrap Recovery

Each case: what you see, then what to run.

## partial upgrade

An upgrade or regeneration stopped halfway, or
`scripts/agent-guard.sh status` lists `pending_generated_candidates=`.
Compare the candidate with your file, then keep yours or restore the
committed version:

```bash
git diff -- <path>
git restore --staged --worktree <path>
```

To take the kit version of one file instead (yours is backed up):

```bash
scripts/harness-kit.sh --take-kit <path>
```

Without `scripts/harness-kit.sh`: `agent-init --apply-candidates --only <path>`
(or `bash "$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target . --apply-candidates --only <path>`).
Then check with `scripts/agent-guard.sh status` and `scripts/verify-ai-deps.sh`.

## parked USER overlays

`parked_user_overlays=` names a file holding:

```markdown
<!-- USER (orphaned): re-home into a current USER block or delete -->
```

Move that text into the `<!-- BEGIN USER: ... -->` block that now owns it, or
delete it. Leave the managed blocks alone.

## overwritten local settings

`.claude/settings.json` is generated wholesale: re-apply local Claude settings
from git history or your notes, and keep personal settings in the tool's local
settings file.

## retired artifact recovery

`bootstrap-multi-agent-project.sh --apply-retirements` removes only exact
copies of the retired agent-guard CI files (`.github/workflows/agent-guard.yml`
and `docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml`),
each after writing a verified backup `<path>.bak.retirement.<run-id>` that is
never removed automatically.

To restore one, set the path and the run ID from the retirement report and run
this from the project root. It restores only the known 605-byte file, never
overwrites an existing one or follows links, and keeps the backup on failure.
A restored file is retired again only by a later `--apply-retirements`.

```bash
RETIRED_PATH=.github/workflows/agent-guard.yml
RUN_ID=YYYYMMDDTHHMMSSZ-0123456789abcdef
python3 - "$RETIRED_PATH" "$RUN_ID" <<'PY'
import hashlib, os, re, stat, sys

SIZE = 605
DIGEST = "751c8c3f88fd1fc3bcc5c1ddff940e1280b1a5149c787d3110a4408a39810ebb"
ALLOWED = (".github/workflows/agent-guard.yml",
           "docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml")
NOFOLLOW = os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


def read_all(fd):
    data = b""
    while len(data) <= SIZE:
        chunk = os.read(fd, SIZE + 1 - len(data))
        if not chunk:
            break
        data += chunk
    return data


def restore(path, run_id):
    if path not in ALLOWED or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}", run_id):
        return "unsupported path or run ID"
    parents, name = path.split("/")[:-1], path.split("/")[-1]
    backup = name + ".bak.retirement." + run_id
    fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    for part in parents:
        if not stat.S_ISDIR(os.lstat(part, dir_fd=fd).st_mode):
            return "unsafe parent (link or not a directory): " + part
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
        os.close(fd)
        fd = child
    st = os.lstat(backup, dir_fd=fd)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        return "backup is not a single-link regular file"
    source = os.open(backup, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=fd)
    data = read_all(source)
    os.close(source)
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != DIGEST:
        return "backup does not hold the known retired bytes"
    try:
        os.lstat(name, dir_fd=fd)
        return "original path exists; nothing was overwritten"
    except FileNotFoundError:
        pass
    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=fd)
    try:
        offset = 0
        while offset < len(data):
            written = os.write(out, data[offset:])
            if written <= 0:
                return "short write; inspect the partial " + path
            offset += written
        os.fchmod(out, stat.S_IMODE(st.st_mode))
        os.utime(out, ns=(st.st_atime_ns, st.st_mtime_ns))
        os.fsync(out)
    finally:
        os.close(out)
    check = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=fd)
    restored = read_all(check)
    os.close(check)
    os.fsync(fd)
    if hashlib.sha256(restored).hexdigest() != DIGEST:
        return "restored bytes do not verify; inspect " + path
    print("recovery: restored " + path + " from " + backup)
    return None


try:
    problem = restore(sys.argv[1], sys.argv[2])
except OSError as exc:
    problem = "%s (%s)" % (exc.strerror, exc.__class__.__name__)
if problem:
    sys.exit("recovery: stopped: " + problem)
PY
```
EOF
}

write_portable_enforcement() {
  copy_bundle_file "agent-local-only-check.sh" "$TARGET_DIR/scripts/agent-local-only-check.sh"
  make_executable "$LAST_WRITTEN_FILE"
  copy_bundle_file "githooks/pre-push" "$TARGET_DIR/scripts/githooks/pre-push"
  make_executable "$LAST_WRITTEN_FILE"
  copy_bundle_file "install-git-hooks.sh" "$TARGET_DIR/scripts/install-git-hooks.sh"
  make_executable "$LAST_WRITTEN_FILE"
  copy_bundle_file "harness-kit-one-shot.sh" "$TARGET_DIR/scripts/harness-kit.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_schema_and_model_catalog() {
  copy_bundle_file \
    "policies/agent-context-policy.json" \
    "$TARGET_DIR/docs/agent-configs/context-policy.json"
  copy_bundle_file \
    "schemas/agent-context-policy-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-model-profiles-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-seats-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-project-tech-stack-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-lock-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-status-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-status-v2.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v2.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-retirement-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-retirement-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-bootstrap-verify-report-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json"
  copy_bundle_file \
    "schemas/agent-guard-event-v2.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-event-v2.schema.json"
  copy_bundle_file \
    "schemas/agent-guard-verification-v2.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-verification-v2.schema.json"
  copy_bundle_file \
    "schemas/harness-project-knowledge-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-project-knowledge-v1.schema.json"
  copy_bundle_file \
    "schemas/harness-kit-run-report-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-kit-run-report-v1.schema.json"
  copy_bundle_file \
    "schemas/harness-tier-v1.schema.json" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-tier-v1.schema.json"
}

write_tech_stack_lib() {
  write_file "$TARGET_DIR/scripts/agent-tech-stack-lib.sh" < <(emit_tech_stack_lib)
  make_executable "$LAST_WRITTEN_FILE"
}

write_runtime_detector() {
  copy_bundle_file "detect-agent-tech-stack.sh" "$TARGET_DIR/scripts/detect-agent-tech-stack.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_guard() {
  copy_bundle_file "agent-guard.sh" "$TARGET_DIR/scripts/agent-guard.sh"
  make_executable "$LAST_WRITTEN_FILE"
  # `agent-guard.sh tier` runs this program from the same directory.
  copy_bundle_file "agent-tier.py" "$TARGET_DIR/scripts/agent-tier.py"
  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_seats() {
  copy_bundle_file "agent-seats.sh" "$TARGET_DIR/scripts/agent-seats.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

# Runs the bundle's canonical seats program against the target's data files.
# seats.json is user data: created once (defaults or legacy migration), never a
# generated candidate, never overwritten. Skipped on --dry-run.
seats_program() {
  AGENT_SEATS_FILE="$TARGET_DIR/docs/agent-configs/seats.json" \
  AGENT_SEATS_LEGACY_PROFILES="${DETECT_ROOT:-$TARGET_DIR}/docs/agent-configs/model-profiles.json" \
  AGENT_SEATS_AGENTS_MD="$TARGET_DIR/AGENTS.md" \
  AGENT_SEATS_PROJECT_ROOT="$TARGET_DIR" \
    bash "$BUNDLE_DIR/agent-seats.sh" "$@"
}

seed_agent_seats() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN agent-seats init docs/agent-configs/seats.json"
    return 0
  fi
  if ! bootstrap_write_parent_is_eligible "$TARGET_DIR/docs/agent-configs/.seats-preflight"; then
    printf 'ERROR: refusing seats configuration directory outside eligible project root\n' >&2
    return 1
  fi
  ensure_dir "$TARGET_DIR/docs/agent-configs" || return 1
  if ! seats_program init >/dev/null; then
    log "warn: docs/agent-configs/seats.json was not created; run scripts/agent-seats.sh wizard (or reset) after generation"
  fi
}

write_agent_onboarding_runtime() {
  copy_bundle_file "agent-onboarding.sh" "$TARGET_DIR/scripts/agent-onboarding.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_hook() {
  copy_bundle_preset_file "agent-hook.sh" "$TARGET_DIR/scripts/agent-hook.sh"
  make_executable "$LAST_WRITTEN_FILE"
}

write_verify_ai_deps() {
  copy_bundle_preset_file "verify-ai-deps.sh" "$TARGET_DIR/scripts/verify-ai-deps.sh"
  make_executable "$LAST_WRITTEN_FILE"
}
