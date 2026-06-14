#!/usr/bin/env bash
# Verify AI tooling versions are pinned to expected releases.
# Usage: scripts/verify-ai-deps.sh

set -euo pipefail

EXPECTED_RTK="0.37.2"
EXPECTED_SUPERPOWERS_VERSION="5.0.7"
EXPECTED_SUPERPOWERS_SHA="f9b088f7b3a6fe9d9a9a98e392ad13c9d47053a4"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_WRAPPER="${ROOT_DIR}/scripts/rtk"
RTK_PINNED_BIN="${ROOT_DIR}/.tools/rtk/v${EXPECTED_RTK}/rtk"
RTK_LINK="${ROOT_DIR}/.tools/bin/rtk"
CODEX_CONFIG="${ROOT_DIR}/.codex/config.toml"
CODEX_MODE_HELPER="${ROOT_DIR}/.codex/codex-mode.sh"
CODEX_SETUP_SCRIPT="${ROOT_DIR}/.codex/setup-codex-project.sh"
CODEX_STATE_FILE="${ROOT_DIR}/.codex/.setup-codex-project.state"
CODEX_MODE_CONTRACT="${ROOT_DIR}/docs/agent-configs/agent-mode-contracts.md"
CODEX_HANDOFF_SCHEMA="${ROOT_DIR}/docs/agent-configs/agent-handoff-schema.md"
CODEX_PROJECT_CONTEXT="${ROOT_DIR}/docs/agent-configs/project-agent-context.md"
AGENT_BOOTSTRAP_LOCK="${ROOT_DIR}/docs/agent-configs/agent-bootstrap.lock.json"
TECH_STACK_DETECTOR="${ROOT_DIR}/scripts/detect-agent-tech-stack.sh"
TECH_STACK_LIB="${ROOT_DIR}/scripts/agent-tech-stack-lib.sh"
AGENT_HOOK="${ROOT_DIR}/scripts/agent-hook.sh"
MULTI_AGENT_BOOTSTRAP="${ROOT_DIR}/scripts/bootstrap-multi-agent-project.sh"
BOOTSTRAP_HOME_INSTALLER="${ROOT_DIR}/scripts/install-agent-bootstrap-home.sh"
BOOTSTRAP_BUNDLE_ROOT="${ROOT_DIR}/agent-bootstrap"
BOOTSTRAP_BUNDLE_VERSION_FILE="${BOOTSTRAP_BUNDLE_ROOT}/VERSION"
BOOTSTRAP_BUNDLE_MANIFEST="${BOOTSTRAP_BUNDLE_ROOT}/MANIFEST.md"
BOOTSTRAP_INTEGRATION_TEST="${ROOT_DIR}/scripts/test-bootstrap-multi-agent-project.sh"
BOOTSTRAP_SOURCE_ROOT="${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project"
BOOTSTRAP_SOLO_README="${BOOTSTRAP_SOURCE_ROOT}/README.md"
CLAUDE_INSTRUCTIONS="${ROOT_DIR}/CLAUDE.md"
CLAUDE_README="${ROOT_DIR}/.claude/README.md"
CLAUDE_SETTINGS="${ROOT_DIR}/.claude/settings.json"
CLAUDE_LOCAL_SETTINGS="${ROOT_DIR}/.claude/settings.local.json"
CLAUDE_COMMAND_DIR="${ROOT_DIR}/.claude/commands"

INSTALL_JSON="${HOME}/.claude/plugins/installed_plugins.json"

PASS=0
FAIL=0
WARN=0

ok()   { printf '  ok    %s\n'   "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n'   "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  warn  %s\n'   "$1"; WARN=$((WARN+1)); }

resolve_codex_bin() {
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  local candidate
  for candidate in \
    /opt/homebrew/bin/codex \
    /usr/local/bin/codex \
    "${HOME}/.local/bin/codex" \
    "${HOME}/.npm-global/bin/codex" \
    "${HOME}/.bun/bin/codex"; do
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

expect_top_level_setting() {
  local key="$1"
  local expected="$2"
  local actual=""
  local count=""

  actual="$(awk -v key="${key}" '
    /^\[/ { exit }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print }
  ' "${CODEX_CONFIG}")"
  count="$(printf '%s\n' "${actual}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "${count}" = "1" ] && [ "${actual}" = "${expected}" ]; then
    ok "Codex top-level config has ${expected}"
  else
    bad "Codex top-level config for ${key} is not exactly ${expected}"
  fi
}

expect_section_setting() {
  local section="$1"
  local key="$2"
  local expected="$3"
  local actual=""
  local count=""

  actual="$(awk -v section="${section}" -v key="${key}" '
    $0 == section { in_section = 1; next }
    in_section && /^\[/ { exit }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print }
  ' "${CODEX_CONFIG}")"
  count="$(printf '%s\n' "${actual}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "${count}" = "1" ] && [ "${actual}" = "${expected}" ]; then
    ok "Codex config ${section} has ${expected}"
  else
    bad "Codex config ${section}.${key} is not exactly ${expected}"
  fi
}

