#!/usr/bin/env bash
# agent-bootstrap/lib/writers-runtime.sh
# Sourced by bootstrap-multi-agent-project.sh. Emits target scripts/* runtime files.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

write_rtk_tools() {
  write_file "$TARGET_DIR/scripts/install-rtk.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_VERSION="0.37.2"

OS="$(uname -s)"
ARCH="$(uname -m)"
PLATFORM="${OS}-${ARCH}"

case "${PLATFORM}" in
  Darwin-arm64)
    ASSET="rtk-aarch64-apple-darwin.tar.gz"
    SHA256="99e20a59847dedbb64032a3f7985f2fe959fcb9674d8eaf940fc58a189e27eca"
    ;;
  Darwin-x86_64)
    ASSET="rtk-x86_64-apple-darwin.tar.gz"
    SHA256="4052e7740a87e121f671a2de269b3f015dcc58b6171d6bedb300da7599cb4d94"
    ;;
  Linux-aarch64)
    ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"
    SHA256="1d8d7fcca6cb05e1867c08bb4e5aa5f107c037c607131e511b726ae33ac35a47"
    ;;
  Linux-x86_64)
    ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"
    SHA256="3dfb7a05636a68687ba1c5aa696fa8d5fcb494447ded86d9eb8b88b7100a37c6"
    ;;
  *)
    echo "Unsupported platform: ${PLATFORM}" >&2
    exit 1
    ;;
esac

DOWNLOAD_URL="https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${ASSET}"
INSTALL_DIR="${ROOT_DIR}/.tools/rtk/v${RTK_VERSION}"
ARCHIVE_PATH="${INSTALL_DIR}/${ASSET}"
BIN_PATH="${INSTALL_DIR}/rtk"
LINK_PATH="${ROOT_DIR}/.tools/bin/rtk"

mkdir -p "${INSTALL_DIR}" "${ROOT_DIR}/.tools/bin"
if command -v curl >/dev/null 2>&1; then
  curl -fL "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}"
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

tar -xzf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
chmod +x "${BIN_PATH}"
ln -sfn "../rtk/v${RTK_VERSION}/rtk" "${LINK_PATH}"

echo "Installed pinned rtk v${RTK_VERSION} at ${BIN_PATH}"
"${BIN_PATH}" --version
EOF
  make_executable "$LAST_WRITTEN_FILE"

  write_file "$TARGET_DIR/scripts/rtk" <<'EOF'
#!/usr/bin/env bash
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
  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md" <<'EOF'
# Base Multi-Agent Template

Portable baseline applied to every bootstrapped project.

Managed sections generated from this template must be bounded by:

```text
<!-- BEGIN MANAGED: multi-agent-bootstrap:<section> -->
<!-- END MANAGED: multi-agent-bootstrap:<section> -->
```

Base rules:

- Keep tool-specific files thin; durable rules live under `docs/agent-configs/`.
- Require runtime stack refresh through `scripts/detect-agent-tech-stack.sh`.
- Require rtk for all shell git operations through `./scripts/rtk git ...`.
- Default planning/coding/reviewing modes are project-local full-flow; use a
  supervised/read-only/propose argument only when the user wants gated actions.
- Use Claude as primary planning owner and Codex as primary coding/review
  owner unless a project-specific override says otherwise.
- Track generated detector state in `docs/agent-configs/agent-bootstrap.lock.json`.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/android_kotlin.md" <<'EOF'
# Android/Kotlin Overlay

Apply only when detector reports `android_kotlin` or `android_java`.

- Prefer existing Android architecture and Gradle module boundaries.
- Verify with project-specific Gradle tasks from `project-agent-context.md`.
- Treat manifests, resources, navigation graphs, DI, R8/ProGuard, Firebase, and build variants as protected areas.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/python.md" <<'EOF'
# Python Overlay

Apply only when detector reports `python`, `python_fastapi`, or `python_django`.

- Prefer existing package/test layout before introducing new structure.
- Verify with the detected test/lint commands only after confirming they exist.
- Do not apply Android/Gradle protected-path rules to Python projects.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/ios_swift.md" <<'EOF'
# iOS/Swift Overlay

Apply only when detector reports `ios_swift`.

- Inspect `.xcodeproj`, `.xcworkspace`, `Package.swift`, `Podfile`, and scheme layout before proposing verification.
- `xcodebuild -list` is discovery only, not a build proof.
- Do not apply Android/Gradle protected-path rules to iOS projects.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/node_js.md" <<'EOF'
# Node/Web Overlay

Apply when detector reports `node_js`, `react`, `nextjs`, `vue`, or `svelte`.

- Confirm whether `package.json` is production code or local tooling before applying frontend rules.
- Prefer package-manager scripts actually present in `package.json`.
- Do not assume `npm test`, `npm run lint`, or `npm run build` exists without checking scripts.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/generic.md" <<'EOF'
# Generic Overlay

Apply when detector cannot identify a specific stack.

