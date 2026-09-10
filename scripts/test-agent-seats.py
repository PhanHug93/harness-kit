#!/usr/bin/env python3
"""QA harness v2 for agent-seats.sh (reference v3).
Usage: seats-qa.py <target-dir> <script-path> [out.json]
Env: SEATS_QA_BASH (default "bash"; use /bin/bash on macOS for a 3.2 run),
     SEATS_QA_BUNDLE_PROFILE (bundle model-profiles file for the legacy-default equality check),
     SEATS_QA_EVIDENCE_DIR (transcripts of failed PTY runs).
Covers the gate's B1-B6/R1-R4 and the council findings (atomic writes, locking,
malformed shapes, set options, repair, wizard edge cases, init never prompts).
Exit 1 when any check fails. Requires a non-root user for the permission cases
(they are skipped with a note when running as root)."""
import hashlib
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

TARGET = os.path.abspath(sys.argv[1])
SCRIPT_SRC = os.path.abspath(sys.argv[2])
OUT = sys.argv[3] if len(sys.argv) > 3 else None
BASH = os.environ.get("SEATS_QA_BASH", "bash")
BUNDLE_PROFILE = os.environ.get("SEATS_QA_BUNDLE_PROFILE", "")
SCHEMA_SRC = os.path.join(os.path.dirname(SCRIPT_SRC), "schemas", "agent-seats-v1.schema.json")
SCRIPT = os.path.join(TARGET, "scripts", "agent-seats.sh")
CFG = os.path.join(TARGET, "docs", "agent-configs")
SEATS = os.path.join(CFG, "seats.json")
LEGACY = os.path.join(CFG, "model-profiles.json")
AGENTS = os.path.join(TARGET, "AGENTS.md")
EVIDENCE_DIR = os.environ.get("SEATS_QA_EVIDENCE_DIR") or (
    os.path.join(os.path.dirname(os.path.abspath(OUT)), "seats-qa-pty") if OUT else tempfile.mkdtemp(prefix="seats-qa-pty-"))
IS_ROOT = os.geteuid() == 0
results = []
_last_pty = None

LEGACY_DEFAULT = {"schema": "agent-model-profiles/v1", "default_profile": "stable", "profiles": {"stable": {
    "reasoning_effort": "xhigh", "planning_model": "gpt-5.6-sol", "coding_model": "gpt-5.6-luna", "reviewing_model": "gpt-5.6-sol",
    "planning_fallback_model": "gpt-5.6-terra", "coding_fallback_model": "gpt-5.6-terra", "reviewing_fallback_model": "gpt-5.6-terra"}}}
LEGACY_CUSTOM = {"schema": "agent-model-profiles/v1", "default_profile": "stable", "profiles": {"stable": {
    "reasoning_effort": "low", "planning_model": "custom-planner", "coding_model": "gpt-5.6-luna", "reviewing_model": "custom-planner",
    "planning_fallback_model": "gpt-5.6-terra", "coding_fallback_model": "gpt-5.6-terra", "reviewing_fallback_model": "gpt-5.6-terra"}}}


def save_transcript(reason):
    global _last_pty
    if _last_pty is None:
        return None
    name, rc, prompts, transcript = _last_pty
    _last_pty = None
    os.makedirs(EVIDENCE_DIR, exist_ok=True)
    path = os.path.join(EVIDENCE_DIR, re.sub(r"[^A-Za-z0-9._-]+", "_", name) + ".pty.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"# pty run: {name}\n# reason: {reason}\n# rc={rc} prompts={prompts}\n{transcript}")
    return path


def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + ("" if not detail else f" — {detail}"))
    if not ok:
        path = save_transcript(f"failed check: {name}")
        if path:
            print(f"      transcript saved: {path}")


def skip(name, why):
    results.append({"check": name, "ok": True, "skipped": True, "detail": why})
    print(f"SKIP {name} — {why}")


