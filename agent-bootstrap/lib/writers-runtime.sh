#!/usr/bin/env bash
# agent-bootstrap/lib/writers-runtime.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits target scripts/* runtime files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

write_rtk_tools() {
  write_file "$TARGET_DIR/scripts/install-rtk.sh" <<'EOF'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"
# Runtime snapshot: run from generated target projects as scripts/install-rtk.sh.
# Source/canonical bundle copies do not carry the generated docs/agent-configs tree.
PROVENANCE_FILE="${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v${RTK_VERSION}.sha256"

OS="$(uname -s)"
ARCH="$(uname -m)"
PLATFORM="${OS}-${ARCH}"

case "${PLATFORM}" in
  Darwin-arm64)
    ASSET="rtk-aarch64-apple-darwin.tar.gz"
    ;;
  Darwin-x86_64)
    ASSET="rtk-x86_64-apple-darwin.tar.gz"
    ;;
  Linux-aarch64)
    ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"
    ;;
  Linux-x86_64)
    ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"
    ;;
  *)
    echo "Unsupported platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac

if [ ! -f "${PROVENANCE_FILE}" ]; then
  echo "Missing rtk provenance manifest: ${PROVENANCE_FILE}" >&2
  exit 1
fi
SHA256="$(awk -v asset="${ASSET}" '$2 == asset { print $1 }' "${PROVENANCE_FILE}" | head -n1)"
if [ -z "${SHA256}" ]; then
  echo "No checksum for ${ASSET} in ${PROVENANCE_FILE}" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${ASSET}"
INSTALL_DIR="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}"
ARCHIVE_PATH="${INSTALL_DIR}/${ASSET}"
BIN_PATH="${INSTALL_DIR}/rtk"
LINK_PATH="${ROOT_DIR}/.tools/bin/rtk"

mkdir -p "${INSTALL_DIR}" "${ROOT_DIR}/.tools/bin"
if command -v curl >/dev/null 2>&1; then
  curl --proto '=https' --proto-redir '=https' -fL "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}"
elif command -v wget >/dev/null 2>&1; then
  wget -O "${ARCHIVE_PATH}" "${DOWNLOAD_URL}"
else
  echo "Need curl or wget to download rtk." >&2; exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
else
  echo "Need sha256sum or shasum to verify rtk." >&2; exit 1
fi
if [ "${ACTUAL_SHA256}" != "${SHA256}" ]; then
  echo "Checksum mismatch for ${ASSET}" >&2
  echo "Expected: ${SHA256}" >&2
  echo "Actual  : ${ACTUAL_SHA256}" >&2
  exit 1
fi

ARCHIVE_MEMBERS="$(tar -tzf "${ARCHIVE_PATH}")"
# Pinned rtk v0.37.2 archives contain exactly one top-level binary. When
# bumping RTK, verify upstream archive layout and update this policy if needed.
case "${ARCHIVE_MEMBERS}" in
  "rtk"|"./rtk")
    ;;
  *)
    echo "Unexpected rtk archive contents:" >&2
    printf '%s\n' "${ARCHIVE_MEMBERS}" >&2
    exit 1
    ;;
esac
tar -xzf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
chmod +x "${BIN_PATH}"
ln -sfn "../rtk/v${RTK_VERSION}/rtk" "${LINK_PATH}"

echo "Installed pinned rtk v${RTK_VERSION} at ${BIN_PATH}"
"${BIN_PATH}" --version
EOF
  make_executable "$LAST_WRITTEN_FILE"

  write_file "$TARGET_DIR/scripts/rtk" <<'EOF'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"
RTK_BIN="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}/rtk"

if [ ! -x "${RTK_BIN}" ]; then
  echo "Pinned rtk v${RTK_VERSION} not found at ${RTK_BIN}." >&2
  echo "Run: ./scripts/install-rtk.sh" >&2
  exit 1
fi

exec "${RTK_BIN}" "$@"
EOF
  make_executable "$LAST_WRITTEN_FILE"
}

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

Use this runbook when an upgrade or regeneration stops halfway, leaves visible
candidates, or parks a USER overlay that no longer has a matching managed
section.

## partial upgrade

Inspect the current harness state first:

```bash
scripts/agent-guard.sh status
```

If `pending_generated_candidates=` lists a file, review the generated candidate
next to the preserved file. Accept it only after review, or restore the managed
file back to the committed state:

```bash
git diff -- <path>
git restore --staged --worktree <path>
```

For bootstrap-managed `.generated.<stamp>` candidates that should replace their
base file, take the kit version of that one file (the local file is backed up):

```bash
scripts/harness-kit.sh --take-kit <path>
```

Without `scripts/harness-kit.sh`, apply the reviewed candidate from the kit that
created it: `agent-init --apply-candidates --only <path>` (or
`bash "$AGENT_BOOTSTRAP_HOME/bootstrap-multi-agent-project.sh" --target . --apply-candidates --only <path>`).

Then run:

```bash
scripts/agent-guard.sh status
scripts/verify-ai-deps.sh
```

## parked USER overlays

If `parked_user_overlays=` names a managed markdown file, open that file and
look for:

```markdown
<!-- USER (orphaned): re-home into a current USER block or delete -->
```

Move the parked text into the current `<!-- BEGIN USER: ... -->` block that now
owns the customization, or delete it if it is obsolete. Do not remove unrelated
managed blocks while doing this.

## overwritten local settings

`.claude/settings.json` is generated wholesale. Re-apply any local-only Claude
customization from git history or your local notes after bootstrap regenerates
the file. Keep machine-specific or personal settings in local files where the
tool supports them.

## retired artifact recovery

`bootstrap-multi-agent-project.sh --apply-retirements` removes only exact
copies of the retired agent-guard CI files (`.github/workflows/agent-guard.yml`
and `docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml`),
and only after writing a verified backup next to each one named
`<path>.bak.retirement.<run-id>`. Backups are never removed automatically, and
status never reads them to infer history.

To restore one file, run this from the project root after setting the path and
the run ID printed in the retirement report. It walks the parent directories
without following links, requires a single-link regular backup holding the
known 605-byte SHA-256, refuses an existing original, then creates the original
exclusively with the backup's mode and mtime and verifies the restored bytes.
On any failed check it stops without overwriting either file; keep the backup
for audit. A restored file is eligible again and is retired only by a later
explicit `--apply-retirements`.

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

write_schema_model_and_provenance_catalog() {
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
    "provenance/rtk-v0.37.2.sha256" \
    "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"
}

write_tech_stack_lib() {
  write_file "$TARGET_DIR/scripts/agent-tech-stack-lib.sh" < <(emit_tech_stack_lib)
  make_executable "$LAST_WRITTEN_FILE"
}

write_runtime_detector() {
  write_file "$TARGET_DIR/scripts/detect-agent-tech-stack.sh" <<'EOF'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FORMAT="markdown"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$SCRIPT_DIR/agent-tech-stack-lib.sh"

usage() {
  printf '%s\n' \
    "Usage: scripts/detect-agent-tech-stack.sh [--root DIR] [--markdown|--summary|--json]" \
    "" \
    "Detect project tech stack from local file signatures and print agent-ready context."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="$(cd "${2:?missing value for --root}" && pwd -P)"
      shift 2
      ;;
    --markdown)
      FORMAT="markdown"
      shift
      ;;
    --summary)
      FORMAT="summary"
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$LIB" ]]; then
  echo "ERROR: missing tech-stack detection library: ${LIB#"$ROOT"/}" >&2
  exit 1
fi

# shellcheck source=scripts/agent-tech-stack-lib.sh
source "$LIB"

agent_detect_tech_stack "$ROOT"

case "$FORMAT" in
  summary)
    agent_print_summary
    ;;
  json)
    agent_print_json
    ;;
  *)
    agent_print_markdown "$ROOT"
    ;;