- Treat all verification commands as placeholders until project scripts are inspected.
- Ask for the smallest missing context before implementation if stack behavior is ambiguous.
- Do not import Android, iOS, Python, or Node-specific rules by default.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/karpathy/README.md" <<'EOF'
# Karpathy-Style LLM Coding Workflow

Opt-in workflow philosophy. Apply only when bootstrap is run with
`--workflow full` or a future workflow preset that explicitly includes
`karpathy`.

- Context first, edits second.
- Small coherent patches.
- Explicit assumptions, risks, verification, and final diff review.
- No success claims without evidence.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/council/README.md" <<'EOF'
# Council Workflow

Opt-in workflow philosophy. Apply only when bootstrap is run with
`--workflow full` or a future workflow preset that explicitly includes
`council`.

- Council is advisory until verified.
- Chair owns synthesis and preserves high-impact minority objections.
- One executor owns overlapping patches.
EOF

  write_file "$TARGET_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md" <<'EOF'
# Three-Mode Workflow

Opt-in workflow philosophy. Apply only when bootstrap is run with
`--workflow full` or `--workflow three-mode`.

- Planning: strategy/spec/refactor/performance planning.
- Coding: implementation/tests/verification with a spec adequacy gate.
- Reviewing: findings-first review with strict stop conditions.
EOF
}

write_tech_stack_lib() {
  write_file "$TARGET_DIR/scripts/agent-tech-stack-lib.sh" < <(emit_tech_stack_lib)
  make_executable "$LAST_WRITTEN_FILE"
}

write_runtime_detector() {
  write_file "$TARGET_DIR/scripts/detect-agent-tech-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FORMAT="markdown"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$SCRIPT_DIR/agent-tech-stack-lib.sh"

usage() {
  printf '%s\n' \
    "Usage: scripts/detect-agent-tech-stack.sh [--root DIR] [--markdown|--summary]" \
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
  echo "ERROR: missing tech-stack detection library: ${LIB#$ROOT/}" >&2
  exit 1
fi

# shellcheck source=scripts/agent-tech-stack-lib.sh
source "$LIB"

agent_detect_tech_stack "$ROOT"

if [[ "$FORMAT" == "summary" ]]; then
  agent_print_summary
  exit 0
fi

agent_print_markdown "$ROOT"
EOF

  make_executable "$LAST_WRITTEN_FILE"
}

write_agent_hook() {
  write_file "$TARGET_DIR/scripts/agent-hook.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RTK="$PROJECT_ROOT/scripts/rtk"
DETECTOR="$PROJECT_ROOT/scripts/detect-agent-tech-stack.sh"
LOCK_FILE="$PROJECT_ROOT/docs/agent-configs/agent-bootstrap.lock.json"
CODEX_HELPER="$PROJECT_ROOT/.codex/codex-mode.sh"
VERIFY_AI_DEPS="$PROJECT_ROOT/scripts/verify-ai-deps.sh"

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
  [[ -f "$1" ]] || fail "missing required file: ${1#$PROJECT_ROOT/}"
}

required_executable() {
  [[ -x "$1" ]] || fail "missing executable file: ${1#$PROJECT_ROOT/}"
}

rtk_available() {
  [[ -x "$RTK" ]] && "$RTK" --version >/dev/null 2>&1
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

lock_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$LOCK_FILE" | head -n1
}

verify_detector_lock() {
  local on_drift="${1:-fail}"
  required_file "$LOCK_FILE"
  local expected actual summary
  expected="$(lock_value detector_summary_sha256)"
  [[ -n "$expected" ]] || fail "missing detector_summary_sha256 in ${LOCK_FILE#$PROJECT_ROOT/}"
  summary="$($DETECTOR --summary)"
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

claude_pretool() {
  required_executable "$DETECTOR"
  verify_detector_lock warn
  cd "$PROJECT_ROOT"
  if rtk_available; then
    exec "$RTK" hook claude
  fi
  echo "agent-hook: warn: pinned rtk binary is not installed; skipping rtk Claude hook. Run: bash scripts/install-rtk.sh" >&2
  exit 0
}

codex_preflight() {
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
  guard_local_state
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

case "${1:-}" in
  claude-pretool)
    shift || true
    claude_pretool "$@"
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
  -h|--help|help|"")
    echo "Usage: scripts/agent-hook.sh claude-pretool|codex-preflight|guard-local-state|no-scan-paths|doctor"
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
set -euo pipefail

WORKFLOW_PRESET="__WORKFLOW_PRESET__"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
WARN=0

ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  warn  %s\n' "$1"; WARN=$((WARN + 1)); }

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

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

lock_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$ROOT_DIR/docs/agent-configs/agent-bootstrap.lock.json" | head -n1
}

