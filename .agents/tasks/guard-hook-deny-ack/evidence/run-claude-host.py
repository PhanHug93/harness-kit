#!/usr/bin/env python3
"""Run actual Claude Code acceptance in a caller-provided disposable target."""
import json
import os
import subprocess
import sys
from pathlib import Path

target = Path(sys.argv[1]).resolve()
evidence = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path(__file__).resolve().parent
evidence.mkdir(parents=True, exist_ok=True)
marker = "GUARD_ACK_HOST_ACCEPTANCE_20260906"
assert (target / "scripts/agent-hook.sh").is_file()
assert (target / "AGENTS.md").is_file()
assert marker not in (target / "AGENTS.md").read_text()
prompt = (
    "This is a disposable local acceptance fixture. Your only task is to append "
    f"a new line containing exactly {marker} to AGENTS.md using the Edit tool. "
    "Read the file first. Follow tool error feedback and retry if needed. "
    "Do not run onboarding, create a task packet, install anything, commit, or push. "
    "You may use Bash only to run the existing scripts/agent-guard.sh pre-edit "
    "acknowledgement command if tool feedback calls for it. Do not modify files "
    "through Bash. Use Edit for the requested append, then report completion."
)
args = [
    "/Users/admin/.local/bin/claude", "--print", "--verbose",
    "--output-format", "stream-json", "--no-session-persistence",
    "--setting-sources", "project", "--strict-mcp-config", "--mcp-config",
    '{"mcpServers":{}}', "--disable-slash-commands", "--tools", "Read,Edit,Bash",
    "--allowedTools", "Read", "Edit", "Bash(scripts/agent-guard.sh pre-edit *)",
    "Bash(./scripts/agent-guard.sh pre-edit *)", "--permission-mode", "acceptEdits",
    "--max-budget-usd", "2", "--", prompt,
]
env = dict(os.environ)
env.pop("AGENT_GUARD_EDIT_ACK", None)
env.pop("AGENT_STATE_DIR", None)
with (evidence / "claude-host.stdout.jsonl").open("w") as out, (evidence / "claude-host.stderr.log").open("w") as err:
    result = subprocess.run(args, cwd=target, env=env, text=True, stdout=out, stderr=err, timeout=240)
records = []
for line in (evidence / "claude-host.stdout.jsonl").read_text().splitlines():
    try:
        records.append(json.loads(line))
    except json.JSONDecodeError:
        continue
# Retain complete local logs; print only the acceptance evidence.
tools, results = [], []
for record in records:
    message = record.get("message", {})
    for item in message.get("content", []) if isinstance(message, dict) else []:
        if item.get("type") == "tool_use":
            tools.append({"id": item.get("id"), "name": item.get("name"), "input": item.get("input")})
        if item.get("type") == "tool_result":
            results.append({"id": item.get("tool_use_id"), "error": item.get("is_error", False), "content": item.get("content")})
ack_log = target / ".agents/state/guard-ack.log"
summary = {
    "target": str(target), "claude_rc": result.returncode,
    "marker_present": marker in (target / "AGENTS.md").read_text(),
    "ack_log_exists": ack_log.exists(),
    "tool_calls": tools, "tool_results": results,
    "result": [x for x in records if x.get("type") == "result"],
}
(evidence / "claude-host-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
by_id = {x["id"]: x for x in results}
edit_indices = [i for i, x in enumerate(tools) if x["name"] == "Edit"]
first_edit = edit_indices[0] if edit_indices else None
first_result = by_id.get(tools[first_edit]["id"], {}) if first_edit is not None else {}
denied = bool(first_result.get("error")) and "DENIED" in str(first_result.get("content", ""))
ack_indices = [i for i, x in enumerate(tools) if x["name"] == "Bash" and "agent-guard.sh pre-edit" in str(x["input"].get("command", "")) and "--ack" in str(x["input"].get("command", ""))]
retry = any(first_edit is not None and i > first_edit and any(first_edit < a < i for a in ack_indices) and tools[i]["id"] in by_id and not by_id[tools[i]["id"]].get("error", False) for i in edit_indices)
summary["initial_edit_denied"] = denied
summary["ack_then_successful_retry"] = retry
summary["host_acceptance_pass"] = result.returncode == 0 and denied and retry and summary["marker_present"] and summary["ack_log_exists"]
(evidence / "claude-host-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({k: v for k, v in summary.items() if k not in ["tool_calls", "tool_results", "result"]}, indent=2))
raise SystemExit(0 if summary["host_acceptance_pass"] else 1)