esac
EOF

  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_guard() {
  copy_bundle_file "agent-guard.sh" "$TARGET_DIR/scripts/agent-guard.sh"
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
  write_file "$TARGET_DIR/scripts/agent-hook.sh" <<'EOF'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RTK="$PROJECT_ROOT/scripts/rtk"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
LOCK_FILE="$PROJECT_ROOT/docs/agent-configs/agent-bootstrap.lock.json"
CODEX_HELPER="$PROJECT_ROOT/.codex/codex-mode.sh"
VERIFY_AI_DEPS="$PROJECT_ROOT/scripts/verify-ai-deps.sh"
AGENT_GUARD="$PROJECT_ROOT/scripts/agent-guard.sh"

NO_SCAN_PATHS=(
  ".claude/worktrees/"
  ".tools/"
  ".gradle/"
  ".gradle-ci/"
  ".gradle-ci-real/"
  ".gradle-codex/"
  ".gradle-local/"
  ".codex/environments/"
  ".superpowers/brainstorm/"
  ".cursor/rules-local/"
  ".gemini/"
  ".windsurf/"
  ".openclaude/"
  ".agents/runtime/"
  ".agents/state/"
  ".agents/cache/"
  "build/"
  "*/build/"
  "*/out/"
)

LOCAL_ONLY_PATHS=(
  "AGENTS.local.md"
  "CLAUDE.local.md"
  "GEMINI.local.md"
  "*.local.agents.md"
  "*.local.claude.md"
  "*.local.gemini.md"
  "docs/agent-configs/*.local.md"
  ".claude/settings.local.json"
  ".claude/*/settings.local.json"
  ".claude/worktrees/"
  ".codex-mode-lock"
  ".codex/.setup-codex-project.state"
  ".codex/.setup-codex-project.bootstrap"
  ".codex/environments/"
  ".codex/config.toml.bak.*"
  ".tools/"
  ".cursor/rules-local/"
  ".cursor/**/*.local.mdc"
  ".gemini/"
  ".windsurf/"
  ".openclaude/"
  ".openclaude-profile.json"
  ".superpowers/brainstorm/"
  ".agents/runtime/"
  ".agents/state/"
  ".agents/cache/"
)

SENSITIVE_LOCAL_PATHS=(
  "local.properties"
  "*/local.properties"
  "keystore.properties"
  "*/keystore.properties"
  ".env"
  ".env.*"
  "*/.env"
  "*/.env.*"
  "*.jks"
  "*.keystore"
  "*.pem"
  "*.p8"
  "*.key"
)

fail() {
  echo "agent-hook: ERROR: $*" >&2
  exit 1
}

required_file() {
  [[ -f "$1" ]] || fail "missing required file: ${1#"$PROJECT_ROOT"/}"
}

required_executable() {
  [[ -x "$1" ]] || fail "missing executable file: ${1#"$PROJECT_ROOT"/}"
}

rtk_available() {
  [[ -x "$RTK" ]] && "$RTK" --version >/dev/null 2>&1
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    echo "ERROR: missing SHA-256 tool: install sha256sum, shasum, or python3" >&2
    return 1
  fi
}

lock_value() {
  local key="$1"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read bootstrap lock"
  python3 - "$LOCK_FILE" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path, wanted = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)


def walk(value):
    if isinstance(value, dict):
        if wanted in value:
            found = value[wanted]
            if isinstance(found, str):
                print(found)
                return True
            if isinstance(found, bool):
                print("true" if found else "false")
                return True
            if isinstance(found, (int, float)):
                print(found)
                return True
        for child in value.values():
            if walk(child):
                return True
    elif isinstance(value, list):
        for child in value:
            if walk(child):
                return True
    return False


walk(document)
PY
}

verify_detector_lock() {
  local on_drift="${1:-fail}"
  required_file "$LOCK_FILE"
  local expected actual summary
  expected="$(lock_value detector_summary_sha256)"
  [[ -n "$expected" ]] || fail "missing detector_summary_sha256 in ${LOCK_FILE#"$PROJECT_ROOT"/}"
  summary="$("$DETECTOR" --summary)"
  actual="$(printf '%s' "$summary" | hash_text)"
  if [[ "$actual" != "$expected" ]]; then
    if [[ "$on_drift" == "warn" ]]; then
      echo "agent-hook: warn: detector summary drifted from lock. Re-run bootstrap/lock refresh intentionally before launching agents. expected=$expected actual=$actual" >&2
      return 0
    fi
    fail "detector summary drifted from lock. Re-run bootstrap/lock refresh intentionally before launching agents. expected=$expected actual=$actual"
  fi
}

is_tracked() {
  local pathspec="$1"
  local tracked_path
  if rtk_available; then
    while IFS= read -r tracked_path; do
      [[ -n "$tracked_path" ]] || continue
      if [[ -e "$PROJECT_ROOT/$tracked_path" ]]; then
        return 0
      fi
    done < <("$RTK" git -C "$PROJECT_ROOT" ls-files -- "$pathspec")
    return 1
  fi
  if command -v git >/dev/null 2>&1 &&
    git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r tracked_path; do
      [[ -n "$tracked_path" ]] || continue
      if [[ -e "$PROJECT_ROOT/$tracked_path" ]]; then
        return 0
      fi
    done < <(git -C "$PROJECT_ROOT" ls-files -- "$pathspec")
  fi
  return 1
}

print_no_scan_paths() {
  printf '%s\n' \
    "${NO_SCAN_PATHS[@]}" \
    "${LOCAL_ONLY_PATHS[@]}" \
    "${SENSITIVE_LOCAL_PATHS[@]}" |
    awk '!seen[$0]++'
}

guard_local_state() {
  local relative
  for relative in "${LOCAL_ONLY_PATHS[@]}"; do
    if is_tracked "$relative"; then
      fail "local-only agent state is tracked: $relative"
    fi
  done
}

parse_claude_hook_input() {
  local input="$1"
  if command -v python3 >/dev/null 2>&1; then
    HOOK_INPUT="$input" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(1)

tool_name = payload.get("tool_name") or payload.get("tool")
tool_input = payload.get("tool_input") or payload.get("input") or {}
if not isinstance(tool_input, dict):
    tool_input = {}
file_path = tool_input.get("file_path") or tool_input.get("path") or ""
if not isinstance(tool_name, str):
    tool_name = ""
if not isinstance(file_path, str):
    file_path = ""
sys.stdout.buffer.write((tool_name + "\0" + file_path + "\0").encode("utf-8"))
PY
    return $?
  fi
  local tool_name file_path
  tool_name="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s\0%s\0' "$tool_name" "$file_path"
}

guard_claude_edit_tool() {
  local edit_path="$1" ask_reason="${2:-}" rc=0 classification=""
  [[ -n "$edit_path" ]] || fail "Claude edit hook did not include tool_input.file_path"
  if [[ -n "${AGENT_GUARD_EDIT_ACK:-}" ]]; then
    classification="$("$AGENT_GUARD" pre-edit --strict --use-ack-log --ack "$AGENT_GUARD_EDIT_ACK" "$edit_path")" || rc=$?
  else
    classification="$("$AGENT_GUARD" pre-edit --strict --use-ack-log "$edit_path")" || rc=$?
  fi
  # Stdout must be pure JSON when the hook asks the user; otherwise keep the
  # classification on stdout (debug log only), so denials stay two stderr lines.
  if [[ -z "$ask_reason" && -n "$classification" ]]; then
    printf '%s\n' "$classification"
  fi
  case "$rc" in
    0) return 0 ;;
    3) exit 2 ;;
    *)
      # Claude Code only blocks on exit 2; any other guard refusal (outside the
      # project root, missing context, failed preflight) must block the edit too.
      echo "agent-hook: ERROR: edit blocked: agent-guard pre-edit exited $rc" >&2
      exit 2
      ;;
  esac
}

claude_anchor_env() {
  # Claude Code adapter: mint the workspace envelope from host-provided hook
  # data (session_id, CLAUDE_PROJECT_DIR) only when no envelope exists. Never
  # derive it from the agent's current directory or overwrite existing values.
  local input="$1" minted
  CLAUDE_ANCHOR_MINTED=false
  [[ -z "${AGENT_WORKSPACE_CONTEXT:-}" && -z "${AGENT_HOST_SESSION_ID:-}" ]] || return 0
  [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && command -v python3 >/dev/null 2>&1 || return 0
  minted="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import base64
import json
import os
import re
import sys

try:
    payload = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(1)
session = payload.get("session_id") if isinstance(payload, dict) else None
root = os.environ.get("CLAUDE_PROJECT_DIR", "")
if (not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9._:-]+", session)
        or not os.path.isabs(root) or not os.path.isdir(root)):
    sys.exit(1)
context = dict(original_workspace=root, target_repository=root, target_source="user", session_id=session)
print(session)
print("base64:" + base64.b64encode(json.dumps(context, ensure_ascii=False).encode("utf-8")).decode("ascii"))
PY
)" || return 0
  AGENT_HOST_SESSION_ID="${minted%%$'\n'*}"
  AGENT_WORKSPACE_CONTEXT="${minted#*$'\n'}"
  export AGENT_HOST_SESSION_ID AGENT_WORKSPACE_CONTEXT
  CLAUDE_ANCHOR_MINTED=true
}

workspace_ask_reason() {
  # Print a reason only when Claude Code should ask the user: a cross-repository
  # mismatch. Worktree mismatches and unattested sessions stay advisory.
  local report
  report="$("$AGENT_GUARD" workspace-check 2>/dev/null)" && return 0
  REPORT="$report" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    doc = json.loads(os.environ.get("REPORT", "").strip().splitlines()[-1])
except Exception:
    raise SystemExit(0)
if doc.get("status") == "mismatch" and doc.get("mismatch_kind") == "repository":
    print("Workspace-repository guard: " + str(doc.get("reason")) + "; context="
          + json.dumps(doc.get("context"), ensure_ascii=False)
          + "; confirm the target repository with the user before writing.")
PY
}

claude_ask() {
  ASK_REASON="$1" python3 - <<'PY'
import json
import os

print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                         "permissionDecisionReason": os.environ["ASK_REASON"]}},
                 ensure_ascii=False))
PY
}

hook_input_field() {
  # Print a string or boolean field of the Claude hook JSON; empty otherwise.
  command -v python3 >/dev/null 2>&1 || return 0
  HOOK_INPUT="$1" python3 - "$2" <<'PY' 2>/dev/null || true
import json
import os
import sys

try:
    value = json.loads(os.environ.get("HOOK_INPUT", "") or "{}").get(sys.argv[1])
except Exception:
    value = None
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
PY
}

# Same order as agent_resolve_state_dir in scripts/agent-guard.sh, so session
# snapshots live next to the guard's reports: $AGENT_STATE_DIR, .agents/state,
# then a per-project dir under TMPDIR. Sets HOOK_STATE_DIR.
hook_state_dir_usable() {
  local d="$1" parent
  if [[ -d "$d" ]]; then
    [[ -w "$d" ]]
    return
  fi
  parent="$(dirname "$d")"
  while [[ ! -d "$parent" && "$parent" != "/" && "$parent" != "." ]]; do
    parent="$(dirname "$parent")"
  done
  [[ -w "$parent" ]]
}

