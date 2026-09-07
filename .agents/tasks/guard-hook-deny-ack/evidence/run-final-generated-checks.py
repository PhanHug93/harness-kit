#!/usr/bin/env python3
"""Verify current generated runtime, including the predeclared deny mutation."""
import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parent
repo = root.parents[3]
evidence = root / "coordinator-final-checks"
evidence.mkdir(exist_ok=False)
target = Path(tempfile.mkdtemp(prefix="guard-final-checks-")).resolve()
files = ["agent-bootstrap/agent-guard.sh", "agent-bootstrap/agent-hook.sh",
         "agent-bootstrap/lib/writers-runtime.sh", "agent-bootstrap/lib/writers-docs.sh"]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
before = {name: digest(repo / name) for name in files}
env = dict(os.environ)
for name in ["AGENT_STATE_DIR", "AGENT_GUARD_EDIT_ACK", "AGENT_GUARD_ACK_TTL_SECONDS"]:
    env.pop(name, None)
checks = []
def run(name, args, expected=0, payload=None):
    start = time.monotonic()
    result = subprocess.run(args, cwd=target, env=env, input=payload,
                            capture_output=True, text=True, timeout=180)
    (evidence / (name + ".stdout.log")).write_text(result.stdout)
    (evidence / (name + ".stderr.log")).write_text(result.stderr)
    check = {"name": name, "command": args, "expected_rc": expected,
             "actual_rc": result.returncode, "seconds": round(time.monotonic()-start, 3)}
    checks.append(check)
    assert result.returncode == expected, check
    return result

run("git-init", ["git", "init", "-q"])
run("bootstrap", ["bash", str(repo / "scripts/bootstrap-multi-agent-project.sh"),
                  "--target", str(target), "--workflow", "full"])
assert (target / "scripts/agent-hook.sh").read_bytes() == (repo / "agent-bootstrap/agent-hook.sh").read_bytes()
assert (target / "scripts/agent-guard.sh").read_bytes() == (repo / "agent-bootstrap/agent-guard.sh").read_bytes()
run("doctor", ["bash", ".codex/codex-mode.sh", "doctor"])
run("verifier", ["bash", "scripts/verify-ai-deps.sh"])
def hook_payload(path, tool="Edit"):
    return json.dumps({"tool_name": tool, "tool_input": {"file_path": str(path)}})
hook = ["bash", "scripts/agent-hook.sh", "claude-pretool"]
denied = run("smoke-deny", hook, 2, hook_payload(target / "AGENTS.md"))
assert "DENIED" in denied.stderr and len(denied.stderr.splitlines()) <= 3
run("smoke-cli-ack", ["bash", "scripts/agent-guard.sh", "pre-edit", "--ack",
                      "coordinator final verification", "--", str(target / "AGENTS.md")])
ack_log = target / ".agents/state/guard-ack.log"
ack_bytes = ack_log.read_bytes()
allowed = run("smoke-allow", hook, 0, hook_payload(target / "AGENTS.md"))
assert "ack_source=log" in allowed.stdout and ack_log.read_bytes() == ack_bytes
run("smoke-wrong-path", hook, 2, hook_payload(target / "CLAUDE.md"))
run("smoke-unprotected", hook, 0, hook_payload(target / "src/final-check.txt", "Write"))

# Change only the existing adapter translation in this disposable target.
snapshot = target / "scripts/agent-hook.sh"
original = snapshot.read_text()
needle = "3) exit 2 ;;"
assert original.count(needle) == 1
snapshot.write_text(original.replace(needle, "3) exit 1 ;;", 1))
try:
    mutated = run("mutation", hook, 1, hook_payload(target / "CLAUDE.md"))
    assert "DENIED" in mutated.stderr
    assertion = subprocess.run(["bash", "-c", '[[ "$1" -eq 2 ]]', "deny-assert", str(mutated.returncode)])
    assert assertion.returncode == 1
finally:
    snapshot.write_text(original)
assert snapshot.read_bytes() == (repo / "agent-bootstrap/agent-hook.sh").read_bytes()
after = {name: digest(repo / name) for name in files}
assert before == after
summary = {"target": str(target), "source_sha256": before,
           "source_unchanged_during_checks": before == after,
           "snapshot_equal_before_and_after": True, "checks": checks,
           "mutation_expected_original_rc": 2, "mutation_actual_rc": mutated.returncode,
           "mutation_exact_rc_assertion_rc": assertion.returncode, "pass": True}
(evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({"pass": True, "checks": checks, "mutation_assertion_rc": assertion.returncode}, indent=2))
