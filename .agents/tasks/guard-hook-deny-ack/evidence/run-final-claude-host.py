#!/usr/bin/env python3
"""Regenerate a disposable target and bind real-host evidence to source hashes."""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

evidence_root = Path(__file__).resolve().parent
repo = evidence_root.parents[3]
evidence = evidence_root / sys.argv[1]
evidence.mkdir(exist_ok=False)
target = Path(tempfile.mkdtemp(prefix="guard-claude-final-")).resolve()
source_files = [
    "agent-bootstrap/agent-guard.sh",
    "agent-bootstrap/agent-hook.sh",
    "agent-bootstrap/lib/writers-runtime.sh",
    "agent-bootstrap/lib/writers-docs.sh",
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

before = {name: digest(repo / name) for name in source_files}
subprocess.run(["git", "init", "-q", str(target)], check=True)
with (evidence / "claude-host-bootstrap.log").open("w") as output:
    subprocess.run([
        "bash", str(repo / "scripts/bootstrap-multi-agent-project.sh"),
        "--target", str(target), "--workflow", "full",
        "--project-name", "guard-claude-acceptance",
    ], cwd=repo, stdout=output, stderr=subprocess.STDOUT, check=True)
assert (target / "scripts/agent-hook.sh").read_bytes() == (repo / "agent-bootstrap/agent-hook.sh").read_bytes()
assert (target / "scripts/agent-guard.sh").read_bytes() == (repo / "agent-bootstrap/agent-guard.sh").read_bytes()
provenance = {
    "target": str(target),
    "source_sha256": before,
    "host_entrypoints_sha256": {
        name: digest(target / name)
        for name in ["AGENTS.md", "CLAUDE.md", ".claude/settings.json"]
    },
    "host_version": subprocess.check_output(
        ["/Users/admin/.local/bin/claude", "--version"], text=True
    ).strip(),
    "branch": subprocess.check_output(
        ["git", "branch", "--show-current"], cwd=repo, text=True
    ).strip(),
    "head": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True
    ).strip(),
}
(evidence / "claude-host-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
result = subprocess.run([
    sys.executable, str(evidence_root / "run-claude-host.py"), str(target), str(evidence),
])
after = {name: digest(repo / name) for name in source_files}
provenance["source_unchanged_during_host_run"] = before == after
(evidence / "claude-host-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
raise SystemExit(result.returncode if before == after else 1)
