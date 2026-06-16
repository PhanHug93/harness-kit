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
  echo "ERROR: missing tech-stack detection library: ${LIB#"$ROOT"/}" >&2
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
