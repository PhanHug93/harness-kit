#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "onboarding-fixtures: FAIL: $*" >&2
  exit 1
}

need_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$label missing '$needle'"
  fi
}

need_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$label unexpectedly contained '$needle'"
  fi
}

make_android_fixture() {
  local dir="$1"
  mkdir -p "$dir/app/src/main"
  cat > "$dir/settings.gradle.kts" <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = "fixture-android"
include(":app")
EOF
  cat > "$dir/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
EOF
  cat > "$dir/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
EOF
}

make_python_fixture() {
  local dir="$1"
  mkdir -p "$dir/src/fixture_api"
  cat > "$dir/pyproject.toml" <<'EOF'
[project]
name = "fixture-api"
version = "0.1.0"
dependencies = ["fastapi"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
  printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$dir/src/fixture_api/main.py"
}

make_node_tooling_fixture() {
  local dir="$1"
  cat > "$dir/package.json" <<'EOF'
{
  "private": true,
  "devDependencies": {
    "prettier": "3.3.3"
  }
}
EOF
}

evaluate_common_onboarding() {
  local dir="$1"
  local onboarding
  local specs_readme
  local tech_md
  local tech_json
  local first_10
  local agents

  onboarding="$(cat "$dir/docs/agent-configs/project-onboarding.md")"
  first_10="$(cat "$dir/docs/agent-configs/first-10-minutes.md")"
  specs_readme="$(cat "$dir/docs/superpowers/specs/README.md")"
  tech_md="$(cat "$dir/docs/superpowers/specs/project-tech-stack.md")"
  tech_json="$(cat "$dir/docs/superpowers/specs/project-tech-stack.json")"
  agents="$(cat "$dir/AGENTS.md")"

  need_contains "$onboarding" "scripts/detect-agent-tech-stack.sh --markdown" "onboarding detector instruction"
  need_contains "$onboarding" "project-agent-context.md" "onboarding project-agent-context target"
  need_contains "$onboarding" "project-brief.md" "onboarding project brief target"
  need_contains "$onboarding" "project-tech-stack.md" "onboarding project tech-stack markdown target"
  need_contains "$onboarding" "project-tech-stack.json" "onboarding project tech-stack JSON target"
  need_contains "$onboarding" "scripts/agent-onboarding.sh check" "onboarding readiness check"
  need_contains "$onboarding" "Do NOT invent facts" "onboarding no-invention guard"
  need_contains "$onboarding" "Open Questions" "onboarding uncertainty sink"
  need_contains "$first_10" "scripts/agent-onboarding.sh next" "first 10 onboarding next"
  need_contains "$first_10" "scripts/agent-onboarding.sh check" "first 10 onboarding check"
  need_contains "$specs_readme" "source-backed" "specs source-backed instruction"
  need_contains "$tech_md" "<!-- UNFILLED -->" "project tech-stack markdown starts unfilled"
  need_contains "$tech_json" '"schema": "agent-project-tech-stack/v1"' "project tech-stack JSON schema"
  need_contains "$tech_json" '"status": "unfilled"' "project tech-stack JSON starts unfilled"
  need_contains "$tech_json" '"source_evidence": []' "project tech-stack evidence starts empty"
  need_contains "$agents" "Read on demand" "startup progressive disclosure"
  need_contains "$agents" "roughly 4k estimated tokens" "startup budget text matches verifier budget"
  local task_journal; task_journal="$(cat "$dir/docs/agent-configs/task-journal.md")"
  need_contains "$task_journal" "## <ISO-8601 date> · <mode> · <task-id>" "task journal doc schema header"
  need_contains "$task_journal" "status: in-progress | decided | blocked | done" "task journal doc status enum"
  need_contains "$task_journal" "append to docs/superpowers/plans/<topic>/journal.md" "task journal doc names concrete journal file"
  need_contains "$task_journal" "newest" "task journal doc resume/discovery rule"
  local mode_contracts; mode_contracts="$(cat "$dir/docs/agent-configs/agent-mode-contracts.md")"
  need_contains "$mode_contracts" "task-journal.md" "mode contracts reference the journal close-out"
  need_contains "$mode_contracts" "append to docs/superpowers/plans/<topic>/journal.md" "mode contracts name concrete journal file"
  local council_doc; council_doc="$(cat "$dir/docs/agent-configs/llm-council-agent-workflow.md")"
  need_contains "$council_doc" "task-journal.md" "council doc has journal close-out"
  need_contains "$council_doc" "append to docs/superpowers/plans/<topic>/journal.md" "council doc names concrete journal file"
  need_contains "$(cat "$dir/.claude/commands/council.md" 2>/dev/null)" "llm-council-agent-workflow.md" "council command points to the doc"
  local karpathy_doc; karpathy_doc="$(cat "$dir/docs/agent-configs/karpathy-llm-coding-agent-config.md")"
  need_contains "$karpathy_doc" "task-journal.md" "karpathy doc has journal close-out"
  need_contains "$karpathy_doc" "append to docs/superpowers/plans/<topic>/journal.md" "karpathy doc names concrete journal file"
  need_contains "$(cat "$dir/.claude/commands/karpathy.md" 2>/dev/null)" "karpathy-llm-coding-agent-config.md" "karpathy command points to the doc"
  need_contains "$(cat "$dir/.claude/commands/planning.md" 2>/dev/null)" "append to docs/superpowers/plans/<topic>/journal.md" "planning command names concrete journal file"
  need_contains "$(cat "$dir/.claude/commands/coding.md" 2>/dev/null)" "append to docs/superpowers/plans/<topic>/journal.md" "coding command names concrete journal file"
  need_contains "$(cat "$dir/.claude/commands/reviewing.md" 2>/dev/null)" "append to docs/superpowers/plans/<topic>/journal.md" "reviewing command names concrete journal file"
  need_contains "$agents" "task-journal.md" "AGENTS.md references the task journal"
  local codex_mode; codex_mode="$(cat "$dir/.codex/codex-mode.sh")"
  need_contains "$codex_mode" "task-journal.md" "codex seeds reference the journal"
  need_contains "$codex_mode" "append to docs/superpowers/plans/<topic>/journal.md" "codex seeds name concrete journal file"
  need_contains "$codex_mode" "docs/agent-configs/task-journal.md" "codex doctor lists the journal doc"
  need_contains "$(cat "$dir/scripts/agent-guard.sh" 2>/dev/null)" "docs/superpowers/plans/*/journal.md" "pre-final advises on the journal"
  need_contains "$(cat "$dir/docs/superpowers/plans/README.md" 2>/dev/null)" "journal.md" "plans README documents the journal"
  need_not_contains "$agents" "agents must read and apply:" "startup must not force heavy workflow docs"
  [[ -x "$dir/scripts/agent-onboarding.sh" ]] || fail "missing executable onboarding helper"
  if command -v python3 >/dev/null 2>&1; then
    (cd "$dir" && scripts/agent-onboarding.sh status --json | python3 -m json.tool >/dev/null) ||
      fail "fresh onboarding status JSON is invalid"
    need_contains "$(cd "$dir" && scripts/agent-onboarding.sh status --json)" '"status": "unfilled"' "fresh onboarding status"
  fi
  if (cd "$dir" && scripts/agent-onboarding.sh check >/dev/null 2>&1); then
    fail "fresh onboarding strict check unexpectedly passed"
  fi
}

write_filled_project_brief() {
  local dir="$1"
  local name="$2"
  cat > "$dir/docs/agent-configs/project-brief.md" <<EOF
# Project Brief

Last verified: fixture / 2026-06-16

> Deep, durable project context for agents. Filled by the onboarding fixture
> using source files from the ${name} project.

## What this project is

${name} fixture used to verify source-backed onboarding contracts.

## Architecture overview

The fixture keeps a minimal project shape so detector and onboarding behavior
can be verified deterministically.

## Entry points / where to start reading

Start with the files listed in project-tech-stack.json source_evidence.

## Modules / packages and responsibilities

The fixture module list is captured in project-tech-stack.json.

## Key domains and business rules

No business domain is modeled; this is a harness validation fixture.

## Key invariants / things that must stay true

Onboarding facts must cite existing project files and avoid invented commands.

## Conventions (code style, patterns, naming)

Prefer existing fixture files and keep generated harness files separate from
project-owned source.

## Protected / sensitive areas

Generated harness files and local-only state remain protected by Agent Guard.

## Build, test, and run commands

Use the verification matrix in project-tech-stack.json.

## Known gotchas and pitfalls

Do not treat tooling-only package manifests as production stack evidence.

## Open questions

No unresolved fixture questions.
EOF
}

write_filled_project_tech_stack_markdown() {
  local dir="$1"
  local name="$2"
  cat > "$dir/docs/superpowers/specs/project-tech-stack.md" <<EOF
# Project Tech Stack Spec

Last verified: fixture / 2026-06-16

## Stack summary

${name} fixture stack facts are captured in the paired JSON contract.

## Module / package map

Module and package evidence is listed in project-tech-stack.json.

## Architecture boundaries

Architecture boundaries are source-backed by the fixture files cited in
project-tech-stack.json.

## Generated files and ownership

Bootstrap-generated files stay under docs/agent-configs, scripts, .codex,
.claude, and .agents paths.

## Protected paths and sensitive config

Protected paths are represented in project-tech-stack.json and Agent Guard
policy.

## Verification matrix

Verification commands are listed with purpose and source in
project-tech-stack.json.

## Conventions agents must follow

Do not invent commands, modules, or production stacks that are not evidenced by
fixture files.

## Open questions

No unresolved fixture questions.
EOF
}

write_filled_project_tech_stack_contract() {
  local dir="$1"
  local name="$2"
  local contract="$dir/docs/superpowers/specs/project-tech-stack.json"

  case "$name" in
    android)
      cat > "$contract" <<'EOF'
{
  "schema": "agent-project-tech-stack/v1",
  "status": "filled",
  "last_verified": {
    "commit": "fixture",
    "date": "2026-06-14"
  },
  "stacks": ["android_kotlin"],
  "modules": [":app"],
  "architecture_boundaries": ["Gradle app module owns Android application entrypoints."],
  "generated_files": ["docs/agent-configs/bootstrap-multi-agent-project/templates/**"],
  "protected_paths": ["app/src/main/AndroidManifest.xml"],
  "verification": [
    {
      "command": "./gradlew test",
      "purpose": "Run JVM/unit tests detected from Android Gradle project shape.",
      "source": "scripts/detect-agent-tech-stack.sh --summary"
    },
    {
      "command": "./gradlew assembleDebug",
      "purpose": "Build debug Android artifact detected from Android Gradle project shape.",
      "source": "scripts/detect-agent-tech-stack.sh --summary"
    }
  ],
  "conventions": ["Confirm actual Gradle tasks before claiming build proof."],
  "source_evidence": [
    {
      "path": "settings.gradle.kts",
      "claim": "Declares :app module."
    },
    {
      "path": "build.gradle.kts",
      "claim": "Declares Android/Kotlin Gradle plugins."
    },
    {
      "path": "app/src/main/AndroidManifest.xml",
      "claim": "Confirms Android application surface."
    }
  ],
  "open_questions": ["Actual shared schemes/flavors/build variants require project inspection."]
}
EOF
      ;;
    python-fastapi)
      cat > "$contract" <<'EOF'
{
  "schema": "agent-project-tech-stack/v1",
  "status": "filled",
  "last_verified": {
    "commit": "fixture",
    "date": "2026-06-14"
  },
  "stacks": ["python_fastapi"],
  "modules": ["src/fixture_api"],
  "architecture_boundaries": ["src/fixture_api owns FastAPI app construction."],
  "generated_files": ["docs/agent-configs/bootstrap-multi-agent-project/templates/**"],
  "protected_paths": [],
  "verification": [
    {
      "command": "python -m pytest",
      "purpose": "Run Python tests detected from pyproject/requirements project shape.",
      "source": "scripts/detect-agent-tech-stack.sh --summary"
    },
    {
      "command": "ruff check .",
      "purpose": "Run Python lint detected from Python project shape.",
      "source": "scripts/detect-agent-tech-stack.sh --summary"
    }
  ],
  "conventions": ["Prefer existing package layout before introducing new structure."],
  "source_evidence": [
    {
      "path": "pyproject.toml",
      "claim": "Declares Python package metadata and FastAPI dependency."
    },
    {
      "path": "src/fixture_api/main.py",
      "claim": "Defines FastAPI application entrypoint."
    }
  ],
  "open_questions": ["Actual dependency manager and lockfile policy require project inspection."]
}
EOF
      ;;
    node-tooling)
      cat > "$contract" <<'EOF'
{
  "schema": "agent-project-tech-stack/v1",
  "status": "filled",
  "last_verified": {
    "commit": "fixture",
    "date": "2026-06-14"
  },
  "stacks": [],
  "modules": [],
  "architecture_boundaries": ["package.json is local tooling only until production Node/Web signals are found."],
  "generated_files": ["docs/agent-configs/bootstrap-multi-agent-project/templates/**"],
  "protected_paths": [],
  "verification": [
    {
      "command": "manual: inspect package.json scripts before inventing npm commands",
      "purpose": "Prevent treating tooling-only package.json as a production Node/Web stack.",
      "source": "scripts/detect-agent-tech-stack.sh --summary"
    }
  ],
  "conventions": ["Do not add npm test/lint/build assumptions without scripts evidence."],
  "source_evidence": [
    {
      "path": "package.json",
      "claim": "Contains devDependencies only and lacks production Node/Web signals."
    }
  ],
  "open_questions": ["Whether tooling should be managed by npm, pnpm, yarn, or another package manager is not established."]
}
EOF
      ;;
    *)
      fail "unknown filled contract fixture: $name"
      ;;
  esac
}