estimate_tokens_for_file() {
  local path="$1"
  local words="0"
  local chars="0"
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  set -- $(wc -w -c < "$path")
  words="$1"
  chars="$2"
  awk -v words="$words" -v chars="$chars" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

sum_estimated_tokens() {
  local total=0
  local token_count=0
  local relpath
  for relpath in "$@"; do
    token_count="$(estimate_tokens_for_file "$ROOT_DIR/$relpath")"
    total=$((total + token_count))
  done
  printf '%s' "$total"
}

check_context_budget() {
  local core_tokens
  local full_tokens
  core_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md)"
  full_tokens="$(sum_estimated_tokens \
    AGENTS.md \
    docs/agent-configs/project-agent-context.md \
    docs/agent-configs/project-brief.md \
    docs/agent-configs/agent-mode-contracts.md \
    docs/agent-configs/agent-handoff-schema.md \
    docs/agent-configs/karpathy-llm-coding-agent-config.md \
    docs/agent-configs/llm-council-agent-workflow.md)"

  if [[ "$core_tokens" -le 3000 ]]; then
    ok "core startup context estimate: ${core_tokens} tokens (budget 3000)"
  else
    warn "core startup context estimate: ${core_tokens} tokens exceeds budget 3000"
  fi

  if [[ "$full_tokens" -le 6500 ]]; then
    ok "on-demand full workflow context estimate: ${full_tokens} tokens (budget 6500)"
  else
    warn "on-demand full workflow context estimate: ${full_tokens} tokens exceeds budget 6500"
  fi
}

echo "Verifying generated agent infrastructure..."

for path in \
  AGENTS.md \
  CLAUDE.md \
  docs/agent-configs/agent-bootstrap.lock.json \
  docs/agent-configs/project-agent-context.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/android_kotlin.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/python.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/ios_swift.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/node_js.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/generic.md \
  .claude/settings.json \
  .claude/README.md \
  .agents/skills/agentmemory-mcp/SKILL.md \
  .agents/skills/agentmemory-mcp/agents/openai.yaml; do
  need_file "$path"
done

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  for path in \
  docs/agent-configs/agent-mode-contracts.md \
  docs/agent-configs/agent-handoff-schema.md \
  docs/agent-configs/karpathy-llm-coding-agent-config.md \
  docs/agent-configs/llm-council-agent-workflow.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/karpathy/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/council/README.md \
  docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md \
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
  docs/superpowers/plans/README.md; do
    need_file "$path"
  done
  if [[ -f "$ROOT_DIR/docs/agent-configs/project-brief.md" ]] &&
    grep -Fq '<!-- UNFILLED -->' "$ROOT_DIR/docs/agent-configs/project-brief.md"; then
    warn "project brief is unfilled; run project onboarding before substantive work"
  else
    ok "project brief is filled or not required"
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
need_executable scripts/detect-agent-tech-stack.sh
need_executable scripts/verify-ai-deps.sh

need_bash_syntax scripts/install-rtk.sh
need_bash_syntax scripts/rtk
need_bash_syntax scripts/agent-tech-stack-lib.sh
need_bash_syntax scripts/agent-hook.sh
need_bash_syntax scripts/detect-agent-tech-stack.sh
need_bash_syntax scripts/verify-ai-deps.sh
if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
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

if "$ROOT_DIR/scripts/agent-hook.sh" codex-preflight planning standard >/dev/null 2>&1; then
  ok "shared agent hook codex preflight passes"
else
  bad "shared agent hook codex preflight failed"
fi

pending_candidate="$(find "$ROOT_DIR" \
  \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.tools" -o -path "$ROOT_DIR/.gradle" -o -path "$ROOT_DIR/build" \) -prune -o \
  -name '*.generated.*' -print -quit 2>/dev/null || true)"
if [[ -n "$pending_candidate" ]]; then
  warn "pending generated candidate requires review: ${pending_candidate#$ROOT_DIR/}"
else
  ok "no pending generated candidates"
fi

if [[ "$WORKFLOW_PRESET" != "infra" && "$WORKFLOW_PRESET" != "none" ]]; then
  if "$ROOT_DIR/.codex/codex-mode.sh" doctor >/dev/null 2>&1; then
    ok "Codex helper doctor passes"
  else
    bad "Codex helper doctor failed"
  fi
else
  ok "Codex helper doctor skipped for infra-only workflow"
fi

if [[ -x "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" ]]; then
  if [[ "${AGENT_BOOTSTRAP_SKIP_SMOKE:-}" == "1" ]]; then
    warn "portable bootstrap integration smoke test skipped to avoid recursion"
  elif AGENT_BOOTSTRAP_SKIP_SMOKE=1 "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" >/dev/null 2>&1; then
    ok "portable bootstrap integration smoke test passes"
  else
    bad "portable bootstrap integration smoke test failed"
  fi
else
  warn "portable bootstrap integration smoke test missing"
fi

printf '\nPass: %s  Warn: %s  Fail: %s\n' "$PASS" "$WARN" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
EOF

  replace_placeholder "$LAST_WRITTEN_FILE" "__WORKFLOW_PRESET__" "$WORKFLOW_PRESET"
  make_executable "$LAST_WRITTEN_FILE"
}