read_state_value() {
  local key="$1"
  if [ -f "${CODEX_STATE_FILE}" ]; then
    sed -n "s/^${key}=//p" "${CODEX_STATE_FILE}" | tail -n1
  fi
}

json_string_value() {
  local key="$1"
  sed -n "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${AGENT_BOOTSTRAP_LOCK}" | head -n1
}

legacy_local_mcp_config_present() {
  awk '
    $0 == "# >>> tech-stack-expert (managed by setup-codex-project.sh) >>>" { found = 1 }
    $0 == "[mcp_servers.tech-stack-expert]" { found = 1 }
    $0 == "[mcp_servers.tech-stack-expert.tools.auto_recall]" { found = 1 }
    $0 == "[mcp_servers.tech-stack-expert.tools.store_working_context]" { found = 1 }
    $0 == "[mcp_servers.tech-stack-expert.tools.search_memory]" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${CODEX_CONFIG}"
}

expect_rejected() {
  local label="$1"
  shift
  local output=""
  if output="$(bash "${CODEX_MODE_HELPER}" "$@" 2>&1)"; then
    bad "codex-mode.sh allowed unsafe passthrough: ${label}"
  elif printf '%s' "${output}" | grep -Fq "not an approved codex-mode.sh passthrough option"; then
    ok "codex-mode.sh rejects ${label}"
  else
    bad "codex-mode.sh rejected ${label} for an unexpected reason: ${output}"
  fi
}

echo "Verifying AI tooling versions..."

# 1. rtk wrapper + version
if [ -x "${RTK_WRAPPER}" ]; then
  actual_rtk="$("${RTK_WRAPPER}" --version 2>/dev/null | awk '{print $2}')"
  if [ "${actual_rtk}" = "${EXPECTED_RTK}" ]; then
    ok "rtk wrapper ${actual_rtk}"
  else
    warn "rtk pinned binary is not installed; run: bash scripts/install-rtk.sh before using rtk-specific hooks"
  fi
else
  bad "missing executable ${RTK_WRAPPER}"
fi

if [ -f "${ROOT_DIR}/scripts/install-rtk.sh" ]; then
  ok "rtk installer exists"
else
  bad "missing scripts/install-rtk.sh"
fi

# 2. pinned rtk binary + stable link
if [ -x "${RTK_PINNED_BIN}" ]; then
  ok "pinned binary ${RTK_PINNED_BIN}"
else
  warn "missing pinned binary ${RTK_PINNED_BIN}"
fi

if [ -L "${RTK_LINK}" ]; then
  ok "stable link ${RTK_LINK}"
else
  warn "missing stable link ${RTK_LINK}"
fi

