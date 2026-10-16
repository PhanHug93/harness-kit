#!/usr/bin/env python3
"""Project knowledge engine for the one-shot install/reinstall/update command.

Maintains `.tools/agent-state/project-knowledge.json` (local-only, schema
`harness-project-knowledge/v1`) inside a target project. Kit-only tooling, never
emitted into targets. Current files always win: recorded resolutions are kept
only while the file still has the hash they were recorded against. Writes are
atomic and refused when any path component below the target is a link.
Exit codes: 0 ok, 1 refused or invalid state, 2 usage.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import stat
import sys
import tempfile

SCHEMA = "harness-project-knowledge/v1"
STATE_DIR = os.path.join(".tools", "agent-state")
KNOWLEDGE = os.path.join(STATE_DIR, "project-knowledge.json")
BASELINE_FILES = os.path.join(STATE_DIR, "harness-baseline", "files")
LOCK = os.path.join("docs", "agent-configs", "agent-bootstrap.lock.json")
CONTRACT = os.path.join("docs", "superpowers", "specs", "project-tech-stack.json")
KINDS = ("resolved", "take-kit", "keep-local")
STATUSES = ("pending", "accepted", "declined", "applied", "failed")
MODES = ("install", "reinstall", "update")
RESULTS = ("done", "needs review", "failed")
IGNORES = ("exclude", "gitignore")
MAX_RUNS = 5
HASH = re.compile(r"^[0-9a-f]{64}$")


class Refused(Exception):
    pass


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _check_relpath(rel):
    parts = rel.split("/") if isinstance(rel, str) else []
    if (not parts or rel.startswith("/") or "\\" in rel or "\0" in rel
            or any(part in ("", ".", "..") for part in parts)):
        raise Refused("unsafe relative path: %r" % (rel,))


def _lstat(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Refused("cannot inspect %s: %s" % (path, exc.strerror))


def _check_chain(root, rel):
    """Refuse when any component of rel below root exists as a link."""
    current = root
    for part in rel.split(os.sep):
        current = os.path.join(current, part)
        st = _lstat(current)
        if st is None:
            return
        if stat.S_ISLNK(st.st_mode):
            raise Refused("refusing to use a path that contains a symbolic link: " + current)


def _file_hash(path):
    st = _lstat(path)
    if st is None or not stat.S_ISREG(st.st_mode):
        return ""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _local_hash(root, rel):
    """Hash of a target file; links and non-regular files count as absent."""
    current = root
    for part in rel.split("/"):
        current = os.path.join(current, part)
        st = _lstat(current)
        if st is None or stat.S_ISLNK(st.st_mode):
            return ""
    return _file_hash(current)


def _baseline_dir_hash(root):
    base = os.path.join(root, BASELINE_FILES)
    st = _lstat(base)
    if st is None or not stat.S_ISDIR(st.st_mode):
        return ""
    lines = []
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, base).replace(os.sep, "/")
            lines.append("%s\0%s\n" % (rel, _file_hash(full)))
    if not lines:
        return ""
    return hashlib.sha256("".join(sorted(lines)).encode("utf-8")).hexdigest()


def _empty():
    return {"schema": SCHEMA,
            "kit": {"version": "", "source": "", "lock_sha256": "", "contract_sha256": "", "baseline_sha256": ""},
            "ignore_target": "exclude", "files": {}, "migrations": {}, "runs": []}


def _valid(doc):
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return False
    return (isinstance(doc.get("kit"), dict) and isinstance(doc.get("files"), dict)
            and isinstance(doc.get("migrations"), dict) and isinstance(doc.get("runs"), list)
            and doc.get("ignore_target", "exclude") in IGNORES)


def _load(root):
    _check_chain(root, KNOWLEDGE)
    path = os.path.join(root, KNOWLEDGE)
    if _lstat(path) is None:
        return _empty()
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        raise Refused("project knowledge is unreadable or invalid JSON: %s" % exc)
    if not _valid(doc):
        raise Refused("project knowledge has an unsupported schema or shape: " + path)
    base = _empty()
    base.update(doc)
    return base


def _save(root, doc):
    _check_chain(root, KNOWLEDGE)
    directory = os.path.join(root, STATE_DIR)
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as exc:
        raise Refused("cannot create %s: %s" % (directory, exc.strerror))
    _check_chain(root, KNOWLEDGE)  # re-check after creation
    fd, tmp = tempfile.mkstemp(prefix=".project-knowledge.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, os.path.join(root, KNOWLEDGE))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _derive_state(entry):
    res = entry.get("resolution")
    if res and res.get("kind") == "keep-local" and not res.get("stale"):
        return "pinned"
    if entry.get("owner") == "user":
        return "clean"  # project-owned (brief, contract): never a kit patch
    if entry["local_sha256"] != entry["baseline_sha256"]:
        return "patched"
    return "clean"


def _hash_or_empty(value):
    return value if isinstance(value, str) and HASH.match(value) else ""


# --------------------------------------------------------------------------
# Commands


def cmd_refresh(root, args):
    try:
        with open(args.plan_json, encoding="utf-8") as handle:
            plan = json.load(handle)
    except (OSError, ValueError) as exc:
        raise Refused("cannot read plan JSON: %s" % exc)
    if not isinstance(plan, dict) or not isinstance(plan.get("files"), list):
        raise Refused("plan JSON has no files list (expected agent-bootstrap-upgrade-plan/v1)")
    doc = _load(root)
    old_files = doc["files"]
    files = {}
    for item in plan["files"]:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise Refused("plan JSON file entry without a path")
        rel = item["path"]
        _check_relpath(rel)
        old = old_files.get(rel, {})
        local = _hash_or_empty(item.get("local_sha256")) or _local_hash(root, rel)
        baseline = _hash_or_empty(item.get("baseline_sha256")) or _file_hash(os.path.join(root, BASELINE_FILES, rel))
        entry = {"owner": item.get("owner") if item.get("owner") in ("kit", "user", "overlay") else old.get("owner", "kit"),
                 "baseline_sha256": baseline, "local_sha256": local,
                 "new_sha256": _hash_or_empty(item.get("new_sha256")),
                 "state": "clean", "reason": old.get("reason", "")}
        res = old.get("resolution")
        if isinstance(res, dict):
            if res.get("local_sha256") == local:
                entry["resolution"] = {"kind": res["kind"], "local_sha256": local, "at": res.get("at", ""), "stale": False}
            elif res.get("kind") == "keep-local":
                entry["resolution"] = {"kind": "keep-local", "local_sha256": res.get("local_sha256", ""),
                                       "at": res.get("at", ""), "stale": True}
        entry["state"] = _derive_state(entry)
        files[rel] = entry
    doc["files"] = files
    doc["kit"] = {"version": args.kit_version, "source": args.kit_source,
                  "lock_sha256": _file_hash(os.path.join(root, LOCK)),
                  "contract_sha256": _file_hash(os.path.join(root, CONTRACT)),
                  "baseline_sha256": _baseline_dir_hash(root)}
    _save(root, doc)
    return 0


def cmd_resolve(root, args):
    _check_relpath(args.path)
    doc = _load(root)
    local = args.local_sha256 if args.local_sha256 is not None else _local_hash(root, args.path)
    if local and not HASH.match(local):
        raise Refused("--local-sha256 must be 64 lowercase hex characters")
    entry = doc["files"].get(args.path)
    if entry is None:
        entry = {"owner": "kit", "baseline_sha256": _file_hash(os.path.join(root, BASELINE_FILES, args.path)),
                 "local_sha256": _local_hash(root, args.path), "new_sha256": "", "state": "clean", "reason": ""}
        doc["files"][args.path] = entry
    if args.reason is not None:
        entry["reason"] = args.reason
    entry["resolution"] = {"kind": args.kind, "local_sha256": local, "at": _now(), "stale": local != entry["local_sha256"]}
    entry["state"] = _derive_state(entry)
    _save(root, doc)
    return 0


def cmd_clear(root, args):
    """Drop recorded resolutions (pins included) of the given paths."""
    doc = _load(root)
    for rel in args.paths:
        _check_relpath(rel)
        entry = doc["files"].get(rel)
        if isinstance(entry, dict) and "resolution" in entry:
            del entry["resolution"]
            entry["reason"] = ""
            entry["state"] = _derive_state(entry)
    _save(root, doc)
    return 0


def cmd_restore(root, args):
    """Put back resolutions saved before a --reset cleared them (rollback).
    A restored resolution is stale when the file no longer has its hash."""
    try:
        with open(args.entries, encoding="utf-8") as handle:
            saved = json.load(handle)
    except (OSError, ValueError) as exc:
        raise Refused("cannot read saved entries: %s" % exc)
    if not isinstance(saved, dict):
        raise Refused("saved entries must be an object of path -> entry")
    doc = _load(root)
    for rel, old in saved.items():
        _check_relpath(rel)
        res = old.get("resolution") if isinstance(old, dict) else None
        if not isinstance(res, dict) or res.get("kind") not in KINDS:
            continue
        entry = doc["files"].get(rel)
        if entry is None:
            entry = {"owner": old.get("owner", "kit"), "baseline_sha256": "", "local_sha256": _local_hash(root, rel),
                     "new_sha256": "", "state": "clean", "reason": ""}
            doc["files"][rel] = entry
        local = _local_hash(root, rel)
        entry["local_sha256"] = local
        entry["reason"] = old.get("reason", "")
        entry["resolution"] = {"kind": res["kind"], "local_sha256": res.get("local_sha256", ""),
                               "at": res.get("at", ""), "stale": res.get("local_sha256", "") != local}
        entry["state"] = _derive_state(entry)
    _save(root, doc)
    return 0


def cmd_pins(root, args):
    for rel in sorted(_load(root)["files"]):
        res = _load(root)["files"][rel].get("resolution")
        if res and res.get("kind") == "keep-local" and not res.get("stale"):
            print(rel)
    return 0


def cmd_decision(root, args):
    if not args.id:
        raise Refused("decision id must not be empty")
    doc = _load(root)
    doc["migrations"][args.id] = {"status": args.status, "facts_sha256": args.facts_sha256, "at": _now()}
    _save(root, doc)
    return 0


def cmd_decisions(root, args):
    for ident in sorted(_load(root)["migrations"]):
        if _load(root)["migrations"][ident].get("status") == "pending":
            print(ident)
    return 0


def cmd_ignore_target(root, args):
    doc = _load(root)
    if args.value is None:
        print(doc.get("ignore_target", "exclude"))
        return 0
    doc["ignore_target"] = args.value
    _save(root, doc)
    return 0


def cmd_record_run(root, args):
    doc = _load(root)
    doc["runs"].append({"stamp": args.stamp, "mode": args.mode, "from": args.from_, "to": args.to, "result": args.result})
    doc["runs"] = doc["runs"][-MAX_RUNS:]
    _save(root, doc)
    return 0


def _clip(text, width=110):
    text = " ".join(str(text).split())
    return text if len(text) <= width else text[:width - 3] + "..."


def cmd_summary(root, args):
    doc = _load(root)
    out = ["kit %s, ignore target: %s" % (doc["kit"].get("version") or "unknown", doc.get("ignore_target", "exclude"))]

    def section(label, items, cap):
        if not items:
            return
        for item in items[:cap]:
            out.append("%s %s" % (label, item))
        if len(items) > cap:
            out.append("%s ... %d more" % (label, len(items) - cap))

    patches, pins = [], []
    for rel in sorted(doc["files"]):
        entry = doc["files"][rel]
        res = entry.get("resolution") or {}
        if entry.get("state") == "patched":
            patches.append("%s%s" % (rel, " (%s)" % entry["reason"] if entry.get("reason") else ""))
        if res.get("kind") == "keep-local":
            pins.append("%s%s" % (rel, " [stale]" if res.get("stale") else ""))
    section("patch:", [_clip(p) for p in patches], 4)
    section("pin:", [_clip(p) for p in pins], 3)
    pending = sorted(i for i, m in doc["migrations"].items() if m.get("status") == "pending")
    if pending:
        out.append(_clip("pending decisions: " + ", ".join(pending)))
    for run in doc["runs"][-3:][::-1]:
        out.append(_clip("run %s %s %s -> %s: %s" % (run.get("stamp", ""), run.get("mode", ""),
                                                      run.get("from", "") or "-", run.get("to", ""), run.get("result", ""))))
    print("\n".join(out[:15]))
    return 0


# --------------------------------------------------------------------------
# Command line


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("knowledge: %s\n" % message)
        raise SystemExit(2)


def _parser():
    parser = _Parser(prog="knowledge.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--target", required=True)
    commands = parser.add_subparsers(dest="command")
    commands.required = True
    sub = commands.add_parser("refresh")
    sub.add_argument("--plan-json", required=True)
    sub.add_argument("--kit-version", required=True)
    sub.add_argument("--kit-source", required=True)
    sub = commands.add_parser("resolve")
    sub.add_argument("path")
    sub.add_argument("--kind", required=True, choices=KINDS)
    sub.add_argument("--reason")
    sub.add_argument("--local-sha256")
    sub = commands.add_parser("clear")
    sub.add_argument("paths", nargs="+")
    sub = commands.add_parser("restore")
    sub.add_argument("--entries", required=True)
    commands.add_parser("pins")
    sub = commands.add_parser("decision")
    sub.add_argument("id")
    sub.add_argument("--status", required=True, choices=STATUSES)
    sub.add_argument("--facts-sha256", required=True)
    sub = commands.add_parser("decisions")
    sub.add_argument("--pending", action="store_true", required=True)
    sub = commands.add_parser("ignore-target")
    sub.add_argument("value", nargs="?", choices=IGNORES)
    sub = commands.add_parser("record-run")
    sub.add_argument("--stamp", required=True)
    sub.add_argument("--mode", required=True, choices=MODES)
    sub.add_argument("--from", dest="from_", required=True)
    sub.add_argument("--to", required=True)
    sub.add_argument("--result", required=True, choices=RESULTS)
    commands.add_parser("summary")
    return parser


HANDLERS = {"refresh": cmd_refresh, "resolve": cmd_resolve, "clear": cmd_clear, "restore": cmd_restore, "pins": cmd_pins, "decision": cmd_decision,
            "decisions": cmd_decisions, "ignore-target": cmd_ignore_target, "record-run": cmd_record_run,
            "summary": cmd_summary}


def main(argv=None):
    args = _parser().parse_args(argv)
    root = os.path.realpath(os.path.abspath(args.target))
    if not os.path.isdir(root):
        sys.stderr.write("knowledge: target is not a directory: %s\n" % args.target)
        return 1
    try:
        return HANDLERS[args.command](root, args)
    except Refused as exc:
        sys.stderr.write("knowledge: %s\n" % exc)
        return 1
    except OSError as exc:
        sys.stderr.write("knowledge: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