resolve_hook_state_dir() {
  local candidate
  HOOK_STATE_DIR=""
  for candidate in \
    "${AGENT_STATE_DIR:-}" \
    "$PROJECT_ROOT/.agents/state" \
    "${TMPDIR:-/tmp}/agent-bootstrap-state/$(printf '%s' "$PROJECT_ROOT" | cksum | tr -d ' \t')"; do
    [[ -n "$candidate" ]] || continue
    if hook_state_dir_usable "$candidate"; then
      HOOK_STATE_DIR="$candidate"
      return 0
    fi
  done
  return 1
}

# Sets SESSION_SNAPSHOT, SESSION_TAG (first 12 hex of sha256(session_id), which
# names this session's close-out report and error log) and HOOK_STATE_DIR; fails
# for ids that are not ^[A-Za-z0-9._-]+$ or when no state dir is usable.
set_session_snapshot() {
  local session="$1" pattern='^[A-Za-z0-9._-]+$' tag_pattern='^[0-9a-f]{12}$'
  SESSION_SNAPSHOT=""
  SESSION_TAG=""
  [[ "$session" =~ $pattern ]] || return 1
  resolve_hook_state_dir || return 1
  SESSION_TAG="$(printf '%s' "$session" | hash_text 2>/dev/null)" || return 1
  SESSION_TAG="${SESSION_TAG:0:12}"
  [[ "$SESSION_TAG" =~ $tag_pattern ]] || return 1
  SESSION_SNAPSHOT="$HOOK_STATE_DIR/sessions/$session.snapshot"
}

change_map() {
  # change_map write|same <snapshot>: the change map starts with "HEAD\t<commit
  # or none>" (so a commit counts as a change), then one sorted line per path
  # that `git status` reports (untracked included, ignored and the hook state
  # dir excluded) as "<path>\t<sha256|deleted|unreadable>"; backslash, tab, CR
  # and newline in paths are escaped. The digest covers the content and the
  # executable bit (a link: its target; a submodule or nested repository: its
  # HEAD and status). `write` replaces the snapshot atomically; `same` exits 0
  # only when the snapshot equals the current map, stopping at the first
  # difference (1 differs, 2 map unavailable).
  python3 - "$PROJECT_ROOT" "$1" "$2" "$HOOK_STATE_DIR" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys

root, mode, snapshot, state_dir = (os.fsencode(sys.argv[1]), sys.argv[2], sys.argv[3],
                                   os.fsencode(sys.argv[4]))


def git(args, cwd):
    return subprocess.run(["git", "--no-optional-locks", "-C", cwd] + args, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True, timeout=120).stdout


try:
    top = os.path.realpath(git(["rev-parse", "--show-toplevel"], root).rstrip(b"\n"))
    raw = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
except Exception:
    sys.exit(2)
try:
    head = git(["rev-parse", "--verify", "-q", "HEAD"], root).strip() or b"none"
except Exception:
    head = b"none"
# Paths under the hook state dir (AGENT_STATE_DIR inside the tree) never count.
skip = os.path.relpath(os.path.realpath(state_dir), top) if state_dir else b".."
skip = None if skip == b"." or skip.startswith(b"..") else skip + b"/"
fields = raw.split(b"\0")
paths = set()
index = 0
while index < len(fields):
    entry = fields[index]
    index += 1
    if len(entry) < 4:
        continue
    found = [entry[3:]]
    if b"R" in entry[:2] or b"C" in entry[:2]:
        # Rename/copy: the source path follows as its own field.
        if index < len(fields) and fields[index]:
            found.append(fields[index])
        index += 1
    paths.update(p for p in found if not (skip and (p + b"/").startswith(skip)))


def digest(rel):
    path = os.path.join(top, rel.rstrip(b"/"))
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return b"deleted"
    except OSError:
        return b"unreadable"
    sha = hashlib.sha256()
    try:
        if stat.S_ISLNK(info.st_mode):
            sha.update(b"link\0" + os.readlink(path))
        elif stat.S_ISDIR(info.st_mode):
            sha.update(b"repo\0")
            # Only a directory with its own .git (a submodule or nested repo)
            # is probed; a plain directory must not hash the parent's status.
            if os.path.lexists(os.path.join(path, b".git")):
                for args in (["rev-parse", "HEAD"], ["status", "--porcelain", "-z"]):
                    try:
                        sha.update(git(args, path) + b"\0")
                    except Exception:
                        sha.update(b"?\0")
            else:
                sha.update(b"dir\0")
        else:
            sha.update(b"file\0x\0" if info.st_mode & 0o111 else b"file\0-\0")
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    sha.update(chunk)
    except OSError:
        return b"unreadable"
    return sha.hexdigest().encode()


def escape(rel):
    return (rel.replace(b"\\", b"\\\\").replace(b"\t", b"\\t")
            .replace(b"\r", b"\\r").replace(b"\n", b"\\n"))


rows = sorted((escape(p), p) for p in paths)
header = b"HEAD\t" + head + b"\n"
if mode == "same":
    try:
        with open(snapshot, "rb") as handle:
            lines = handle.read().split(b"\n")
    except OSError:
        sys.exit(1)
    if lines[0] + b"\n" != header or lines[-1] != b"" or len(lines) - 2 != len(rows):
        sys.exit(1)
    saved = {}
    for line in lines[1:-1]:
        name, sep, value = line.rpartition(b"\t")
        if not sep:
            sys.exit(1)
        saved[name] = value
    if set(saved) != set(name for name, _ in rows):
        sys.exit(1)
    for name, path in rows:
        if digest(path) != saved[name]:
            sys.exit(1)
    sys.exit(0)
content = header + b"".join(name + b"\t" + digest(path) + b"\n" for name, path in rows)
os.makedirs(os.path.dirname(snapshot), exist_ok=True)
temp = "{}.tmp.{}".format(snapshot, os.getpid())
try:
    with open(temp, "wb") as handle:
        handle.write(content)
    os.replace(temp, snapshot)
finally:
    if os.path.lexists(temp):
        os.unlink(temp)
PY
}

write_session_snapshot() {
  # Record which paths are already changed when the session starts, so the Stop
  # hook verifies only this session's changes. An existing snapshot is kept:
  # SessionStart also fires on resume and compact for the same session id.
  local session snapshot
  command -v python3 >/dev/null 2>&1 || {
    echo "agent-hook: warn: python3 is unavailable; no session snapshot, close-out will be skipped" >&2
    return 0
  }
  session="$(hook_input_field "$1" session_id)"
  if ! set_session_snapshot "$session"; then
    echo "agent-hook: warn: no usable session_id or state dir; no session snapshot, close-out will be skipped" >&2
    return 0
  fi
  snapshot="$SESSION_SNAPSHOT"
  [[ ! -f "$snapshot" ]] || return 0
  # Snapshots and close-out reports/logs of finished sessions are pruned after 30 days.
  find "$HOOK_STATE_DIR/sessions" -type f \( -name '*.snapshot' -o -name '*.snapshot.tmp.*' \) \
    -mtime +30 -exec rm -f {} + 2>/dev/null || true
  find "$HOOK_STATE_DIR" -maxdepth 1 -type f \( -name 'closeout-*-verify.json' -o -name 'closeout-*.err' \) \
    -mtime +30 -exec rm -f {} + 2>/dev/null || true
  change_map write "$snapshot" ||
    echo "agent-hook: warn: could not record the session snapshot; close-out will be skipped" >&2
  return 0
}

claude_session_start() {
  # SessionStart hook: anchor the session, persist the envelope for later Bash
  # tool commands through CLAUDE_ENV_FILE, report the status to Claude, then
  # record the session's change snapshot for close-out (after the JSON, so the
  # report is not held behind hashing). Never blocks the session.
  local input="" report
  if [[ ! -t 0 ]]; then
    input="$(cat || true)"
  fi
  claude_anchor_env "$input"
  if [[ "$CLAUDE_ANCHOR_MINTED" == "true" && -n "${CLAUDE_ENV_FILE:-}" ]]; then
    printf 'export AGENT_HOST_SESSION_ID=%s\nexport AGENT_WORKSPACE_CONTEXT=%s\n' \
      "$AGENT_HOST_SESSION_ID" "$AGENT_WORKSPACE_CONTEXT" >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  report="$("$AGENT_GUARD" workspace-check 2>/dev/null || true)"
  REPORT="$report" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    doc = json.loads(os.environ.get("REPORT", "").strip().splitlines()[-1])
except Exception:
    doc = {"status": "unknown"}
status = str(doc.get("status", "unknown"))
line = "Workspace-repository guard (advisory): " + status
if status == "verified":
    line += "; target " + str(doc.get("target_repository"))
elif status == "mismatch":
    line += " (" + str(doc.get("mismatch_kind")) + "): " + str(doc.get("reason")) \
        + "; confirm the target repository with the user before writing"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": line}},
                 ensure_ascii=False), flush=True)
PY
  write_session_snapshot "$input" || true
  exit 0
}

