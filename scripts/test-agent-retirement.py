#!/usr/bin/env python3
"""HK-07 retirement lifecycle acceptance tests (R1-R14).

Every case runs through a public boundary: the bundle bootstrap entrypoint, an
installed canonical home, the updater or the one-shot upgrader, against
disposable Git and non-Git targets. Fault injection uses a test-only wrapper
that imports the bundled engine and patches its own operations; the shipped
engine has no switch that weakens containment, hashing or backups. Historical
bytes come from the HK-06 immutable v2026.08.10.1 selector, never from current
output. Independent cases run in parallel; each owns its disposable directory.

Tiers: `fast` (default) runs everything except real one-shot upgrades, whose
dry-run cases stay included; `one-shot` runs only the real one-shot upgrades
(about two minutes each, invoked by scripts/test-one-shot-upgrade.sh); `all`
runs both.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from urllib.parse import urljoin

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "agent-bootstrap"
# A release renames the shipped migrations from next-<slug> to <version>-<slug>.
_RETIRE = sorted((BUNDLE / "migrations").glob("*-retire-files.sh"))
RETIRE_ID = _RETIRE[0].stem if _RETIRE else "next-retire-files"
ONE_SHOT = BUNDLE / "harness-kit-one-shot-upgrade.sh"
WORKFLOW = ".github/workflows/agent-guard.yml"
TEMPLATE = "docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml"
PATHS = (WORKFLOW, TEMPLATE)
IDS = ("agent-guard-workflow", "agent-guard-template")
SIZE = 605
DIGEST = "751c8c3f88fd1fc3bcc5c1ddff940e1280b1a5149c787d3110a4408a39810ebb"
HIST_REF = "v2026.08.10.1"
HIST_COMMIT = "b1907f5fe7caf9d9e401606a93fa0815739b6df0"
POLICY_ID = "hk07-agent-guard/v1"
RETIREMENT_ID = "https://agent-bootstrap.local/schemas/agent-bootstrap-retirement-v1.schema.json"
STATUS_V1_ID = "https://agent-bootstrap.local/schemas/agent-bootstrap-status-v1.schema.json"
STATUS_V2_ID = "https://agent-bootstrap.local/schemas/agent-bootstrap-status-v2.schema.json"
RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$")
STATES = ("absent", "eligible", "modified", "unsafe-type", "error")
RESULTS = ("planned", "retired", "preserved", "unchanged", "error", "not-attempted")
VERSION = (BUNDLE / "VERSION").read_text().strip()
IS_ROOT = hasattr(os, "geteuid") and os.geteuid() == 0

WORK = None
WORK_RAW = None
ENV = None
HIST = None
HIST_TARGET = None
SCHEMAS = None
INJECT = None
PY_SHIM_DIR = None
GIT_SHIM_DIR = None
COVERAGE = {"states": set(), "results": set()}
SHARED = {}
COVERAGE_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# Generic helpers


class Case:
    def __init__(self, name):
        self.name = name
        self.results = []
        self.elapsed = 0.0

    def check(self, label, ok, detail=""):
        self.results.append((label, bool(ok), "" if ok else str(detail)[:2000]))
        return bool(ok)

    @property
    def failed(self):
        return [item for item in self.results if not item[1]]


def run(argv, cwd=None, env=None, timeout=900, stdin=None):
    return subprocess.run([str(a) for a in argv], cwd=cwd, env=env or ENV, capture_output=True,
                          encoding="utf-8", errors="backslashreplace", timeout=timeout,
                          stdin=stdin if stdin is not None else subprocess.DEVNULL)


def run_ok(argv, cwd=None, env=None):
    proc = run(argv, cwd=cwd, env=env)
    if proc.returncode != 0:
        raise AssertionError(f"command failed rc={proc.returncode}: {argv}\n{proc.stderr[-2000:]}")
    return proc


def boot(target, *args, bundle=BUNDLE, env=None, timeout=900):
    return run(["/bin/bash", bundle / "bootstrap-multi-agent-project.sh", "--target", target, *args],
               env=env, timeout=timeout)


def engine(*args, bundle=BUNDLE, env=None):
    return run([sys.executable, "-I", bundle / "lib/retirement.py", *args], env=env, timeout=120)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    with open(path, "rb") as handle:
        return sha(handle.read())


def put(path, data, mode=0o640, mtime=1_700_000_000):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.chmod(path, mode)
    os.utime(path, (mtime, mtime))


def ident(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(st.st_mode):
        return ("link", os.readlink(path), st.st_ino)
    if stat.S_ISREG(st.st_mode):
        return ("file", sha_file(path), stat.S_IMODE(st.st_mode), st.st_mtime_ns, st.st_ino, st.st_nlink, st.st_size)
    if stat.S_ISDIR(st.st_mode):
        return ("dir", stat.S_IMODE(st.st_mode), st.st_ino, st.st_mtime_ns)
    return ("other", stat.S_IFMT(st.st_mode), st.st_ino, st.st_mtime_ns)


def tree(root, dir_mtime=True):
    """Metadata/bytes/link identity of every entry except the .git subtree."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            dirnames[:] = [d for d in dirnames if d != ".git"]
            filenames = [f for f in filenames if f != ".git"]
        for name in dirnames + filenames:
            rel = os.path.normpath(os.path.join(rel_dir, name))
            value = ident(os.path.join(dirpath, name))
            if value and value[0] == "dir" and not dir_mtime:
                value = value[:3]
            out[rel] = value
    return out


def tree_delta(before, after):
    removed = sorted(set(before) - set(after))
    added = sorted(set(after) - set(before))
    changed = sorted(k for k in set(before) & set(after) if before[k] != after[k])
    return removed, added, changed


def init_git(path, commit_readme=True):
    run_ok(["git", "init", "-q", path])
    if commit_readme:
        (Path(path) / "README.md").write_text("# Disposable project\n")
        run_ok(["git", "-C", path, "add", "README.md"])
        run_ok(["git", "-C", path, "commit", "-q", "-m", "seed"])


def synth(path, git=True, ignore=True, files=PATHS, data=None):
    """Small target holding the verified historical bytes at retired paths."""
    path = Path(path)
    path.mkdir(parents=True)
    if git:
        init_git(path)
        if ignore:
            (path / ".gitignore").write_text("".join(p + "\n" for p in PATHS))
    for rel in files:
        put(path / rel, HIST if data is None else data)
    return path


def copy_target(src, dst):
    shutil.copytree(src, dst, symlinks=True)
    return Path(dst)


def strict_json(c, label, proc):
    out = proc.stdout
    doc = None
    try:
        doc = json.loads(out)
    except ValueError:
        pass
    ok = out.endswith("\n") and out.count("\n") == 1 and isinstance(doc, dict)
    c.check(f"{label}: stdout is exactly one JSON object and newline", ok, out[:400] + proc.stderr[-400:])
    return doc if isinstance(doc, dict) else None


def note_coverage(report):
    with COVERAGE_LOCK:
        for entry in report.get("entries", []):
            for obs in (entry.get("observed"), entry.get("after")):
                if isinstance(obs, dict):
                    COVERAGE["states"].add(obs.get("status"))
            COVERAGE["results"].add(entry.get("result"))


def expected_action(observed, scope):
    if observed["status"] == "absent":
        return "none"
    allowed = ("local-only",) if scope == "local-only" else ("local-only", "project-owned")
    if observed["status"] == "eligible" and observed["ownership"] in allowed:
        return "retire"
    return "preserve"


def invariants(report):
    errs = []
    entries = report.get("entries", [])
    if [(e.get("id"), e.get("path")) for e in entries] != list(zip(IDS, PATHS)):
        errs.append("entries are not the two inventory rows in order")
        return errs
    summary = report["summary"]
    states = {s: 0 for s in STATES}
    results = {r: 0 for r in RESULTS}
    for entry in entries:
        states[(entry["after"] or entry["observed"])["status"]] += 1
        results[entry["result"]] += 1
        if entry["action"] != expected_action(entry["observed"], report["scope"]):
            errs.append(f"{entry['id']}: action {entry['action']} does not follow observation/scope")
        if entry["backup"] is not None and report["run_id"] and not entry["backup"].endswith(".bak.retirement." + report["run_id"]):
            errs.append(f"{entry['id']}: backup is not named with the run id")
    if summary["states"] != states:
        errs.append(f"state counts {summary['states']} != {states}")
    if summary["results"] != results:
        errs.append(f"result counts {summary['results']} != {results}")
    stale = sum(len(e["stale_candidates"]) for e in entries)
    incomplete = sum(e["candidate_scan"] != "complete" for e in entries)
    if summary["stale_candidate_count"] != stale or summary["incomplete_candidate_scans"] != incomplete:
        errs.append("candidate counts disagree with entries")
    attention = (any(states[s] for s in ("eligible", "modified", "unsafe-type", "error")) or stale > 0
                 or incomplete > 0 or bool(report["errors"]))
    if summary["attention_required"] != attention:
        errs.append("attention_required disagrees with states/candidates/errors")
    if report["mode"] in ("plan", "status") and report["run_id"] is not None:
        errs.append("plan/status carries a run id")
    if report["mode"] == "apply" and not RUN_ID_RE.match(report["run_id"] or ""):
        errs.append("apply lacks a well-formed run id")
    if report["target"] != os.path.realpath(report["target"]):
        errs.append("target is not canonical")
    return errs


def validate_report(c, label, report, schema_id=RETIREMENT_ID):
    if report is None:
        return
    if SCHEMAS is None:
        c.check(f"{label}: schemas available", False, "schema files could not be loaded")
        return
    errors = SCHEMAS.validate(report, schema_id)
    c.check(f"{label}: matches {schema_id.rsplit('/', 1)[-1]}", not errors, "; ".join(errors[:6]))
    retirement = report.get("retirement") if schema_id == STATUS_V2_ID else report
    if isinstance(retirement, dict) and schema_id != STATUS_V1_ID:
        inv = invariants(retirement)
        c.check(f"{label}: report invariants", not inv, "; ".join(inv))
        note_coverage(retirement)


def jrun(c, label, target, *args, bundle=BUNDLE, expect=0, env=None):
    proc = boot(target, *args, "--json", bundle=bundle, env=env)
    c.check(f"{label}: exit {expect}", proc.returncode == expect, f"rc={proc.returncode}\n{proc.stdout[-600:]}\n{proc.stderr[-1200:]}")
    report = strict_json(c, label, proc)
    validate_report(c, label, report)
    if expect in (0, 3):
        c.check(f"{label}: no stderr diagnostics", proc.stderr == "", proc.stderr[-800:])
    return report, proc


def entry(report, rel):
    if not report:
        return {}
    for item in report.get("entries", []):
        if item.get("path") == rel:
            return item
    return {}


def backups(target, rel):
    parent = (Path(target) / rel).parent
    name = Path(rel).name + ".bak.retirement."
    try:
        return sorted(p.name for p in parent.iterdir() if p.name.startswith(name))
    except OSError:
        return []


def restore_tree_permissions(root):
    for dirpath, dirnames, _ in os.walk(root):
        for name in dirnames:
            path = os.path.join(dirpath, name)
            try:
                if not os.path.islink(path):
                    os.chmod(path, 0o755)
            except OSError:
                pass


def inject(c, label, target, plan, *args, bundle=BUNDLE, expect=None):
    plan = dict(plan)
    plan.setdefault("hist", HIST.hex())
    proc = run([sys.executable, "-I", INJECT, bundle / "lib/retirement.py", json.dumps(plan),
                "apply", "--target", target, "--json", *args], timeout=120)
    if expect is not None:
        c.check(f"{label}: exit {expect}", proc.returncode == expect, f"rc={proc.returncode}\n{proc.stdout[-500:]}\n{proc.stderr[-1500:]}")
    report = strict_json(c, label, proc)
    validate_report(c, label, report)
    return report, proc


