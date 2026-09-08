#!/usr/bin/env python3
"""Reproducible release checks against disposable generated targets."""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[5]
OUT = Path(__file__).resolve().parent / "static-final"
OUT.mkdir(exist_ok=True)
ENV = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
checks = []


def run(name, argv, cwd=ROOT):
    start = time.monotonic()
    result = subprocess.run([str(v) for v in argv], cwd=cwd, env=ENV,
                            text=True, capture_output=True, timeout=240)
    (OUT / (name + ".stdout")).write_text(result.stdout)
    (OUT / (name + ".stderr")).write_text(result.stderr)
    checks.append({"name": name, "argv": [str(v) for v in argv],
                   "rc": result.returncode, "seconds": round(time.monotonic() - start, 2)})
    print(name, result.returncode, flush=True)
    assert result.returncode == 0, (name, result.stderr[-3000:], result.stdout[-3000:])
    return result.stdout


def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (ROOT / "agent-bootstrap").rglob("*") if p.is_file()}


before = hashes()
summary = {"status": "running", "checks": checks, "budgets": {}}
try:
    run("bash-version", ["/bin/bash", "--version"])
    shell_files = sorted((ROOT / "agent-bootstrap").rglob("*.sh")) + sorted((ROOT / "scripts").glob("*.sh"))
    for path in shell_files:
        run("syntax-" + str(path.relative_to(ROOT)).replace("/", "-"), ["/bin/bash", "-n", path])
    ci = (ROOT / ".github/workflows/test.yml").read_text()
    lint_block = ci.split("shellcheck --external-sources", 1)[1].split("else\n", 1)[0]
    lint_paths = list(dict.fromkeys(re.findall(r"^\s+((?:scripts|agent-bootstrap)/[a-zA-Z0-9_./-]+)(?: \\\n|\n)", lint_block, re.M)))
    assert "agent-bootstrap/agent-seats.sh" in lint_paths
    run("shellcheck-source", ["shellcheck", "--external-sources", "--exclude=SC1090,SC1091,SC2034,SC2154", *lint_paths])
    run("catalog", ["/bin/bash", "scripts/sync-template-catalog.sh", "--check"])
    script = (ROOT / "agent-bootstrap/agent-seats.sh").read_text()
    program = script.split("<<'PY' || true\n", 1)[1].split("\nPY\n", 1)[0]
    ast.parse(program, feature_version=(3, 8))
    for path in (ROOT / "scripts").glob("test-agent-seats*.py"):
        ast.parse(path.read_text(), feature_version=(3, 8))
    summary["python_3_8_ast"] = "pass"
    with tempfile.TemporaryDirectory(prefix="agent-seats-static-") as temp:
        for name in ("normal", "very-long-project-name-for-budget-check", "android-suite", "android-long"):
            target = Path(temp) / name
            if name == "android-long":
                target = target / "very-long-project-name-for-budget-check"
            target.mkdir(parents=True)
            if name.startswith("android"):
                suite = (ROOT / "scripts/test-bootstrap-multi-agent-project.sh").read_text()
                start = suite.index('mkdir -p "$TMP_DIR/app/src/main/AndroidManifest"')
                end = suite.index('\n(\n  cd "$TMP_DIR"', start)
                setup = 'set -euo pipefail\nTMP_DIR="$1"\n' + suite[start:end]
                run(name + "-fixture", ["/bin/bash", "-c", setup, "fixture", target])
            run(name + "-generate", ["/bin/bash", ROOT / "agent-bootstrap/bootstrap-multi-agent-project.sh", "--target", target, "--workflow", "full"])
            report = run(name + "-verify", ["/bin/bash", target / "scripts/verify-ai-deps.sh", "--json"], target)
            json.loads(report)
            budgets = {}
            for kind, phrase, limit in (("core", "core startup context estimate", 4000), ("on_demand", "on-demand full workflow context estimate", 6200)):
                match = re.search(re.escape(phrase) + r": (\d+) tokens", report)
                assert match, (name, phrase)
                budgets[kind] = int(match.group(1))
                assert budgets[kind] <= limit, (name, kind, budgets[kind], limit)
            summary["budgets"][name] = budgets
            run(name + "-shellcheck", ["shellcheck", "--external-sources", "--exclude=SC1090,SC1091,SC2034,SC2154", *sorted((target / "scripts").glob("*.sh")), target / ".codex/codex-mode.sh"])
            for rel in ("agent-seats.sh", "verify-ai-deps.sh", "agent-hook.sh", "agent-guard.sh"):
                assert (target / "scripts" / rel).read_bytes() == (ROOT / "agent-bootstrap" / rel).read_bytes(), rel
            assert (target / "docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-seats-v1.schema.json").read_bytes() == (ROOT / "agent-bootstrap/schemas/agent-seats-v1.schema.json").read_bytes()
    assert before == hashes(), "production source changed during final checks"
    summary["source_sha256"] = before
    summary["status"] = "pass"
except Exception as exc:
    summary["status"] = "fail"
    summary["error"] = repr(exc)
    raise
finally:
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
