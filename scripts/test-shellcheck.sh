#!/usr/bin/env bash
set -euo pipefail

# Shellcheck for the kit sources and a generated full target, plus the
# generated verifier (plain and --json). CI (CI=true) requires shellcheck;
# locally a missing shellcheck is a skip, reported as such.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v shellcheck >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then
    echo "shellcheck: FAIL: shellcheck is not installed" >&2
    exit 1
  fi
  echo "shellcheck: skipped (not installed; CI runs it)"
  exit 0
fi
cd "$ROOT_DIR"
exclude=SC1090,SC1091,SC2034,SC2154
shellcheck --external-sources --exclude="$exclude" \
  scripts/bootstrap-multi-agent-project.sh \
  scripts/install-agent-bootstrap-home.sh \
  scripts/test-bootstrap-multi-agent-project.sh \
  scripts/test-onboarding-fixtures.sh \
  scripts/test-one-shot-upgrade.sh \
  scripts/test-verification-evidence.sh \
  scripts/test-harness-kit-entry.sh \
  scripts/test-harness-migrations.sh \
  scripts/test-harness-kit-staging.sh \
  scripts/test-harness-kit-oneshot.sh \
  scripts/test-change-tiers.sh \
  scripts/test.sh \
  scripts/test-fast.sh \
  scripts/test-runner-selftest.sh \
  scripts/test-pipe-safety.sh \
  scripts/test-hook-hot-path.sh \
  scripts/test-historical-fixtures.sh \
  scripts/test-seats-no-path.sh \
  scripts/test-shellcheck.sh \
  scripts/ci-gate.sh \
  scripts/test-ci-gate.sh \
  agent-bootstrap/bootstrap-multi-agent-project.sh \
  agent-bootstrap/harness-kit-one-shot.sh \
  agent-bootstrap/harness-kit-one-shot-upgrade.sh \
  agent-bootstrap/harness-kit-run.sh \
  agent-bootstrap/agent-bootstrap-update.sh \
  agent-bootstrap/install-agent-bootstrap-home.sh \
  agent-bootstrap/agent-hook.sh \
  agent-bootstrap/agent-guard.sh \
  agent-bootstrap/agent-seats.sh \
  agent-bootstrap/verify-ai-deps.sh \
  agent-bootstrap/lib/*.sh
shellcheck --shell=bash --exclude="$exclude" agent-bootstrap/migrations/*.sh
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash scripts/bootstrap-multi-agent-project.sh --target "$work" --workflow full >/dev/null
shellcheck --external-sources --exclude="$exclude" "$work"/scripts/*.sh "$work"/.codex/codex-mode.sh
(cd "$work" && scripts/verify-ai-deps.sh >/dev/null)
(cd "$work" && scripts/verify-ai-deps.sh --json) | python3 -m json.tool >/dev/null
echo "shellcheck: ok"