claude_pretool() {
  required_executable "$DETECTOR"
  # Internal errors must not lock all edits: without python3 or the guard the
  # policy cannot be evaluated, so warn and allow.
  if ! command -v "${AGENT_HOOK_PYTHON:-python3}" >/dev/null 2>&1 || [[ ! -x "$AGENT_GUARD" ]]; then
    echo "agent-hook: warn: python3 or scripts/agent-guard.sh is unavailable; skipping the edit guard" >&2
    exit 0
  fi
  local hook_input=""
  local tool_name=""
  local edit_path=""
  local ask_reason=""
  if [[ ! -t 0 ]]; then
    hook_input="$(cat || true)"
  fi
  claude_anchor_env "$hook_input"
  local preflight_rc=0
  "$AGENT_GUARD" preflight >/dev/null || preflight_rc=$?
  if [[ "$preflight_rc" -ne 0 && -z "$hook_input" ]]; then
    exit "$preflight_rc"
  fi
  ask_reason="$(workspace_ask_reason)"
  if [[ -n "$hook_input" ]]; then
    tool_name=""
    edit_path=""
    exec 3< <(parse_claude_hook_input "$hook_input" || true)
    IFS= read -r -d '' tool_name <&3 || true
    IFS= read -r -d '' edit_path <&3 || true
    exec 3<&-
    if [[ "$preflight_rc" -ne 0 ]]; then
      case "$tool_name" in
        Edit|Write|MultiEdit)
          echo "agent-hook: ERROR: edit blocked: agent-guard preflight exited $preflight_rc" >&2
          exit 2
          ;;
      esac
      exit "$preflight_rc"
    fi
    case "$tool_name" in
      Edit|Write|MultiEdit)
        guard_claude_edit_tool "$edit_path" "$ask_reason"
        [[ -z "$ask_reason" ]] || claude_ask "$ask_reason"
        exit 0
        ;;
    esac
  fi
  verify_detector_lock warn
  if [[ -n "$ask_reason" ]]; then
    claude_ask "$ask_reason"
    exit 0
  fi
  cd "$PROJECT_ROOT"
  if rtk_available; then
    exec "$RTK" hook claude
  fi
  echo "agent-hook: warn: pinned rtk binary is not installed; skipping rtk Claude hook. Run: bash scripts/install-rtk.sh" >&2
  exit 0
}

codex_preflight() {
  local check_only=false
  if [[ "${1:-}" == "--check-only" ]]; then
    check_only=true
    shift
  fi
  if [[ "$check_only" != "true" ]]; then
    "$AGENT_GUARD" workspace-check >/dev/null || true
  fi
  local mode="${1:-unknown}"
  local flow="${2:-unknown}"
  required_file "$PROJECT_ROOT/AGENTS.md"
  required_file "$PROJECT_ROOT/CLAUDE.md"
  required_file "$PROJECT_ROOT/docs/agent-configs/project-agent-context.md"
  if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
    required_file "$PROJECT_ROOT/docs/agent-configs/agent-mode-contracts.md"
    required_file "$PROJECT_ROOT/docs/agent-configs/agent-handoff-schema.md"
    required_file "$PROJECT_ROOT/.codex/config.toml"
  fi
  required_executable "$DETECTOR"
  required_executable "$AGENT_GUARD"
  guard_local_state
  if [[ "$check_only" == "true" ]]; then
    "$AGENT_GUARD" check >/dev/null
  else
    "$AGENT_GUARD" preflight >/dev/null
  fi
  verify_detector_lock
  echo "agent-hook: codex preflight ok (mode=$mode flow=$flow)" >&2
}

doctor() {
  if [[ -x "$CODEX_HELPER" ]]; then
    "$CODEX_HELPER" doctor
  fi
  if [[ -x "$VERIFY_AI_DEPS" ]]; then
    "$VERIFY_AI_DEPS"
  else
    codex_preflight doctor standard
  fi
}

close_out() {
  # Claude Code Stop hook. Verify only when the paths changed since this
  # session's snapshot (written at SessionStart, advanced after each
  # non-blocking close-out), so a seat is not blocked by another seat's edits and
  # an unchanged turn costs nothing. Fast verification runs in advisory mode,
  # within 300 s (the Stop hook timeout is 360 s), into this session's own report
  # (closeout-<tag>-verify.json, never last-verify-report.json); Stop is blocked
  # (exit 2) on missing evidence or any fail/error/timeout, and kept blocked
  # until the change verifies. Unverified only warns.
  # Gemini/Cursor/Windsurf have no equivalent close-out hook, so those surfaces
  # stay advisory and should call agent-guard pre-final manually.
  local input session snapshot out report verdict err_file budget digits='^[0-9]{1,3}$'
  input="$(cat 2>/dev/null || true)"
  claude_anchor_env "$input"
  [[ "$(hook_input_field "$input" stop_hook_active)" == "true" ]] && exit 0
  session="$(hook_input_field "$input" session_id)"
  if ! command -v python3 >/dev/null 2>&1 || ! set_session_snapshot "$session" ||
    [[ ! -f "$SESSION_SNAPSHOT" ]]; then
    echo "agent-hook: close-out skipped (no session snapshot); run scripts/agent-guard.sh pre-final --run-verify" >&2
    exit 0
  fi
  snapshot="$SESSION_SNAPSHOT"
  change_map same "$snapshot" && exit 0
  err_file="$HOOK_STATE_DIR/closeout-$SESSION_TAG.err"
  # The total budget overrides the fast default in the guard; cap it at 300 s.
  budget="${AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS:-${AGENT_GUARD_VERIFY_TOTAL_FAST_SECONDS:-300}}"
  if [[ ! "$budget" =~ $digits ]] || ((10#$budget == 0 || 10#$budget > 300)); then
    budget=300
  fi
  out="$(AGENT_GUARD_VERIFY_REPORT_NAME="closeout-$SESSION_TAG-verify.json" \
    AGENT_GUARD_VERIFY_TOTAL_TIMEOUT_SECONDS="$((10#$budget))" \
    "$AGENT_GUARD" pre-final --run-verify --verify-scope fast --advisory 2>"$err_file" || true)"
  report="$(printf '%s\n' "$out" | sed -n 's/^agent-guard: verify_report=//p' | tail -n 1)"
  verdict="$(python3 - "$report" <<'PY' 2>/dev/null || printf 'missing\n'
import json
import sys

try:
    doc = json.load(open(sys.argv[1], encoding="utf-8")) if sys.argv[1] else None
except Exception:
    doc = None
if not isinstance(doc, dict) or not isinstance(doc.get("results", []), list):
    print("missing")
    raise SystemExit(0)
status = doc.get("status")
counts = {}
for item in doc.get("results", []):
    if isinstance(item, dict) and item.get("status") in ("fail", "error", "timeout"):
        counts[item["status"]] = counts.get(item["status"], 0) + 1
if counts or status in ("fail", "error"):
    detail = ", ".join("{} {}".format(n, s) for s, n in sorted(counts.items()))
    print("block {}{}".format(status, " (" + detail + ")" if detail else ""))
elif status in ("pass", "unverified"):
    print(status)
else:
    print("missing")
PY
)"
  case "$verdict" in
    pass) ;;
    unverified)
      echo "agent-hook: warn: close-out verification unverified (no verification command ran); fill verification[] in docs/superpowers/specs/project-tech-stack.json; report $report" >&2
      ;;
    "block "*)
      printf 'agent-hook: close-out fast verification %s for changes in this session; review %s before completing.\n' \
        "${verdict#block }" "$report" >&2
      grep '^agent-guard: verify\[' "$err_file" 2>/dev/null | head -n 5 >&2 || true
      exit 2
      ;;
    *)
      printf 'agent-hook: close-out verification report missing or unreadable (%s); see %s and run scripts/agent-guard.sh pre-final --run-verify before completing.\n' \
        "${report:-no verify_report line}" "$err_file" >&2
      exit 2
      ;;
  esac
  change_map write "$snapshot" ||
    echo "agent-hook: warn: could not advance the session snapshot; the next close-out re-verifies" >&2
  exit 0
}

case "${1:-}" in
  claude-pretool)
    shift || true
    claude_pretool "$@"
    ;;
  claude-session-start)
    claude_session_start
    ;;
  codex-preflight)
    shift || true
    codex_preflight "$@"
    ;;
  guard-local-state)
    guard_local_state
    ;;
  no-scan-paths)
    print_no_scan_paths
    ;;
  doctor)
    doctor
    ;;
  close-out)
    close_out
    ;;
  -h|--help|help|"")
    echo "Usage: scripts/agent-hook.sh claude-pretool|claude-session-start|codex-preflight|guard-local-state|no-scan-paths|doctor|close-out"
    ;;
  *)
    fail "unknown command: $1"
    ;;
esac
EOF

  replace_placeholder "$LAST_WRITTEN_FILE" "__WORKFLOW_PRESET__" "$WORKFLOW_PRESET"
  make_executable "$LAST_WRITTEN_FILE"
}

write_verify_ai_deps() {
  write_file "$TARGET_DIR/scripts/verify-ai-deps.sh" <<'EOF'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
WARN=0
OUTPUT_JSON=false
BUDGET_ONLY=false
CHECKS=()
CONTEXT_BUDGET_JSON=""

usage() {
  printf '%s\n' "Usage: scripts/verify-ai-deps.sh [--json] [--context-budget]" \
    "  --context-budget  run only the context budget check (core startup and on-demand)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --context-budget)
      BUDGET_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    JSON_ESCAPE_VALUE="$1" python3 - <<'PY'
import json
import os

print(json.dumps(os.environ.get("JSON_ESCAPE_VALUE", ""), ensure_ascii=False)[1:-1], end="")
PY
    return
  fi
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

record_check() {
  local status="$1"
  local label="$2"
  CHECKS+=("$status"$'\t'"$label")
  if [[ "$OUTPUT_JSON" != "true" ]]; then
    case "$status" in
      pass) printf '  ok    %s\n' "$label" ;;
      fail) printf '  FAIL  %s\n' "$label" ;;
      warn) printf '  warn  %s\n' "$label" ;;
    esac
  fi
}

