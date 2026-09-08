#!/usr/bin/env python3
"""Exercise real older releases through the public one-shot/candidate upgrade.

Requires the two historical Git tags (CI checks out full history). Never runs on
real downstream projects. --source-dir accepts a disposable bundle snapshot for
RED checks; historical releases still come from this repository.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-dir", type=Path, default=ROOT)
parser.add_argument("--evidence-dir", type=Path)
parser.add_argument("--legacy-ref", action="append")
args = parser.parse_args()
SOURCE = args.source_dir.resolve()
REFS = args.legacy_ref or ["v2026.08.10.1", "v2026.09.07.1"]
WORK = Path(tempfile.mkdtemp(prefix="seats-migration-"))
OUT = (args.evidence_dir or WORK / "evidence").resolve()
OUT.mkdir(parents=True, exist_ok=True)
ENV = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
VERSION = (SOURCE / "agent-bootstrap/VERSION").read_text().strip()
checks = []
error = None


def command(label, argv, cwd=ROOT, expected=0):
    proc = subprocess.run([str(a) for a in argv], cwd=cwd, env=ENV,
                          capture_output=True, text=True, timeout=240)
    log = OUT / re.sub(r"[^a-zA-Z0-9._-]", "-", label)
    Path(str(log) + ".stdout").write_text(proc.stdout)
    Path(str(log) + ".stderr").write_text(proc.stderr)
    Path(str(log) + ".json").write_text(json.dumps({"command": [str(a) for a in argv], "rc": proc.returncode, "expected": expected}, indent=2) + "\n")
    assert proc.returncode == expected, (label, proc.returncode, proc.stderr[-3000:])
    return proc


def check(label, ok):
    checks.append({"check": label, "ok": bool(ok)})
    print(("PASS " if ok else "FAIL ") + label, flush=True)
    assert ok, label


def export(ref):
    dest = WORK / ref
    dest.mkdir()
    archive = subprocess.run(["git", "archive", "--format=tar", ref, "agent-bootstrap"],
                             cwd=ROOT, env=ENV, capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            path = dest / member.name
            assert dest.resolve() in path.resolve().parents, member.name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(tar.extractfile(member).read())
                path.chmod(member.mode)
            else:
                raise AssertionError("unexpected archive member " + member.name)
    return dest


def generate(source, target, label, *flags):
    return command(label, ["/bin/bash", source / "agent-bootstrap/bootstrap-multi-agent-project.sh",
                           "--target", target, "--workflow", "full", *flags])


def seed_target(source, name):
    target = WORK / name
    target.mkdir()
    command(name + "-git-init", ["git", "init", "-q", str(target)])
    (target / "README.md").write_text("# Existing project\n")
    generate(source, target, name + "-old-generate")
    agents = target / "AGENTS.md"
    text = agents.read_text()
    marker = "<!-- BEGIN USER: agents:extra -->"
    if marker in text:
        text = text.replace(marker, marker + "\nCUSTOM USER OVERLAY: keep the project-specific policy.\n", 1)
    else:
        text += "\n" + marker + "\nCUSTOM USER OVERLAY: keep the project-specific policy.\n<!-- END USER: agents:extra -->\n"
    agents.write_text(text)
    brief = target / "docs/agent-configs/project-brief.md"
    brief.write_text("# Filled project brief\n\nUser-owned architecture: offline-first sync; never discard this onboarding knowledge.\n")
    return target


def upgrade(target, label, apply=False, dry=False):
    argv = ["/bin/bash", SOURCE / "agent-bootstrap/harness-kit-one-shot-upgrade.sh",
            "--source-dir", SOURCE, "--ref", "v" + VERSION,
            "--target", target, "--home", WORK / (target.name + "-home"),
            "--allow-dirty", "--no-branch", "--skip-verify"]
    if apply:
        argv.append("--apply-candidates")
    if dry:
        argv.append("--dry-run")
    return command(label, argv)


def tree_hashes(target):
    return {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in target.rglob("*") if p.is_file() and ".git" not in p.relative_to(target).parts}


def keep_knowledge(target, before_brief, label):
    check(label + " brief bytes preserved", (target / "docs/agent-configs/project-brief.md").read_bytes() == before_brief)
    check(label + " USER overlay preserved", b"CUSTOM USER OVERLAY" in (target / "AGENTS.md").read_bytes())


def seats(target, label, *cmd, expected=0):
    return command(label, ["/bin/bash", target / "scripts/agent-seats.sh", *cmd], cwd=target, expected=expected)


try:
    for ref in REFS:
        old = export(ref)
        target = seed_target(old, "custom-" + ref)
        cfg = target / "docs/agent-configs"
        legacy = cfg / "model-profiles.json"
        profile = {"reasoning_effort": "low", "planning_model": "custom-planner",
                   "coding_model": "gpt-5.6-luna", "reviewing_model": "custom-verifier",
                   "planning_fallback_model": "custom-backup", "coding_fallback_model": "gpt-5.6-terra",
                   "reviewing_fallback_model": "custom-backup", "planning_reasoning_effort": "high",
                   "reviewing_reasoning_effort": "xhigh", "planning_fallback_reasoning_effort": "medium"}
        legacy.write_text(json.dumps({"schema": "agent-model-profiles/v1", "default_profile": "team",
                                      "profiles": {"team": profile, "spare": dict(profile)}}) + "\n")
        legacy_before = legacy.read_bytes()
        stale_candidate = cfg / "model-profiles.json.generated.20000101"
        stale_candidate.write_bytes(b'{"obsolete_candidate": true}\n')
        brief_before = (cfg / "project-brief.md").read_bytes()
        agents_before = (target / "AGENTS.md").read_bytes()
        before = tree_hashes(target)
        upgrade(target, ref + "-dry-upgrade", dry=True)
        check(ref + " public dry-run no writes", tree_hashes(target) == before)
        check(ref + " public dry-run no home installation", not (WORK / (target.name + "-home")).exists())
        upgrade(target, ref + "-candidate-upgrade")
        check(ref + " creates seats runtime", (target / "scripts/agent-seats.sh").is_file())
        check(ref + " keeps live AGENTS before apply", (target / "AGENTS.md").read_bytes() == agents_before)
        check(ref + " legacy input bytes preserved", legacy.read_bytes() == legacy_before)
        doc = json.loads((cfg / "seats.json").read_text())
        for route, seat in (("planning", "gate"), ("coding", "build"), ("reviewing", "verify")):
            expected = {"host": "codex", "model": profile[route + "_model"],
                        "effort": profile.get(route + "_reasoning_effort", "low"),
                        "fallback_model": profile[route + "_fallback_model"],
                        "fallback_effort": profile.get(route + "_fallback_reasoning_effort", "low")}
            check(ref + " migrates " + seat + " model/effort/fallback", doc["seats"][seat]["occupant"] == expected)
        seats_before = (cfg / "seats.json").read_bytes()
        upgrade(target, ref + "-apply-upgrade", apply=True)
        keep_knowledge(target, brief_before, ref + " apply")
        check(ref + " apply keeps seats and legacy", (cfg / "seats.json").read_bytes() == seats_before and legacy.read_bytes() == legacy_before)
        check(ref + " obsolete legacy candidate is not promoted", stale_candidate.read_bytes() == b'{"obsolete_candidate": true}\n')
        check(ref + " no seats candidate", not list(cfg.glob("seats.json.generated.*")))
        seats(target, ref + "-validate", "validate")
        status = command(ref + "-status", ["/bin/bash", target / ".codex/codex-mode.sh", "status"], cwd=target)
        check(ref + " launcher uses migrated model", "custom-planner" in status.stdout or "custom-planner" in status.stderr)
        upgrade(target, ref + "-repeat-upgrade", apply=True)
        check(ref + " repeated migration keeps exact config bytes", (cfg / "seats.json").read_bytes() == seats_before and legacy.read_bytes() == legacy_before)
        keep_knowledge(target, brief_before, ref + " repeat")
        lock = json.loads((cfg / "agent-bootstrap.lock.json").read_text())
        state = json.loads(generate(SOURCE, target, ref + "-bootstrap-status", "--status", "--json").stdout)
        check(ref + " retired candidate agrees with complete lock and zero pending",
              lock["apply_state"] == "complete" and state["pending_generated_candidates"] == 0)

    # Existing authoritative seats take precedence even over damaged legacy.
    authoritative = cfg / "seats.json"
    doc = json.loads(authoritative.read_text())
    doc["seats"]["spec"]["occupant"] = {"host": "gemini"}
    doc["seats"]["gate"]["occupant"]["effort"] = "medium"
    authoritative.write_text(json.dumps(doc, indent=4) + "\n")
    exact = authoritative.read_bytes()
    legacy.write_bytes(b"{ damaged legacy, kept for operator recovery\n")
    damaged_legacy = legacy.read_bytes()
    upgrade(target, "existing-seats-upgrade", apply=True)
    check("existing seats win and remain byte-identical", authoritative.read_bytes() == exact)
    check("damaged inactive legacy remains untouched", legacy.read_bytes() == damaged_legacy)
    command("existing-seats-status", ["/bin/bash", target / ".codex/codex-mode.sh", "status"], cwd=target)
    command("existing-seats-verifier", ["/bin/bash", target / "scripts/verify-ai-deps.sh"], cwd=target)
    keep_knowledge(target, brief_before, "existing seats")

    # A failed migration never quietly replaces the operator's invalid data.
    authoritative.unlink()
    upgrade(target, "malformed-legacy-upgrade", apply=True)
    check("malformed legacy never seeds defaults", not authoritative.exists() and legacy.read_bytes() == damaged_legacy)
    command("malformed-legacy-no-launch", ["/bin/bash", target / ".codex/codex-mode.sh", "planning", "probe"], cwd=target, expected=1)
    keep_knowledge(target, brief_before, "malformed legacy")

    default_target = seed_target(old, "old-defaults")
    old_defaults = (default_target / "docs/agent-configs/model-profiles.json").read_bytes()
    upgrade(default_target, "old-defaults-upgrade", apply=True)
    default_doc = json.loads((default_target / "docs/agent-configs/seats.json").read_text())
    check("old uncustomized defaults adopt Astra ultra", default_doc["seats"]["gate"]["occupant"]["model"] == "gpt-6-astra" and default_doc["seats"]["gate"]["occupant"]["effort"] == "ultra")
    check("old default input is retained", (default_target / "docs/agent-configs/model-profiles.json").read_bytes() == old_defaults)

    fresh = WORK / "fresh"
    fresh.mkdir()
    generate(SOURCE, fresh, "fresh-generate")
    check("fresh target has seats and no legacy", (fresh / "docs/agent-configs/seats.json").is_file() and not (fresh / "docs/agent-configs/model-profiles.json").exists())
except Exception as exc:
    error = str(exc)
    raise
finally:
    summary = {"source": str(SOURCE), "work": str(WORK), "historical_refs": REFS,
               "checks": checks, "passed": sum(c["ok"] for c in checks),
               "failed": sum(not c["ok"] for c in checks), "error": error}
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Migration evidence: " + str(OUT), flush=True)
