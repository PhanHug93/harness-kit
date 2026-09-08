#!/usr/bin/env python3
"""Attempt 4: additional init I/O and nested-entry checks on temporary files."""
import copy
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

out = Path(__file__).resolve().parent
source = out.parent / "reference-agent-seats.sh"
target = Path(tempfile.mkdtemp(prefix="seats-attempt4-independent-")).resolve()
cfg = target / "docs/agent-configs"
cfg.mkdir(parents=True)
(target / "scripts").mkdir()
script = target / "scripts/agent-seats.sh"
shutil.copy2(source, script)
config = cfg / "seats.json"
agents = target / "AGENTS.md"
agents.write_bytes(b"# Independent probe\n")
env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
checks = []


def run(*args):
    return subprocess.run(["/bin/bash", str(script), *args], cwd=target,
                          env=env, capture_output=True, text=True, timeout=20)


assert os.getuid() != 0, "Permission checks require a non-root user"
assert run("init").returncode == 0
good = json.loads(config.read_text())

for timing in ("fast-path", "under-lock"):
    for name, payload, mode in (
        ("wrong-schema", b'{"schema":"wrong"}\n', 0o644),
        ("malformed", b'{ malformed\n', 0o644),
        ("unreadable", json.dumps(good).encode(), 0o000),
    ):
        config.unlink()
        waiting = None
        before_agents = agents.read_bytes()
        if timing == "under-lock":
            fd = os.open(cfg, os.O_RDONLY)
            fcntl.flock(fd, fcntl.LOCK_EX)
            proc = subprocess.Popen(["/bin/bash", str(script), "init"], cwd=target,
                                    env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            time.sleep(0.6)
            waiting = proc.poll() is None
        config.write_bytes(payload)
        config.chmod(mode)
        try:
            if timing == "under-lock":
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
                stdout, stderr = proc.communicate(timeout=20)
                result = subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
            else:
                result = run("init")
        finally:
            config.chmod(0o644)
        kept = config.read_bytes() == payload
        diagnostic = ("does not overwrite" in result.stderr and
                      "Traceback" not in result.stderr and
                      (timing != "under-lock" or "appeared while waiting" in result.stderr))
        ok = (result.returncode == 1 and kept and diagnostic and
              agents.read_bytes() == before_agents and waiting is not False)
        checks.append({"check": f"init-{timing}-{name}", "ok": ok,
                       "rc": result.returncode, "waiting_before_publish": waiting,
                       "bytes_preserved": kept, "stderr": result.stderr})

for shape in ("not-an-object", [], True):
    doc = copy.deepcopy(good)
    doc["catalog"]["models"]["gpt-6-astra"] = shape
    config.write_text(json.dumps(doc))
    before_config, before_agents = config.read_bytes(), agents.read_bytes()
    result = run("wizard", "--yes")
    ok = (result.returncode == 1 and "ERROR:" in result.stderr and
          "Traceback" not in result.stderr and config.read_bytes() == before_config and
          agents.read_bytes() == before_agents)
    checks.append({"check": "wizard-model-entry-" + type(shape).__name__, "ok": ok,
                   "rc": result.returncode, "stderr": result.stderr})

summary = {"target": str(target), "uid": os.getuid(), "checks": checks,
           "passed": sum(c["ok"] for c in checks),
           "failed": sum(not c["ok"] for c in checks)}
(out / "independent-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
raise SystemExit(1 if summary["failed"] else 0)
