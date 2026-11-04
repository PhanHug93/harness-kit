#!/usr/bin/env bash
# agent-bootstrap/lib/detect.sh
# Sourced by bootstrap-multi-agent-project.sh. Tech-stack detection.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

emit_tech_stack_lib() {
  # agent-bootstrap/agent-tech-stack-lib.sh is the source of truth: the
  # generator sources it for detection and writes it into every target.
  cat "$BUNDLE_DIR/agent-tech-stack-lib.sh"
}

load_embedded_tech_stack_lib() {
  local tmp_lib
  tmp_lib="$(mktemp)"
  emit_tech_stack_lib > "$tmp_lib"
  # shellcheck source=/dev/null
  source "$tmp_lib"
  rm -f "$tmp_lib"
}

detect_tech_stack() {
  load_embedded_tech_stack_lib
  agent_detect_tech_stack "${DETECT_ROOT:-$TARGET_DIR}"
  TECH_STACKS=()
  MODULES=()
  VERIFY_COMMANDS=()
  WARNINGS=()
  if [[ ${#AGENT_TECH_STACKS[@]} -gt 0 ]]; then
    TECH_STACKS=("${AGENT_TECH_STACKS[@]}")
  fi
  if [[ ${#AGENT_MODULES[@]} -gt 0 ]]; then
    MODULES=("${AGENT_MODULES[@]}")
  fi
  if [[ ${#AGENT_VERIFY_COMMANDS[@]} -gt 0 ]]; then
    VERIFY_COMMANDS=("${AGENT_VERIFY_COMMANDS[@]}")
  fi
  if [[ ${#AGENT_WARNINGS[@]} -gt 0 ]]; then
    WARNINGS=("${AGENT_WARNINGS[@]}")
  fi
}

detector_summary_for_lock() {
  printf 'tech_stack_lib_version=%s\n' "${AGENT_TECH_STACK_LIB_VERSION:-unknown}"
  printf 'tech_stacks=%s\n' "${TECH_STACKS[*]}"
  printf 'modules=%s\n' "${MODULES[*]}"
  printf 'verification_commands=%s\n' "${VERIFY_COMMANDS[*]}"
  printf 'warnings=%s\n' "${WARNINGS[*]:-}"
}