copy_fixture_for_negative_case() {
  local source_dir="$1"
  local case_name="$2"
  local dest="$TMP_ROOT/${case_name}"
  rm -rf "$dest"
  cp -R "$source_dir" "$dest"
  printf '%s' "$dest"
}

expect_onboarding_check_rejects() {
  local dir="$1"
  local label="$2"
  local status_json
  if (cd "$dir" && scripts/agent-onboarding.sh check >/dev/null 2>&1); then
    fail "$label onboarding strict check unexpectedly passed"
  fi
  if command -v python3 >/dev/null 2>&1; then
    status_json="$(cd "$dir" && scripts/agent-onboarding.sh status --json)"
    if printf '%s' "$status_json" |
      python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("status") == "filled" else 1)'; then
      fail "$label onboarding status stayed filled after semantic contract break"
    fi
  fi
}

evaluate_adversarial_contract_cases() {
  local dir="$1"
  local name="$2"
  local case_dir

  case_dir="$(copy_fixture_for_negative_case "$dir" "$name-missing-evidence-path")"
  python3 - "$case_dir/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["source_evidence"][0]["path"] = "does/not/exist.txt"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  expect_onboarding_check_rejects "$case_dir" "$name missing evidence path"

  case_dir="$(copy_fixture_for_negative_case "$dir" "$name-unsafe-evidence-path")"
  python3 - "$case_dir/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["source_evidence"][0]["path"] = "../outside.txt"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  expect_onboarding_check_rejects "$case_dir" "$name unsafe evidence path"

  case_dir="$(copy_fixture_for_negative_case "$dir" "$name-empty-verification")"
  python3 - "$case_dir/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["verification"][0] = {"command": "", "purpose": "", "source": ""}
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  expect_onboarding_check_rejects "$case_dir" "$name empty verification fields"

  case_dir="$(copy_fixture_for_negative_case "$dir" "$name-empty-evidence-claim")"
  python3 - "$case_dir/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["source_evidence"][0]["claim"] = ""
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  expect_onboarding_check_rejects "$case_dir" "$name empty evidence claim"

  case_dir="$(copy_fixture_for_negative_case "$dir" "$name-unfilled-tech-md")"
  printf '<!-- UNFILLED -->\n' >> "$case_dir/docs/superpowers/specs/project-tech-stack.md"
  expect_onboarding_check_rejects "$case_dir" "$name unfilled tech-stack markdown"
}