INJECT_SOURCE = r'''
import errno, importlib.util, json, os, signal, stat, subprocess, sys
sys.dont_write_bytecode = True
engine_path, plan = sys.argv[1], json.loads(sys.argv[2])
argv = sys.argv[3:]
target = argv[argv.index("--target") + 1]
spec = importlib.util.spec_from_file_location("retirement_under_test", engine_path)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
hist = bytes.fromhex(plan.get("hist", ""))
armed = set()

def write(path, data):
    with open(path, "wb") as handle:
        handle.write(data)

def act(kind, rel, arg=None):
    path = os.path.join(target, rel)
    if kind == "flip":
        with open(path, "r+b") as handle:
            first = handle.read(1)
            handle.seek(0)
            handle.write(bytes([first[0] ^ 1]))
    elif kind == "replace":
        write(path + ".swap", hist)
        os.rename(path + ".swap", path)
    elif kind == "symlink":
        os.unlink(path)
        os.symlink(arg, path)
    elif kind == "remove":
        os.unlink(path)
    elif kind == "swap-parent":
        parent = os.path.dirname(path)
        os.rename(parent, parent + ".moved")
        os.mkdir(parent)
        write(path, hist)
    elif kind == "track":
        subprocess.run(["git", "-C", target, "add", "-f", "--", rel], check=True)
    elif kind == "create":
        write(path, b"collision\n")
    elif kind == "signal":
        os.kill(os.getpid(), getattr(signal, arg))
    elif kind == "arm":
        armed.add(arg)
    else:
        raise SystemExit("unknown barrier action " + kind)

barriers = plan.get("barriers", {})
def barrier(stage, entry_id):
    for step in barriers.get(stage + ":" + entry_id, []):
        act(*step)
engine._barrier = barrier
if plan.get("run_ids"):
    ids = list(plan["run_ids"])
    engine._new_run_id = lambda: ids.pop(0)

faults = set(plan.get("faults", []))
def on(name):
    return name in faults or name in armed
excl = set()
counts = {"write": 0}
real_open, real_write, real_fsync, real_close, real_unlink = os.open, os.write, os.fsync, os.close, os.unlink
def fake_open(path, flags, mode=0o777, *, dir_fd=None):
    fd = real_open(path, flags, mode, dir_fd=dir_fd)
    if flags & os.O_EXCL:
        excl.add(fd)
    return fd
def fake_write(fd, data):
    if on("short-write") and fd in excl:
        counts["write"] += 1
        if counts["write"] == 1:
            return real_write(fd, bytes(data[:100]))
        raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
    return real_write(fd, data)
def fake_fsync(fd):
    if on("fsync-backup") and fd in excl:
        raise OSError(errno.EIO, os.strerror(errno.EIO))
    if on("dir-flush") and stat.S_ISDIR(os.fstat(fd).st_mode):
        raise OSError(errno.EIO, os.strerror(errno.EIO))
    return real_fsync(fd)
def fake_close(fd):
    real_close(fd)
    if fd in excl:
        excl.discard(fd)
        if on("close-backup"):
            raise OSError(errno.EIO, os.strerror(errno.EIO))
def fake_unlink(path, *, dir_fd=None):
    if on("unlink"):
        raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
    return real_unlink(path, dir_fd=dir_fd)
os.open, os.write, os.fsync, os.close, os.unlink = fake_open, fake_write, fake_fsync, fake_close, fake_unlink
sys.exit(engine.main(argv))
'''


# --------------------------------------------------------------------------
# Minimal JSON Schema 2020-12 validator for the keywords these contracts use.