ok() { PASS=$((PASS + 1)); record_check pass "$1"; }
bad() { FAIL=$((FAIL + 1)); record_check fail "$1"; }
warn() { WARN=$((WARN + 1)); record_check warn "$1"; }

emit_json_report() {
  local first=true
  local check status label
  printf '{"schema":"agent-bootstrap-verify-report/v1","workflow_preset":"%s","summary":{"pass":%s,"warn":%s,"fail":%s},"checks":[' \
    "$(json_escape "$WORKFLOW_PRESET")" "$PASS" "$WARN" "$FAIL"
  for check in "${CHECKS[@]}"; do
    status="${check%%$'\t'*}"
    label="${check#*$'\t'}"
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"status":"%s","label":"%s"}' "$(json_escape "$status")" "$(json_escape "$label")"
  done
  printf ']'
  if [[ -n "$CONTEXT_BUDGET_JSON" ]]; then
    printf ',"context_budget":%s' "$CONTEXT_BUDGET_JSON"
  fi
  printf '}\n'
}

need_file() {
  if [[ -f "$ROOT_DIR/$1" ]]; then
    ok "file exists: $1"
  else
    bad "missing file: $1"
  fi
}

need_executable() {
  if [[ -x "$ROOT_DIR/$1" ]]; then
    ok "executable: $1"
  else
    bad "not executable: $1"
  fi
}

need_bash_syntax() {
  if bash -n "$ROOT_DIR/$1"; then
    ok "bash syntax: $1"
  else
    bad "bash syntax failed: $1"
  fi
}

