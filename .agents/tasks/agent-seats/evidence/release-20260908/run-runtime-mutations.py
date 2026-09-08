#!/usr/bin/env python3
"""Run the nine predeclared reference regressions against canonical production."""
import concurrent.futures
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

OUT = Path(__file__).resolve().parent / "runtime-mutations"
ROOT = next(p for p in Path(__file__).resolve().parents if (p / "agent-bootstrap/VERSION").exists())
SCRIPT = ROOT / "agent-bootstrap/agent-seats.sh"
HARNESS = ROOT / "scripts/test-agent-seats.py"
OUT.mkdir(exist_ok=True)
schema_source = ROOT / "agent-bootstrap/schemas/agent-seats-v1.schema.json"
(OUT / "schemas").mkdir(exist_ok=True)
(OUT / "schemas/agent-seats-v1.schema.json").write_bytes(schema_source.read_bytes())
raw = SCRIPT.read_text()
env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "SEATS_QA_BASH": "/bin/bash",
       "SEATS_QA_BUNDLE_PROFILE": str(ROOT / "agent-bootstrap/model-profiles/codex-model-profiles.json")}


def replace(old, new):
    assert raw.count(old) == 1, ("mutation boundary changed", old)
    return raw.replace(old, new, 1)


variants = {
    "m1-stdin": replace('python3 -c "$SEATS_PY" "$cmd" "$@"', 'python3 - "$cmd" "$@" <<< "$SEATS_PY"'),
    "m2-markers": replace('raise SeatsError(f"seat roster markers in {AGENTS_MD} are unbalanced (BEGIN={nb}, END={ne}); repair the markers by hand, then rerun render", code=3)', 'new = data'),
    "m3-conflict": replace('if model in reviewer_models:', 'if False:'),
    "m4-grammar": raw.replace('MODEL_RE.fullmatch(v)', 'MODEL_RE.match(v)').replace('EFFORT_RE.fullmatch(v)', 'EFFORT_RE.match(v)'),
    "m5-legacy-keys": replace('for key in ("reasoning_effort",) + LEGACY_ROUTE_KEYS:', 'for key in ("reasoning_effort",):'),
    "m7-set-creates": replace('if read_json(SEATS_FILE)[1] == "missing":', 'if False:'),
    "m8-init-recheck": replace('if init_precheck(True):  # same rules under the lock', 'doc2, err2 = read_json(SEATS_FILE)\n        if err2 is None:'),
    "m9-model-shape": replace('''                spec = model_spec(models, mid)
                if spec is None:
                    errors.append(f"seat {seat}: catalog entry for {mid} must be an object, not {type(models.get(mid)).__name__}")
                    continue''', '                spec = models.get(mid)'),
}
start = raw.index('def write_atomic(path, data):\n')
end = raw.index('\n\nSAVED = ', start)
variants["m6-inplace"] = raw[:start] + 'def write_atomic(path, data):\n    pathlib.Path(path).write_bytes(data)\n' + raw[end:]


def run(name, script):
    target = Path(tempfile.mkdtemp(prefix="seats-release-" + name + "-"))
    (target / "scripts").mkdir()
    (target / "docs/agent-configs").mkdir(parents=True)
    (target / "AGENTS.md").write_text("# Mutation fixture\n")
    with (OUT / (name + ".stdout")).open("w") as stdout, (OUT / (name + ".stderr")).open("w") as stderr:
        proc = subprocess.run([sys.executable, str(HARNESS), str(target), str(script), str(OUT / (name + ".json"))],
                              env=env, stdout=stdout, stderr=stderr, timeout=240)
    summary = json.loads((OUT / (name + ".json")).read_text())
    return {"rc": proc.returncode, "passed": summary["passed"], "failed": summary["failed"],
            "skipped": summary["skipped"], "failures": [r["check"] for r in summary["checks"] if not r["ok"]]}


result = {"baseline": run("baseline", SCRIPT), "source_sha256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
          "schema_sha256": hashlib.sha256(schema_source.read_bytes()).hexdigest()}
assert result["baseline"]["rc"] == 0 and result["baseline"]["skipped"] == 0, result["baseline"]
print("Baseline:", result["baseline"], flush=True)
paths = {}
for name, content in variants.items():
    path = OUT / (name + ".sh")
    path.write_text(content)
    paths[name] = path
    (OUT / (name + ".patch")).write_text(''.join(difflib.unified_diff(raw.splitlines(True), content.splitlines(True), fromfile="canonical", tofile=name)))
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    pending = {pool.submit(run, name, path): name for name, path in paths.items()}
    for future in concurrent.futures.as_completed(pending):
        name = pending[future]
        result[name] = future.result()
        print(name + ": " + json.dumps(result[name]), flush=True)
(OUT / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
for name in variants:
    assert result[name]["rc"] == 1 and result[name]["failed"] > 0, (name, result[name])
assert all(any(f.startswith(prefix) for f in result["m6-inplace"]["failures"]) for prefix in ("R7 ", "R8 "))
assert SCRIPT.read_text() == raw, "canonical changed during the run; rerun on final production"
print("All nine mutations caught; canonical source unchanged.", flush=True)