def run(*args, env=None, stdin=None, cwd=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([BASH, SCRIPT, *args], cwd=cwd or TARGET, env=e, input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def read_seats():
    with open(SEATS, encoding="utf-8") as fh:
        return json.load(fh)


def write_seats(doc):
    with open(SEATS, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


def mutate(fn):
    doc = read_seats()
    fn(doc)
    write_seats(doc)


def write_json(path, doc):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def no_traceback(err):
    return "Traceback" not in err


def fsize_limited_run(nbytes, *args):
    """Run the script with RLIMIT_FSIZE applied to python3 only, through a shim
    earlier on PATH. The limit therefore reaches write_atomic instead of the
    shell's heredoc spool file, on Bash 3.2 as on Bash 5."""
    real = os.path.realpath(sys.executable)
    d = tempfile.mkdtemp(prefix="seats-qa-fsize-")
    shim = os.path.join(d, "python3")
    with open(shim, "w", encoding="utf-8") as fh:
        fh.write(
            "#!" + real + "\n"
            "import os, resource, signal, sys\n"
            "signal.signal(signal.SIGXFSZ, signal.SIG_IGN)\n"
            f"resource.setrlimit(resource.RLIMIT_FSIZE, ({nbytes}, {nbytes}))\n"
            f"os.execv({real!r}, [{real!r}] + sys.argv[1:])\n"
        )
    os.chmod(shim, 0o755)
    env = dict(os.environ, PATH=d + os.pathsep + os.environ.get("PATH", ""))
    try:
        return subprocess.run([BASH, SCRIPT, *args], cwd=TARGET, env=env, capture_output=True, text=True)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _read_master(master):
    try:
        return os.read(master, 65536)
    except OSError:
        return b""


def pty_run(cmd_args, answers, timeout=20, reap_timeout=5.0, name="pty", signal_at_prompt=None):
    """Run the script under a real PTY; answer each prompt (a line ending in '>') from
    `answers` in order. Prompts are detected on the output received since the last answer.
    After EOF the child is reaped with a bounded wait. Returns (rc, transcript, prompts)."""
    global _last_pty
    master, slave = pty.openpty()
    try:
        proc = subprocess.Popen([BASH, SCRIPT, *cmd_args], cwd=TARGET, stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
    finally:
        os.close(slave)
    transcript = bytearray()
    pending = b""
    prompts = 0
    idx = 0
    eof = False
    killed = False
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            r, _, _ = select.select([master], [], [], min(0.2, max(0.0, deadline - time.monotonic())))
            if r:
                chunk = _read_master(master)
                if not chunk:
                    eof = True
                    break
                transcript += chunk
                pending += chunk
                if pending.rstrip().endswith(b">"):
                    prompts += 1
                    if signal_at_prompt is not None and prompts == signal_at_prompt:
                        os.killpg(proc.pid, signal.SIGINT)
                        pending = b""
                        continue
                    answer = answers[idx] if idx < len(answers) else ""
                    idx += 1
                    try:
                        if answer == "<EOF>":
                            os.write(master, b"\x04")
                        else:
                            os.write(master, (answer + "\n").encode())
                    except OSError:
                        eof = True
                        break
                    pending = b""
            elif proc.poll() is not None:
                while True:
                    r, _, _ = select.select([master], [], [], 0.2)
                    chunk = _read_master(master) if r else b""
                    if not chunk:
                        break
                    transcript += chunk
                break
        try:
            rc = proc.wait(timeout=reap_timeout if eof else max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            rc = -1
            killed = True
    finally:
        os.close(master)
    text = transcript.decode(errors="replace")
    _last_pty = (name, rc, prompts, text)
    if killed:
        path = save_transcript("child killed")
        print(f"      pty run {name}: child killed (eof={eof}); transcript saved: {path}")
    return rc, text, prompts


def pty_wizard(answers, **kw):
    return pty_run(["wizard"], answers, **kw)


# ---------- setup ----------
os.makedirs(os.path.dirname(SCRIPT), exist_ok=True)
shutil.copy(SCRIPT_SRC, SCRIPT)
os.chmod(SCRIPT, 0o755)
for p in (SEATS, LEGACY):
    if os.path.exists(p):
        os.remove(p)
agents_original = open(AGENTS, "rb").read() if os.path.exists(AGENTS) else b"# Agent Conventions\n"
base = b"# Agent Conventions - demo\n\n## Project-Specific Conventions\n\n<!-- BEGIN USER: agents:extra -->\nPRESERVE_USER_OVERLAY\n<!-- END USER: agents:extra -->\n"


def write_agents(data: bytes):
    with open(AGENTS, "wb") as fh:
        fh.write(data)


write_agents(base)

# ---------- L: lifecycle (R1/B3) ----------
rc, o, e = run("init")
check("L1 init: no seats, no legacy -> defaults (Astra/ultra)", rc == 0 and "created from defaults" in o and read_seats()["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra", o.strip().splitlines()[0] if o else e)
rc, o, e = run("init")
check("L2 init: valid seats present -> no write, no lock", rc == 0 and "nothing written" in o)
os.remove(SEATS)
write_json(LEGACY, LEGACY_DEFAULT)
rc, o, e = run("init")
d = read_seats()
check("L3 init: legacy equal to old generator default -> seat defaults, labeled defaults", rc == 0 and "created from defaults" in o and d["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra" and "gpt-5.6-sol" not in json.dumps(d) and "no user customization" in e)
if BUNDLE_PROFILE and os.path.exists(BUNDLE_PROFILE):
    with open(BUNDLE_PROFILE, encoding="utf-8") as fh:
        bundle = json.load(fh)["profiles"]["stable"]
    check("L4 LEGACY_BUNDLE_DEFAULT equals the bundle model-profiles file", bundle == LEGACY_DEFAULT["profiles"]["stable"], json.dumps(bundle))
else:
    skip("L4 LEGACY_BUNDLE_DEFAULT equals the bundle model-profiles file", "SEATS_QA_BUNDLE_PROFILE not set")
os.remove(SEATS)
write_json(LEGACY, LEGACY_CUSTOM)
rc, o, e = run("suggest")
check("L5 suggest: customized legacy (unknown model, low) -> migrated proposal + notes", rc == 0 and "custom-planner @ low" in o and "catalog: added custom-planner" in e)
rc, o, e = run("init")
rc2, _, e2 = run("validate")
check("L6 init: customized legacy migrates and validates", rc == 0 and "created from legacy" in o and rc2 == 0 and read_seats()["seats"]["gate"]["occupant"] == {"host": "codex", "model": "custom-planner", "effort": "low", "fallback_model": "gpt-5.6-terra", "fallback_effort": "low"}, e2)
# A legacy choice remains user data even when fresh catalogs no longer offer it.
os.remove(SEATS)
legacy_none = json.loads(json.dumps(LEGACY_DEFAULT))
legacy_none["profiles"]["stable"]["reasoning_effort"] = "none"
write_json(LEGACY, legacy_none)
legacy_before = open(LEGACY, "rb").read()
rc, o, e = run("init")
d = read_seats()
check("L6b legacy none effort is preserved without rewriting the input",
      rc == 0 and "created from legacy" in o and run("validate")[0] == 0
      and open(LEGACY, "rb").read() == legacy_before
      and all(d["seats"][seat]["occupant"][key] == "none"
              for seat in ("gate", "build", "verify") for key in ("effort", "fallback_effort")))
# extra route effort key: not "untouched", migrated with the declared effort
os.remove(SEATS)
extra = json.loads(json.dumps(LEGACY_DEFAULT)); extra["profiles"]["stable"]["planning_reasoning_effort"] = "max"
write_json(LEGACY, extra)
rc, o, e = run("init")
check("L7 init: default models + planning_reasoning_effort=max -> migrated (max kept)", rc == 0 and "created from legacy" in o and read_seats()["seats"]["gate"]["occupant"]["effort"] == "max")
# incomplete / invalid legacy -> refused, nothing written
for label, prof in (("missing planning_model", {"reasoning_effort": "high"}),
                    ("unsupported effort turbo", dict(LEGACY_CUSTOM["profiles"]["stable"], reasoning_effort="turbo")),
                    ("empty fallback", dict(LEGACY_CUSTOM["profiles"]["stable"], coding_fallback_model="")),
                    ("route effort with LF", dict(LEGACY_CUSTOM["profiles"]["stable"], planning_reasoning_effort="high\n"))):
    if os.path.exists(SEATS):
        os.remove(SEATS)
    write_json(LEGACY, {"schema": "agent-model-profiles/v1", "default_profile": "stable", "profiles": {"stable": prof}})
    rc, o, e = run("init")
    rc2, o2, e2 = run("suggest")
    rc3, o3, e3 = run("wizard", "--yes")
    check(f"L8 legacy {label}: init/suggest/wizard --yes -> rc 1, nothing written, no traceback", rc == 1 and rc2 == 1 and rc3 == 1 and not os.path.exists(SEATS) and all(no_traceback(x) for x in (e, e2, e3)), (e or e2 or e3).strip().splitlines()[-1] if (e or e2 or e3) else "")
# A malformed legacy selector must fail as a configuration error rather than
# reaching dict.get with an unhashable key.  Each read/init path is checked and
# none may create seats.json.
for label, default_profile in (("list", ["bad"]), ("dict", {"bad": True}), ("boolean", True)):
    if os.path.exists(SEATS):
        os.remove(SEATS)
    write_json(LEGACY, {"schema": "agent-model-profiles/v1", "default_profile": default_profile, "profiles": {"stable": {}}})
    calls = [run("init"), run("suggest"), run("wizard", "--yes")]
    diagnostic = "\n".join(r[1] + r[2] for r in calls)
    check(f"L8b legacy default_profile {label}: init/suggest/wizard -> rc 1, clear diagnostic, no traceback or write",
          all(r[0] == 1 and no_traceback(r[2]) for r in calls) and not os.path.exists(SEATS) and "default_profile must be a non-empty string" in diagnostic,
          diagnostic.strip().splitlines()[-1] if diagnostic else "")
# A selected legacy profile with a non-object value must remain a clean refusal.
for label, profile_value in (("list", []), ("boolean", True), ("null", None)):
    if os.path.exists(SEATS):
        os.remove(SEATS)
    write_json(LEGACY, {"schema": "agent-model-profiles/v1", "default_profile": "stable", "profiles": {"stable": profile_value}})
    calls = [run("init"), run("suggest"), run("wizard", "--yes")]
    diagnostic = "\n".join(r[1] + r[2] for r in calls)
    check(f"L8c legacy default profile entry {label}: init/suggest/wizard -> rc 1, no traceback or write",
          all(r[0] == 1 and no_traceback(r[2]) for r in calls) and not os.path.exists(SEATS) and "no usable default profile" in diagnostic,
          diagnostic.strip().splitlines()[-1] if diagnostic else "")
rc, o, e = run("reset")
check("L9 reset with invalid legacy present -> defaults, rc 0, valid", rc == 0 and run("validate")[0] == 0 and read_seats()["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra")
with open(LEGACY, "w", encoding="utf-8") as fh:
    fh.write("{ broken")
check("L10 malformed legacy does not block wizard --yes on valid seats", run("wizard", "--yes")[0] == 0)
rc, o, e = run("set", "@build", "--effort", "high")
check("L11 malformed legacy does not block set on valid seats", rc == 0 and read_seats()["seats"]["build"]["occupant"]["effort"] == "high", e.strip())
os.remove(SEATS)
rc, o, e = run("init")
check("L12 init: missing seats + malformed legacy -> rc 1, nothing written", rc == 1 and not os.path.exists(SEATS) and "legacy" in e)
rc, o, e = run("set", "@build", "--effort", "high")
check("L13 set on a missing seats.json fails closed (run init)", rc == 1 and not os.path.exists(SEATS) and "init" in e)
os.remove(LEGACY)
with open(SEATS, "w", encoding="utf-8") as fh:
    fh.write("{ nope")
rc, o, e = run("show")
check("L14 malformed seats -> show rc 1 with reset guidance, no traceback", rc == 1 and "reset" in e and no_traceback(e))
rc, o, e = run("init")
check("L15 malformed seats -> init refuses to overwrite", rc == 1 and open(SEATS).read() == "{ nope")
check("L16 reset repairs malformed seats", run("reset")[0] == 0 and read_seats()["schema"] == "agent-seats/v1")
with open(SEATS, "rb") as fh:
    raw = fh.read()
with open(SEATS, "wb") as fh:
    fh.write(b"\xef\xbb\xbf" + raw)
check("L17 UTF-8 BOM in a hand-edited seats.json is accepted", run("validate")[0] == 0)
run("reset")
rc, o, e = run("validate")
check("L18 defaults are warning-clean (fallback overlap is not a conflict)", rc == 0 and "warn" not in e, e.strip())
# init must never prompt (PTY, no answers)
os.remove(SEATS)
rc, text, prompts = pty_run(["init"], [], timeout=10, name="init-pty")
check("L19 init under a PTY never prompts", rc == 0 and prompts == 0 and ">" not in text.replace("->", ""), f"rc={rc} prompts={prompts}")

# ---------- G: grammar / transport (R2/B2) ----------
run("reset")
lines = run("resolve", "planning")[1].split("\n")[:-1]
check("G1 resolve: 8 lines, empty fields preserved when fallback absent", True and len(lines) == 8, str(lines))
run("set", "@gate", "--no-fallback")
lines = run("resolve", "planning")[1].split("\n")[:-1]
check("G2 resolve: no fallback -> 8 lines with empty fallback fields", len(lines) == 8 and lines[6] == "" and lines[7] == "", str(lines))
reader = r'''
i=0; n=0
while IFS= read -r line; do i=$((i+1)); n=$i; eval "f$i=\$line"; done < <("$1" "$2" resolve planning)
printf 'count=%s model=[%s] fallback=[%s] fbeff=[%s]\n' "$n" "$f5" "$f7" "$f8"
'''
p = subprocess.run([BASH, "-c", reader, "reader", BASH, SCRIPT], cwd=TARGET, capture_output=True, text=True)
check("G3 bash line reader keeps empty columns", p.stdout.strip() == "count=8 model=[gpt-6-astra] fallback=[] fbeff=[]", p.stdout.strip() + p.stderr.strip())
run("set", "@gate", "--host", "claude")
lines = run("resolve", "@gate")[1].split("\n")[:-1]
check("G4 resolve non-codex host: 8 lines, empty model fields", len(lines) == 8 and lines[3] == "claude" and lines[4] == "" and lines[5] == "", str(lines))
run("reset")
grammar_cases = [
    ("model LF in catalog+occupant", lambda d: (d["catalog"]["models"].__setitem__("custom\n", {"host": "codex", "efforts": ["high"], "default_effort": "high"}), d["seats"]["gate"].__setitem__("occupant", {"host": "codex", "model": "custom\n", "effort": "high"}))),
    ("effort LF", lambda d: (d["catalog"]["models"]["gpt-6-astra"]["efforts"].append("high\n"), d["seats"]["gate"]["occupant"].__setitem__("effort", "high\n"))),
    ("effort CRLF", lambda d: (d["catalog"]["models"]["gpt-6-astra"]["efforts"].append("high\r\n"), d["seats"]["gate"]["occupant"].__setitem__("effort", "high\r\n"))),
    ("model TAB", lambda d: d["catalog"]["models"].__setitem__("bad\tmodel", {"host": "codex", "efforts": ["high"], "default_effort": "high"})),
    ("informational model LF on claude seat", lambda d: d["seats"]["gate"].__setitem__("occupant", {"host": "claude", "model": "info\nmodel"})),
    ("orphan fallback_effort", lambda d: (d["seats"]["gate"]["occupant"].pop("fallback_model"), d["seats"]["gate"]["occupant"].__setitem__("fallback_effort", "high"))),
    ("non-codex effort/fallback garbage", lambda d: d["seats"]["spec"].__setitem__("occupant", {"host": "claude", "effort": "a\nb", "fallback_model": "x y", "fallback_effort": "Q\n"})),
    ("empty model", lambda d: d["seats"]["gate"]["occupant"].__setitem__("model", "")),
    ("model with space", lambda d: d["seats"]["gate"]["occupant"].__setitem__("model", "gpt 6")),
    ("host LF", lambda d: d["seats"]["gate"]["occupant"].__setitem__("host", "codex\n")),
    ("tag TAB", lambda d: d["seats"]["gate"].__setitem__("tag", "@gate\t")),
    ("owner not human", lambda d: d["seats"]["owner"].__setitem__("occupant", {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh"})),
    ("default_effort not in efforts", lambda d: d["catalog"]["models"]["gpt-6-astra"].__setitem__("default_effort", "unsupported")),
    ("non-string efforts", lambda d: d["catalog"]["models"]["gpt-6-astra"].__setitem__("efforts", [1, 2])),
]
for label, fn in grammar_cases:
    run("reset")
    mutate(fn)
    rc, o, e = run("validate")
    rr = run("resolve", "gate")
    ok_lines = rr[0] != 0 or len(rr[1].split("\n")[:-1]) == 8
    check(f"G5 validate rejects: {label}", rc == 1 and no_traceback(e) and ok_lines, (e.strip().splitlines() or [""])[-1])
run("reset")
mutate(lambda d: d["seats"]["gate"].__setitem__("occupant", {"host": "claude", "model": "gpt-6-astra"}))
rc, o, e = run("validate")
check("G6 informational model on a host-controlled seat -> valid with a warning", rc == 0 and "informational" in e)
run("reset")
mutate(lambda d: d["catalog"]["models"]["gpt-6-astra"]["efforts"].append("ultra"))
rc, o, e = run("validate")
check("G6b duplicate efforts -> valid with a warning (existing files stay usable)", rc == 0 and "duplicates" in e)
run("reset")
rc, o, e = run("model-info", "gpt-5.6-terra")
check("G7 model-info: host/default_effort/efforts", rc == 0 and o.split("\n")[:3] == ["codex", "xhigh", "low medium high xhigh max ultra"], o.strip().replace("\n", " / "))
check("G8 model-info unknown model -> rc 1 with guidance", run("model-info", "nope")[0] == 1 and "catalog" in run("model-info", "nope")[2])

# Newly declared efforts work through the CLI; removed defaults fail without writing.
for model, effort in (("gpt-6-astra", "max"), ("gpt-5.6-terra", "ultra")):
    run("reset")
    rc, o, e = run("set", "gate", "--model", model, "--effort", effort)
    check(f"G9 set accepts {model} at {effort}", rc == 0 and run("validate")[0] == 0
          and read_seats()["seats"]["gate"]["occupant"]["effort"] == effort, e.strip())
for model in ("gpt-6-astra", "gpt-5.6-luna", "gpt-5.6-terra"):
    run("reset")
    before = open(SEATS, "rb").read()
    rc, o, e = run("set", "gate", "--model", model, "--effort", "none")
    check(f"G9 fresh catalog refuses none for {model} without writing",
          rc == 1 and open(SEATS, "rb").read() == before and "not supported" in e, e.strip())

# ---------- C: conflict on the effective model (B5) ----------
run("reset")
check("C1 conflict: build with luna -> 0", run("conflict", "build", "gpt-5.6-luna")[1].strip() == "0")
check("C2 conflict: build effective astra (gate primary) -> 1", run("conflict", "@build", "gpt-6-astra")[1].strip() == "1")
check("C3 conflict: build effective terra (only a fallback) -> 0", run("conflict", "coding", "gpt-5.6-terra")[1].strip() == "0")
check("C4 conflict: non-build seat -> 0", run("conflict", "gate", "gpt-6-astra")[1].strip() == "0")
run("set", "@gate", "--host", "claude"); run("set", "@verify", "--host", "claude")
check("C5 conflict: reviewers on claude -> 0 even for astra", run("conflict", "build", "gpt-6-astra")[1].strip() == "0")
check("C6 conflict: unknown seat -> rc 1", run("conflict", "nope", "x")[0] == 1)
run("reset")
run("set", "@build", "--model", "gpt-6-astra")
rc, o, e = run("validate")
check("C7 shared primary model -> warning names gate_coding", rc == 0 and "gate_coding" in e and "@gate and @build share" in e)
run("reset")

# ---------- S: set option handling (F4/F5) ----------
before = sha(SEATS)
for label, argv in (("unknown option", ["set", "build", "--efort", "high"]),
                    ("--host=claude form", ["set", "gate", "--host=claude"]),
                    ("model on host-controlled", ["set", "spec", "--host", "claude", "--model", "gpt-6-astra"]),
                    ("--no-fallback with --fallback-model", ["set", "gate", "--no-fallback", "--fallback-model", "gpt-5.6-luna"]),
                    ("--fallback-effort without fallback", ["set", "build", "--no-fallback"], ),
                    ("empty host", ["set", "gate", "--host", ""]),
                    ("unsupported effort", ["set", "verify", "--effort", "turbo"]),
                    ("unknown model", ["set", "verify", "--model", "nope"]),
                    ("owner to codex", ["set", "@owner", "--host", "codex", "--model", "gpt-5.6-luna"]),
                    ("uppercase seat", ["set", "GATE", "--host", "claude"])):
    if label == "--fallback-effort without fallback":
        run(*argv)  # remove fallback first
        argv = ["set", "build", "--fallback-effort", "max"]
        before = sha(SEATS)
    rc, o, e = run(*argv)
    check(f"S1 set rejects {label}: rc 1, file unchanged, no traceback", rc == 1 and sha(SEATS) == before and no_traceback(e), (e.strip().splitlines() or [""])[-1])
run("reset")
rc, o, e = run("set", "@gate", "--host", "claude")
check("S2 set host claude drops model fields", rc == 0 and read_seats()["seats"]["gate"]["occupant"] == {"host": "claude"})
rc, o, e = run("set", "planning", "--host", "codex", "--model", "gpt-5.6-luna")
check("S3 set via route alias, model without effort -> catalog default", rc == 0 and read_seats()["seats"]["gate"]["occupant"]["effort"] == "xhigh")
mutate(lambda d: d["seats"]["gate"]["occupant"].__setitem__("effort", "turbo"))
rc, o, e = run("set", "gate", "--effort", "ultra", "--model", "gpt-6-astra")
check("S4 set repairs an invalid (structurally sound) file", rc == 0 and run("validate")[0] == 0, e.strip())
run("reset")

# ---------- M: malformed shapes never trace back (F3) ----------
shapes = [
    ("catalog is a list", lambda d: d.__setitem__("catalog", ["x"])),
    ("seat entry is a string", lambda d: d["seats"].__setitem__("gate", "x")),
    ("occupant is a list", lambda d: d["seats"]["gate"].__setitem__("occupant", [])),
    ("occupant is null", lambda d: d["seats"]["gate"].__setitem__("occupant", None)),
    ("missing seat", lambda d: d["seats"].pop("verify")),
    ("models is a list", lambda d: d["catalog"].__setitem__("models", [])),
]
for label, fn in shapes:
    run("reset"); mutate(fn)
    outs = [run(*c) for c in (["show"], ["validate"], ["model-info", "gpt-6-astra"], ["conflict", "build", "x"], ["resolve", "gate"], ["render"])]
    check(f"M1 {label}: every command rc 1 without traceback", all(r[0] == 1 and no_traceback(r[2]) for r in outs), "; ".join(f"{c}:{r[0]}" for c, r in zip(("show", "validate", "model-info", "conflict", "resolve", "render"), outs)))
with open(SEATS, "w", encoding="utf-8") as fh:
    fh.write("[]\n")
outs = [run(*c) for c in (["show"], ["validate"], ["resolve", "gate"])]
check("M2 top-level list: rc 1 without traceback", all(r[0] == 1 and no_traceback(r[2]) for r in outs))
run("reset")
# The entry an occupant points at is the one that gets dereferenced (gate attempt 3, F2).
for label, value in (("string", "xhigh"), ("list", ["xhigh"]), ("boolean", True)):
    run("reset")
    mutate(lambda d, v=value: d["catalog"]["models"].__setitem__("gpt-6-astra", v))
    before = sha(SEATS)
    cmds = (["show"], ["validate"], ["model-info", "gpt-6-astra"], ["conflict", "build", "gpt-6-astra"],
            ["resolve", "gate"], ["render"], ["set", "build", "--effort", "high"])
    outs = [run(*c) for c in cmds]
    check(f"M3 catalog entry for a seat's model is a {label}: rc 1, diagnostic not traceback, file kept",
          all(r[0] == 1 and no_traceback(r[2]) and "ERROR" in (r[1] + r[2]) for r in outs) and sha(SEATS) == before,
          "; ".join(f"{c[0]}:{r[0]}" for c, r in zip(cmds, outs)))
run("reset")

# ---------- P: malformed field access and command usage (R1-R3) ----------
run("reset")
mutate(lambda d: d["seats"]["gate"].pop("tag"))
seats_before = sha(SEATS); agents_before = open(AGENTS, "rb").read()
rc, o, e = run("show")
check("P1 missing gate.tag -> rc 1, clean diagnostic, no traceback or write",
      rc == 1 and no_traceback(e) and "ERROR" in e and "tag/phase" in e and sha(SEATS) == seats_before and open(AGENTS, "rb").read() == agents_before,
      e.strip())

run("reset")
mutate(lambda d: d["seats"]["gate"]["occupant"].__setitem__("model", ["gpt-6-astra"]))
seats_before = sha(SEATS); agents_before = open(AGENTS, "rb").read()
rc, o, e = run("conflict", "build", "gpt-6-astra")
check("P2 list gate model in conflict -> rc 1, clean diagnostic, no traceback or write",
      rc == 1 and no_traceback(e) and "ERROR" in e and "occupant.model" in e and sha(SEATS) == seats_before and open(AGENTS, "rb").read() == agents_before,
      e.strip())

run("reset")
mutate(lambda d: (d["seats"]["build"]["occupant"].__setitem__("model", ["gpt-5.6-luna"]), d["seats"]["build"]["occupant"].pop("effort")))
seats_before = sha(SEATS); agents_before = open(AGENTS, "rb").read()
rc, o, e = run("set", "build", "--fallback-effort", "high")
check("P3 list build model during repair -> rc 1, clean diagnostic, no traceback or write",
      rc == 1 and no_traceback(e) and "ERROR" in e and "occupant.model" in e and sha(SEATS) == seats_before and open(AGENTS, "rb").read() == agents_before,
      e.strip())

run("reset")
mutate(lambda d: d["seats"]["build"]["occupant"].__setitem__("effort", "high"))
invalid_commands = [
    ("show extra", ["show", "extra"]),
    ("validate extra", ["validate", "extra"]),
    ("suggest extra", ["suggest", "extra"]),
    ("wizard extra", ["wizard", "--yes", "extra"]),
    ("init extra", ["init", "extra"]),
    ("reset unknown option", ["reset", "--not-an-option"]),
    ("reset dry-run option", ["reset", "--dry-run"]),
    ("render extra", ["render", "extra"]),
    ("roster-block extra", ["roster-block", "extra"]),
    ("resolve extra", ["resolve", "gate", "extra"]),
    ("model-info extra", ["model-info", "gpt-6-astra", "extra"]),
    ("conflict extra", ["conflict", "build", "gpt-6-astra", "extra"]),
    ("set missing seat", ["set"]),
    ("set unknown option", ["set", "build", "--not-an-option", "high"]),
]
for label, argv in invalid_commands:
    seats_before = sha(SEATS); agents_before = open(AGENTS, "rb").read()
    rc, o, e = run(*argv)
    check(f"P4 {label} -> rc 1, no traceback or writes",
          rc == 1 and no_traceback(e) and "ERROR" in e and sha(SEATS) == seats_before and open(AGENTS, "rb").read() == agents_before,
          e.strip())

run("reset")
mutate(lambda d: d["catalog"]["models"]["gpt-6-astra"]["efforts"].append("ultra"))
with open(SCHEMA_SRC, encoding="utf-8") as fh:
    schema_doc = json.load(fh)
schema_efforts = schema_doc["$defs"]["catalogModel"]["properties"]["efforts"]
rc, o, e = run("validate")
check("P5 duplicate catalog effort is runtime warning and schema-permitted",
      rc == 0 and "duplicates" in e and "uniqueItems" not in schema_efforts,
      e.strip())
run("reset")

# ---------- R: renderer, atomic writes, filesystem failures (B6/R4/F1) ----------
write_agents(base)
rc, o, e = run("render")
after1 = open(AGENTS, "rb").read()
rc2, o2, e2 = run("render")
after2 = open(AGENTS, "rb").read()
check("R1 render appends block, preserves prefix bytes, idempotent", rc == 0 and rc2 == 0 and after1.startswith(base) and after1 == after2 and b"PRESERVE_USER_OVERLAY" in after2 and after2.count(b"BEGIN MANAGED: multi-agent-bootstrap:seat-roster") == 1)
run("set", "@build", "--effort", "high")
after3 = open(AGENTS, "rb").read()
check("R2 set re-renders only the block", after3.startswith(base) and b"@ high" in after3 and after3.count(b"seat-roster -->") == 2)
crlf = base.replace(b"\n", b"\r\n")
write_agents(crlf)
rc, o, e = run("render")
after = open(AGENTS, "rb").read()
check("R3 CRLF file keeps CRLF everywhere", rc == 0 and b"\n" not in after.replace(b"\r\n", b"") and after.startswith(crlf))
orphan = base + b"\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\nstale line\n"
write_agents(orphan)
rc, o, e = run("render"); s1 = open(AGENTS, "rb").read() == orphan
rc2, o2, e2 = run("render"); s2 = open(AGENTS, "rb").read() == orphan
check("R4 orphan BEGIN -> exit 3 twice, file untouched, overlay intact", rc == 3 and rc2 == 3 and s1 and s2)
dup = base + b"\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\nx\n<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->\n<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->\ny\n<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->\n"
write_agents(dup)
check("R5 duplicate blocks -> exit 3, untouched", run("render")[0] == 3 and open(AGENTS, "rb").read() == dup)
before = sha(SEATS)
rc, o, e = run("set", "@build", "--effort", "xhigh")
check("R6 set with broken markers -> seats written, exit 2, explicit message", rc == 2 and sha(SEATS) != before and "NOT rendered" in e)
write_agents(base); run("render")
# atomic write: a failing write must leave the old bytes. The size limit is applied
# to the interpreter that runs the seats program, never to the shell around it:
# Bash 3.2 spools a large heredoc through a temp file, so `ulimit -f` there fails
# before the program is even loaded (gate attempt 3, F3). SIGXFSZ is ignored so the
# write returns EFBIG and the program's own error handling is what gets tested.
# AGENTS.md is padded above the 4 KiB limit so that seats.json (~2 KiB) still writes.
write_agents(base + b"<!-- filler -->\n" + (b"filler line for the size limit test\n" * 300)); run("render")
agents_before = open(AGENTS, "rb").read(); seats_before = sha(SEATS)
p = fsize_limited_run(4096, "set", "build", "--effort", "high")
agents_after = open(AGENTS, "rb").read()
check("R7 failed AGENTS write (RLIMIT_FSIZE in the interpreter) -> rc 2, old AGENTS bytes intact, seats written, no traceback", p.returncode == 2 and agents_after == agents_before and sha(SEATS) != seats_before and no_traceback(p.stderr) and "NOT rendered" in p.stderr, (p.stderr.strip().splitlines() or [""])[-1])
run("reset")
seats_before = sha(SEATS); agents_before = open(AGENTS, "rb").read()
p = fsize_limited_run(1024, "set", "build", "--effort", "high")
check("R8 failed seats write (RLIMIT_FSIZE in the interpreter) -> rc 1, nothing written, no traceback", p.returncode == 1 and sha(SEATS) == seats_before and open(AGENTS, "rb").read() == agents_before and no_traceback(p.stderr) and "nothing written" in p.stderr, (p.stderr.strip().splitlines() or [""])[-1])
# symlink write-through
real = os.path.join(TARGET, "AGENTS.real.md")
shutil.copy(AGENTS, real); os.remove(AGENTS); os.symlink("AGENTS.real.md", AGENTS)
rc, o, e = run("set", "build", "--effort", "high")
check("R9 symlinked AGENTS.md is written through (link kept, target updated)", rc == 0 and os.path.islink(AGENTS) and b"@ high" in open(real, "rb").read())
os.remove(AGENTS); shutil.move(real, AGENTS)
if IS_ROOT:
    skip("R10 read-only AGENTS.md -> rc 2 with message", "running as root (permissions are not enforced)")
else:
    os.chmod(AGENTS, 0o444)
    rc, o, e = run("set", "build", "--effort", "xhigh")
    os.chmod(AGENTS, 0o644)
    check("R10 read-only AGENTS.md -> rc 2 with message, config changed", rc == 2 and "NOT rendered" in e and no_traceback(e) and read_seats()["seats"]["build"]["occupant"]["effort"] == "xhigh")
run("reset")

# ---------- K: locking (F2) ----------
procs = []
lost = 0
for i in range(20):
    a = subprocess.Popen([BASH, SCRIPT, "set", "spec", "--host", "gemini" if i % 2 else "cursor"], cwd=TARGET, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    b = subprocess.Popen([BASH, SCRIPT, "set", "audit", "--host", "cursor" if i % 2 else "gemini"], cwd=TARGET, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ra, rb = a.wait(), b.wait()
    d = read_seats()
    if ra == 0 and rb == 0 and not (d["seats"]["spec"]["occupant"]["host"] == ("gemini" if i % 2 else "cursor") and d["seats"]["audit"]["occupant"]["host"] == ("cursor" if i % 2 else "gemini")):
        lost += 1
check("K1 20 concurrent set pairs -> no lost updates", lost == 0, f"lost={lost}")
holder = subprocess.Popen([sys.executable, "-c", f"import fcntl,os,time; fd=os.open({CFG!r}, os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(3)"])
time.sleep(0.3)
t0 = time.monotonic(); rc, o, e = run("resolve", "gate"); t_read = time.monotonic() - t0
t0 = time.monotonic(); rc2, o2, e2 = run("set", "build", "--effort", "high"); t_set = time.monotonic() - t0
holder.wait()
check("K2a lock released within the wait window: reads unblocked, set waits then succeeds", rc == 0 and t_read < 2 and rc2 == 0 and 1.5 < t_set < 9, f"read={t_read:.1f}s set={t_set:.1f}s rc2={rc2}")
holder = subprocess.Popen([sys.executable, "-c", f"import fcntl,os,time; fd=os.open({CFG!r}, os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(13)"])
time.sleep(0.3)
before = sha(SEATS)
t0 = time.monotonic(); rc2, o2, e2 = run("set", "build", "--effort", "xhigh"); t_set = time.monotonic() - t0
holder.wait()
check("K2b lock held beyond the wait window: set refuses after ~10s, nothing written", rc2 == 1 and "in progress" in e2 and 9 < t_set < 14 and sha(SEATS) == before, f"set={t_set:.1f}s rc2={rc2}")
rc, o, e = run("init")
check("K3 init on a present file needs no lock (fast path)", rc == 0 and "nothing written" in o)
run("reset")
# A file that appears while init waits for the lock is never overwritten, and the
# recheck applies the same rules as the fast path (gate attempt 3, F1).
good = read_seats()
appearing = [
    ("valid", json.dumps(good, indent=2) + "\n", 0, "appeared while waiting"),
    ("invalid schema", json.dumps({**good, "seats": {**good["seats"], "gate": {**good["seats"]["gate"], "occupant": {"host": "codex", "model": "nope", "effort": "ultra"}}}}, indent=2) + "\n", 1, "does not overwrite"),
    ("malformed JSON", "{ malformed\n", 1, "does not overwrite"),
]
for label, payload, want_rc, want_msg in appearing:
    os.remove(SEATS)
    holder = subprocess.Popen([sys.executable, "-c", f"import fcntl,os,time; fd=os.open({CFG!r}, os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(3)"])
    time.sleep(0.3)
    proc = subprocess.Popen([BASH, SCRIPT, "init"], cwd=TARGET, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.6)
    with open(SEATS, "w", encoding="utf-8") as fh:
        fh.write(payload)
    o2, e2 = proc.communicate(timeout=30)
    holder.wait()
    kept = open(SEATS, encoding="utf-8").read()
    check(f"K4 {label} seats.json appears while init waits: rc {want_rc}, bytes kept, no traceback",
          proc.returncode == want_rc and kept == payload and no_traceback(e2) and want_msg in (o2 + e2),
          f"rc={proc.returncode} kept={kept == payload} msg={(e2 or o2).strip().splitlines()[-1:]}")
run("reset")

# ---------- W: wizard on a real PTY (B1/R3) ----------
answers = ["2", "2", "", "3", "",          # spec: host codex, model luna, effort keep, fallback terra, fb effort keep
           "", "", "", "", "",             # gate keep
           "", "1", "", "none",            # build: model astra (ultra), effort keep, fallback none
           "1",                            # verify: claude
           ""]                             # audit keep
rc, text, prompts = pty_wizard(answers, name="wizard-main")
d = read_seats()
check("W1 wizard on PTY: exact prompt count and rc 0", rc == 0 and prompts == 16 and "host>" in text, f"rc={rc} prompts={prompts}")
check("W2 non-default choices land in JSON (@spec codex luna xhigh fallback terra)", d["seats"]["spec"]["occupant"] == {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"}, json.dumps(d["seats"]["spec"]["occupant"]))
check("W3 Enter keeps suggestion (@gate astra ultra)", d["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra" and d["seats"]["gate"]["occupant"]["effort"] == "ultra")
check("W4 model change adopts default effort; 'none' drops fallback (@build astra ultra)", d["seats"]["build"]["occupant"] == {"host": "codex", "model": "gpt-6-astra", "effort": "ultra"})
check("W5 host change to claude drops model (@verify)", d["seats"]["verify"]["occupant"] == {"host": "claude"})
run("reset")
rc, text, prompts = pty_wizard(["", "2", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""], name="wizard-same-host")
check("W6 re-choosing the same host keeps the suggested model", rc == 0 and read_seats()["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra")
for label, ans, expect_prompts in (("host 99", ["99"], 1), ("model 99", ["", "", "99"], 3), ("fallback 99", ["", "", "", "", "99"], 5), ("fallback by name", ["", "", "", "", "gpt-5.6-luna"], 5), ("host letter", ["x"], 1)):
    run("reset"); before = sha(SEATS)
    rc, text, prompts = pty_wizard(ans, name=f"wizard-invalid-{label}")
    check(f"W7 invalid choice ({label}) -> rc 1 at prompt {expect_prompts}, nothing written", rc == 1 and prompts == expect_prompts and sha(SEATS) == before and "nothing written" in text, f"rc={rc} prompts={prompts}")
run("reset"); before = sha(SEATS)
rc, text, prompts = pty_wizard(["", "", "", "turbo"], name="wizard-bad-effort")
check("W8 invalid interactive effort -> rc 1, nothing written", rc == 1 and sha(SEATS) == before, f"rc={rc}")
run("reset"); before = sha(SEATS)
rc, text, prompts = pty_wizard(["<EOF>"], name="wizard-eof")
check("W9 Ctrl-D aborts the wizard: rc 1, nothing written", rc == 1 and sha(SEATS) == before and "nothing written" in text, f"rc={rc}")
run("reset"); before = sha(SEATS)
rc, text, prompts = pty_wizard([], name="wizard-sigint", signal_at_prompt=1)
check("W10 Ctrl-C at a prompt -> rc 130, nothing written, no traceback", rc == 130 and sha(SEATS) == before and "Traceback" not in text, f"rc={rc}")
run("reset")
mutate(lambda d: [s.pop("duty", None) for s in d["seats"].values()])
rc, text, prompts = pty_wizard([""] * 17, name="wizard-no-duty")
check("W11 seats.json without duty keys (spec example shape) runs the wizard (17 prompts, all Enter)", rc == 0 and prompts == 17, f"rc={rc} prompts={prompts}")
run("reset")
mutate(lambda d: (d["catalog"].__setitem__("models", {"m1": {"host": "claude", "efforts": ["x"], "default_effort": "x"}}), [d["seats"][s].__setitem__("occupant", {"host": "claude"}) for s in ("gate", "build", "verify")]))
before = sha(SEATS)
rc, text, prompts = pty_wizard(["2"], name="wizard-no-codex-model")
check("W12 catalog without a codex model + host codex -> rc 1, nothing written, no traceback", rc == 1 and sha(SEATS) == before and "Traceback" not in text, f"rc={rc}")
run("reset")
rc, o, e = run("wizard")
check("W13 non-TTY wizard without --yes accepts suggestions", rc == 0)
rc, text, prompts = pty_run(["wizard", "--yes"], [], timeout=10, name="wizard-yes-pty")
check("W14 wizard --yes on a PTY never prompts", rc == 0 and prompts == 0)

# ---------- cleanup ----------
write_agents(agents_original)
run("reset")
failed = [r for r in results if not r["ok"]]
summary = {"target": TARGET, "bash": BASH, "script_sha256": sha(SCRIPT_SRC), "checks": results, "passed": len(results) - len(failed), "failed": len(failed), "skipped": len([r for r in results if r.get("skipped")])}
if OUT:
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
print(f"\n{summary['passed']} passed, {summary['failed']} failed, {summary['skipped']} skipped")
sys.exit(1 if failed else 0)