evaluate_filled_contract() {
  local dir="$1"
  local name="$2"
  local contract
  local onboarding_status
  contract="$(cat "$dir/docs/superpowers/specs/project-tech-stack.json")"
  need_contains "$contract" '"status": "filled"' "$name filled contract status"
  need_contains "$contract" '"source_evidence": [' "$name filled contract source evidence"
  need_not_contains "$contract" '"source_evidence": []' "$name filled contract must not have empty source evidence"
  if command -v python3 >/dev/null 2>&1; then
    onboarding_status="$(cd "$dir" && scripts/agent-onboarding.sh status --json)"
    need_contains "$onboarding_status" '"status": "filled"' "$name onboarding status"
    (cd "$dir" && scripts/agent-onboarding.sh check >/dev/null) ||
      fail "$name onboarding strict check rejected filled contract"
    (cd "$dir" && scripts/verify-ai-deps.sh --json | python3 -m json.tool >/dev/null) ||
      fail "$name verifier rejected filled project tech-stack contract"
    evaluate_adversarial_contract_cases "$dir" "$name"
  fi
}

evaluate_fixture() {
  local name="$1"
  local expected="$2"
  local unexpected="$3"
  local dir="$TMP_ROOT/$name"
  local summary
  mkdir -p "$dir"

  case "$name" in
    android) make_android_fixture "$dir" ;;
    python-fastapi) make_python_fixture "$dir" ;;
    node-tooling) make_node_tooling_fixture "$dir" ;;
    *) fail "unknown fixture: $name" ;;
  esac

  bash "$BOOTSTRAP" --target "$dir" --workflow full > "$TMP_ROOT/$name.bootstrap.out"
  evaluate_common_onboarding "$dir"
  summary="$(cd "$dir" && scripts/detect-agent-tech-stack.sh --summary)"
  need_contains "$summary" "$expected" "$name detector expected signal"
  if [[ -n "$unexpected" ]]; then
    need_not_contains "$summary" "$unexpected" "$name detector excluded signal"
  fi
  if command -v python3 >/dev/null 2>&1; then
    (cd "$dir" && scripts/verify-ai-deps.sh --json | python3 -m json.tool >/dev/null) ||
      fail "$name verifier JSON is invalid or failing"
  fi
  write_filled_project_tech_stack_contract "$dir" "$name"
  write_filled_project_brief "$dir" "$name"
  write_filled_project_tech_stack_markdown "$dir" "$name"
  evaluate_filled_contract "$dir" "$name"
}

evaluate_fixture android "tech_stacks=android_kotlin" ""
evaluate_fixture python-fastapi "tech_stacks=python_fastapi" ""
evaluate_fixture node-tooling "lacks production Node/Web signals" "node_js"

printf 'filled golden contracts: 3\n'
printf 'onboarding-fixtures: ok (%s)\n' "$TMP_ROOT"
