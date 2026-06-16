#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
COMMAND="status"
OUTPUT_JSON=false

usage() {
  cat <<'HELP'
Usage: scripts/agent-onboarding.sh [status|next|check] [--json] [--root DIR]

Compute the project onboarding readiness contract from generated onboarding
files. No state file is written; status is derived from project-brief.md and
project-tech-stack.json each time.

Commands:
  status   Print current readiness. Always succeeds unless the contract cannot be read.
  next     Print the next operator/agent actions.
  check    Enforce the onboarding gate. Succeeds only when status is filled.

Options:
  --json   Emit machine-readable status JSON.
  --root   Evaluate another project root.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    status|next|check)
      COMMAND="$1"
      shift
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --root)
      ROOT_DIR="$(cd "${2:?missing value for --root}" && pwd -P)"
      shift 2
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for onboarding contract checks." >&2
  exit 1
fi

STATUS_JSON="$(
  python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
brief_path = root / "docs/agent-configs/project-brief.md"
tech_md_path = root / "docs/superpowers/specs/project-tech-stack.md"
tech_json_path = root / "docs/superpowers/specs/project-tech-stack.json"

required_sections = [
    "What this project is",
    "Architecture overview",
    "Entry points / where to start reading",
    "Modules / packages and responsibilities",
    "Key domains and business rules",
    "Key invariants / things that must stay true",
    "Conventions (code style, patterns, naming)",
    "Protected / sensitive areas",
    "Build, test, and run commands",
    "Known gotchas and pitfalls",
    "Open questions",
]

tech_stack_sections = [
    "Stack summary",
    "Module / package map",
    "Architecture boundaries",
    "Generated files and ownership",
    "Protected paths and sensitive config",
    "Verification matrix",
    "Conventions agents must follow",
    "Open questions",
]


def relative(path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def non_empty_string(value):
    return isinstance(value, str) and value.strip() != ""


def safe_relative_path(value):
    if not non_empty_string(value):
        return False
    if value.startswith("./") or value.endswith("/") or "//" in value:
        return False
    if any(ch in value for ch in "*?["):
        return False
    path = pathlib.PurePosixPath(value)
    if path.is_absolute():
        return False
    if any(part in ("", ".", "..") for part in path.parts):
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    return True


def markdown_sections(text):
    sections = {}
    current = None
    lines = []
    for line in text.splitlines():
        match = re.match(r"^##\s+(.+?)\s*$", line)
        if match:
            if current is not None:
                sections[current] = "\n".join(lines).strip()
            current = match.group(1)
            lines = []
        elif current is not None:
            lines.append(line)
    if current is not None:
        sections[current] = "\n".join(lines).strip()
    return sections


def evaluate_markdown_contract(path, required_headings, label):
    missing = []
    warnings = []
    if not path.exists():
        return {
            "status": "missing",
            "path": relative(path),
            "missing": [f"{label} file"],
            "warnings": warnings,
        }
    text = path.read_text(encoding="utf-8")
    if "<!-- UNFILLED -->" in text:
        missing.append("remove UNFILLED marker")
    last_verified = ""
    for line in text.splitlines():
        if line.startswith("Last verified:"):
            last_verified = line.split(":", 1)[1].strip()
            break
    if not last_verified or "<commit-sha>" in last_verified or "<date>" in last_verified:
        missing.append("set Last verified to commit/date")
    sections = markdown_sections(text)
    empty_sections = []
    for heading in required_headings:
        value = sections.get(heading, "").strip()
        if not value:
            empty_sections.append(heading)
    if empty_sections:
        missing.append("fill required sections: " + ", ".join(empty_sections))
    if missing:
        status = "unfilled" if "<!-- UNFILLED -->" in text else "partial"
    else:
        status = "filled"
    return {
        "status": status,
        "path": relative(path),
        "last_verified": last_verified,
        "missing": missing,
        "warnings": warnings,
    }


def evaluate_brief():
    return evaluate_markdown_contract(brief_path, required_sections, "project brief")


def evaluate_tech_stack():
    missing = []
    warnings = []
    markdown = evaluate_markdown_contract(tech_md_path, tech_stack_sections, "project tech-stack markdown")
    missing.extend(f"project-tech-stack.md: {item}" for item in markdown.get("missing", []))
    warnings.extend(markdown.get("warnings", []))
    if not tech_json_path.exists():
        return {
            "status": "missing",
            "path": relative(tech_json_path),
            "missing": ["project tech-stack JSON file"],
            "warnings": warnings,
            "markdown": markdown,
        }
    try:
        doc = json.loads(tech_json_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "status": "invalid",
            "path": relative(tech_json_path),
            "missing": [f"valid JSON: {exc}"],
            "warnings": warnings,
            "markdown": markdown,
        }
    if not isinstance(doc, dict):
        return {
            "status": "invalid",
            "path": relative(tech_json_path),
            "missing": ["top-level JSON object"],
            "warnings": warnings,
            "markdown": markdown,
        }
    if doc.get("schema") != "agent-project-tech-stack/v1":
        missing.append("schema agent-project-tech-stack/v1")
    declared_status = doc.get("status")
    if declared_status not in ("unfilled", "partial", "filled"):
        missing.append("status unfilled/partial/filled")
    last_verified = doc.get("last_verified")
    if not isinstance(last_verified, dict):
        missing.append("last_verified object")
        last_verified = {}
    if not non_empty_string(last_verified.get("commit")):
        missing.append("last_verified.commit")
    if not non_empty_string(last_verified.get("date")):
        missing.append("last_verified.date")
    verification = doc.get("verification")
    if not isinstance(verification, list) or not verification:
        missing.append("at least one verification entry")
    if isinstance(verification, list):
        for index, item in enumerate(verification):
            if not isinstance(item, dict):
                missing.append(f"verification[{index}] object")
                continue
            for key in ("command", "purpose", "source"):
                if not non_empty_string(item.get(key)):
                    missing.append(f"verification[{index}].{key}")
    source_evidence = doc.get("source_evidence")
    if not isinstance(source_evidence, list) or not source_evidence:
        missing.append("at least one source_evidence entry")
    if isinstance(source_evidence, list):
        for index, item in enumerate(source_evidence):
            if not isinstance(item, dict):
                missing.append(f"source_evidence[{index}] object")
                continue
            evidence_path = item.get("path")
            claim = item.get("claim")
            if not non_empty_string(evidence_path):
                missing.append(f"source_evidence[{index}].path")
            elif not safe_relative_path(evidence_path):
                missing.append(f"source_evidence[{index}].path must be a safe project-relative file path")
            elif not (root / evidence_path).is_file():
                missing.append(f"source_evidence[{index}].path must reference an existing file: {evidence_path}")
            if not non_empty_string(claim):
                missing.append(f"source_evidence[{index}].claim")
    if declared_status == "unfilled":
        status = "unfilled"
    elif declared_status == "filled" and not missing:
        status = "filled"
    elif declared_status in ("partial", "filled") or missing:
        status = "partial"
    else:
        status = "invalid"
    return {
        "status": status,
        "declared_status": declared_status or "",
        "path": relative(tech_json_path),
        "missing": missing,
        "warnings": warnings,
        "markdown": markdown,
        "source_evidence_count": len(source_evidence) if isinstance(source_evidence, list) else 0,
        "verification_count": len(verification) if isinstance(verification, list) else 0,
        "open_questions_count": len(doc.get("open_questions")) if isinstance(doc.get("open_questions"), list) else 0,
    }


brief = evaluate_brief()
tech_stack = evaluate_tech_stack()
missing = []
warnings = []
for area in (brief, tech_stack):
    missing.extend(area.get("missing", []))
    warnings.extend(area.get("warnings", []))

if brief["status"] == "filled" and tech_stack["status"] == "filled":
    status = "filled"
elif brief["status"] in ("missing",) or tech_stack["status"] in ("missing", "invalid"):
    status = "invalid"
elif brief["status"] == "unfilled" and tech_stack["status"] == "unfilled":
    status = "unfilled"
else:
    status = "partial"

next_actions = []
if status in ("invalid", "unfilled", "partial"):
    next_actions.extend([
        "Run /project-onboarding in an agent session, or follow docs/agent-configs/project-onboarding.md.",
        "Refresh detector facts with scripts/detect-agent-tech-stack.sh --markdown.",
        "Fill docs/agent-configs/project-brief.md and remove the UNFILLED marker.",
        "Fill docs/superpowers/specs/project-tech-stack.md and project-tech-stack.json with source-backed evidence.",
        "Re-run scripts/agent-onboarding.sh check, then scripts/verify-ai-deps.sh.",
    ])
else:
    next_actions.extend([
        "Run scripts/verify-ai-deps.sh before substantive work.",
        "Keep project-brief.md and project-tech-stack.json current when architecture or conventions change.",
    ])

report = {
    "schema": "agent-onboarding-status/v1",
    "root": str(root),
    "status": status,
    "brief": brief,
    "tech_stack": tech_stack,
    "missing": missing,
    "warnings": warnings,
    "next_actions": next_actions,
}
print(json.dumps(report, indent=2, sort_keys=True))
PY
)"