def json_equal(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(json_equal(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def type_ok(value, name):
    return {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "string": isinstance(value, str),
        "array": isinstance(value, list),
        "object": isinstance(value, dict),
    }[name]


class Schemas:
    def __init__(self, paths):
        self.by_id = {}
        for path in paths:
            doc = json.loads(Path(path).read_text(encoding="utf-8"))
            if doc.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
                raise AssertionError(f"{path} is not a 2020-12 schema")
            self.by_id[doc["$id"]] = doc

    def validate(self, instance, schema_id):
        errors = []
        self._v(instance, self.by_id[schema_id], schema_id, "$", errors)
        return errors

    def _errs(self, value, schema, base):
        errors = []
        self._v(value, schema, base, "", errors)
        return errors

    def _resolve(self, ref, base):
        url, _, fragment = urljoin(base, ref).partition("#")
        node = self.by_id[url]
        for part in [p for p in fragment.split("/") if p]:
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return node, url

    def _v(self, value, schema, base, where, errs):
        if schema is True:
            return
        if schema is False:
            errs.append(f"{where}: not allowed")
            return
        base = schema.get("$id", base)
        if "$ref" in schema:
            node, node_base = self._resolve(schema["$ref"], base)
            self._v(value, node, node_base, where, errs)
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(type_ok(value, name) for name in names):
                errs.append(f"{where}: expected {schema['type']}")
                return
        if "const" in schema and not json_equal(value, schema["const"]):
            errs.append(f"{where}: expected const {schema['const']!r}, got {value!r}")
        if "enum" in schema and not any(json_equal(value, item) for item in schema["enum"]):
            errs.append(f"{where}: {value!r} not in enum")
        if isinstance(value, dict):
            for key in schema.get("required", []):
                if key not in value:
                    errs.append(f"{where}: missing {key}")
            props = schema.get("properties", {})
            for key, item in value.items():
                if key in props:
                    self._v(item, props[key], base, f"{where}.{key}", errs)
                elif "additionalProperties" in schema:
                    self._v(item, schema["additionalProperties"], base, f"{where}.{key}", errs)
        if isinstance(value, list):
            prefix = schema.get("prefixItems", [])
            for index, item in enumerate(value):
                if index < len(prefix):
                    self._v(item, prefix[index], base, f"{where}[{index}]", errs)
                elif "items" in schema:
                    self._v(item, schema["items"], base, f"{where}[{index}]", errs)
            if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
                errs.append(f"{where}: array length {len(value)}")
        if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
            errs.append(f"{where}: {value!r} does not match {schema['pattern']}")
        if type_ok(value, "number") and "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{where}: below minimum")
        for sub in schema.get("allOf", []):
            self._v(value, sub, base, where, errs)
        if "anyOf" in schema and all(self._errs(value, sub, base) for sub in schema["anyOf"]):
            errs.append(f"{where}: no anyOf branch matched")
        if "oneOf" in schema and sum(not self._errs(value, sub, base) for sub in schema["oneOf"]) != 1:
            errs.append(f"{where}: oneOf did not match exactly one branch")
        if "not" in schema and not self._errs(value, schema["not"], base):
            errs.append(f"{where}: matched a forbidden schema")
        if "if" in schema:
            if not self._errs(value, schema["if"], base):
                if "then" in schema:
                    self._v(value, schema["then"], base, where, errs)
            elif "else" in schema:
                self._v(value, schema["else"], base, where, errs)


# --------------------------------------------------------------------------
# Historical fixture (R1)


def load_historical_bundle(selector):
    path = ROOT / "scripts/test-agent-seats-migration.py"
    spec = importlib.util.spec_from_file_location("hk06_historical_selector", path)
    selector_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(selector_module)
    selector_module.configure(["--source-dir", str(ROOT), "--legacy-ref", HIST_REF,
                               "--historical-source", selector, "--evidence-dir", str(WORK / "hk06-evidence")])
    try:
        old = selector_module.historical_export(HIST_REF)
        dest = WORK / "historical-bundle"
        shutil.copytree(old, dest, symlinks=True)
        provenance = list(selector_module.historical_provenance)
    finally:
        shutil.rmtree(selector_module.WORK, ignore_errors=True)
    return dest, provenance


def prepare_historical(c, selector):
    global HIST, HIST_TARGET
    old, provenance = load_historical_bundle(selector)
    c.check("historical selector pinned the immutable commit",
            provenance and provenance[0]["commit"] == HIST_COMMIT, provenance)
    source_bytes = (old / "agent-bootstrap/templates/ci/agent-guard.yml").read_bytes()
    target = WORK / "historical-target"
    target.mkdir()
    init_git(target)
    run_ok(["/bin/bash", old / "agent-bootstrap/bootstrap-multi-agent-project.sh", "--target", target, "--workflow", "full"])
    for rel in PATHS:
        data = (target / rel).read_bytes()
        c.check(f"R1 historical generated {rel} is {SIZE} bytes", len(data) == SIZE, len(data))
        c.check(f"R1 historical generated {rel} has the pinned digest", sha(data) == DIGEST, sha(data))
        c.check(f"R1 historical {rel} equals the source template bytes", data == source_bytes)
    HIST = (target / WORKFLOW).read_bytes()
    HIST_TARGET = target


# --------------------------------------------------------------------------
# Fast cases: dedicated actions and the bundled engine


def case_r1_policy(c, work, bundle=BUNDLE):
    policy_path = bundle / "policies/retired-artifacts-v1.json"
    raw = policy_path.read_bytes()
    doc = json.loads(raw)
    c.check("R1 bundled policy is the closed two-entry inventory",
            doc.get("schema") == "agent-bootstrap-retired-artifacts/v1" and doc.get("policy_id") == POLICY_ID
            and [(a.get("id"), a.get("path")) for a in doc.get("artifacts", [])] == list(zip(IDS, PATHS)), doc)
    for artifact in doc.get("artifacts", []):
        c.check(f"R1 {artifact.get('id')} fingerprint pins source commit/size/digest",
                artifact.get("fingerprints") == [{"source_ref": HIST_REF, "source_commit": HIST_COMMIT,
                                                  "source_path": "agent-bootstrap/templates/ci/agent-guard.yml",
                                                  "size_bytes": SIZE, "sha256": DIGEST}]
                and artifact.get("reason") == "generated-remote-ci-retired", artifact)
    target = synth(work / "r1-target")
    report, _ = jrun(c, "R1 bundled plan", target, "--retirement-plan")
    c.check("R1 report policy digest is the bundled file digest", report and report["policy_sha256"] == sha(raw))

    def mutate(name, change=None, text=None):
        mutant = work / ("policy-" + name) / "agent-bootstrap"
        shutil.copytree(bundle, mutant, symlinks=True)
        doc2 = json.loads(raw)
        if change:
            change(doc2)
        body = text if text is not None else json.dumps(doc2, indent=2) + "\n"
        (mutant / "policies/retired-artifacts-v1.json").write_text(body)
        return mutant, body.encode()

    first = json.loads(raw)["artifacts"][0]
    cases = {
        "third-path": lambda d: d["artifacts"].append(dict(first, id="extra-workflow", path=".github/workflows/ci.yml")),
        "wrong-digest": lambda d: d["artifacts"][0]["fingerprints"][0].__setitem__("sha256", "0" * 64),
        "extra-digest": lambda d: d["artifacts"][0]["fingerprints"].append(dict(first["fingerprints"][0], sha256="1" * 64)),
        "alias-path": lambda d: d["artifacts"][0].__setitem__("path", "./.github/workflows/agent-guard.yml"),
        "absolute-path": lambda d: d["artifacts"][0].__setitem__("path", "/etc/agent-guard.yml"),
        "traversal-path": lambda d: d["artifacts"][1].__setitem__("path", "docs/../.github/workflows/agent-guard.yml"),
        "glob-path": lambda d: d["artifacts"][0].__setitem__("path", ".github/workflows/*.yml"),
        "unknown-field": lambda d: d["artifacts"][1].__setitem__("owner", "anyone"),
        "duplicate-entry": lambda d: d["artifacts"].__setitem__(1, json.loads(json.dumps(d["artifacts"][0]))),
        "unsupported-version": lambda d: d.__setitem__("schema", "agent-bootstrap-retired-artifacts/v2"),
        "float-size": lambda d: d["artifacts"][0]["fingerprints"][0].__setitem__("size_bytes", 605.0),
        "bad-digest-encoding": lambda d: d["artifacts"][0]["fingerprints"][0].__setitem__("sha256", DIGEST.upper()),
    }
    for name, change in list(cases.items()) + [("duplicate-key", None)]:
        text = None
        if name == "duplicate-key":
            text = raw.decode().replace('"policy_id"', '"policy_id": "shadow",\n  "policy_id"', 1)
        mutant, body = mutate(name, change, text)
        tgt = synth(work / ("r1-" + name))
        before = tree(tgt)
        report, _ = jrun(c, f"R1 {name} plan", tgt, "--retirement-plan", bundle=mutant, expect=1)
        c.check(f"R1 {name}: policy-invalid error", report and [e["code"] for e in report["errors"]][:1] == ["policy-invalid"],
                report and report["errors"])
        c.check(f"R1 {name}: entries are pinned rows in error", report and all(
            e["observed"]["status"] == "error" and e["observed"]["reason"] == "invalid-policy" for e in report["entries"]))
        c.check(f"R1 {name}: digest reports the invalid file", report and report["policy_sha256"] == sha(body))
        jrun(c, f"R1 {name} apply", tgt, "--apply-retirements", "--retirement-scope", "all-matching", bundle=mutant, expect=1)
        human = boot(tgt, "--apply-retirements", bundle=mutant)
        c.check(f"R1 {name}: human apply exits 1", human.returncode == 1, human.returncode)
        c.check(f"R1 {name}: invalid inventory stops before writes", tree(tgt) == before)

    tgt = synth(work / "r1-override")
    before = tree(tgt)
    for flag in ("--retirement-policy", "--retirement-inventory", "--retired-path"):
        proc = boot(tgt, "--apply-retirements", flag, str(tgt / WORKFLOW))
        c.check(f"R1 no CLI inventory override {flag}", proc.returncode == 2 and proc.stdout == "", proc.returncode)
    hostile, _ = mutate("environment", cases["third-path"])
    env = dict(ENV, AGENT_BOOTSTRAP_RETIREMENT_POLICY=str(hostile / "policies/retired-artifacts-v1.json"),
               AGENT_BOOTSTRAP_RETIRED_ARTIFACTS=str(hostile / "policies/retired-artifacts-v1.json"))
    report, _ = jrun(c, "R1 environment cannot select a policy", tgt, "--retirement-plan", env=env)
    c.check("R1 environment policy is ignored", report and report["policy_sha256"] == sha(raw))
    c.check("R1 override attempts wrote nothing", tree(tgt) == before)


def case_r3_local_only(c, work, bundle=BUNDLE):
    target = synth(work / "r3-local")
    before = {rel: ident(target / rel) for rel in PATHS}
    index_before = ident(target / ".git/index")
    plan, _ = jrun(c, "R3 local-only plan", target, "--retirement-plan", bundle=bundle)
    for rel in PATHS:
        e = entry(plan, rel)
        c.check(f"R3 plan {rel} eligible local-only retire", e.get("observed", {}).get("status") == "eligible"
                and e["observed"].get("ownership") == "local-only" and e.get("action") == "retire", e)
    c.check("R3 plan does not refresh the Git index", ident(target / ".git/index") == index_before)
    report, _ = jrun(c, "R3 local-only apply", target, "--apply-retirements", bundle=bundle)
    for rel in PATHS:
        e = entry(report, rel)
        c.check(f"R3 {rel} retired with absent after-state", e.get("result") == "retired"
                and (e.get("after") or {}).get("status") == "absent", e)
        c.check(f"R3 {rel} removed", ident(target / rel) is None)
        backup = target / e["backup"] if e.get("backup") else None
        c.check(f"R3 {rel} mandatory backup holds verified bytes", backup and backup.is_file()
                and backup.read_bytes() == HIST, e.get("backup"))
        if backup and backup.is_file():
            st = os.lstat(backup)
            c.check(f"R3 {rel} backup keeps mode and mtime", (stat.S_IMODE(st.st_mode), st.st_mtime_ns)
                    == (before[rel][2], before[rel][3]))
            c.check(f"R3 {rel} backup is adjacent with run-id name",
                    e["backup"] == rel + ".bak.retirement." + report["run_id"])
    c.check("R3 .gitignore untouched", (target / ".gitignore").read_text() == "".join(p + "\n" for p in PATHS))


def case_r3_project_owned(c, work, bundle=BUNDLE):
    target = synth(work / "r3-tracked")
    run_ok(["git", "-C", target, "add", "-f", "--", *PATHS])
    run_ok(["git", "-C", target, "commit", "-q", "-m", "track retired files"])
    before = tree(target)
    plan, _ = jrun(c, "R3 tracked plan", target, "--retirement-plan", bundle=bundle)
    c.check("R3 tracked files are project-owned", all(entry(plan, rel).get("observed", {}).get("ownership") == "project-owned"
                                                     for rel in PATHS), plan and plan["entries"])
    report, _ = jrun(c, "R3 tracked default apply", target, "--apply-retirements", bundle=bundle, expect=3)
    c.check("R3 tracked default apply preserves both", report and [e["result"] for e in report["entries"]] == ["preserved", "preserved"])
    c.check("R3 default scope wrote nothing for project-owned files", tree(target) == before)
    scope_plan, _ = jrun(c, "R3 scope plan alone", target, "--retirement-plan", "--retirement-scope", "all-matching", bundle=bundle)
    c.check("R3 scope plan proposes retire", scope_plan and [e["action"] for e in scope_plan["entries"]] == ["retire", "retire"])
    c.check("R3 scope flag alone does not delete", tree(target) == before)
    report, _ = jrun(c, "R3 all-matching apply", target, "--apply-retirements", "--retirement-scope", "all-matching", bundle=bundle)
    c.check("R3 all-matching retires project-owned exact files", report and [e["result"] for e in report["entries"]] == ["retired", "retired"])
    staged = run(["git", "-C", target, "ls-files", "--stage", "--", *PATHS]).stdout
    c.check("R3 retirement leaves the Git index untouched", all(rel in staged for rel in PATHS), staged)
    status = run(["git", "-C", target, "status", "--porcelain"]).stdout
    c.check("R3 deletion is left for the owner to commit", all(" D " + rel in status for rel in PATHS), status)


def case_r3_untracked_unignored(c, work, bundle=BUNDLE):
    target = synth(work / "r3-unignored", ignore=False)
    plan, _ = jrun(c, "R3 unignored plan", target, "--retirement-plan", bundle=bundle)
    c.check("R3 untracked unignored is project-owned", plan and all(
        e["observed"]["ownership"] == "project-owned" and e["action"] == "preserve" for e in plan["entries"]))
    jrun(c, "R3 unignored default apply", target, "--apply-retirements", bundle=bundle, expect=3)
    c.check("R3 unignored files kept", all(ident(target / rel) for rel in PATHS))


def case_r3_non_git(c, work, bundle=BUNDLE):
    target = synth(work / "r3-plain", git=False)
    before = tree(target)
    plan, _ = jrun(c, "R3 non-Git plan", target, "--retirement-plan", bundle=bundle)
    c.check("R3 non-Git target is project-owned", plan and all(e["observed"]["ownership"] == "project-owned" for e in plan["entries"]))
    jrun(c, "R3 non-Git default apply", target, "--apply-retirements", bundle=bundle, expect=3)
    c.check("R3 non-Git default apply wrote nothing", tree(target) == before)
    dry, _ = jrun(c, "R3 non-Git dry-run", target, "--apply-retirements", "--dry-run", "--retirement-scope", "all-matching", bundle=bundle)
    c.check("R3 dry-run is a plan report", dry and dry["mode"] == "plan" and dry["dry_run"] is True and dry["run_id"] is None)
    c.check("R3 dry-run wrote nothing", tree(target) == before)
    report, _ = jrun(c, "R3 non-Git all-matching apply", target, "--apply-retirements", "--retirement-scope", "all-matching", bundle=bundle)
    c.check("R3 non-Git all-matching retires", report and [e["result"] for e in report["entries"]] == ["retired", "retired"])
    c.check("R3 non-Git backups verified", all(len(backups(target, rel)) == 1 and
                                               (target / entry(report, rel).get("backup", "missing")).read_bytes() == HIST
                                               for rel in PATHS))


def flip_byte(data):
    return bytes([data[0] ^ 1]) + data[1:]


MODIFIED = {
    "same-size-bytes": (flip_byte, "digest-mismatch"),
    "crlf-line-endings": (lambda d: d.replace(b"\n", b"\r\n"), "size-mismatch"),
    "truncated": (lambda d: d[: len(d) // 2], "size-mismatch"),
    "empty": (lambda d: b"", "size-mismatch"),
    "appended-comment": (lambda d: d + b"# local change\n", "size-mismatch"),
}


def case_r4_modified(c, work, bundle=BUNDLE):
    for name, (change, reason) in MODIFIED.items():
        target = synth(work / ("r4-" + name), files=(TEMPLATE,))
        put(target / WORKFLOW, change(HIST))
        modified_before = ident(target / WORKFLOW)
        report, _ = jrun(c, f"R4 {name} apply", target, "--apply-retirements", bundle=bundle, expect=3)
        wf = entry(report, WORKFLOW)
        c.check(f"R4 {name}: workflow is modified/{reason}", wf.get("observed", {}).get("status") == "modified"
                and wf["observed"].get("reason") == reason, wf.get("observed"))
        c.check(f"R4 {name}: workflow preserved", wf.get("result") == "preserved" and ident(target / WORKFLOW) == modified_before)
        c.check(f"R4 {name}: no workflow backup", backups(target, WORKFLOW) == [])
        c.check(f"R4 {name}: exact template still retires", entry(report, TEMPLATE).get("result") == "retired"
                and ident(target / TEMPLATE) is None)
    target = synth(work / "r4-force", files=(TEMPLATE,))
    put(target / WORKFLOW, flip_byte(HIST))
    before = tree(target)
    for flag in ("--force", "--skip-existing", "--no-backup"):
        proc = boot(target, "--apply-retirements", flag)
        c.check(f"R4 {flag} cannot bypass preservation (exit 2)", proc.returncode == 2 and proc.stdout == "", proc.returncode)
    c.check("R4 refused overrides wrote nothing", tree(target) == before)


def r5_layout(name, root, outside):
    """Return (target, expected status, expected reason, expected file type, scan)."""
    target = root / "target"
    target.mkdir(parents=True)
    init_git(target)
    (target / ".gitignore").write_text("".join(p + "\n" for p in PATHS))
    wf = target / WORKFLOW
    if name == "external-leaf-link":
        put(outside / "exact.yml", HIST)
        wf.parent.mkdir(parents=True)
        os.symlink(outside / "exact.yml", wf)
        return target, "unsafe-type", "symlink-leaf", "symlink", "complete"
    if name == "sentinel-leaf-link":
        put(outside / "sentinel.txt", SENTINEL)
        wf.parent.mkdir(parents=True)
        os.symlink(outside / "sentinel.txt", wf)
        return target, "unsafe-type", "symlink-leaf", "symlink", "complete"
    if name == "in-root-leaf-link":
        put(target / "exact-copy.yml", HIST)
        wf.parent.mkdir(parents=True)
        os.symlink("../../exact-copy.yml", wf)
        return target, "unsafe-type", "symlink-leaf", "symlink", "complete"
    if name == "broken-leaf-link":
        wf.parent.mkdir(parents=True)
        os.symlink("missing-referent.yml", wf)
        return target, "unsafe-type", "symlink-leaf", "symlink", "complete"
    if name == "external-parent-link":
        put(outside / "workflows/agent-guard.yml", HIST)
        put(outside / "workflows/agent-guard.yml.generated.20990101-000000", HIST)
        (target / ".github").mkdir()
        os.symlink(outside / "workflows", target / ".github/workflows")
        return target, "unsafe-type", "symlink-ancestor", "unknown", "unsafe-parent"
    if name == "in-root-parent-link":
        put(target / "github-real/workflows/agent-guard.yml", HIST)
        os.symlink("github-real", target / ".github")
        return target, "unsafe-type", "symlink-ancestor", "unknown", "unsafe-parent"
    if name == "broken-parent-link":
        os.symlink("missing-directory", target / ".github")
        return target, "unsafe-type", "symlink-ancestor", "unknown", "unsafe-parent"
    if name == "non-directory-ancestor":
        put(target / ".github", b"not a directory\n")
        return target, "unsafe-type", "non-directory-ancestor", "unknown", "unsafe-parent"
    if name == "fifo-leaf":
        wf.parent.mkdir(parents=True)
        os.mkfifo(wf)
        return target, "unsafe-type", "special-leaf", "other", "complete"
    if name == "directory-leaf":
        (wf / "nested").mkdir(parents=True)
        return target, "unsafe-type", "special-leaf", "directory", "complete"
    if name == "socket-leaf":
        wf.parent.mkdir(parents=True)
        proc = run([sys.executable, "-c", "import socket; socket.socket(socket.AF_UNIX).bind('agent-guard.yml')"], cwd=wf.parent)
        if proc.returncode != 0:
            return None
        return target, "unsafe-type", "special-leaf", "other", "complete"
    if name == "multiple-hard-links":
        put(wf, HIST)
        os.link(wf, target / "second-name.yml")
        return target, "unsafe-type", "multiple-hard-links", "regular", "complete"
    raise AssertionError(name)


SENTINEL = b"EXTERNAL-SENTINEL-7f3c1e-do-not-read\n"
R5_CASES = ("external-leaf-link", "sentinel-leaf-link", "in-root-leaf-link", "broken-leaf-link",
            "external-parent-link", "in-root-parent-link", "broken-parent-link", "non-directory-ancestor",
            "fifo-leaf", "directory-leaf", "socket-leaf", "multiple-hard-links")


def case_r5_path_types(c, work, bundle=BUNDLE, names=R5_CASES):
    for name in names:
        root = work / ("r5-" + name)
        outside = root / "outside"
        outside.mkdir(parents=True)
        layout = r5_layout(name, root, outside)
        if layout is None:
            c.check(f"R5 {name}: platform cannot create fixture (recorded skip)", True)
            continue
        target, status, reason, ftype, scan = layout
        before, outside_before = tree(target), tree(outside)
        report, proc = jrun(c, f"R5 {name} plan", target, "--retirement-plan", bundle=bundle)
        obs = entry(report, WORKFLOW).get("observed", {})
        c.check(f"R5 {name}: classified {status}/{reason}/{ftype}", (obs.get("status"), obs.get("reason"), obs.get("file_type"))
                == (status, reason, ftype), obs)
        c.check(f"R5 {name}: candidate scan {scan}", entry(report, WORKFLOW).get("candidate_scan") == scan)
        report, apply_proc = jrun(c, f"R5 {name} apply", target, "--apply-retirements", "--retirement-scope", "all-matching",
                                  bundle=bundle, expect=3)
        c.check(f"R5 {name}: preserved", entry(report, WORKFLOW).get("result") == "preserved")
        c.check(f"R5 {name}: no target write or link replacement", tree(target) == before, tree_delta(before, tree(target)))
        c.check(f"R5 {name}: outside bytes/metadata unchanged", tree(outside) == outside_before)
        text = proc.stdout + proc.stderr + apply_proc.stdout + apply_proc.stderr
        human = boot(target, "--retirement-plan", bundle=bundle)
        text += human.stdout + human.stderr
        c.check(f"R5 {name}: no referent content or link target in output",
                SENTINEL.decode().strip() not in text and "missing-referent" not in text and "missing-directory" not in text
                and str(outside) not in text)
    # Prefix-lookalike root: a sibling sharing the root's string prefix is outside.
    base = work / "r5-prefix"
    target = base / "proj"
    sibling = base / "proj-evil"
    put(sibling / WORKFLOW, HIST)
    target.mkdir(parents=True)
    os.symlink("../proj-evil/.github", target / ".github")
    sibling_before = tree(sibling)
    report, _ = jrun(c, "R5 prefix-lookalike apply", target, "--apply-retirements", "--retirement-scope", "all-matching",
                     bundle=bundle, expect=3)
    c.check("R5 prefix-lookalike sibling is an unsafe ancestor", entry(report, WORKFLOW).get("observed", {}).get("reason") == "symlink-ancestor")
    c.check("R5 prefix-lookalike sibling untouched", tree(sibling) == sibling_before)
    # Spaces and physical aliases: canonicalize the explicit root once.
    spaced = synth(work / "r5 spaced root" / "proj dir", git=False)
    alias = work / "r5-alias"
    os.symlink(spaced, alias)
    for label, given in (("symlinked alias", alias), ("raw temp alias", Path(str(WORK_RAW)) / spaced.relative_to(WORK))):
        proc = engine("plan", "--target", given, "--json", bundle=bundle)
        doc = strict_json(c, f"R5 engine {label}", proc)
        validate_report(c, f"R5 engine {label}", doc)
        c.check(f"R5 {label} reports the canonical root", doc and doc["target"] == os.path.realpath(spaced), doc and doc["target"])
        c.check(f"R5 {label} sees exact files", doc and [e["observed"]["status"] for e in doc["entries"]] == ["eligible", "eligible"])
    report, _ = jrun(c, "R5 spaced alias apply", alias, "--apply-retirements", "--retirement-scope", "all-matching", bundle=bundle)
    c.check("R5 spaced root retirement through alias", report and [e["result"] for e in report["entries"]] == ["retired", "retired"])
    # Linux syscall tracing, when available, proves the sentinel is never opened.
    if sys.platform.startswith("linux") and shutil.which("strace"):
        root = work / "r5-strace"
        outside = root / "outside"
        outside.mkdir(parents=True)
        target = r5_layout("sentinel-leaf-link", root, outside)[0]
        log = root / "strace.log"
        run(["strace", "-f", "-qq", "-e", "trace=open,openat,openat2,stat,newfstatat,statx", "-o", log,
             sys.executable, "-I", bundle / "lib/retirement.py", "apply", "--target", target, "--json"])
        c.check("R5 strace: external sentinel never opened", "sentinel.txt" not in log.read_text(errors="replace"))


def seed_candidates(target, outside):
    """Candidates of every entry type; returns the expected scan per path."""
    wf_dir = (target / WORKFLOW).parent
    put(outside / "candidate-sentinel.txt", SENTINEL)
    expected = {
        WORKFLOW + ".generated.20260810-120000": "regular",
        WORKFLOW + ".generated.20991231-235959": "regular",
        WORKFLOW + ".generated.custom suffix": "regular",
        WORKFLOW + ".generated.custom\nline": "regular",
        WORKFLOW + ".generated.link": "symlink",
        WORKFLOW + ".generated.broken": "symlink",
        WORKFLOW + ".generated.dir": "directory",
        WORKFLOW + ".generated.fifo": "other",
    }
    put(target / (WORKFLOW + ".generated.20260810-120000"), b"old stamped candidate\n")
    put(target / (WORKFLOW + ".generated.20991231-235959"), HIST)
    put(target / (WORKFLOW + ".generated.custom suffix"), b"custom\n")
    put(target / (WORKFLOW + ".generated.custom\nline"), b"newline name\n")
    os.symlink(outside / "candidate-sentinel.txt", target / (WORKFLOW + ".generated.link"))
    os.symlink("nowhere", target / (WORKFLOW + ".generated.broken"))
    put(target / (WORKFLOW + ".generated.dir") / "inner.txt", b"inside a candidate directory\n")
    os.mkfifo(target / (WORKFLOW + ".generated.fifo"))
    put(wf_dir / "agent-guard.yml.generated.", b"empty suffix is not a candidate\n")
    put(wf_dir / "agent-guard.yml.generatedX", b"not a candidate\n")
    put(target / (TEMPLATE + ".generated.20260810-120000"), b"old template candidate\n")
    expected_template = {TEMPLATE + ".generated.20260810-120000": "regular"}
    return expected, expected_template


def case_r6_candidates(c, work, bundle=BUNDLE):
    target = synth(work / "r6-target")
    outside = work / "r6-outside"
    outside.mkdir()
    expected, expected_template = seed_candidates(target, outside)
    watched = [rel for rel in list(expected) + list(expected_template)] + [
        str(Path(WORKFLOW).parent / "agent-guard.yml.generated."), str(Path(WORKFLOW).parent / "agent-guard.yml.generatedX")]
    before = {rel: ident(target / rel) for rel in watched}
    inner_before = ident(target / (WORKFLOW + ".generated.dir") / "inner.txt")
    report, _ = jrun(c, "R6 plan", target, "--retirement-plan", bundle=bundle)
    got = {item["path"]: item["file_type"] for item in entry(report, WORKFLOW).get("stale_candidates", [])}
    c.check("R6 workflow candidates listed by metadata type", got == expected, got)
    got_t = {item["path"]: item["file_type"] for item in entry(report, TEMPLATE).get("stale_candidates", [])}
    c.check("R6 template candidate listed", got_t == expected_template, got_t)
    human = boot(target, "--retirement-plan", bundle=bundle)
    c.check("R6 human plan escapes candidate names", "generated.custom\\nline" in human.stdout
            and "generated.custom\nline" not in human.stdout, human.stdout[-1500:])
    c.check("R6 human plan names candidates for manual review", "generated.20991231-235959" in human.stdout)
    report, _ = jrun(c, "R6 apply", target, "--apply-retirements", bundle=bundle)
    c.check("R6 apply retires bases", report and [e["result"] for e in report["entries"]] == ["retired", "retired"])
    c.check("R6 apply leaves candidates byte/link-identical", {rel: ident(target / rel) for rel in watched} == before)
    c.check("R6 apply does not descend candidate directories", ident(target / (WORKFLOW + ".generated.dir") / "inner.txt") == inner_before)
    c.check("R6 apply still reports candidates for review", report and report["summary"]["stale_candidate_count"] == len(expected) + 1
            and report["summary"]["attention_required"] is True)
    report, _ = jrun(c, "R6 repeat apply", target, "--apply-retirements", bundle=bundle)
    c.check("R6 repeat apply unchanged", report and [e["result"] for e in report["entries"]] == ["unchanged", "unchanged"])
    c.check("R6 repeat apply keeps candidates", {rel: ident(target / rel) for rel in watched} == before)
    c.check("R6 retired candidates never restore deleted CI", ident(target / WORKFLOW) is None)

    unsafe = synth(work / "r6-unsafe", files=())
    put(outside / "linked/agent-guard.yml.generated.20990101-000000", HIST)
    (unsafe / ".github").mkdir()
    os.symlink(outside / "linked", unsafe / ".github/workflows")
    report, _ = jrun(c, "R6 unsafe parent plan", unsafe, "--retirement-plan", bundle=bundle)
    e = entry(report, WORKFLOW)
    c.check("R6 unsafe parent scan is reported as not performed", e.get("candidate_scan") == "unsafe-parent"
            and e.get("stale_candidates") == [], e)
    human = boot(unsafe, "--retirement-plan", bundle=bundle)
    c.check("R6 human output states the omitted scan", "not performed" in human.stdout, human.stdout[-800:])

    if not IS_ROOT:
        blocked = synth(work / "r6-scan-error")
        parent = blocked / Path(WORKFLOW).parent
        before = tree(blocked)
        os.chmod(parent, 0o311)
        try:
            report, _ = jrun(c, "R6 enumeration failure plan", blocked, "--retirement-plan", bundle=bundle, expect=1)
            c.check("R6 enumeration failure is an error, not clean", entry(report, WORKFLOW).get("candidate_scan") == "error"
                    and any(err["code"] == "candidate-scan-failed" for err in (report or {}).get("errors", [])))
            report, _ = jrun(c, "R6 enumeration failure apply", blocked, "--apply-retirements", bundle=bundle, expect=1)
            c.check("R6 initial inspection error prevents every retirement", report and
                    [e["result"] for e in report["entries"]] == ["error", "not-attempted"])
        finally:
            os.chmod(parent, 0o755)
        c.check("R6 enumeration failure wrote nothing", tree(blocked) == before)


def case_r7_preview_changes(c, work, bundle=BUNDLE):
    variants = {
        "modified": (lambda t: put(t / WORKFLOW, flip_byte(HIST)), 3, "preserved"),
        "symlink": (lambda t: (os.unlink(t / WORKFLOW), put(t / "copy.yml", HIST), os.symlink("../../copy.yml", t / WORKFLOW)), 3, "preserved"),
        "absent": (lambda t: os.unlink(t / WORKFLOW), 0, "unchanged"),
        "project-owned": (lambda t: run_ok(["git", "-C", t, "add", "-f", "--", WORKFLOW]), 3, "preserved"),
    }
    for name, (change, code, result) in variants.items():
        target = synth(work / ("r7-" + name))
        plan, _ = jrun(c, f"R7 {name} preview", target, "--retirement-plan", bundle=bundle)
        c.check(f"R7 {name}: preview proposed retirement", entry(plan, WORKFLOW).get("action") == "retire")
        change(target)
        live = ident(target / WORKFLOW)
        report, _ = jrun(c, f"R7 {name} apply", target, "--apply-retirements", bundle=bundle, expect=code)
        c.check(f"R7 {name}: fresh inspection result {result}", entry(report, WORKFLOW).get("result") == result, entry(report, WORKFLOW))
        c.check(f"R7 {name}: live entry kept", ident(target / WORKFLOW) == live)
        c.check(f"R7 {name}: no stale-authorized backup", backups(target, WORKFLOW) == [])
        c.check(f"R7 {name}: template still handled", entry(report, TEMPLATE).get("result") == "retired")
    # Changes between the apply's own initial inspection and its recheck.
    barrier_cases = {
        "modified": ([["flip", WORKFLOW]], 3, "preserved"),
        "symlink": ([["symlink", WORKFLOW, "elsewhere.yml"]], 3, "preserved"),
        "absent": ([["remove", WORKFLOW]], 0, "unchanged"),
        "project-owned": ([["track", WORKFLOW]], 3, "preserved"),
        "identity": ([["replace", WORKFLOW]], 1, "error"),
    }
    for name, (steps, code, result) in barrier_cases.items():
        target = synth(work / ("r7-barrier-" + name))
        report, _ = inject(c, f"R7 recheck {name}", target, {"barriers": {"before-recheck:agent-guard-workflow": steps}},
                           bundle=bundle, expect=code)
        wf = entry(report, WORKFLOW)
        c.check(f"R7 recheck {name}: initial plan retained, result {result}", wf.get("action") == "retire"
                and wf.get("observed", {}).get("status") == "eligible" and wf.get("result") == result, wf)
        c.check(f"R7 recheck {name}: no backup before a failed recheck", backups(target, WORKFLOW) == [])
        expect_template = "not-attempted" if code == 1 else "retired"
        c.check(f"R7 recheck {name}: template {expect_template}", entry(report, TEMPLATE).get("result") == expect_template)


def case_r8_backup_delete_boundary(c, work, bundle=BUNDLE):
    cases = {
        "bytes": [["flip", WORKFLOW]],
        "inode": [["replace", WORKFLOW]],
        "type": [["symlink", WORKFLOW, "elsewhere.yml"]],
        "parent": [["swap-parent", WORKFLOW]],
    }
    for name, steps in cases.items():
        target = synth(work / ("r8-" + name))
        template_before = ident(target / TEMPLATE)
        report, _ = inject(c, f"R8 {name}", target, {"barriers": {"after-backup:agent-guard-workflow": steps}},
                           bundle=bundle, expect=1)
        wf = entry(report, WORKFLOW)
        c.check(f"R8 {name}: changed-before-delete error", wf.get("result") == "error" and any(
            err["code"] == "changed-before-delete" for err in (report or {}).get("errors", [])), report and report["errors"])
        holder = target / (str(Path(WORKFLOW).parent) + ".moved") if name == "parent" else target / Path(WORKFLOW).parent
        names = [p.name for p in holder.iterdir() if ".bak.retirement." in p.name]
        c.check(f"R8 {name}: verified backup retained and reported", len(names) == 1 and wf.get("backup")
                and wf["backup"].endswith(names[0]) and (holder / names[0]).read_bytes() == HIST, (names, wf.get("backup")))
        c.check(f"R8 {name}: new live entry not deleted", os.path.lexists(target / WORKFLOW))
        if name == "bytes":
            c.check("R8 bytes: changed content kept", (target / WORKFLOW).is_file() and (target / WORKFLOW).read_bytes() == flip_byte(HIST))
        if name == "parent":
            c.check("R8 parent: moved original kept", (target / (str(Path(WORKFLOW).parent) + ".moved") / "agent-guard.yml").read_bytes() == HIST)
        c.check(f"R8 {name}: later entry not attempted", entry(report, TEMPLATE).get("result") == "not-attempted"
                and ident(target / TEMPLATE) == template_before)


def case_r9_failures(c, work, bundle=BUNDLE):
    def fresh(name):
        target = synth(work / ("r9-" + name))
        return target, ident(target / WORKFLOW), ident(target / TEMPLATE)

    if not IS_ROOT:
        target, wf0, tp0 = fresh("permission")
        parent = target / Path(WORKFLOW).parent
        os.chmod(parent, 0o555)
        try:
            report, _ = jrun(c, "R9 read-only parent", target, "--apply-retirements", bundle=bundle, expect=1)
        finally:
            os.chmod(parent, 0o755)
        c.check("R9 permission: backup-failed and original kept", entry(report, WORKFLOW).get("result") == "error"
                and any(e["code"] == "backup-failed" for e in (report or {}).get("errors", [])) and ident(target / WORKFLOW) == wf0)
        c.check("R9 permission: later entry not attempted", entry(report, TEMPLATE).get("result") == "not-attempted" and ident(target / TEMPLATE) == tp0)

    for fault in ("short-write", "fsync-backup", "close-backup"):
        target, wf0, tp0 = fresh(fault)
        report, _ = inject(c, f"R9 {fault}", target, {"faults": [fault]}, bundle=bundle, expect=1)
        wf = entry(report, WORKFLOW)
        c.check(f"R9 {fault}: backup-failed, original intact", wf.get("result") == "error" and ident(target / WORKFLOW) == wf0
                and any(e["code"] == "backup-failed" for e in (report or {}).get("errors", [])), report and report["errors"])
        c.check(f"R9 {fault}: partial backup is never claimed usable", wf.get("backup") is None)
        partial = backups(target, WORKFLOW)
        c.check(f"R9 {fault}: partial backup kept and named", len(partial) == 1 and any(
            partial[0] in e["message"] for e in (report or {}).get("errors", [])), (partial, report and report["errors"]))
        c.check(f"R9 {fault}: template not attempted", entry(report, TEMPLATE).get("result") == "not-attempted" and ident(target / TEMPLATE) == tp0)

    first, second = "20990101T000000Z-aaaaaaaaaaaaaaaa", "20990101T000001Z-bbbbbbbbbbbbbbbb"
    target, _, _ = fresh("collision-before")
    put(target / (WORKFLOW + ".bak.retirement." + first), b"pre-existing\n")
    pre = ident(target / (WORKFLOW + ".bak.retirement." + first))
    report, _ = inject(c, "R9 collision before work", target, {"run_ids": [first, second, second]}, bundle=bundle, expect=0)
    c.check("R9 colliding fresh run id retried before any backup", report and report["run_id"] == second
            and [e["result"] for e in report["entries"]] == ["retired", "retired"], report and report["run_id"])
    c.check("R9 colliding file untouched", ident(target / (WORKFLOW + ".bak.retirement." + first)) == pre)

    target, _, tp0 = fresh("collision-after")
    report, _ = inject(c, "R9 collision after work", target, {"run_ids": [first], "barriers": {
        "after-unlink:agent-guard-workflow": [["create", TEMPLATE + ".bak.retirement." + first]]}}, bundle=bundle, expect=1)
    c.check("R9 collision after work: first result retained", entry(report, WORKFLOW).get("result") == "retired"
            and (target / (WORKFLOW + ".bak.retirement." + first)).read_bytes() == HIST)
    c.check("R9 collision after work: second is a backup error, not overwritten", entry(report, TEMPLATE).get("result") == "error"
            and (target / (TEMPLATE + ".bak.retirement." + first)).read_bytes() == b"collision\n" and ident(target / TEMPLATE) == tp0)

    target, wf0, tp0 = fresh("unlink-first")
    report, _ = inject(c, "R9 unlink failure", target, {"faults": ["unlink"]}, bundle=bundle, expect=1)
    wf = entry(report, WORKFLOW)
    c.check("R9 unlink failure: delete-failed with backup retained", wf.get("result") == "error" and wf.get("backup")
            and (target / wf["backup"]).read_bytes() == HIST and ident(target / WORKFLOW) == wf0
            and any(e["code"] == "delete-failed" for e in (report or {}).get("errors", [])))
    c.check("R9 unlink failure: later entry not attempted", entry(report, TEMPLATE).get("result") == "not-attempted")

    target, _, tp0 = fresh("second-fails")
    report, _ = inject(c, "R9 second fails", target, {"barriers": {"before-unlink:agent-guard-template": [["arm", TEMPLATE, "unlink"]]}},
                       bundle=bundle, expect=1)
    c.check("R9 first retired, second failed (partial outcome)", report and [e["result"] for e in report["entries"]] == ["retired", "error"]
            and ident(target / WORKFLOW) is None and ident(target / TEMPLATE) == tp0)
    c.check("R9 both backups retained", all(entry(report, rel).get("backup") and (target / entry(report, rel)["backup"]).is_file() for rel in PATHS))

    target, wf0, tp0 = fresh("sigint")
    report, proc = inject(c, "R9 SIGINT after backup", target, {"barriers": {"after-backup:agent-guard-workflow": [["signal", WORKFLOW, "SIGINT"]]}},
                          bundle=bundle, expect=130)
    c.check("R9 SIGINT: interrupted reported, original kept", ident(target / WORKFLOW) == wf0 and any(
        e["code"] == "interrupted" for e in (report or {}).get("errors", [])))
    c.check("R9 SIGINT: completed backup retained", len(backups(target, WORKFLOW)) == 1
            and (target / Path(WORKFLOW).parent / backups(target, WORKFLOW)[0]).read_bytes() == HIST)
    c.check("R9 SIGINT: unattempted entry untouched", entry(report, TEMPLATE).get("result") == "not-attempted" and ident(target / TEMPLATE) == tp0)

    target, _, tp0 = fresh("sigterm")
    report, _ = inject(c, "R9 SIGTERM before second backup", target, {"barriers": {"before-backup:agent-guard-template": [["signal", TEMPLATE, "SIGTERM"]]}},
                       bundle=bundle, expect=143)
    c.check("R9 SIGTERM: first retirement reported", entry(report, WORKFLOW).get("result") == "retired" and ident(target / WORKFLOW) is None)
    c.check("R9 SIGTERM: second untouched without backup", ident(target / TEMPLATE) == tp0 and backups(target, TEMPLATE) == [])

    target, _, tp0 = fresh("dir-flush")
    report, _ = inject(c, "R9 directory flush failure", target, {"barriers": {"after-unlink:agent-guard-workflow": [["arm", WORKFLOW, "dir-flush"]]}},
                       bundle=bundle, expect=1)
    wf = entry(report, WORKFLOW)
    c.check("R9 dir flush: error with known absent after-state", wf.get("result") == "error"
            and (wf.get("after") or {}).get("status") == "absent" and wf.get("backup") and (target / wf["backup"]).is_file(), wf)
    c.check("R9 dir flush: stop before later entry", entry(report, TEMPLATE).get("result") == "not-attempted" and ident(target / TEMPLATE) == tp0)


def case_r11_cli(c, work, bundle=BUNDLE):
    target = synth(work / "r11-cli")
    before = tree(target)
    invalid = [
        ["--apply-retirements", "--apply-candidates"], ["--apply-candidates", "--apply-retirements"],
        ["--retirement-plan", "--apply-retirements"], ["--retirement-status", "--retirement-plan"],
        ["--apply-retirements", "--status"], ["--diff", "--retirement-plan"], ["--upgrade-plan", "--retirement-status"],
        ["--apply-retirements", "--cleanup-backups"], ["--refresh-lock", "--apply-retirements"],
        ["--apply-retirements", "--force"], ["--force", "--apply-retirements"], ["--skip-existing", "--retirement-plan"],
        ["--apply-retirements", "--no-backup"], ["--apply-retirements", "--dry-run", "--force"],
        ["--retirement-status", "--no-backup"], ["--apply-retirements", "--retirement-scope", "everything"],
        ["--retirement-plan", "--retirement-scope"], ["--status", "--json", "--status-version", "3"],
        ["--status", "--status-version", "2"], ["--diff", "--status-version", "2"],
        ["--status", "--json", "--retirement-scope", "all-matching"],
        ["--status", "--json", "--status-version", "1", "--retirement-scope", "local-only"],
        ["--apply-candidates", "--retirement-scope", "all-matching"], ["--apply-retirements", "--only", "AGENTS.md"],
    ]
    for args in invalid:
        proc = boot(target, *args, bundle=bundle)
        c.check(f"R11 invalid {' '.join(args)} exits 2 with empty stdout", proc.returncode == 2 and proc.stdout == "",
                f"rc={proc.returncode} out={proc.stdout[:200]} err={proc.stderr[-300:]}")
    c.check("R11 invalid combinations wrote nothing", tree(target) == before)
    for args, mode, dry in ((["--retirement-plan"], "plan", False), (["--retirement-plan", "--dry-run"], "plan", True),
                            (["--retirement-status"], "status", False), (["--apply-retirements", "--dry-run"], "plan", True)):
        report, _ = jrun(c, "R11 " + " ".join(args), target, *args, bundle=bundle)
        c.check(f"R11 {' '.join(args)} mode={mode} dry_run={dry}", report and report["mode"] == mode and report["dry_run"] is dry
                and all(e["result"] == "planned" and e["after"] is None and e["backup"] is None for e in report["entries"]))
    c.check("R11 read-only actions wrote nothing", tree(target) == before)
    plan = boot(target, "--retirement-plan", bundle=bundle)
    c.check("R11 human plan names policy, scope, paths and next step", plan.returncode == 0 and all(
        token in plan.stdout for token in (POLICY_ID, "scope=local-only", WORKFLOW, TEMPLATE, "action=retire", "--apply-retirements")),
        plan.stdout[-1500:])
    c.check("R11 human plan is not JSON", not plan.stdout.lstrip().startswith("{"))
    applied = boot(target, "--apply-retirements", bundle=bundle)
    c.check("R11 human apply names results and backups", applied.returncode == 0 and "result=retired" in applied.stdout
            and "backup:" in applied.stdout and ".bak.retirement." in applied.stdout, applied.stdout[-1500:])
    help_text = boot(target, "--help", bundle=bundle).stdout
    c.check("R11 usage documents the new interfaces", all(flag in help_text for flag in (
        "--retirement-plan", "--retirement-status", "--apply-retirements", "--retirement-scope", "--status-version")))


def case_r13_unrelated(c, work, bundle=BUNDLE):
    target = synth(work / "r13-target", git=False)
    unrelated = {
        "README.md": b"# Application README\n",
        "CHANGELOG.md": b"# Application changelog\n",
        "docs/agent-configs/model-profiles.json": b'{"schema": "agent-model-profiles/v1"}\n',
        "docs/agent-configs/seats.json": b'{"schema": "agent-seats/v1"}\n',
        ".github/workflows/ci.yml": HIST,
        ".github/workflows/agent-guard.yaml": HIST,
        "docs/agent-configs/bootstrap-multi-agent-project/templates/ci/other.yml": HIST,
        "notes.generated.20990101-000000": b"unknown generated file\n",
        WORKFLOW + ".bak.20990101-000000": HIST,
        WORKFLOW + ".bak.retirement.20200101T000000Z-0123456789abcdef": HIST,
    }
    for rel, data in unrelated.items():
        put(target / rel, data)
    before = tree(target, dir_mtime=False)
    report, _ = jrun(c, "R13 all-matching apply", target, "--apply-retirements", "--retirement-scope", "all-matching", bundle=bundle)
    after = tree(target, dir_mtime=False)
    removed, added, changed = tree_delta(before, after)
    expected_added = sorted(entry(report, rel).get("backup") or "?" for rel in PATHS)
    c.check("R13 only the two retired paths were removed", removed == sorted(PATHS), removed)
    c.check("R13 only the two new backups were added", added == expected_added, added)
    c.check("R13 unrelated files/backups/workflows unchanged", changed == [], changed)


def case_r14_direct_probe(c, work, bundle=BUNDLE):
    target = synth(work / "r14-direct")
    log = work / "probe-direct.log"
    env = dict(ENV, PATH=f"{PY_SHIM_DIR}:{ENV['PATH']}", RETIREMENT_PROBE_LOG=str(log))
    report, _ = jrun(c, "R14 direct bundle", target, "--retirement-plan", env=env, bundle=bundle)
    text = log.read_text() if log.exists() else ""
    c.check("R14 direct bundle reached the engine", f"{bundle}/lib/retirement.py plan" in text, text)


def case_refresh_lock(c, work, bundle=BUNDLE):
    target = copy_target(HIST_TARGET, work / "r2-refresh-lock")
    watched = watched_paths(target, work / "r2-refresh-lock-outside")
    before = {rel: ident(target / rel) for rel in watched}
    proc = boot(target, "--refresh-lock", bundle=bundle)
    c.check("R2 refresh-lock succeeds", proc.returncode == 0, proc.stderr[-800:])
    c.check("R2 refresh-lock leaves retired files and candidates untouched", {rel: ident(target / rel) for rel in watched} == before)


def project_tree(root):
    """tree() without the kit copy and run state the one-shot keeps in the target."""
    return {rel: value for rel, value in tree(root).items()
            if rel.split(os.sep)[0] not in (".harness-kit", ".tools")}


def case_r12_dry_run(c, work, bundle=BUNDLE):
    """R12 with the one-shot entry: --dry-run is --plan, which never deletes;
    --apply-retirements is ignored with a plan; nothing is fetched."""
    target = synth(work / "r12-target")
    git_log = work / "r12-git.log"
    env = dict(ENV, PATH=f"{GIT_SHIM_DIR}:{ENV['PATH']}", RETIREMENT_PROBE_LOG=str(git_log))
    home, cache = work / "r12-home", work / "r12-cache-missing"
    before, index_before = project_tree(target), ident(target / ".git/index")
    source_status = run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"]).stdout

    proc = run([ONE_SHOT, "--dry-run", "--source-dir", ROOT, "--target", target, "--home", home, "--cache-dir", cache], env=env)
    out = proc.stdout + proc.stderr
    c.check("R12 dry-run with local source exits 0", proc.returncode == 0, out[-2000:])
    c.check("R12 dry-run is a plan of this kit version", f"mode: install {VERSION} (plan only)" in proc.stdout
            and "--dry-run now means --plan" in proc.stderr, out[-2000:])
    c.check("R12 dry-run reports the plan", "RESULT: done (plan only, nothing applied)" in proc.stdout
            and (target / ".tools/agent-state/upgrades").is_dir(), out[-2000:])
    proc = run([ONE_SHOT, "--dry-run", "--apply-retirements", "--retirement-scope", "all-matching", "--source-dir", ROOT,
                "--target", target, "--home", home, "--cache-dir", cache], env=env)
    out = proc.stdout + proc.stderr
    c.check("R12 dry-run apply is plan only", proc.returncode == 0 and "plan only" in proc.stdout
            and "--apply-retirements is ignored with --plan" in proc.stderr, out[-2000:])
    c.check("R12 dry-run never deletes a retired file", all((target / rel).is_file() for rel in PATHS))
    c.check("R12 dry-run wrote nothing outside .harness-kit/ and .tools/",
            project_tree(target) == before and ident(target / ".git/index") == index_before,
            tree_delta(before, project_tree(target)))
    c.check("R12 dry-run created no home/cache", not home.exists() and not cache.exists())
    c.check("R12 dry-run wrote nothing to the source", run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"]).stdout == source_status)

    plain = synth(work / "r12-plain", git=False)
    proc = run([ONE_SHOT, "--dry-run", "--source-dir", ROOT, "--target", plain, "--home", home, "--cache-dir", cache], env=env)
    c.check("R12 dry-run refuses a non-Git target like the real run", proc.returncode == 1, proc.stderr[-800:])
    log = git_log.read_text() if git_log.exists() else ""
    forbidden = [line for line in log.splitlines() if re.search(r"^git (.* )?(fetch|clone|checkout|switch|init|ls-remote)( |$)", line)]
    c.check("R12 dry-run never fetches, clones, checks out or switches", not forbidden, forbidden)
    c.check("R12 retired files and home still unwritten", all((target / rel).read_bytes() == HIST for rel in PATHS)
            and not home.exists())


# --------------------------------------------------------------------------
# Slow cases: ordinary public actions against real historical targets


def watched_paths(target, outside):
    """Seed bash-line-safe candidates/leftovers next to the retired files."""
    outside.mkdir(parents=True, exist_ok=True)
    put(outside / "candidate-sentinel.txt", SENTINEL)
    entries = {
        WORKFLOW + ".generated.20260810-120000": b"old stamped candidate\n",
        WORKFLOW + ".generated.20991231-235959": HIST,
        WORKFLOW + ".generated.custom suffix": b"custom\n",
        WORKFLOW + ".bak.20990101-000000": HIST,
        WORKFLOW + ".bak.retirement.20200101T000000Z-0123456789abcdef": HIST,
        TEMPLATE + ".generated.20260810-120000": b"old template candidate\n",
    }
    for rel, data in entries.items():
        put(target / rel, data)
    os.symlink(outside / "candidate-sentinel.txt", target / (WORKFLOW + ".generated.link"))
    os.symlink("nowhere", target / (WORKFLOW + ".generated.broken"))
    put(target / (WORKFLOW + ".generated.dir") / "inner.txt", b"inner\n")
    return list(PATHS) + list(entries) + [WORKFLOW + ".generated.link", WORKFLOW + ".generated.broken",
                                          WORKFLOW + ".generated.dir", WORKFLOW + ".generated.dir/inner.txt"]


def slow_public_action(c, work, label, args, expect=0, extra=None, section=True, bundle=BUNDLE):
    target = copy_target(HIST_TARGET, work / ("r2-" + label))
    watched = watched_paths(target, work / ("r2-" + label + "-outside"))
    before = {rel: ident(target / rel) for rel in watched}
    listing_before = sorted(p.name for p in (target / WORKFLOW).parent.iterdir())
    proc = boot(target, *args, bundle=bundle)
    c.check(f"R2 {label}: exit {expect}", proc.returncode == expect, f"rc={proc.returncode}\n{proc.stdout[-800:]}\n{proc.stderr[-1500:]}")
    after = {rel: ident(target / rel) for rel in watched}
    c.check(f"R2 {label}: retired files, candidates and leftovers untouched", after == before,
            [rel for rel in watched if before[rel] != after[rel]])
    if section:
        c.check(f"R14 {label}: appends the retirement plan section", "Retirement plan" in proc.stdout
                and WORKFLOW in proc.stdout and "nothing was removed" in proc.stdout, proc.stdout[-1500:])
    listing = sorted(p.name for p in (target / WORKFLOW).parent.iterdir())
    c.check(f"R2 {label}: no new entry next to a retired path", listing == listing_before, (listing_before, listing))
    if extra:
        extra(c, target, proc)
    return target, proc


def slow_diff_extra(c, target, proc):
    c.check("R2 diff never proposes retired paths", f"--- {WORKFLOW}" not in proc.stdout and f"--- {TEMPLATE}" not in proc.stdout)


def slow_status_v1(c, work, target):
    proc = boot(target, "--status", "--json")
    c.check("R11 status v1 exit 0", proc.returncode == 0, proc.stderr[-800:])
    doc = strict_json(c, "R11 status v1", proc)
    validate_report(c, "R11 status v1", doc, STATUS_V1_ID)
    c.check("R11 status v1 has no retirement field", doc is not None and "retirement" not in doc and doc["schema"] == "agent-bootstrap-status/v1")
    SHARED["status-v1"] = doc


def slow_status_v2(c, work, target):
    proc = boot(target, "--status", "--json", "--status-version", "2", "--retirement-scope", "all-matching")
    c.check("R11 status v2 exit 0", proc.returncode == 0, proc.stderr[-800:])
    doc = strict_json(c, "R11 status v2", proc)
    validate_report(c, "R11 status v2", doc, STATUS_V2_ID)
    c.check("R11 status v2 embeds a status-mode report", doc is not None and doc["schema"] == "agent-bootstrap-status/v2"
            and doc["retirement"]["mode"] == "status" and doc["retirement"]["scope"] == "all-matching")
    SHARED["status-v2"] = doc


def slow_status_human(c, work, target):
    proc = boot(target, "--status")
    c.check("R2 human status exit 0", proc.returncode == 0, proc.stderr[-800:])
    c.check("R14 human status appends retirement state", "Retirement status" in proc.stdout and "state=eligible" in proc.stdout, proc.stdout[-1200:])
    c.check("R2 human status keeps old fields", "generated_file_drift=" in proc.stdout)


def observer_case(c, work, action, mode):
    """Ordinary apply-candidates/cleanup-backups exit precedence (R11)."""
    label = f"{action}-{mode}"
    target = copy_target(HIST_TARGET, work / label)
    watched = watched_paths(target, work / (label + "-outside"))
    if action == "--apply-candidates":
        put(target / "AGENTS.md.generated.20990101-000000", b"# Promoted by the ordinary action\n")
    else:
        put(target / "AGENTS.md.bak.20990101-000000", b"old ordinary backup\n")
    if mode == "retirement-error":
        os.rename(target / ".git", target / ".git-real")
        os.symlink(".git-real", target / ".git")
    if mode == "ordinary-failure":
        lock = target / "docs/agent-configs/agent-bootstrap.lock.json"
        put(work / (label + "-outside/lock.json"), b"{}\n")
        lock.unlink()
        os.symlink(work / (label + "-outside/lock.json"), lock)
    before = {rel: ident(target / rel) for rel in watched}
    # Plain --apply-candidates keeps a base without a baseline; --only promotes it.
    only = ["--only", "AGENTS.md"] if action == "--apply-candidates" else []
    proc = boot(target, action, *only)
    expect = {"attention": 0, "retirement-error": 1, "ordinary-failure": 1}[mode]
    c.check(f"R11 {label}: exit {expect}", proc.returncode == expect, f"rc={proc.returncode}\n{proc.stdout[-800:]}\n{proc.stderr[-800:]}")
    c.check(f"R11 {label}: retired files and candidates untouched", {rel: ident(target / rel) for rel in watched} == before)
    if mode != "ordinary-failure":
        if action == "--apply-candidates":
            c.check(f"R11 {label}: completed ordinary write retained", (target / "AGENTS.md").read_bytes() == b"# Promoted by the ordinary action\n")
        else:
            c.check(f"R11 {label}: completed ordinary cleanup retained", not (target / "AGENTS.md.bak.20990101-000000").exists())
        c.check(f"R11 {label}: preservation summary appended", "Retirement plan" in proc.stdout, proc.stdout[-1000:])
    if mode == "retirement-error":
        c.check(f"R11 {label}: ownership refusal reported", "ownership" in proc.stdout, proc.stdout[-1000:])


def install_home(work, name):
    home = work / name
    tags = work / (name + "-tags")
    tags.mkdir()
    init_git(tags, commit_readme=False)
    run_ok(["git", "-C", tags, "commit", "-q", "--allow-empty", "-m", "release"])
    run_ok(["git", "-C", tags, "tag", "v" + VERSION])
    run_ok(["/bin/bash", BUNDLE / "install-agent-bootstrap-home.sh", "--home", home, "--no-git", "--repo", tags])
    return home, tags


def slow_updater(c, work):
    home, tags = install_home(work, "updater-home")
    for rel in ("lib/retirement.py", "policies/retired-artifacts-v1.json",
                "schemas/agent-bootstrap-retirement-v1.schema.json", "schemas/agent-bootstrap-status-v2.schema.json"):
        c.check(f"R12 installed home exports {rel} exactly", (home / rel).is_file() and (home / rel).read_bytes() == (BUNDLE / rel).read_bytes())
    target = copy_target(HIST_TARGET, work / "updater-target")
    before = {rel: ident(target / rel) for rel in PATHS}
    log = work / "updater-probe.log"
    env = dict(ENV, PATH=f"{PY_SHIM_DIR}:{ENV['PATH']}", RETIREMENT_PROBE_LOG=str(log))
    proc = run(["/bin/bash", home / "agent-bootstrap-update.sh", "--home", home, "--repo", tags, "--target", target, "--plan"], env=env)
    c.check("R14 updater --plan exit 0 with retirement plan", proc.returncode == 0 and "Retirement plan" in proc.stdout,
            proc.stdout[-800:] + proc.stderr[-800:])
    plan_probe = log.read_text() if log.exists() else ""
    c.check("R14 updater --plan reached the installed engine", f"{home}/lib/retirement.py section" in plan_probe, plan_probe)
    proc = run(["/bin/bash", home / "agent-bootstrap-update.sh", "--home", home, "--repo", tags, "--target", target, "--apply"], env=env)
    c.check("R14 updater --apply exit 0 with retirement plan", proc.returncode == 0 and "Retirement plan" in proc.stdout,
            proc.stdout[-800:] + proc.stderr[-800:])
    probe = log.read_text() if log.exists() else ""
    c.check("R14 updater --apply reached the installed engine", probe.count(f"{home}/lib/retirement.py section") >= 2, probe)
    c.check("R2 updater apply never retires", {rel: ident(target / rel) for rel in PATHS} == before)
    report, _ = jrun(c, "R14 installed home dedicated status", target, "--retirement-status", bundle=home, env=env)
    c.check("R14 installed home dedicated action reached the engine", f"{home}/lib/retirement.py status" in log.read_text())


def one_shot(c, work, label, flags, *, expect, prepare=None, apply_expected=False):
    """A real one-shot update of the historical target through the entry script.
    The legacy target has no baseline, so its changed kit files are conflicts
    (exit 3 when nothing fails); retirement is the retire-files decision."""
    target = copy_target(HIST_TARGET, work / ("one-shot-" + label))
    watched = watched_paths(target, work / ("one-shot-" + label + "-outside"))
    if prepare:
        prepare(target)
    before = {rel: ident(target / rel) for rel in watched}
    log = work / f"one-shot-{label}.log"
    env = dict(ENV, PATH=f"{PY_SHIM_DIR}:{ENV['PATH']}", RETIREMENT_PROBE_LOG=str(log))
    home = work / f"one-shot-{label}-home"
    proc = run([ONE_SHOT, "--source-dir", ROOT, "--target", target, "--home", home, "--skip-verify", "--allow-dirty", *flags], env=env)
    out = proc.stdout + proc.stderr
    c.check(f"R12 one-shot {label}: exit {expect}", proc.returncode == expect, out[-2500:])
    match = re.search(r"^report: (.+)$", proc.stdout, re.M)
    report = json.loads((target / match.group(1)).read_text()) if match else {}
    c.check(f"R12 one-shot {label}: writes a run report", bool(report), out[-1500:])
    decisions = {status: [m["id"] for m in report.get("migrations", {}).get(status, [])]
                 for status in ("applied", "pending", "declined", "failed")}
    probe = log.read_text() if log.exists() else ""
    c.check(f"R14 one-shot {label}: reached the kit copy's engine",
            f"/.harness-kit/v{VERSION}/agent-bootstrap/lib/retirement.py" in probe, probe[-800:])
    c.check(f"R12 one-shot {label}: no home install", not home.exists())
    after = {rel: ident(target / rel) for rel in watched}
    if not apply_expected:
        c.check(f"R12 one-shot {label}: retirement stays a pending decision", RETIRE_ID in decisions["pending"], decisions)
        c.check(f"R12 one-shot {label}: never deletes", after == before, [r for r in watched if before[r] != after[r]])
        c.check(f"R12 one-shot {label}: never reaches apply", " apply --target" not in probe)
    else:
        c.check(f"R12 one-shot {label}: candidates untouched", all(after[r] == before[r] for r in watched if r not in PATHS))
    return target, out, report, decisions, before, after


def slow_one_shot_default(c, work):
    target, out, report, decisions, before, after = one_shot(c, work, "default", [], expect=3)
    plan = report and json.loads((target / ".tools/agent-state/upgrades" / report["stamp"] / "plan.json").read_text())
    planned = [item["path"] for item in (plan or {}).get("files", [])]
    c.check("R2 one-shot never generates retired paths", planned and WORKFLOW not in planned and TEMPLATE not in planned)
    c.check("R12 one-shot console names the retire-files decision", f"--accept {RETIRE_ID}" in out, out[-1500:])


def slow_one_shot_flags(c, work):
    target, out, report, decisions, before, after = one_shot(
        c, work, "flags-no-apply", ["--no-branch", "--apply-candidates", "--retirement-scope", "all-matching"], expect=3)
    c.check("R12 one-shot old flags print their notes", all(note in out for note in (
        "--no-branch is now the default", "--apply-candidates is replaced", "--retirement-scope is no longer used",
        "--allow-dirty is now the default")), out[-1500:])


def slow_one_shot_apply3(c, work):
    target, out, report, decisions, before, after = one_shot(
        c, work, "apply-exit3", ["--no-branch", "--apply-retirements"], expect=3,
        prepare=lambda t: put(t / TEMPLATE, flip_byte(HIST)), apply_expected=True)
    fresh = [name for name in backups(target, WORKFLOW) if not name.endswith("20200101T000000Z-0123456789abcdef")]
    c.check("R12 one-shot apply retired the exact local-only workflow", after[WORKFLOW] is None and len(fresh) == 1)
    c.check("R12 one-shot apply preserved the modified template", after[TEMPLATE] == before[TEMPLATE])
    c.check("R12 one-shot retirement with a preserved file is applied", decisions["applied"] == [RETIRE_ID], decisions)
    c.check("R12 one-shot exit 3 comes from the remaining conflicts", report.get("result") == "needs review"
            and report["files"]["conflicts"], report.get("result"))


def slow_one_shot_apply1(c, work):
    if IS_ROOT:
        c.check("R12 one-shot apply failure needs a non-root permission fixture (recorded skip)", True)
        return
    holder = {}

    def prepare(target):
        holder["parent"] = target / Path(WORKFLOW).parent
        os.chmod(holder["parent"], 0o555)
    try:
        target, out, report, decisions, before, after = one_shot(
            c, work, "apply-exit1", ["--no-branch", "--apply-retirements"], expect=1, prepare=prepare, apply_expected=True)
    finally:
        if "parent" in holder:
            os.chmod(holder["parent"], 0o755)
    c.check("R12 one-shot apply failure keeps the original", after[WORKFLOW] == before[WORKFLOW])
    c.check("R12 one-shot apply failure is a failed migration", decisions["failed"] == [RETIRE_ID]
            and report.get("result") == "failed", decisions)
    c.check("R12 one-shot apply failure stops further actions",
            [p["status"] for p in report.get("phases", []) if p["name"] in ("migrate", "verify")] == ["failed", "skipped"],
            report.get("phases"))


def slow_idempotence(c, work):
    target = copy_target(HIST_TARGET, work / "r10-target")
    watched = [rel for rel in watched_paths(target, work / "r10-outside") if rel not in PATHS]
    cand_before = {rel: ident(target / rel) for rel in watched}
    report, _ = jrun(c, "R10 first apply", target, "--apply-retirements")
    c.check("R10 first apply retires both local-only exact files", report and [e["result"] for e in report["entries"]] == ["retired", "retired"])
    snapshot = tree(target)
    for args in (["--retirement-plan"], ["--retirement-status"]):
        again, _ = jrun(c, "R10 repeat " + args[0], target, *args)
        c.check(f"R10 repeat {args[0]} reports absent", again and [e["observed"]["status"] for e in again["entries"]] == ["absent", "absent"])
    again, _ = jrun(c, "R10 repeat apply", target, "--apply-retirements")
    c.check("R10 repeat apply: two unchanged results, exit 0", again and [e["result"] for e in again["entries"]] == ["unchanged", "unchanged"])
    c.check("R10 repeat apply still asks for candidate review", again and again["summary"]["attention_required"] is True)
    c.check("R10 repeat read-only/apply created nothing", tree(target) == snapshot, tree_delta(snapshot, tree(target)))
    backups_before = (backups(target, WORKFLOW), backups(target, TEMPLATE))
    proc = boot(target, "--workflow", "full")
    c.check("R10 regeneration succeeds", proc.returncode == 0, proc.stderr[-800:])
    c.check("R10 regeneration does not recreate retired files", all(ident(target / rel) is None for rel in PATHS))
    c.check("R10 regeneration adds no tombstone or backup", (backups(target, WORKFLOW), backups(target, TEMPLATE)) == backups_before)
    c.check("R10 candidates preserved throughout", {rel: ident(target / rel) for rel in watched} == cand_before)
    again, _ = jrun(c, "R10 apply after regeneration", target, "--apply-retirements")
    c.check("R10 apply after regeneration unchanged", again and [e["result"] for e in again["entries"]] == ["unchanged", "unchanged"])


def extract_recipe(text):
    section = text.split("## retired artifact recovery", 1)[1]
    match = re.search(r"```bash\n(.*?)```", section, re.S)
    return match.group(1) if match else ""


def run_recipe(recipe, target, rel, run_id):
    script = re.sub(r"(?m)^RETIRED_PATH=.*$", f"RETIRED_PATH={rel}", recipe)
    script = re.sub(r"(?m)^RUN_ID=.*$", f"RUN_ID={run_id}", script)
    return run(["/bin/bash", "-c", script], cwd=target)


def slow_fresh_and_recovery(c, work):
    fresh = work / "fresh-latest"
    fresh.mkdir()
    proc = boot(fresh, "--workflow", "full")
    c.check("R10 latest fresh generation succeeds with plan", proc.returncode == 0 and "Retirement plan" in proc.stdout, proc.stderr[-800:])
    report, _ = jrun(c, "R10 latest fresh plan", fresh, "--retirement-plan")
    c.check("R10 latest fresh target: both absent, no attention", report and [e["observed"]["status"] for e in report["entries"]]
            == ["absent", "absent"] and report["summary"]["attention_required"] is False)
    recovery = (fresh / "docs/agent-configs/RECOVERY.md").read_text()
    recipe = extract_recipe(recovery) if "## retired artifact recovery" in recovery else ""
    c.check("R9 generated RECOVERY.md documents the exclusive-create recipe", recipe and "O_EXCL" in recipe and DIGEST in recipe
            and "cp " not in recipe, recovery[-500:])
    target = synth(work / "recovery-target", git=False)
    original = ident(target / WORKFLOW)
    report, _ = jrun(c, "R9 recovery source apply", target, "--apply-retirements", "--retirement-scope", "all-matching")
    run_id = report["run_id"] if report else "missing"
    proc = run_recipe(recipe, target, WORKFLOW, run_id)
    c.check("R9 recipe restores into the absent safe path", proc.returncode == 0 and (target / WORKFLOW).read_bytes() == HIST,
            proc.stdout + proc.stderr)
    st = os.lstat(target / WORKFLOW) if (target / WORKFLOW).exists() else None
    c.check("R9 recipe preserves mode and mtime", st and (stat.S_IMODE(st.st_mode), st.st_mtime_ns) == (original[2], original[3]))
    plan, _ = jrun(c, "R9 recovered file is eligible again", target, "--retirement-plan", "--retirement-scope", "all-matching")
    c.check("R9 recovered file eligible again", entry(plan, WORKFLOW).get("observed", {}).get("status") == "eligible")
    present = ident(target / WORKFLOW)
    proc = run_recipe(recipe, target, WORKFLOW, run_id)
    c.check("R9 recipe refuses an existing original", proc.returncode != 0 and ident(target / WORKFLOW) == present)
    backup = target / (TEMPLATE + ".bak.retirement." + run_id)
    put(backup, flip_byte(HIST))
    proc = run_recipe(recipe, target, TEMPLATE, run_id)
    c.check("R9 recipe refuses a backup that is not the known bytes", proc.returncode != 0 and not os.path.lexists(target / TEMPLATE))
    put(backup, HIST)
    real = target / "docs-real"
    os.rename(target / "docs", real)
    os.symlink("docs-real", target / "docs")
    proc = run_recipe(recipe, target, TEMPLATE, run_id)
    c.check("R9 recipe refuses an unsafe parent", proc.returncode != 0 and not os.path.lexists(real / TEMPLATE[len("docs/"):]))


# --------------------------------------------------------------------------
# Mutation oracles: each removed defense must turn a passing case red.

ENGINE_MUTATIONS = [
    ("hash-bypass", case_r4_modified, [("lib/retirement.py", 'if digest == fingerprint["sha256"]:', "if True:")]),
    ("follow-leaf", lambda c, w, b: case_r5_path_types(c, w, b, ("external-leaf-link", "broken-leaf-link")),
     [("lib/retirement.py", "leaf_stat = os.lstat(name, dir_fd=parent_fd)", "leaf_stat = os.stat(name, dir_fd=parent_fd)"),
      ("lib/retirement.py", "LEAF_FLAGS = os.O_RDONLY | os.O_NOFOLLOW", "LEAF_FLAGS = os.O_RDONLY")]),
    ("follow-ancestor", lambda c, w, b: case_r5_path_types(c, w, b, ("external-parent-link",)),
     [("lib/retirement.py", "st = os.lstat(component, dir_fd=fd)", "st = os.stat(component, dir_fd=fd)"),
      ("lib/retirement.py", "DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW", "DIR_FLAGS = os.O_RDONLY")]),
    ("no-final-recheck", case_r8_backup_delete_boundary,
     [("lib/retirement.py", "if not _same_safe_match(recheck, final, scope):", "if False:")]),
    ("skip-backup", case_r3_local_only,
     [("lib/retirement.py", "_make_backup(parent_fd, name, backup_name, recheck, fingerprint, progress)", "pass")]),
    ("tracked-as-local", case_r3_project_owned,
     [("lib/retirement.py", 'return "project-owned"  # tracked', 'return "local-only"  # tracked')]),
]


def entrypoint_allowlist_mutant(c, work, bundle):
    target = copy_target(HIST_TARGET, work / "allowlist-target")
    watched = watched_paths(target, work / "allowlist-outside")
    before = {rel: ident(target / rel) for rel in watched}
    # Named explicitly: plain --apply-candidates keeps a base without a baseline.
    boot(target, "--apply-candidates", "--only", WORKFLOW, bundle=bundle)
    c.check("R6 apply-candidates never promotes a retired base", {rel: ident(target / rel) for rel in watched} == before)


def entrypoint_observer_mutant(c, work, bundle):
    target = copy_target(HIST_TARGET, work / "observer-target")
    os.rename(target / ".git", target / ".git-real")
    os.symlink(".git-real", target / ".git")
    proc = boot(target, "--apply-candidates", bundle=bundle)
    c.check("R11 observer inspection error returns 1", proc.returncode == 1, proc.returncode)


SLOW_MUTATIONS = [
    ("allowlist-retired-base", entrypoint_allowlist_mutant,
     [("bootstrap-multi-agent-project.sh", "} | sort -u | exclude_retired_artifact_paths",
       "  printf '%s\\n' .github/workflows/agent-guard.yml\n  } | sort -u")]),
    ("observer-forced-success", entrypoint_observer_mutant,
     [("bootstrap-multi-agent-project.sh", "print_retirement_section apply-candidates || exit $?",
       "print_retirement_section apply-candidates || true")]),
]


def mutation(c, work, name, func, edits):
    mutant = work / "agent-bootstrap"
    shutil.copytree(BUNDLE, mutant, symlinks=True)
    for rel, old, new in edits:
        path = mutant / rel
        text = path.read_text()
        if text.count(old) != 1:
            c.check(f"mutation {name}: anchor present exactly once in {rel}", False, old)
            return
        path.write_text(text.replace(old, new))
    probe = Case("mutant " + name)
    try:
        func(probe, work / "run", mutant)
    except Exception:
        probe.check("raised", False, traceback.format_exc())
    c.check(f"mutation {name} is killed by its public case", bool(probe.failed), "mutant passed every check")


# --------------------------------------------------------------------------
# Runner


def setup_tools():
    global INJECT, PY_SHIM_DIR, GIT_SHIM_DIR
    INJECT = WORK / "inject.py"
    INJECT.write_text(INJECT_SOURCE)
    PY_SHIM_DIR = WORK / "python-shim"
    PY_SHIM_DIR.mkdir()
    real_python = shutil.which("python3", path=ENV["PATH"]) or sys.executable
    (PY_SHIM_DIR / "python3").write_text(
        "#!/bin/bash\nfor arg in \"$@\"; do case \"$arg\" in */lib/retirement.py) "
        "printf '%s\\n' \"$*\" >> \"$RETIREMENT_PROBE_LOG\";; esac; done\n"
        f"exec {real_python} \"$@\"\n")
    os.chmod(PY_SHIM_DIR / "python3", 0o755)
    GIT_SHIM_DIR = WORK / "git-shim"
    GIT_SHIM_DIR.mkdir()
    (GIT_SHIM_DIR / "git").write_text(
        "#!/bin/bash\nprintf 'git %s\\n' \"$*\" >> \"$RETIREMENT_PROBE_LOG\"\n"
        f"exec {shutil.which('git', path=ENV['PATH'])} \"$@\"\n")
    os.chmod(GIT_SHIM_DIR / "git", 0o755)


def load_schemas(c):
    global SCHEMAS
    paths = [BUNDLE / "schemas" / name for name in (
        "agent-bootstrap-retirement-v1.schema.json", "agent-bootstrap-status-v1.schema.json",
        "agent-bootstrap-status-v2.schema.json")]
    try:
        SCHEMAS = Schemas(paths)
        c.check("R11 schemas load as JSON Schema 2020-12 documents", True)
    except Exception as exc:
        c.check("R11 schemas load as JSON Schema 2020-12 documents", False, exc)


def make_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    gitconfig = WORK / "gitconfig"
    excludes = WORK / "git-excludes"
    excludes.write_text("")
    gitconfig.write_text("[init]\n\tdefaultBranch = main\n[user]\n\tname = Retirement Test\n"
                         "\temail = retirement@example.invalid\n[core]\n\texcludesFile = " + str(excludes) + "\n"
                         "[advice]\n\tdetachedHead = false\n")
    env.update({"GIT_CONFIG_GLOBAL": str(gitconfig), "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CEILING_DIRECTORIES": str(WORK), "LC_ALL": "C", "LANG": "C"})
    env.pop("AGENT_BOOTSTRAP_WRITE_LOG", None)
    return env


def main(argv=None):
    global WORK, WORK_RAW, ENV
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--historical-source", choices=("auto", "tags", "fixtures"),
                        default=os.environ.get("HARNESS_MIGRATION_HISTORICAL_SOURCE", "auto"))
    parser.add_argument("--jobs", type=int, default=max(4, min(10, os.cpu_count() or 4)))
    parser.add_argument("--only", action="append", default=[], help="run tasks whose name contains this text")
    parser.add_argument("--keep", action="store_true", help="keep the disposable work directory")
    parser.add_argument("--tier", choices=("fast", "one-shot", "all"), default="fast",
                        help="fast (default): all but real one-shot upgrades; one-shot: only those; all: both")
    args = parser.parse_args(argv)

    WORK_RAW = tempfile.mkdtemp(prefix="hk07-retirement-")
    WORK = Path(os.path.realpath(WORK_RAW))
    ENV = make_env()
    started = time.time()
    setup = Case("setup")
    tasks = []
    try:
        setup_tools()
        load_schemas(setup)
        prepare_historical(setup, args.historical_source)
    except Exception:
        setup.check("historical fixture and tools prepared (required, never skipped)", False, traceback.format_exc())
    report_case(setup)
    if setup.failed and HIST is None:
        print("retirement-test: FAIL (setup)", flush=True)
        return 1

    status_target = None
    try:
        status_target = copy_target(HIST_TARGET, WORK / "status-shared")
        watched_paths(status_target, WORK / "status-shared-outside")
    except Exception:
        setup.check("shared status target prepared", False, traceback.format_exc())

    def add(name, func, *fargs):
        tasks.append((name, func, fargs))

    # Slow public actions first so they overlap with everything else.
    for label in ("default", "flags", "apply3", "apply1"):
        add("one-shot-" + label, globals()["slow_one_shot_" + label])
    add("status-v1", lambda c, w: slow_status_v1(c, w, status_target))
    add("status-v2", lambda c, w: slow_status_v2(c, w, status_target))
    add("status-human", lambda c, w: slow_status_human(c, w, status_target))
    add("updater", slow_updater)
    add("upgrade-plan", lambda c, w: slow_public_action(c, w, "upgrade-plan", ["--upgrade-plan"]))
    add("diff", lambda c, w: slow_public_action(c, w, "diff", ["--diff"], extra=slow_diff_extra))
    for action in ("--apply-candidates", "--cleanup-backups"):
        for mode in ("attention", "retirement-error", "ordinary-failure"):
            add(f"observer{action}-{mode}", lambda c, w, a=action, m=mode: observer_case(c, w, a, m))
    add("generate-default", lambda c, w: slow_public_action(c, w, "generate", ["--workflow", "full"]))
    add("generate-force", lambda c, w: slow_public_action(c, w, "force", ["--workflow", "full", "--force"]))
    add("generate-skip-existing", lambda c, w: slow_public_action(c, w, "skip-existing", ["--workflow", "full", "--skip-existing"]))
    add("generate-dry-run", lambda c, w: slow_public_action(c, w, "dry-run", ["--workflow", "full", "--dry-run"]))
    add("idempotence", slow_idempotence)
    add("fresh-and-recovery", slow_fresh_and_recovery)
    for name, func, edits in SLOW_MUTATIONS:
        add("mutation-" + name, lambda c, w, n=name, f=func, e=edits: mutation(c, w, n, f, e))
    # Fast dedicated-action and engine cases.
    for func in (case_r1_policy, case_r3_local_only, case_r3_project_owned, case_r3_untracked_unignored, case_r3_non_git,
                 case_r4_modified, case_r5_path_types, case_r6_candidates, case_r7_preview_changes,
                 case_r8_backup_delete_boundary, case_r9_failures, case_r11_cli, case_r13_unrelated,
                 case_r14_direct_probe, case_refresh_lock, case_r12_dry_run):
        add(func.__name__, lambda c, w, f=func: f(c, w))
    for name, func, edits in ENGINE_MUTATIONS:
        add("mutation-" + name, lambda c, w, n=name, f=func, e=edits: mutation(c, w, n, f, e))

    if args.tier == "fast":
        tasks = [t for t in tasks if not t[0].startswith("one-shot-")]
    elif args.tier == "one-shot":
        tasks = [t for t in tasks if t[0].startswith("one-shot-")]
    if args.only:
        tasks = [t for t in tasks if any(text in t[0] for text in args.only)]

    def execute(task):
        name, func, fargs = task
        case = Case(name)
        work = WORK / ("task-" + re.sub(r"[^A-Za-z0-9_.-]", "-", name))
        work.mkdir()
        t0 = time.time()
        try:
            func(case, work, *fargs)
        except Exception:
            case.check("completed without exception", False, traceback.format_exc())
        finally:
            restore_tree_permissions(work)
        case.elapsed = time.time() - t0
        return case

    failed = bool(setup.failed)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(execute, task) for task in tasks]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            report_case(result)
            failed = failed or bool(result.failed)

    if "status-v1" in SHARED and "status-v2" in SHARED:
        compare = Case("status-compare")
        v1, v2 = dict(SHARED["status-v1"]), dict(SHARED["status-v2"])
        for doc in (v1, v2):
            doc.pop("schema", None)
        v2.pop("retirement", None)
        compare.check("R11 status v2 keeps every v1 field and meaning", v1 == v2, (v1, v2))
        report_case(compare)
        failed = failed or bool(compare.failed)
    if not args.only and args.tier != "one-shot":
        coverage = Case("coverage")
        coverage.check("R11 every observation status validated", COVERAGE["states"] >= set(STATES), sorted(COVERAGE["states"]))
        coverage.check("R11 every result validated", COVERAGE["results"] >= set(RESULTS), sorted(COVERAGE["results"]))
        report_case(coverage)
        failed = failed or bool(coverage.failed)
    if not args.keep and not failed:
        restore_tree_permissions(WORK)
        shutil.rmtree(WORK, ignore_errors=True)
    else:
        print(f"retirement-test: work kept at {WORK}", flush=True)
    print(f"retirement-test: {'FAIL' if failed else 'ok'} ({len(tasks)} tasks, {time.time() - started:.0f}s)", flush=True)
    return 1 if failed else 0


PRINT_LOCK = threading.Lock()


def report_case(case):
    with PRINT_LOCK:
        status = "FAIL" if case.failed else "PASS"
        print(f"{status} {case.name} ({len(case.results)} checks, {case.elapsed:.1f}s)", flush=True)
        for label, ok, detail in case.results:
            if not ok:
                print(f"  - {label}", flush=True)
                if detail:
                    print("    " + detail.replace("\n", "\n    ")[:3000], flush=True)


if __name__ == "__main__":
    sys.exit(main())