is_bootstrap_generated_base() {
  local relpath="$1"
  case "$relpath" in
    AGENTS.md|CLAUDE.md|GEMINI.md|.windsurfrules|.gitignore)
      return 0
      ;;
    .cursor/rules/agent-conventions.mdc)
      return 0
      ;;
    .claude/README.md|.claude/settings.json|.claude/commands/*)
      return 0
      ;;
    .codex/*)
      return 0
      ;;
    .agents/skills/*)
      return 0
      ;;
    docs/agent-configs/*)
      return 0
      ;;
    docs/superpowers/specs/*|docs/superpowers/plans/*)
      return 0
      ;;
    scripts/agent-*.sh|scripts/detect-agent-tech-stack.sh|scripts/install-rtk.sh|scripts/rtk|scripts/verify-ai-deps.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pending_bootstrap_generated_candidate() {
  local candidate rel_candidate base rel_base
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    rel_candidate="${candidate#"$ROOT_DIR"/}"
    base="${candidate%.generated.*}"
    rel_base="${base#"$ROOT_DIR"/}"
    if is_bootstrap_generated_base "$rel_base"; then
      printf '%s\n' "$rel_candidate"
      return 0
    fi
  done < <(find "$ROOT_DIR" \
    \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.tools" -o -path "$ROOT_DIR/.gradle" -o -path "$ROOT_DIR/build" \) -prune -o \
    -type f -name '*.generated.*' -print 2>/dev/null || true)
  return 1
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    echo "ERROR: missing SHA-256 tool: install sha256sum, shasum, or python3" >&2
    return 1
  fi
}

lock_value() {
  local key="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" "$key" <<'PY' 2>/dev/null || true
import json
import sys

path, wanted = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)


def walk(value):
    if isinstance(value, dict):
        if wanted in value:
            found = value[wanted]
            if isinstance(found, str):
                print(found)
                return True
            if isinstance(found, bool):
                print("true" if found else "false")
                return True
            if isinstance(found, (int, float)):
                print(found)
                return True
        for child in value.values():
            if walk(child):
                return True
    elif isinstance(value, list):
        for child in value:
            if walk(child):
                return True
    return False


walk(document)
PY
}

token_estimate() {  # <words> <bytes>: the larger of bytes/4 and words*1.3
  awk -v words="$1" -v chars="$2" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

estimate_tokens_for_file() {
  local path="$1"
  local words="0"
  local chars="0"
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  read -r words chars < <(LC_ALL=C wc -w -c < "$path")
  token_estimate "$words" "$chars"
}

# Project content is the user's: the user-owned files below, and in any other
# counted file the body of each <!-- BEGIN USER: ... --> region and of each
# detector-filled managed block (stacks, modules, verification commands,
# warnings). The rest, marker lines included, is kit text.
BUDGET_USER_OWNED_FILES=" docs/agent-configs/project-brief.md docs/agent-configs/project-agent-context.md "

# Prints "<kit> <project>" token estimates for one counted file.
split_file_estimate() {
  local relpath="$1"
  local path="$ROOT_DIR/$1"
  if [[ ! -f "$path" ]]; then
    printf '0 0\n'
    return 0
  fi
  if [[ "$BUDGET_USER_OWNED_FILES" == *" $relpath "* ]]; then
    printf '0 %s\n' "$(estimate_tokens_for_file "$path")"
    return 0
  fi
  LC_ALL=C awk '
    function est(b, w) { b = b / 4; w = w * 1.3; return int(b > w ? b : w) }
    /<!-- BEGIN (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 1; next }
    /<!-- END (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 0; next }
    user { pb += length($0) + 1; pw += NF; next }
    { kb += length($0) + 1; kw += NF }
    END { printf "%d %d\n", est(kb, kw), est(pb, pw) }
  ' "$path"
}

# Prints "<kit><TAB><project><TAB><heading text>" for each ## or ### section of a
# Markdown file; a section runs to the next such heading outside a code fence.
markdown_section_estimates() {
  [[ -f "$1" ]] || return 0
  LC_ALL=C awk '
    function est(b, w) { b = b / 4; w = w * 1.3; return int(b > w ? b : w) }
    function flush() { if (name != "") printf "%d\t%d\t%s\n", est(kb, kw), est(pb, pw), name }
    /^```/ { fence = !fence }
    !fence && /^###? / { flush(); name = $0; sub(/^#+ /, "", name); kb = 0; kw = 0; pb = 0; pw = 0 }
    name == "" { next }
    /<!-- BEGIN (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 1; next }
    /<!-- END (USER:|MANAGED: multi-agent-bootstrap:(detected-stack|detected-modules|verification-candidates|detection-warnings) )/ { kb += length($0) + 1; kw += NF; user = 0; next }
    user { pb += length($0) + 1; pw += NF; next }
    { kb += length($0) + 1; kw += NF }
    END { flush() }
  ' "$1"
}

budget_status() {  # <estimate> <amber> <gate>
  if [[ "$1" -gt "$3" ]]; then
    printf 'over'
  elif [[ "$1" -gt "$2" ]]; then
    printf 'amber'
  else
    printf 'ok'
  fi
}

# Prints the largest project parts as "path N, path N" (at most three).
largest_project_parts() {
  [[ $# -gt 0 ]] || return 0
  printf '%s\n' "$@" | sort -t "$(printf '\t')" -k1,1nr | head -3 |
    awk -F '\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'
}

# The total (kit + project) only warns: project content is the user's to shorten.
# Kit text above a gate is an error.
report_budget() {  # <label> <total> <kit> <amber> <gate> <status> <kit status> [project part...]
  local label="$1" total="$2" kit="$3" amber="$4" gate="$5" status="$6" kit_status="$7" parts
  shift 7
  case "$status" in
    over)
      parts="$(largest_project_parts "$@")"
      warn "$label: $total tokens exceeds gate $gate${parts:+; project content is yours to shorten: $parts}"
      ;;
    amber) warn "$label: $total tokens (gate $gate, amber above $amber); measure after any edit to a counted file" ;;
    *) ok "$label: $total tokens (gate $gate, amber above $amber)" ;;
  esac
  case "$kit_status" in
    over) bad "kit $label: $kit tokens exceeds gate $gate" ;;
    amber) warn "kit $label: $kit tokens (gate $gate, amber above $amber); measure after any edit to a counted file" ;;
    *) ok "kit $label: $kit tokens (gate $gate, amber above $amber)" ;;
  esac
}

budget_json() {  # <total> <kit> <project> <amber> <gate> <status> <kit status>
  printf '"estimate":%s,"kit":%s,"project":%s,"amber":%s,"gate":%s,"status":"%s","kit_status":"%s"' "$@"
}

# Core startup: what every seat reads first. On demand: core plus the workflow
# docs and, from the handoff reference, its State values section and the largest
# other section (a seat reads those two, not the whole reference).
check_context_budget() {
  local reference="$ROOT_DIR/docs/agent-configs/agent-handoff-reference.md"
  local relpath kit project label tab
  local core_kit=0 core_project=0 od_kit=0 od_project=0
  local state_kit=0 state_project=0 largest_kit=0 largest_project=0 largest_name=""
  local section_kit section_project section_name sections_json=""
  local core_total od_total core_status core_kit_status od_status od_kit_status
  local core_parts=() od_parts=()
  tab="$(printf '\t')"
  for relpath in \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md; do
    read -r kit project < <(split_file_estimate "$relpath")
    label="$relpath"
    if [[ "$BUDGET_USER_OWNED_FILES" != *" $relpath "* ]]; then
      label="$relpath (USER and detected blocks)"
    fi
    case "$relpath" in
      AGENTS.md|docs/agent-configs/project-agent-context.md|docs/agent-configs/project-brief.md)
        core_kit=$((core_kit + kit))
        core_project=$((core_project + project))
        if [[ "$project" -gt 0 ]]; then
          core_parts+=("$project$tab$label")
        fi
        ;;
    esac
    od_kit=$((od_kit + kit))
    od_project=$((od_project + project))
    if [[ "$project" -gt 0 ]]; then
      od_parts+=("$project$tab$label")
    fi
  done
  while IFS="$tab" read -r section_kit section_project section_name; do
    if [[ "$section_name" == "State values" ]]; then
      state_kit="$section_kit"
      state_project="$section_project"
    elif [[ $((section_kit + section_project)) -gt $((largest_kit + largest_project)) ]]; then
      largest_kit="$section_kit"
      largest_project="$section_project"
      largest_name="$section_name"
    fi
  done < <(markdown_section_estimates "$reference")
  od_kit=$((od_kit + state_kit + largest_kit))
  od_project=$((od_project + state_project + largest_project))
  if [[ $((state_project + largest_project)) -gt 0 ]]; then
    od_parts+=("$((state_project + largest_project))${tab}docs/agent-configs/agent-handoff-reference.md (USER and detected blocks)")
  fi
  core_total=$((core_kit + core_project))
  od_total=$((od_kit + od_project))
  core_status="$(budget_status "$core_total" 3800 4000)"
  core_kit_status="$(budget_status "$core_kit" 3800 4000)"
  od_status="$(budget_status "$od_total" 5900 6200)"
  od_kit_status="$(budget_status "$od_kit" 5900 6200)"

  report_budget "core startup context estimate" "$core_total" "$core_kit" 3800 4000 \
    "$core_status" "$core_kit_status" ${core_parts[@]+"${core_parts[@]}"}
  report_budget "on-demand full workflow context estimate" "$od_total" "$od_kit" 5900 6200 \
    "$od_status" "$od_kit_status" ${od_parts[@]+"${od_parts[@]}"}

  if [[ $((state_kit + state_project)) -gt 0 ]]; then
    sections_json='"State values"'
  fi
  if [[ -n "$largest_name" ]]; then
    sections_json="${sections_json:+$sections_json,}\"$(json_escape "$largest_name")\""
  fi
  CONTEXT_BUDGET_JSON="{\"core\":{$(budget_json "$core_total" "$core_kit" "$core_project" 3800 4000 "$core_status" "$core_kit_status")},\"on_demand\":{$(budget_json "$od_total" "$od_kit" "$od_project" 5900 6200 "$od_status" "$od_kit_status"),\"reference_sections\":[$sections_json]}}"
}

finish_report() {
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    emit_json_report
  else
    printf '\nPass: %s  Warn: %s  Fail: %s\n' "$PASS" "$WARN" "$FAIL"
  fi
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

validate_json_contracts() {
  python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
errors = []


def load_json(relpath):
    path = root / relpath
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{relpath}: {exc}")
        return None


def require(condition, message):
    if not condition:
        errors.append(message)


def require_exact_keys(value, expected, name):
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    actual = set(value.keys())
    expected_set = set(expected)
    extra = sorted(actual - expected_set)
    missing = sorted(expected_set - actual)
    if extra:
        errors.append(f"{name} has unexpected keys: {', '.join(extra)}")
    if missing:
        errors.append(f"{name} is missing keys: {', '.join(missing)}")


def non_empty_string(value):
    return isinstance(value, str) and value != ""


def safe_relative_path(value):
    if not non_empty_string(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


lock = load_json("docs/agent-configs/agent-bootstrap.lock.json") or {}
context_policy = load_json("docs/agent-configs/context-policy.json") or {}

if isinstance(lock, dict):
    require(lock.get("schema") == "agent-bootstrap-lock/v1", "lock.schema must be agent-bootstrap-lock/v1")
    for key in ("version", "channel", "project_name", "generated_at", "detector_summary_sha256", "detector_summary"):
        require(non_empty_string(lock.get(key)), f"lock.{key} must be a non-empty string")
    rtk = lock.get("rtk")
    require(isinstance(rtk, dict), "lock.rtk must be an object")
    if isinstance(rtk, dict):
        require(rtk.get("required") is True, "lock.rtk.required must be true")
        require(non_empty_string(rtk.get("version")), "lock.rtk.version must be a non-empty string")
        require(non_empty_string(rtk.get("install_command")), "lock.rtk.install_command must be a non-empty string")
    templates = lock.get("templates")
    require(isinstance(templates, dict), "lock.templates must be an object")
    if isinstance(templates, dict):
        require(non_empty_string(templates.get("base")), "lock.templates.base must be a non-empty string")
        require(templates.get("workflow_preset") in ("infra", "full"), "lock.templates.workflow_preset must be infra or full")
        overlays = templates.get("overlays")
        require(isinstance(overlays, list) and all(non_empty_string(item) for item in overlays), "lock.templates.overlays must be a non-empty string array")
else:
    require(False, "lock must be a JSON object")

if isinstance(context_policy, dict):
    require_exact_keys(
        context_policy,
        (
            "schema",
            "version",
            "mode",
            "purpose",
            "required_context",
            "recommended_context",
            "protected_paths",
            "change_protocol",
            "agent_instructions",
        ),
        "context policy",
    )
    require(context_policy.get("schema") == "agent-context-policy/v1", "context policy schema must be agent-context-policy/v1")
    require(non_empty_string(context_policy.get("version")), "context policy version must be a non-empty string")
    require(context_policy.get("mode") == "lite", "context policy mode must be lite")
    required_context = context_policy.get("required_context")
    require(isinstance(required_context, list) and all(non_empty_string(item) for item in required_context), "context policy required_context must be a non-empty string array")
    if isinstance(required_context, list):
        for index, item in enumerate(required_context):
            require(safe_relative_path(item), f"context policy required_context[{index}] must be a safe project-relative path")
    recommended_context = context_policy.get("recommended_context")
    require(isinstance(recommended_context, list) and all(non_empty_string(item) for item in recommended_context), "context policy recommended_context must be a string array")
    if isinstance(recommended_context, list):
        for index, item in enumerate(recommended_context):
            require(safe_relative_path(item), f"context policy recommended_context[{index}] must be a safe project-relative path")
    protected_paths = context_policy.get("protected_paths")
    require(isinstance(protected_paths, list) and bool(protected_paths), "context policy protected_paths must be a non-empty array")
    if isinstance(protected_paths, list):
        for index, item in enumerate(protected_paths):
            require(isinstance(item, dict), f"context policy protected_paths[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("pattern", "reason"), f"context policy protected_paths[{index}]")
                require(non_empty_string(item.get("pattern")), f"context policy protected_paths[{index}].pattern must be a non-empty string")
                require(safe_relative_path(item.get("pattern")), f"context policy protected_paths[{index}].pattern must be a safe project-relative path")
                require(non_empty_string(item.get("reason")), f"context policy protected_paths[{index}].reason must be a non-empty string")
    change_protocol = context_policy.get("change_protocol")
    require(isinstance(change_protocol, dict), "context policy change_protocol must be an object")
    if isinstance(change_protocol, dict):
        require_exact_keys(change_protocol, ("preflight", "pre_edit", "pre_final", "rollback"), "context policy change_protocol")
        for key in ("preflight", "pre_edit", "pre_final", "rollback"):
            require(non_empty_string(change_protocol.get(key)), f"context policy change_protocol.{key} must be a non-empty string")
    agent_instructions = context_policy.get("agent_instructions")
    require(isinstance(agent_instructions, list) and all(non_empty_string(item) for item in agent_instructions), "context policy agent_instructions must be a non-empty string array")
else:
    require(False, "context policy must be a JSON object")

schema_dir = "docs/agent-configs/bootstrap-multi-agent-project/schemas"
expected_schema_ids = {
    "agent-context-policy-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-context-policy-v1.schema.json",
    "agent-model-profiles-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-model-profiles-v1.schema.json",
    "agent-seats-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-seats-v1.schema.json",
    "agent-project-tech-stack-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-project-tech-stack-v1.schema.json",
    "agent-bootstrap-lock-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-lock-v1.schema.json",
    "agent-bootstrap-status-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-status-v1.schema.json",
    "agent-bootstrap-verify-report-v1.schema.json": "https://agent-bootstrap.local/schemas/agent-bootstrap-verify-report-v1.schema.json",
    "agent-guard-event-v2.schema.json": "https://agent-bootstrap.local/schemas/agent-guard-event-v2.schema.json",
    "agent-guard-verification-v2.schema.json": "https://agent-bootstrap.local/schemas/agent-guard-verification-v2.schema.json",
    "harness-project-knowledge-v1.schema.json": "https://agent-bootstrap.local/schemas/harness-project-knowledge-v1.schema.json",
    "harness-kit-run-report-v1.schema.json": "https://agent-bootstrap.local/schemas/harness-kit-run-report-v1.schema.json",
}
for filename, schema_id in expected_schema_ids.items():
    schema = load_json(f"{schema_dir}/{filename}") or {}
    require(isinstance(schema, dict), f"{filename} must be a JSON object")
    if isinstance(schema, dict):
        require(schema.get("$id") == schema_id, f"{filename} has unexpected $id")
        require(schema.get("type") == "object", f"{filename} must describe an object")

provenance_path = root / "docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"
entries = {}
try:
    for line_no, raw_line in enumerate(provenance_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        require(len(parts) == 2, f"rtk provenance line {line_no} must contain '<sha256> <asset>'")
        if len(parts) == 2:
            digest, asset = parts
            require(re.fullmatch(r"[0-9a-f]{64}", digest) is not None, f"rtk provenance digest for {asset} must be lowercase sha256")
            entries[asset] = digest
except Exception as exc:
    errors.append(f"rtk provenance manifest cannot be read: {exc}")

required_assets = (
    "rtk-aarch64-apple-darwin.tar.gz",
    "rtk-x86_64-apple-darwin.tar.gz",
    "rtk-aarch64-unknown-linux-gnu.tar.gz",
    "rtk-x86_64-unknown-linux-musl.tar.gz",
)
for asset in required_assets:
    require(asset in entries, f"rtk provenance missing asset {asset}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
}

validate_project_tech_stack_contract() {
  python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "docs/superpowers/specs/project-tech-stack.json"
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def non_empty_string(value):
    return isinstance(value, str) and value != ""


def safe_relative_path(value):
    if not non_empty_string(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


def require_exact_keys(value, expected, name):
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    actual = set(value.keys())
    expected_set = set(expected)
    extra = sorted(actual - expected_set)
    missing = sorted(expected_set - actual)
    if extra:
        errors.append(f"{name} has unexpected keys: {', '.join(extra)}")
    if missing:
        errors.append(f"{name} is missing keys: {', '.join(missing)}")


try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"project-tech-stack.json: {exc}", file=sys.stderr)
    sys.exit(1)

require(isinstance(doc, dict), "project tech-stack contract must be an object")
if isinstance(doc, dict):
    require_exact_keys(
        doc,
        (
            "schema",
            "status",
            "last_verified",
            "stacks",
            "modules",
            "architecture_boundaries",
            "generated_files",
            "protected_paths",
            "verification",
            "conventions",
            "source_evidence",
            "open_questions",
        ) + (("toolchain",) if "toolchain" in doc else ()),
        "project tech-stack contract",
    )
    require(doc.get("schema") == "agent-project-tech-stack/v1", "project tech-stack schema must be agent-project-tech-stack/v1")
    require(doc.get("status") in ("unfilled", "partial", "filled"), "project tech-stack status must be unfilled, partial, or filled")
    last_verified = doc.get("last_verified")
    require(isinstance(last_verified, dict), "project tech-stack last_verified must be an object")
    if isinstance(last_verified, dict):
        require_exact_keys(last_verified, ("commit", "date"), "project tech-stack last_verified")
        require(isinstance(last_verified.get("commit"), str), "project tech-stack last_verified.commit must be a string")
        require(isinstance(last_verified.get("date"), str), "project tech-stack last_verified.date must be a string")
    for key in (
        "stacks",
        "modules",
        "architecture_boundaries",
        "generated_files",
        "protected_paths",
        "conventions",
        "open_questions",
    ):
        require(isinstance(doc.get(key), list) and all(isinstance(item, str) for item in doc.get(key, [])), f"project tech-stack {key} must be a string array")
    for key in ("generated_files", "protected_paths"):
        values = doc.get(key)
        if isinstance(values, list):
            for index, item in enumerate(values):
                require(safe_relative_path(item), f"project tech-stack {key}[{index}] must be a safe project-relative path")
    verification = doc.get("verification")
    require(isinstance(verification, list), "project tech-stack verification must be an array")
    if isinstance(verification, list):
        for index, item in enumerate(verification):
            require(isinstance(item, dict), f"project tech-stack verification[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("command", "purpose", "source") + (("scope",) if "scope" in item else ()), f"project tech-stack verification[{index}]")
                if "scope" in item:
                    require(item.get("scope") in ("fast", "full"), f"project tech-stack verification[{index}].scope must be fast or full")
                for key in ("command", "purpose", "source"):
                    require(non_empty_string(item.get(key)), f"project tech-stack verification[{index}].{key} must be a non-empty string")
    if "toolchain" in doc:
        toolchain = doc.get("toolchain")
        require(isinstance(toolchain, list) and all(non_empty_string(entry) for entry in toolchain), "project tech-stack toolchain must be an array of non-empty strings")
    evidence = doc.get("source_evidence")
    require(isinstance(evidence, list), "project tech-stack source_evidence must be an array")
    if isinstance(evidence, list):
        for index, item in enumerate(evidence):
            require(isinstance(item, dict), f"project tech-stack source_evidence[{index}] must be an object")
            if isinstance(item, dict):
                require_exact_keys(item, ("path", "claim"), f"project tech-stack source_evidence[{index}]")
                evidence_path = item.get("path")
                require(non_empty_string(evidence_path), f"project tech-stack source_evidence[{index}].path must be a non-empty string")
                if non_empty_string(evidence_path):
                    require(safe_relative_path(evidence_path), f"project tech-stack source_evidence[{index}].path must be a safe project-relative path")
                    if safe_relative_path(evidence_path):
                        require((root / evidence_path).is_file(), f"project tech-stack source_evidence[{index}].path must reference an existing file")
                require(non_empty_string(item.get("claim")), f"project tech-stack source_evidence[{index}].claim must be a non-empty string")
    if doc.get("status") == "filled":
        require(non_empty_string(last_verified.get("commit") if isinstance(last_verified, dict) else None), "filled project tech-stack requires last_verified.commit")
        require(non_empty_string(last_verified.get("date") if isinstance(last_verified, dict) else None), "filled project tech-stack requires last_verified.date")
        require(bool(doc.get("source_evidence")), "filled project tech-stack requires source_evidence")
        require(bool(doc.get("verification")), "filled project tech-stack requires verification")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
}

if [[ "$BUDGET_ONLY" == "true" ]]; then
  if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
    check_context_budget
  else
    ok "workflow preset is infra-only; no context budget applies"
  fi
  finish_report
fi

if [[ "$OUTPUT_JSON" != "true" ]]; then
  echo "Verifying generated agent infrastructure..."
fi

for path in \
  AGENTS.md \
  CLAUDE.md \
  docs/agent-configs/agent-bootstrap.lock.json \
  docs/agent-configs/project-agent-context.md \
  docs/agent-configs/context-policy.json \
  docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/android_kotlin.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/python.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/ios_swift.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/node_js.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/generic.md \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json \
  docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256 \
  .claude/settings.json \
  .claude/README.md \
  .agents/skills/agentmemory-mcp/SKILL.md \
  .agents/skills/agentmemory-mcp/agents/openai.yaml; do
  need_file "$path"
done

lock_schema="$(lock_value schema)"
if [[ "$lock_schema" == "agent-bootstrap-lock/v1" ]]; then
  ok "bootstrap lock schema is agent-bootstrap-lock/v1"
else
  bad "bootstrap lock schema is not agent-bootstrap-lock/v1"
fi

lock_workflow="$(lock_value workflow_preset)"
case "$lock_workflow" in
  infra|full) ok "bootstrap lock workflow preset is valid: $lock_workflow" ;;
  *) bad "bootstrap lock workflow preset is invalid: ${lock_workflow:-missing}" ;;
esac

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if [[ -e "$ROOT_DIR/docs/agent-configs/seats.json" ]]; then
    if [[ -x "$ROOT_DIR/scripts/agent-seats.sh" ]] && "$ROOT_DIR/scripts/agent-seats.sh" validate >/dev/null 2>&1; then
      ok "seats.json is valid"
    else
      bad "seats.json is invalid"
    fi
  else
    warn "seats.json is missing; run scripts/agent-seats.sh init"
  fi

  if [[ -e "$ROOT_DIR/docs/agent-configs/model-profiles.json" ]]; then
    warn "inactive legacy model-profiles.json is present; seats.json is authoritative"
    if python3 -m json.tool "$ROOT_DIR/docs/agent-configs/model-profiles.json" >/dev/null 2>&1; then
      ok "inactive legacy model profile JSON parses"
    else
      warn "inactive legacy model profile JSON is malformed; seats.json is authoritative"
    fi
  fi
fi

if grep -Eq '"schema"[[:space:]]*:[[:space:]]*"agent-context-policy/v1"' "$ROOT_DIR/docs/agent-configs/context-policy.json"; then
  ok "agent context policy schema is agent-context-policy/v1"
else
  bad "agent context policy schema is not agent-context-policy/v1"
fi

if grep -Fq 'rtk-aarch64-apple-darwin.tar.gz' "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256"; then
  ok "rtk provenance manifest exists"
else
  bad "rtk provenance manifest is missing expected assets"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$ROOT_DIR/docs/agent-configs/context-policy.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-event-v2.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-guard-verification-v2.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-project-knowledge-v1.schema.json" >/dev/null 2>&1 &&
    python3 -m json.tool "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-kit-run-report-v1.schema.json" >/dev/null 2>&1; then
    ok "schema JSON parses"
  else
    bad "schema JSON is invalid"
  fi
  if validate_json_contracts >/dev/null; then
    ok "bootstrap JSON contracts validate"
  else
    bad "bootstrap JSON contracts failed validation"
  fi
else
  warn "python3 not found; skipped schema/model JSON validation"
  warn "python3 not found; skipped bootstrap JSON contract validation"
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  for path in \
  docs/agent-configs/agent-mode-contracts.md \
  docs/agent-configs/agent-handoff-schema.md \
  docs/agent-configs/karpathy-llm-coding-agent-config.md \
  docs/agent-configs/llm-council-agent-workflow.md \
  docs/agent-configs/task-journal.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/karpathy/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/council/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md \
  docs/agent-configs/first-10-minutes.md \
  docs/agent-configs/project-onboarding.md \
  docs/agent-configs/project-brief.md \
  .codex/config.toml \
  .codex/codex-mode.sh \
  .codex/README.md \
  .agents/skills/doubt-driven/SKILL.md \
  .claude/commands/planning.md \
  .claude/commands/planning-full-flow.md \
  .claude/commands/coding.md \
  .claude/commands/coding-full-flow.md \
  .claude/commands/reviewing.md \
  .claude/commands/reviewing-full-flow.md \
  .claude/commands/project-onboarding.md \
  .claude/commands/codex/setup.md \
  .claude/commands/codex/rescue.md \
  .claude/commands/codex/status.md \
  .claude/commands/doctor.md \
  docs/superpowers/specs/README.md \
  docs/superpowers/specs/project-tech-stack.md \
  docs/superpowers/specs/project-tech-stack.json \
  docs/superpowers/plans/README.md; do
    need_file "$path"
  done
  if command -v python3 >/dev/null 2>&1; then
    if validate_project_tech_stack_contract >/dev/null; then
      ok "project tech-stack contract validates"
    else
      bad "project tech-stack contract failed validation"
    fi
  else
    warn "python3 not found; skipped project tech-stack contract validation"
  fi
  if [[ -f "$ROOT_DIR/docs/agent-configs/project-brief.md" ]] &&
    grep -Fq '<!-- UNFILLED -->' "$ROOT_DIR/docs/agent-configs/project-brief.md"; then
    warn "project brief is unfilled; run project onboarding before substantive work"
  else
    ok "project brief is filled or not required"
  fi
  if [[ -x "$ROOT_DIR/scripts/agent-onboarding.sh" ]]; then
    onboarding_status_json="$("$ROOT_DIR/scripts/agent-onboarding.sh" status --json 2>/dev/null || true)"
    if printf '%s' "$onboarding_status_json" | python3 -m json.tool >/dev/null 2>&1; then
      onboarding_status="$(
        printf '%s' "$onboarding_status_json" |
          python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","invalid"))'
      )"
      case "$onboarding_status" in
        filled) ok "onboarding contract is filled" ;;
        partial) warn "onboarding contract is partial; run scripts/agent-onboarding.sh next" ;;
        unfilled) warn "onboarding contract is unfilled; run scripts/agent-onboarding.sh next" ;;
        *) bad "onboarding contract status is invalid: $onboarding_status" ;;
      esac
    else
      bad "onboarding contract status JSON is invalid"
    fi
  else
    bad "missing executable onboarding helper: scripts/agent-onboarding.sh"
  fi
  check_context_budget
else
  ok "workflow preset is infra-only; workflow philosophy files are opt-in"
fi

need_file scripts/install-rtk.sh
need_executable scripts/install-rtk.sh
need_executable scripts/rtk
need_file scripts/agent-tech-stack-lib.sh
need_executable scripts/agent-tech-stack-lib.sh
need_executable scripts/agent-hook.sh
need_executable scripts/agent-guard.sh
need_executable scripts/agent-local-only-check.sh
need_executable scripts/harness-kit.sh
need_executable scripts/detect-agent-tech-stack.sh
need_executable scripts/verify-ai-deps.sh

need_bash_syntax scripts/install-rtk.sh
need_bash_syntax scripts/rtk
need_bash_syntax scripts/agent-tech-stack-lib.sh
need_bash_syntax scripts/agent-hook.sh
need_bash_syntax scripts/agent-guard.sh
need_bash_syntax scripts/agent-local-only-check.sh
need_bash_syntax scripts/harness-kit.sh
need_bash_syntax scripts/detect-agent-tech-stack.sh
need_bash_syntax scripts/verify-ai-deps.sh
if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  need_executable scripts/agent-seats.sh
  need_bash_syntax scripts/agent-seats.sh
  need_executable scripts/agent-onboarding.sh
  need_bash_syntax scripts/agent-onboarding.sh
  need_bash_syntax .codex/codex-mode.sh
fi

if "$ROOT_DIR/scripts/rtk" --version 2>/dev/null | grep -Fq '0.37.2'; then
  ok "rtk wrapper resolves pinned version 0.37.2"
else
  warn "rtk pinned binary is not installed; run: bash scripts/install-rtk.sh before using rtk-specific hooks"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$ROOT_DIR/.claude/settings.json" >/dev/null 2>&1; then
    ok "Claude settings JSON is valid"
  else
    bad "Claude settings JSON is invalid"
  fi
else
  warn "python3 not found; skipped Claude settings JSON validation"
fi

if grep -Fq './scripts/agent-hook.sh claude-pretool' "$ROOT_DIR/.claude/settings.json"; then
  ok "Claude PreToolUse uses shared agent hook"
else
  bad "Claude PreToolUse does not use shared agent hook"
fi

if grep -Fq '"matcher": "Edit|Write|MultiEdit"' "$ROOT_DIR/.claude/settings.json"; then
  ok "Claude PreToolUse guards edit/write tools"
else
  bad "Claude PreToolUse does not guard edit/write tools"
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if grep -Fq 'codex-preflight' "$ROOT_DIR/.codex/codex-mode.sh"; then
    ok "Codex helper calls shared hook preflight"
  else
    bad "Codex helper does not call shared hook preflight"
  fi
else
  ok "Codex mode helper not installed for infra-only workflow"
fi

if "$ROOT_DIR/scripts/detect-agent-tech-stack.sh" --summary >/dev/null 2>&1; then
  ok "runtime detector runs"
else
  bad "runtime detector failed"
fi

detector_summary="$("$ROOT_DIR/scripts/detect-agent-tech-stack.sh" --summary 2>/dev/null || true)"
if [[ "$detector_summary" == *"modules="* ]]; then
  ok "runtime detector reports modules"
else
  bad "runtime detector summary does not report modules"
fi

expected_detector_hash="$(lock_value detector_summary_sha256)"
actual_detector_hash="$(printf '%s' "$detector_summary" | hash_text)"
if [[ -n "$expected_detector_hash" && "$expected_detector_hash" == "$actual_detector_hash" ]]; then
  ok "runtime detector summary matches bootstrap lock"
else
  bad "runtime detector summary drifted from bootstrap lock"
fi

if "$ROOT_DIR/scripts/agent-hook.sh" guard-local-state >/dev/null 2>&1; then
  ok "local-only agent state is not tracked"
else
  bad "local-only agent state guard failed"
fi

no_scan_paths="$("$ROOT_DIR/scripts/agent-hook.sh" no-scan-paths 2>/dev/null || true)"
if printf '%s\n' "$no_scan_paths" | grep -Fq '.claude/worktrees/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.tools/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.gemini/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.windsurf/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '.openclaude/' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq 'AGENTS.local.md' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq 'local.properties' &&
   printf '%s\n' "$no_scan_paths" | grep -Fq '*.jks'; then
  ok "no-scan guard exposes local/sensitive paths"
else
  bad "no-scan guard paths are incomplete"
fi

if "$ROOT_DIR/scripts/agent-hook.sh" codex-preflight --check-only planning standard >/dev/null 2>&1; then
  ok "shared agent hook codex preflight passes"
else
  bad "shared agent hook codex preflight failed"
fi

if "$ROOT_DIR/scripts/agent-guard.sh" check >/dev/null 2>&1; then
  ok "agent guard check passes"
else
  bad "agent guard check failed"
fi

pending_candidate="$(pending_bootstrap_generated_candidate || true)"
if [[ -n "$pending_candidate" ]]; then
  warn "pending generated candidate requires review: $pending_candidate"
else
  ok "no pending generated candidates"
fi

lock_version="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" 2>/dev/null | head -1)"
if [[ -n "$lock_version" ]]; then
  stale_version_refs=""
  for version_file in README.md docs/superpowers/specs/project-tech-stack.json docs/agent-configs/project-brief.md; do
    [[ -f "$ROOT_DIR/$version_file" ]] || continue
    while IFS= read -r found_version; do
      [[ -n "$found_version" && "$found_version" != "$lock_version" ]] &&
        stale_version_refs="$stale_version_refs $version_file:$found_version"
    done < <(grep -oE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+' "$ROOT_DIR/$version_file" 2>/dev/null | sort -u)
  done
  if [[ -n "$stale_version_refs" ]]; then
    warn "stale harness version references (lock is $lock_version):$stale_version_refs"
  else
    ok "harness version references match lock ($lock_version)"
  fi
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if "$ROOT_DIR/.codex/codex-mode.sh" doctor >/dev/null 2>&1; then
    ok "Codex helper doctor passes"
  else
    codex_candidate="$(find "$ROOT_DIR/.codex" -name '*.generated.*' -print 2>/dev/null | head -1)"
    if [[ -n "$codex_candidate" && ! -w "$ROOT_DIR/.codex" ]]; then
      warn "Codex helper doctor skipped: read-only .codex candidate unapplied (${codex_candidate#"$ROOT_DIR"/}); promote with write access"
    else
      bad "Codex helper doctor failed"
    fi
  fi
else
  ok "Codex helper doctor skipped for infra-only workflow"
fi

if [[ -x "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" ]]; then
  if [[ "${AGENT_BOOTSTRAP_SKIP_SMOKE:-}" == "1" ]]; then
    warn "portable bootstrap integration smoke test skipped to avoid recursion"
  elif [[ ! -t 0 ]]; then
    warn "portable bootstrap integration smoke test skipped in non-interactive shell"
  elif ! command -v timeout >/dev/null 2>&1; then
    warn "portable bootstrap integration smoke test skipped because timeout is unavailable"
  elif AGENT_BOOTSTRAP_SKIP_SMOKE=1 timeout 120 "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" </dev/null >/dev/null 2>&1; then
    ok "portable bootstrap integration smoke test passes"
  else
    bad "portable bootstrap integration smoke test failed"
  fi
else
  warn "portable bootstrap integration smoke test missing"
fi

finish_report
EOF

  replace_placeholder "$LAST_WRITTEN_FILE" "__WORKFLOW_PRESET__" "$WORKFLOW_PRESET"
  make_executable "$LAST_WRITTEN_FILE"
}