json_value() {
  STATUS_JSON_DATA="$STATUS_JSON" python3 - "$1" <<'PY'
import json
import os
import sys

doc = json.loads(os.environ["STATUS_JSON_DATA"])
value = doc
for part in sys.argv[1].split("."):
    value = value.get(part, "") if isinstance(value, dict) else ""
print(value if isinstance(value, str) else json.dumps(value))
PY
}

print_human_status() {
  local status brief tech
  status="$(json_value status)"
  brief="$(json_value brief.status)"
  tech="$(json_value tech_stack.status)"
  printf 'Onboarding status: %s\n' "$status"
  printf 'Brief: %s\n' "$brief"
  printf 'Tech stack contract: %s\n' "$tech"
  STATUS_JSON_DATA="$STATUS_JSON" python3 - <<'PY'
import json
import os
import sys

doc = json.loads(os.environ["STATUS_JSON_DATA"])
for label, key in (("Missing", "missing"), ("Warnings", "warnings")):
    values = doc.get(key) or []
    if not values:
        continue
    print(f"{label}:")
    for value in values:
        print(f"  - {value}")
PY
}

print_next_actions() {
  STATUS_JSON_DATA="$STATUS_JSON" python3 - <<'PY'
import json
import os
import sys

doc = json.loads(os.environ["STATUS_JSON_DATA"])
print(f"Onboarding status: {doc.get('status')}")
print("Next actions:")
for index, action in enumerate(doc.get("next_actions") or [], start=1):
    print(f"  {index}. {action}")
PY
}

case "$COMMAND" in
  status)
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      printf '%s\n' "$STATUS_JSON"
    else
      print_human_status
    fi
    ;;
  next)
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      printf '%s\n' "$STATUS_JSON"
    else
      print_next_actions
    fi
    ;;
  check)
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      printf '%s\n' "$STATUS_JSON"
    fi
    if [[ "$(json_value status)" == "filled" ]]; then
      [[ "$OUTPUT_JSON" == "true" ]] || print_human_status
      exit 0
    fi
    [[ "$OUTPUT_JSON" == "true" ]] || print_next_actions
    exit 3
    ;;
esac
