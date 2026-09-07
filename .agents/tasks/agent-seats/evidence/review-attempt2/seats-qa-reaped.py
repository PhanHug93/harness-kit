#!/usr/bin/env python3
"""QA harness for agent-seats.sh (reference). Usage: seats-qa.py <target-dir> <script-path> [out-json]
Runs B1..B6 scenarios from the @gate review on a generated target copy. Exit 1 when any check fails."""
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import time

TARGET = os.path.abspath(sys.argv[1])
SCRIPT_SRC = os.path.abspath(sys.argv[2])
OUT = sys.argv[3] if len(sys.argv) > 3 else None
SCRIPT = os.path.join(TARGET, "scripts", "agent-seats.sh")
SEATS = os.path.join(TARGET, "docs", "agent-configs", "seats.json")
LEGACY = os.path.join(TARGET, "docs", "agent-configs", "model-profiles.json")
AGENTS = os.path.join(TARGET, "AGENTS.md")
results = []


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + ("" if not detail else f" — {detail}"))


def run(*args, env=None, stdin=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run(["bash", SCRIPT, *args], cwd=TARGET, env=e, input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def read_seats():
    with open(SEATS, encoding="utf-8") as fh:
        return json.load(fh)


def sha(path):
    import hashlib
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def pty_wizard(answers, timeout=20):
    """Run `wizard` under a real PTY; answer each prompt from the list in order.
    Returns (rc, transcript, prompts_seen)."""
    master, slave = pty.openpty()
    proc = subprocess.Popen(["bash", SCRIPT, "wizard"], cwd=TARGET, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    transcript = b""
    prompts = 0
    idx = 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            transcript += chunk
            if transcript.rstrip().endswith(b">"):
                prompts += 1
                answer = answers[idx] if idx < len(answers) else ""
                idx += 1
                os.write(master, (answer + "\n").encode())
        elif proc.poll() is not None:
            break
    if proc.poll() is None:
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    if proc.poll() is None:
        proc.kill()
        proc.wait()
        os.close(master)
        return -1, transcript.decode(errors="replace"), prompts
    os.close(master)
    return proc.returncode, transcript.decode(errors="replace"), prompts


# ---------- setup ----------
os.makedirs(os.path.dirname(SCRIPT), exist_ok=True)
shutil.copy(SCRIPT_SRC, SCRIPT)
os.chmod(SCRIPT, 0o755)
if os.path.exists(SEATS):
    os.remove(SEATS)
legacy_backup = None
if os.path.exists(LEGACY):
    with open(LEGACY, encoding="utf-8") as fh:
        legacy_backup = fh.read()
agents_original = open(AGENTS, "rb").read() if os.path.exists(AGENTS) else b"# Agent Conventions\n"

# ---------- B3: lifecycle matrix ----------
rc, o, e = run("init")
check("B3 init: missing seats + legacy -> migrated", rc == 0 and "created from legacy" in o, o.strip().splitlines()[0] if o else e)
rc, o, e = run("init")
check("B3 init: existing valid seats -> no write", rc == 0 and "nothing written" in o)
# customized legacy: unknown model + low effort
custom_legacy = {"schema": "agent-model-profiles/v1", "default_profile": "stable", "profiles": {"stable": {
    "reasoning_effort": "low", "planning_model": "custom-planner", "coding_model": "gpt-5.6-luna", "reviewing_model": "custom-planner",
    "planning_fallback_model": "gpt-5.6-terra", "coding_fallback_model": "gpt-5.6-terra", "reviewing_fallback_model": "gpt-5.6-terra"}}}
os.remove(SEATS)
with open(LEGACY, "w", encoding="utf-8") as fh:
    json.dump(custom_legacy, fh)
rc, o, e = run("suggest")
check("B3 suggest: legacy unknown model + low effort -> valid proposal with notes", rc == 0 and "custom-planner @ low" in o and "catalog: added custom-planner" in e)
rc, o, e = run("wizard", "--yes")
rc2, o2, e2 = run("validate")
check("B3 wizard --yes migrates legacy low effort and stays valid", rc == 0 and rc2 == 0, e2.strip())
rc, o, e = run("reset")
doc = read_seats()
rc2, _, _ = run("validate")
check("B3 reset ignores legacy (bundle defaults) and validates", rc == 0 and doc["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra" and "custom-planner" not in json.dumps(doc) and rc2 == 0)
# malformed legacy must not block operations on valid seats
with open(LEGACY, "w", encoding="utf-8") as fh:
    fh.write("{ broken")
rc, o, e = run("wizard", "--yes")
check("B3 malformed legacy does not block wizard --yes on valid seats", rc == 0, e.strip())
rc, o, e = run("set", "@build", "--effort", "high")
check("B3 malformed legacy does not block set on valid seats", rc == 0 and read_seats()["seats"]["build"]["occupant"]["effort"] == "high", e.strip())
os.remove(SEATS)
rc, o, e = run("init")
check("B3 init: missing seats + malformed legacy -> error, nothing written", rc == 1 and not os.path.exists(SEATS) and "legacy" in e)
os.remove(LEGACY)
rc, o, e = run("init")
check("B3 init: missing seats, no legacy -> defaults", rc == 0 and "created from defaults" in o)
# malformed seats
with open(SEATS, "w", encoding="utf-8") as fh:
    fh.write("{ nope")
rc, o, e = run("show")
check("B3 malformed seats -> show rc 1 with reset guidance", rc == 1 and "reset" in e)
rc, o, e = run("init")
check("B3 malformed seats -> init refuses to overwrite", rc == 1 and open(SEATS).read() == "{ nope")
rc, o, e = run("reset")
check("B3 reset repairs malformed seats", rc == 0 and read_seats()["schema"] == "agent-seats/v1")

# ---------- B2: transport ----------
rc, o, e = run("set", "@gate", "--no-fallback")
lines = run("resolve", "planning")[1].split("\n")[:-1]
check("B2 resolve: 8 lines with empty fallback fields preserved", len(lines) == 8 and lines[0] == "gate" and lines[6] == "" and lines[7] == "", str(lines))
bash_reader = r'''
i=0; n=0
while IFS= read -r line; do
  i=$((i+1)); n=$i; eval "f$i=\$line"
done < <(bash scripts/agent-seats.sh resolve planning)
printf 'count=%s model=[%s] fallback=[%s] fbeff=[%s]\n' "$n" "$f5" "$f7" "$f8"
'''
p = subprocess.run(["bash", "-c", bash_reader], cwd=TARGET, capture_output=True, text=True)
check("B2 bash line reader keeps empty columns", p.stdout.strip() == "count=8 model=[gpt-6-astra] fallback=[] fbeff=[]", p.stdout.strip())
rc, o, e = run("set", "@gate", "--host", "claude")
lines = run("resolve", "@gate")[1].split("\n")[:-1]
check("B2 resolve non-codex host: 8 lines, host claude, empty model fields", len(lines) == 8 and lines[3] == "claude" and lines[4] == "" and lines[5] == "", str(lines))
# delimiter in model id must be rejected by validate
doc = read_seats()
doc["catalog"]["models"]["bad\tmodel"] = {"host": "codex", "efforts": ["high"], "default_effort": "high"}
with open(SEATS, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
rc, o, e = run("validate")
check("B2 model id with TAB rejected by grammar", rc == 1 and "grammar" in e)
run("reset")
rc, o, e = run("model-info", "gpt-5.6-terra")
check("B2 model-info gives host/default_effort/efforts", rc == 0 and o.split("\n")[:3] == ["codex", "xhigh", "none low medium high xhigh max"], o)
rc, o, e = run("model-info", "not-in-catalog")
check("B2 model-info unknown model -> rc 1 with guidance", rc == 1 and "catalog" in e)

# ---------- B5: conflict by effective model ----------
run("reset")
check("B5 conflict: build with luna -> 0", run("conflict", "build", "gpt-5.6-luna")[1].strip() == "0")
check("B5 conflict: build effective astra (gate primary) -> 1", run("conflict", "@build", "gpt-6-astra")[1].strip() == "1")
check("B5 conflict: build effective terra (gate fallback) -> 1", run("conflict", "coding", "gpt-5.6-terra")[1].strip() == "1")
check("B5 conflict: non-build seat -> 0", run("conflict", "gate", "gpt-6-astra")[1].strip() == "0")
run("set", "@gate", "--host", "claude")
run("set", "@verify", "--host", "claude")
check("B5 conflict: reviewers on claude -> 0 even for astra", run("conflict", "build", "gpt-6-astra")[1].strip() == "0")
run("reset")

# ---------- B6: renderer ----------
def write_agents(data: bytes):
    with open(AGENTS, "wb") as fh:
        fh.write(data)

base = b"# Agent Conventions - demo\n\n## Project-Specific Conventions\n\n<!-- BEGIN USER: agents:extra -->\nPRESERVE_USER_OVERLAY\n<!-- END USER: agents:extra -->\n"
write_agents(base)
rc, o, e = run("render")
after1 = open(AGENTS, "rb").read()
rc2, o2, e2 = run("render")
after2 = open(AGENTS, "rb").read()
check("B6 render appends block, preserves prefix bytes, idempotent", rc == 0 and rc2 == 0 and after1.startswith(base) and after1 == after2 and b"PRESERVE_USER_OVERLAY" in after2 and after2.count(b"BEGIN MANAGED: multi-agent-bootstrap:seat-roster") == 1)
run("set", "@build", "--effort", "high")
after3 = open(AGENTS, "rb").read()
check("B6 set re-renders only the block", after3.startswith(base) and b"@ high" in after3 and after3.count(b"seat-roster -->") == 2)
# CRLF
crlf = base.replace(b"\n", b"\r\n")
write_agents(crlf)
rc, o, e = run("render")
after = open(AGENTS, "rb").read()
check("B6 CRLF file keeps CRLF everywhere", rc == 0 and b"\n" not in after.replace(b"\r\n", b"") and after.startswith(crlf))
# orphan BEGIN without END: must fail with exit 3 and not modify
orphan = base + b"\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\nstale line\n"
write_agents(orphan)
rc, o, e = run("render")
same1 = open(AGENTS, "rb").read() == orphan
rc2, o2, e2 = run("render")
same2 = open(AGENTS, "rb").read() == orphan
check("B6 orphan BEGIN -> exit 3 twice, file untouched, overlay intact", rc == 3 and rc2 == 3 and same1 and same2)
# duplicate blocks
dup = base + b"\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\nx\n<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\ny\n<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->\n"
write_agents(dup)
rc, o, e = run("render")
check("B6 duplicate blocks -> exit 3, untouched", rc == 3 and open(AGENTS, "rb").read() == dup)
# partial failure: set writes seats.json but render fails -> exit 2
before = sha(SEATS)
rc, o, e = run("set", "@build", "--effort", "xhigh")
check("B6 set with broken markers -> seats written, exit 2, explicit message", rc == 2 and sha(SEATS) != before and "NOT rendered" in e)
write_agents(base)
run("render")

# ---------- B1: interactive wizard on a real PTY ----------
run("reset")
# @spec: host 2 (codex) -> model 2 (luna), effort Enter, fallback 3 (terra), fb effort Enter
# @gate: host Enter, model Enter, effort Enter, fallback Enter, fb effort Enter (keeps astra)
# @build: host Enter, model 1 (astra -> ultra), effort Enter, fallback 'none'
# @verify: host 1 (claude)
# @audit: Enter
answers = ["2", "2", "", "3", "",          # spec
           "", "", "", "", "",             # gate
           "", "1", "", "none",            # build
           "1",                            # verify
           ""]                             # audit
rc, transcript, prompts = pty_wizard(answers)
doc = read_seats() if os.path.exists(SEATS) else {}
spec = doc.get("seats", {}).get("spec", {}).get("occupant", {})
gate = doc.get("seats", {}).get("gate", {}).get("occupant", {})
build = doc.get("seats", {}).get("build", {}).get("occupant", {})
verify = doc.get("seats", {}).get("verify", {}).get("occupant", {})
check("B1 wizard on PTY shows host prompt and waits for input", "host>" in transcript and prompts >= 10, f"prompts={prompts} rc={rc}")
check("B1 wizard applies non-default choices (@spec -> codex luna xhigh fallback terra)", spec == {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"}, json.dumps(spec))
check("B1 wizard Enter keeps suggestion (@gate astra ultra)", gate.get("model") == "gpt-6-astra" and gate.get("effort") == "ultra", json.dumps(gate))
check("B1 wizard model change adopts default effort and 'none' drops fallback (@build astra ultra)", build == {"host": "codex", "model": "gpt-6-astra", "effort": "ultra"}, json.dumps(build))
check("B1 wizard host change to claude drops model (@verify)", verify == {"host": "claude"}, json.dumps(verify))
check("B1 wizard exits 0 and validates", rc == 0 and run("validate")[0] == 0)
# re-choosing the same host keeps the suggested model
run("reset")
answers = ["", "2", "", "", "", "",  # spec keep; gate: host 2 (same codex), model Enter, effort Enter, fb Enter, fbe Enter
           "", "", "", "", "",       # build keep
           "", "", "", "", "",       # verify keep
           ""]                       # audit
rc, transcript, prompts = pty_wizard(answers)
gate = read_seats()["seats"]["gate"]["occupant"]
check("B1 re-choosing the same host keeps the suggested model", rc == 0 and gate.get("model") == "gpt-6-astra" and gate.get("effort") == "ultra", json.dumps(gate))
# non-TTY without --yes accepts suggestions (documented)
rc, o, e = run("wizard")
check("B1 non-TTY wizard accepts suggestions", rc == 0)
# invalid interactive effort is rejected without writing
run("reset")
before = sha(SEATS)
answers = ["", "", "", "turbo", "", ""]  # spec keep; gate: host Enter, model Enter, effort turbo
rc, transcript, prompts = pty_wizard(answers)
check("B1 invalid interactive effort -> rc 1, nothing written", rc == 1 and sha(SEATS) == before, f"rc={rc}")

# ---------- cleanup ----------
write_agents(agents_original)
if legacy_backup is not None:
    with open(LEGACY, "w", encoding="utf-8") as fh:
        fh.write(legacy_backup)
run("reset")

failed = [r for r in results if not r["ok"]]
summary = {"target": TARGET, "script_sha256": sha(SCRIPT_SRC), "checks": results, "passed": len(results) - len(failed), "failed": len(failed)}
if OUT:
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
print(f"\n{summary['passed']} passed, {summary['failed']} failed")
sys.exit(1 if failed else 0)