# 3. superpowers plugin version + commit SHA
if [ -f "${INSTALL_JSON}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    if EXPECTED_VER="${EXPECTED_SUPERPOWERS_VERSION}" \
       EXPECTED_SHA="${EXPECTED_SUPERPOWERS_SHA}" \
       INSTALL_JSON="${INSTALL_JSON}" \
       python3 -c '
import json, os, sys
path = os.environ["INSTALL_JSON"]
ver  = os.environ["EXPECTED_VER"]
sha  = os.environ["EXPECTED_SHA"]
with open(path) as f:
    data = json.load(f)
entries = data.get("plugins", {}).get("superpowers@superpowers-marketplace", [])
match = any(e.get("version") == ver and e.get("gitCommitSha") == sha for e in entries)
sys.exit(0 if match else 1)
' 2>/dev/null; then
      ok "superpowers ${EXPECTED_SUPERPOWERS_VERSION} @ ${EXPECTED_SUPERPOWERS_SHA:0:8}"
    else
      bad "superpowers version/SHA mismatch in ${INSTALL_JSON}"
    fi
  else
    bad "python3 not found; cannot parse ${INSTALL_JSON}"
  fi
else
  bad "${INSTALL_JSON} not found (install via /plugin install superpowers)"
fi

# 4. Codex CLI + managed mode gates
if CODEX_BIN="$(resolve_codex_bin)"; then
  codex_version="$("${CODEX_BIN}" --version 2>/dev/null | head -n1 || true)"
  ok "Codex CLI reachable (${CODEX_BIN}${codex_version:+, ${codex_version}})"
  if "${CODEX_BIN}" --help 2>/dev/null | grep -Fq -- "--no-alt-screen"; then
    ok "Codex CLI supports documented --no-alt-screen option"
  else
    bad "Codex CLI help does not list --no-alt-screen"
  fi
else
  bad "Codex CLI not found on PATH or known install paths"
fi

syntax_ok=true
for shell_script in \
  "${CODEX_MODE_HELPER}" \
  "${CODEX_SETUP_SCRIPT}" \
  "${ROOT_DIR}/scripts/install-rtk.sh" \
  "${RTK_WRAPPER}" \
  "${AGENT_HOOK}" \
  "${TECH_STACK_LIB}" \
  "${TECH_STACK_DETECTOR}" \
  "${MULTI_AGENT_BOOTSTRAP}" \
  "${BOOTSTRAP_HOME_INSTALLER}" \
  "${BOOTSTRAP_BUNDLE_ROOT}/bootstrap-multi-agent-project.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/install-agent-bootstrap-home.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/agent-hook.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/agent-tech-stack-lib.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/detect-agent-tech-stack.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/install-rtk.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/rtk" \
  "${BOOTSTRAP_BUNDLE_ROOT}/verify-ai-deps.sh" \
  "${BOOTSTRAP_INTEGRATION_TEST}"; do
  if ! bash -n "${shell_script}"; then
    syntax_ok=false
    bad "shell syntax failed: ${shell_script}"
  fi
done
if [ "${syntax_ok}" = true ]; then
  ok "Codex shell scripts pass bash -n"
fi

if bash "${CODEX_MODE_HELPER}" --help >/dev/null && bash "${CODEX_SETUP_SCRIPT}" --help >/dev/null; then
  ok "Codex helper/setup help works"
else
  bad "Codex helper/setup help failed"
fi

for required_file in \
  "${AGENT_BOOTSTRAP_LOCK}" \
  "${CODEX_MODE_CONTRACT}" \
  "${CODEX_HANDOFF_SCHEMA}" \
  "${CODEX_PROJECT_CONTEXT}" \
  "${ROOT_DIR}/docs/agent-configs/espl-android-agent-context.md" \
  "${ROOT_DIR}/docs/agent-configs/llm-council-agent-workflow.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/base/README.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/android_kotlin.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/python.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/ios_swift.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/node_js.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/overlays/generic.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/karpathy/README.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/council/README.md" \
  "${ROOT_DIR}/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md" \
  "${BOOTSTRAP_SOLO_README}" \
  "${BOOTSTRAP_BUNDLE_ROOT}/README.md" \
  "${BOOTSTRAP_BUNDLE_VERSION_FILE}" \
  "${BOOTSTRAP_BUNDLE_MANIFEST}" \
  "${BOOTSTRAP_BUNDLE_ROOT}/bootstrap-multi-agent-project.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/install-agent-bootstrap-home.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/agent-hook.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/agent-tech-stack-lib.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/detect-agent-tech-stack.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/install-rtk.sh" \
  "${BOOTSTRAP_BUNDLE_ROOT}/rtk" \
  "${BOOTSTRAP_BUNDLE_ROOT}/verify-ai-deps.sh" \
  "${MULTI_AGENT_BOOTSTRAP}" \
  "${BOOTSTRAP_HOME_INSTALLER}" \
  "${CLAUDE_INSTRUCTIONS}" \
  "${CLAUDE_README}" \
  "${CLAUDE_SETTINGS}" \
  "${ROOT_DIR}/.agents/skills/espl-brainstorm/SKILL.md" \
  "${ROOT_DIR}/.agents/skills/espl-code-implement/SKILL.md" \
  "${ROOT_DIR}/.agents/skills/agentmemory-mcp/SKILL.md" \
  "${ROOT_DIR}/.agents/skills/agentmemory-mcp/agents/openai.yaml"; do
  if [ -f "${required_file}" ]; then
    ok "required agent config exists: ${required_file#${ROOT_DIR}/}"
  else
    bad "missing required agent config: ${required_file#${ROOT_DIR}/}"
  fi
done

bootstrap_version_output="$("${MULTI_AGENT_BOOTSTRAP}" --version 2>/dev/null || true)"
if printf '%s' "${bootstrap_version_output}" | grep -Fq "bootstrap-multi-agent-project"; then
  ok "solo bootstrap reports version"
else
  bad "solo bootstrap version command failed"
fi

bundle_version="$(sed -n '1p' "${BOOTSTRAP_BUNDLE_VERSION_FILE}" 2>/dev/null || true)"
if [ -n "${bundle_version}" ] &&
   printf '%s' "${bootstrap_version_output}" | grep -Fq "${bundle_version}" &&
   grep -Fq "Version: \`${bundle_version}\`" "${BOOTSTRAP_BUNDLE_MANIFEST}" 2>/dev/null; then
  ok "agent-bootstrap VERSION and MANIFEST match bootstrap version"
else
  bad "agent-bootstrap VERSION/MANIFEST do not match bootstrap version"
fi

if grep -Fq "PAYLOAD_START" "${MULTI_AGENT_BOOTSTRAP}"; then
  bad "solo bootstrap unexpectedly contains embedded dist payload"
else
  ok "solo bootstrap is direct shell, not base64 dist"
fi

if grep -Fq "agent-init()" "${BOOTSTRAP_SOLO_README}" &&
   grep -Fq "AGENT_BOOTSTRAP_HOME" "${BOOTSTRAP_SOLO_README}"; then
  ok "solo workflow README documents canonical shell functions"
else
  bad "solo workflow README is missing canonical shell function docs"
fi

if "${BOOTSTRAP_HOME_INSTALLER}" --dry-run --no-git >/dev/null 2>&1; then
  ok "canonical home installer dry-run works"
else
  bad "canonical home installer dry-run failed"
fi

if grep -Fq 'agent-bootstrap/bootstrap-multi-agent-project.sh' "${MULTI_AGENT_BOOTSTRAP}" &&
   grep -Fq 'agent-bootstrap/install-agent-bootstrap-home.sh' "${BOOTSTRAP_HOME_INSTALLER}"; then
  ok "legacy bootstrap script entrypoints delegate to agent-bootstrap bundle"
else
  bad "legacy bootstrap script entrypoints do not delegate to agent-bootstrap bundle"
fi

if [ -d "${CLAUDE_COMMAND_DIR}" ]; then
  ok "Claude command directory exists"
else
  bad "missing Claude command directory"
fi

for claude_command in \
  planning.md \
  planning-full-flow.md \
  coding.md \
  coding-full-flow.md \
  reviewing.md \
  reviewing-full-flow.md \
  codex/setup.md \
  codex/rescue.md \
  codex/status.md \
  doctor.md; do
  command_path="${CLAUDE_COMMAND_DIR}/${claude_command}"
  if [ -f "${command_path}" ]; then
    ok "Claude command exists: .claude/commands/${claude_command}"
  else
    bad "missing Claude command: .claude/commands/${claude_command}"
  fi
done

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
    ok "Claude shared settings JSON is valid"
  else
    bad "Claude shared settings JSON is invalid"
  fi
else
  warn "python3 not found; cannot validate Claude settings JSON"
fi

for local_only_path in \
  .claude/settings.local.json \
  .claude/worktrees/ \
  .codex-mode-lock \
  .codex/.setup-codex-project.state \
  .codex/.setup-codex-project.bootstrap \
  .codex/environments/ \
  .tools/ \
  .gemini/ \
  .windsurf/ \
  .openclaude/ \
  .openclaude-profile.json \
  AGENTS.local.md \
  CLAUDE.local.md \
  GEMINI.local.md; do
  local_only_tracked_present=false
  if [ -x "${RTK_WRAPPER}" ]; then
    while IFS= read -r tracked_local_path; do
      [ -n "${tracked_local_path}" ] || continue
      if [ -e "${ROOT_DIR}/${tracked_local_path}" ]; then
        local_only_tracked_present=true
        break
      fi
    done <<EOF_LOCAL_ONLY_TRACKED
$("${RTK_WRAPPER}" git -C "${ROOT_DIR}" ls-files -- "${local_only_path}")
EOF_LOCAL_ONLY_TRACKED
  fi
  if [ "${local_only_tracked_present}" = true ]; then
    bad "${local_only_path} is tracked; it must remain local-only"
  else
    ok "${local_only_path} is not tracked"
  fi
done

if grep -Fq '.claude/commands' "${CLAUDE_INSTRUCTIONS}" &&
   grep -Fq 'agent-mode-contracts.md' "${CLAUDE_INSTRUCTIONS}" &&
   grep -Fq 'detect-agent-tech-stack.sh' "${CLAUDE_INSTRUCTIONS}"; then
  ok "CLAUDE.md references commands, mode contracts, and runtime detector"
else
  bad "CLAUDE.md is missing command/mode/detector references"
fi

if [ -x "${AGENT_HOOK}" ]; then
  ok "shared agent hook is executable"
else
  bad "shared agent hook is not executable"
fi

no_scan_paths="$("${AGENT_HOOK}" no-scan-paths 2>/dev/null || true)"
if printf '%s\n' "${no_scan_paths}" | grep -Fq '.claude/worktrees/' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq '.tools/' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq '.gemini/' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq '.windsurf/' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq '.openclaude/' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq 'AGENTS.local.md' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq 'local.properties' &&
   printf '%s\n' "${no_scan_paths}" | grep -Fq '*.jks'; then
  ok "shared agent hook exposes no-scan paths"
else
  bad "shared agent hook no-scan paths are incomplete"
fi

if [ -x "${TECH_STACK_LIB}" ]; then
  ok "shared tech-stack detection library is executable"
else
  bad "shared tech-stack detection library is not executable"
fi

if [ -x "${TECH_STACK_DETECTOR}" ]; then
  ok "runtime tech-stack detector is executable"
else
  bad "runtime tech-stack detector is not executable"
fi

if grep -Fq './scripts/agent-hook.sh claude-pretool' "${CLAUDE_SETTINGS}"; then
  ok "Claude PreToolUse uses shared agent hook"
else
  bad "Claude PreToolUse does not use shared agent hook"
fi

if grep -Fq 'codex-preflight' "${CODEX_MODE_HELPER}" &&
   grep -Fq 'AGENT_HOOK=' "${CODEX_MODE_HELPER}"; then
  ok "Codex helper calls shared hook preflight"
else
  bad "Codex helper does not call shared hook preflight"
fi

if awk '/^  cat > "\$MODE_HELPER_FILE" <<'\''MODE_HELPER_SCRIPT'\''$/ { capture = 1; next } /^MODE_HELPER_SCRIPT$/ { capture = 0 } capture { print }' "${CODEX_SETUP_SCRIPT}" | cmp -s - "${CODEX_MODE_HELPER}"; then
  ok "setup script embedded helper matches .codex/codex-mode.sh"
else
  bad "setup script embedded helper differs from .codex/codex-mode.sh"
fi

expect_top_level_setting "model" 'model = "gpt-5.5"'
expect_top_level_setting "model_reasoning_effort" 'model_reasoning_effort = "xhigh"'
expect_top_level_setting "approval_policy" 'approval_policy = "never"'
expect_top_level_setting "sandbox_mode" 'sandbox_mode = "workspace-write"'
expect_top_level_setting "approvals_reviewer" 'approvals_reviewer = "user"'
expect_top_level_setting "allow_login_shell" 'allow_login_shell = false'
expect_top_level_setting "web_search" 'web_search = "disabled"'
expect_section_setting "[shell_environment_policy]" "inherit" 'inherit = "none"'
expect_section_setting "[shell_environment_policy]" "include_only" 'include_only = ["PATH", "HOME", "PWD", "SHELL"]'
expect_section_setting "[shell_environment_policy]" "ignore_default_excludes" 'ignore_default_excludes = false'
expect_section_setting "[apps._default]" "destructive_enabled" 'destructive_enabled = false'
expect_section_setting "[apps._default]" "open_world_enabled" 'open_world_enabled = false'
expect_section_setting "[apps._default]" "default_tools_approval_mode" 'default_tools_approval_mode = "prompt"'

if detector_summary="$("${TECH_STACK_DETECTOR}" --summary 2>/dev/null)"; then
  if printf '%s\n' "${detector_summary}" | grep -Fq 'android_kotlin'; then
    ok "runtime detector identifies android_kotlin"
  else
    bad "runtime detector did not identify android_kotlin"
  fi
  if printf '%s\n' "${detector_summary}" | grep -Fq ':app' &&
     printf '%s\n' "${detector_summary}" | grep -Fq ':wear' &&
     printf '%s\n' "${detector_summary}" | grep -Fq ':health-core'; then
    ok "runtime detector identifies current Gradle modules"
  else
    bad "runtime detector missed expected Gradle modules"
  fi
  if printf '%s\n' "${detector_summary}" | grep -Fq 'tech_stack_lib_version='; then
    ok "runtime detector reports shared library version"
  else
    bad "runtime detector did not report shared library version"
  fi
  expected_detector_hash="$(json_string_value detector_summary_sha256)"
  actual_detector_hash="$(printf '%s' "${detector_summary}" | hash_string)"
  if [ -n "${expected_detector_hash}" ] && [ "${expected_detector_hash}" = "${actual_detector_hash}" ]; then
    ok "runtime detector summary matches bootstrap lock"
  else
    bad "runtime detector summary drifted from bootstrap lock"
  fi
else
  bad "runtime detector failed"
fi

if "${AGENT_HOOK}" codex-preflight coding full_flow >/dev/null 2>&1; then
  ok "shared agent hook codex preflight passes"
else
  bad "shared agent hook codex preflight failed"
fi

if bash "${CODEX_MODE_HELPER}" doctor >/dev/null; then
  ok "codex-mode.sh doctor passes"
else
  bad "codex-mode.sh doctor failed"
fi

if [[ ! -x "${BOOTSTRAP_INTEGRATION_TEST}" ]]; then
  warn "portable bootstrap integration smoke test missing"
elif [[ "${AGENT_BOOTSTRAP_SKIP_SMOKE:-}" == "1" ]]; then
  warn "portable bootstrap integration smoke test skipped to avoid recursion"
elif AGENT_BOOTSTRAP_SKIP_SMOKE=1 "${BOOTSTRAP_INTEGRATION_TEST}" >/dev/null; then
  ok "portable bootstrap integration smoke test passes"
else
  bad "portable bootstrap integration smoke test failed"
fi

if legacy_local_mcp_config_present; then
  bad "legacy local tech-stack-expert MCP config is still present in .codex/config.toml"
else
  ok "legacy local tech-stack-expert MCP config is absent"
fi

state_memory_provider="$(read_state_value MEMORY_PROVIDER)"
state_memory_skill="$(read_state_value MEMORY_SKILL)"
if [ -z "${state_memory_provider}" ] && [ ! -f "${CODEX_STATE_FILE}" ]; then
  warn "Codex setup state file is absent; run .codex/setup-codex-project.sh to record MEMORY_PROVIDER=agentmemory"
elif [ "${state_memory_provider}" = "agentmemory" ]; then
  ok "Codex setup state MEMORY_PROVIDER=agentmemory"
else
  warn "Codex setup state MEMORY_PROVIDER is stale or missing; run .codex/setup-codex-project.sh to refresh local state"
fi
if [ -z "${state_memory_skill}" ] && [ ! -f "${CODEX_STATE_FILE}" ]; then
  warn "Codex setup state file is absent; run .codex/setup-codex-project.sh to record MEMORY_SKILL=agentmemory-mcp"
elif [ "${state_memory_skill}" = "agentmemory-mcp" ]; then
  ok "Codex setup state MEMORY_SKILL=agentmemory-mcp"
else
  warn "Codex setup state MEMORY_SKILL is stale or missing; run .codex/setup-codex-project.sh to refresh local state"
fi

expect_rejected "--dangerously-bypass-approvals-and-sandbox" coding --dangerously-bypass-approvals-and-sandbox -- "prompt"
expect_rejected "--add-dir" coding --add-dir /tmp -- "prompt"
expect_rejected "--remote" planning --remote ws://127.0.0.1:1 -- "prompt"
expect_rejected "exec subcommand" coding exec -- "prompt"
expect_rejected "apply subcommand" coding apply -- "prompt"

echo
printf 'Pass: %d  Warn: %d  Fail: %d\n' "${PASS}" "${WARN}" "${FAIL}"
exit $(( FAIL > 0 ? 1 : 0 ))
