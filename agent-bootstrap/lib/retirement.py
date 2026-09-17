#!/usr/bin/env python3
"""HK-07 retired-artifact engine for bootstrap-multi-agent-project.sh.

One closed-inventory classifier, typed renderer and backup/apply engine. This is
bundled code with a fixed inventory location, not a general cleanup API: there
is no inventory, path or digest override. `plan`, `status`, `section` and
`status-v2` are read-only; only `apply` removes an exact historical match, and
only after writing and verifying an adjacent backup. Paths are walked with
lstat/O_NOFOLLOW one component at a time; links, special files and multi-link
files are reported, never followed, read or removed. This is bounded path
hardening with deterministic rechecks, not a sandbox against hostile
concurrent directory replacement.
"""
import argparse
import datetime
import errno
import hashlib
import json
import os
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys

SCHEMA = "agent-bootstrap-retirement/v1"
STATUS_V1 = "agent-bootstrap-status/v1"
STATUS_V2 = "agent-bootstrap-status/v2"
POLICY_SCHEMA = "agent-bootstrap-retired-artifacts/v1"
POLICY_ID = "hk07-agent-guard/v1"
POLICY_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "policies", "retired-artifacts-v1.json")
REASON = "generated-remote-ci-retired"

# The reviewed inventory is pinned here as well as in the bundled JSON, so an
# edited policy document cannot widen retirement to other paths or bytes.
FINGERPRINT = {
    "source_ref": "v2026.08.10.1",
    "source_commit": "b1907f5fe7caf9d9e401606a93fa0815739b6df0",
    "source_path": "agent-bootstrap/templates/ci/agent-guard.yml",
    "size_bytes": 605,
    "sha256": "751c8c3f88fd1fc3bcc5c1ddff940e1280b1a5149c787d3110a4408a39810ebb",
}
ARTIFACTS = (
    ("agent-guard-workflow", ".github/workflows/agent-guard.yml"),
    ("agent-guard-template", "docs/agent-configs/bootstrap-multi-agent-project/templates/ci/agent-guard.yml"),
)
PINNED_POLICY = {
    "schema": POLICY_SCHEMA,
    "policy_id": POLICY_ID,
    "artifacts": [{"id": artifact_id, "path": path, "reason": REASON, "fingerprints": [dict(FINGERPRINT)]}
                  for artifact_id, path in ARTIFACTS],
}

STATES = ("absent", "eligible", "modified", "unsafe-type", "error")
RESULTS = ("planned", "retired", "preserved", "unchanged", "error", "not-attempted")
SCOPES = ("local-only", "all-matching")
CONTEXTS = ("generate", "diff", "upgrade-plan", "status", "apply-candidates", "cleanup-backups")
# HK-01 lexical exclusions from core.sh bootstrap_path_is_within_root. No link
# is ever followed here, so the resolved spelling equals the lexical one.
EXCLUDED = {".git", ".tools", ".idea", ".next", "node_modules", "Pods", "vendor", "build", "dist", "out",
            "local.properties", "keystore.properties"}
# Variables that would redirect Git away from the target's own repository.
GIT_REDIRECTS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_QUARANTINE_PATH",
                 "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")

O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC
LEAF_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0) | O_CLOEXEC
BACKUP_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | O_CLOEXEC


class PolicyError(ValueError):
    pass


class StopRun(Exception):
    """An apply failure after which remaining actions are not attempted."""


class BackupError(Exception):
    pass


class BackupCollision(Exception):
    pass


class Interrupted(BaseException):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def _barrier(stage, entry_id):
    """Stage hook between apply operations; a no-op outside test harnesses."""
    return None


def _new_run_id():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return stamp + "-" + secrets.token_hex(8)


def _one_line(text):
    return " ".join(str(text).split())


def _os_error(exc, action):
    name = errno.errorcode.get(exc.errno, "error") if exc.errno else "error"
    return "%s failed: %s (%s)" % (action, name, exc.strerror or "unknown")


def _display(value):
    """Escape control, line-break and undecodable characters for terminals."""
    out = []
    for char in value:
        code = ord(char)
        if char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif code < 0x20 or 0x7f <= code <= 0x9f or 0xd800 <= code <= 0xdfff:
            out.append("\\u%04x" % code)
        else:
            out.append(char)
    return "".join(out)


def _hk01_excluded(parts):
    return any(
        part in EXCLUDED or part.startswith(".gradle") or part.startswith(".env")
        or part.endswith((".jks", ".keystore", ".pem", ".p8", ".key"))
        or (part == ".agents" and index + 1 < len(parts) and parts[index + 1] in {"runtime", "state", "cache"})
        for index, part in enumerate(parts))


# --------------------------------------------------------------------------
# Inventory


def _no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise PolicyError("duplicate key " + json.dumps(key))
        seen[key] = value
    return seen


def _reject_constant(name):
    raise PolicyError("non-finite number " + name)


def _exact_keys(value, keys, where):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise PolicyError("%s must have exactly the keys %s" % (where, ", ".join(keys)))


def _check_relpath(path, where):
    if not isinstance(path, str) or not path:
        raise PolicyError(where + " must be a non-empty string")
    if path.startswith("/") or "\\" in path or any(char in path for char in "*?[]{}"):
        raise PolicyError(where + " must be an exact relative path without globs")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise PolicyError(where + " must not contain alias components")
    if _hk01_excluded(parts):
        raise PolicyError(where + " is excluded by the core root policy")


def validate_policy(doc):
    _exact_keys(doc, ("schema", "policy_id", "artifacts"), "inventory")
    if doc["schema"] != POLICY_SCHEMA:
        raise PolicyError("unsupported inventory schema")
    if doc["policy_id"] != POLICY_ID:
        raise PolicyError("unsupported policy id")
    artifacts = doc["artifacts"]
    if not isinstance(artifacts, list) or len(artifacts) != len(ARTIFACTS):
        raise PolicyError("inventory must list exactly the reviewed artifacts")
    seen_ids, seen_paths = set(), set()
    for index, (artifact, pinned) in enumerate(zip(artifacts, ARTIFACTS)):
        where = "artifacts[%d]" % index
        _exact_keys(artifact, ("id", "path", "reason", "fingerprints"), where)
        _check_relpath(artifact["path"], where + ".path")
        if artifact["id"] in seen_ids or artifact["path"] in seen_paths:
            raise PolicyError("duplicate artifact id or path")
        seen_ids.add(artifact["id"])
        seen_paths.add(artifact["path"])
        if (artifact["id"], artifact["path"]) != pinned:
            raise PolicyError(where + " is not the pinned id/path pair")
        if artifact["reason"] != REASON:
            raise PolicyError(where + ".reason is not supported")
        prints = artifact["fingerprints"]
        if not isinstance(prints, list) or len(prints) != 1:
            raise PolicyError(where + " must have exactly one fingerprint")
        fingerprint = prints[0]
        _exact_keys(fingerprint, tuple(FINGERPRINT), where + ".fingerprints[0]")
        size = fingerprint["size_bytes"]
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise PolicyError(where + " size must be a nonnegative integer")
        if not isinstance(fingerprint["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint["sha256"]):
            raise PolicyError(where + " digest must be lowercase SHA-256 hex")
        if not isinstance(fingerprint["source_commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", fingerprint["source_commit"]):
            raise PolicyError(where + " source commit must be a full lowercase hex commit")
        if fingerprint != FINGERPRINT:
            raise PolicyError(where + " is not the reviewed historical fingerprint")
    if doc != PINNED_POLICY:
        raise PolicyError("inventory differs from the pinned reviewed policy")


def load_policy():
    """Return (digest or None, {id: fingerprint} or None, error message or None)."""
    try:
        with open(POLICY_FILE, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        return None, None, "inventory unreadable: " + _os_error(exc, "read")
    digest = hashlib.sha256(raw).hexdigest()
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicates, parse_constant=_reject_constant)
        validate_policy(doc)
    except (UnicodeDecodeError, ValueError) as exc:
        return digest, None, "inventory invalid: " + _one_line(exc)
    return digest, {item["id"]: item["fingerprints"][0] for item in doc["artifacts"]}, None


# --------------------------------------------------------------------------
# Observation


def _obs(status, reason, file_type, size=None, digest=None, ownership=None):
    return {"status": status, "reason": reason, "file_type": file_type,
            "size_bytes": size, "sha256": digest, "ownership": ownership}


def _file_type(mode):
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    return "other"


def _same_file(current, checked):
    return (stat.S_ISREG(current.st_mode) and current.st_dev == checked.st_dev and current.st_ino == checked.st_ino
            and current.st_size == checked.st_size and current.st_mtime_ns == checked.st_mtime_ns
            and current.st_nlink == checked.st_nlink)


def _read_all(fd, limit):
    chunks, total = [], 0
    while total < limit:
        chunk = os.read(fd, min(65536, limit - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def _write_all(fd, data):
    view = memoryview(data)
    offset = 0
    while offset < len(view):
        written = os.write(fd, view[offset:])
        if written <= 0:
            raise OSError(errno.EIO, "short write")
        offset += written


class Inspection(object):
    __slots__ = ("observation", "ancestors", "leaf", "candidates", "scan", "errors", "parent_fd")

    def __init__(self):
        self.observation = None
        self.ancestors = None
        self.leaf = None
        self.candidates = []
        self.scan = "complete"
        self.errors = []
        self.parent_fd = None


def _open_parent(root, components):
    """Open the parent chain one checked ordinary directory at a time.

    Returns ("ok", (fd, identities)), ("absent", None), ("unsafe", reason) or
    ("error", (reason, message)). Links are never followed or resolved.
    """
    try:
        fd = os.open(root, DIR_FLAGS)
    except OSError as exc:
        return "error", ("io-error", _os_error(exc, "root open"))
    try:
        opened = os.fstat(fd)
        identities = [(opened.st_dev, opened.st_ino)]
        for component in components:
            try:
                st = os.lstat(component, dir_fd=fd)
            except FileNotFoundError:
                return "absent", None
            except OSError as exc:
                return "error", ("io-error", _os_error(exc, "ancestor lstat"))
            if stat.S_ISLNK(st.st_mode):
                return "unsafe", "symlink-ancestor"
            if not stat.S_ISDIR(st.st_mode):
                return "unsafe", "non-directory-ancestor"
            try:
                child = os.open(component, DIR_FLAGS, dir_fd=fd)
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOTDIR, errno.ENOENT):
                    return "error", ("identity-changed", "ancestor changed during inspection")
                return "error", ("io-error", _os_error(exc, "ancestor open"))
            os.close(fd)
            fd = child
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino):
                return "error", ("identity-changed", "ancestor identity changed during inspection")
            identities.append((st.st_dev, st.st_ino))
        result, fd = fd, None
        return "ok", (result, identities)
    except OSError as exc:
        return "error", ("io-error", _os_error(exc, "ancestor inspection"))
    finally:
        if fd is not None:
            os.close(fd)


def _inspect_leaf(parent_fd, name, fingerprint):
    """Classify one leaf; returns (observation, (dev, ino) or None, message)."""
    try:
        leaf_stat = os.lstat(name, dir_fd=parent_fd)
    except FileNotFoundError:
        return _obs("absent", "missing", "absent"), None, None
    except OSError as exc:
        return _obs("error", "io-error", "unknown"), None, _os_error(exc, "leaf lstat")
    mode = leaf_stat.st_mode
    if stat.S_ISLNK(mode):
        return _obs("unsafe-type", "symlink-leaf", "symlink"), None, None
    if not stat.S_ISREG(mode):
        return _obs("unsafe-type", "special-leaf", _file_type(mode)), None, None
    size = leaf_stat.st_size
    if leaf_stat.st_nlink != 1:
        return _obs("unsafe-type", "multiple-hard-links", "regular", size), None, None
    identity = (leaf_stat.st_dev, leaf_stat.st_ino)
    if size != fingerprint["size_bytes"]:
        return _obs("modified", "size-mismatch", "regular", size), identity, None
    changed = _obs("error", "identity-changed", "regular", size)
    try:
        fd = os.open(name, LEAF_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOENT, errno.ENXIO, errno.EISDIR):
            return changed, None, "leaf changed during inspection"
        return _obs("error", "io-error", "regular", size), None, _os_error(exc, "leaf open")
    try:
        opened = os.fstat(fd)
        if not _same_file(opened, leaf_stat):
            return changed, None, "leaf identity changed during inspection"
        data = _read_all(fd, size + 1)
        after = os.fstat(fd)
        again = os.lstat(name, dir_fd=parent_fd)
    except OSError as exc:
        return _obs("error", "io-error", "regular", size), None, _os_error(exc, "leaf read")
    finally:
        os.close(fd)
    if len(data) != size or not (_same_file(after, leaf_stat) and _same_file(again, leaf_stat)):
        return changed, None, "leaf changed while it was read"
    digest = hashlib.sha256(data).hexdigest()
    if digest == fingerprint["sha256"]:
        return _obs("eligible", "exact-match", "regular", size, digest), identity, None
    return _obs("modified", "digest-mismatch", "regular", size, digest), identity, None


def _entry_type(item):
    try:
        if item.is_symlink():
            return "symlink"
        if item.is_dir(follow_symlinks=False):
            return "directory"
        if item.is_file(follow_symlinks=False):
            return "regular"
        return "other"
    except OSError:
        return "unknown"


def _scan_candidates(parent_fd, parent_rel, base):
    """List direct siblings named <base>.generated.<suffix>; metadata only."""
    prefix = base + ".generated."
    found = []
    try:
        with os.scandir(parent_fd) as entries:
            for item in entries:
                if item.name.startswith(prefix) and len(item.name) > len(prefix):
                    found.append({"path": parent_rel + "/" + item.name, "file_type": _entry_type(item)})
    except OSError as exc:
        return "error", [], _os_error(exc, "candidate enumeration")
    found.sort(key=lambda item: item["path"])
    return "complete", found, None


def _git_env():
    env = {key: value for key, value in os.environ.items()
           if key not in GIT_REDIRECTS and not key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["LC_ALL"] = "C"
    return env


def _git(root, *args):
    return subprocess.run(["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", root] + list(args),
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=_git_env(), timeout=60)


def _git_metadata_above(root):
    path = root
    while True:
        if os.path.lexists(os.path.join(path, ".git")):
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


def _ownership(root, parts):
    """local-only (untracked and ignored), project-owned or error.

    Literal-path, read-only index/ignore queries (check-ignore takes plain
    pathnames); optional locks and index refresh are disabled. A
    target-controlled .git link or a nested repository boundary is refused
    rather than followed.
    """
    for index in range(len(parts)):
        try:
            git_entry = os.lstat(os.path.join(root, *(list(parts[:index]) + [".git"])))
        except FileNotFoundError:
            continue
        except OSError:
            return "error"
        if index > 0 or stat.S_ISLNK(git_entry.st_mode):
            return "error"
    try:
        probe = _git(root, "rev-parse", "--is-inside-work-tree")
    except FileNotFoundError:
        return "error" if _git_metadata_above(root) else "project-owned"
    except (OSError, subprocess.SubprocessError):
        return "error"
    if probe.returncode != 0:
        return "project-owned" if b"not a git repository" in probe.stderr.lower() else "error"
    if probe.stdout.strip() != b"true":
        return "error"
    rel = "/".join(parts)
    try:
        listed = _git(root, "ls-files", "--cached", "-z", "--", ":(literal)" + rel)
        if listed.returncode != 0:
            return "error"
        if listed.stdout:
            return "project-owned"  # tracked
        ignored = _git(root, "check-ignore", "-q", "--", rel)
    except (OSError, subprocess.SubprocessError):
        return "error"
    if ignored.returncode == 0:
        return "local-only"
    if ignored.returncode == 1:
        return "project-owned"
    return "error"


def inspect_entry(root, rel, fingerprint, keep_parent=False):
    """Fresh inspection of one inventory path; keep_parent returns its open parent fd."""
    parts = rel.split("/")
    parent_rel = "/".join(parts[:-1])
    insp = Inspection()
    state, value = _open_parent(root, parts[:-1])
    if state == "absent":
        insp.observation = _obs("absent", "missing", "absent")
        return insp
    if state == "unsafe":
        insp.observation = _obs("unsafe-type", value, "unknown")
        insp.scan = "unsafe-parent"
        return insp
    if state == "error":
        reason, message = value
        insp.observation = _obs("error", reason, "unknown")
        insp.scan = "error"
        insp.errors = [("inspection-failed", rel, message),
                       ("candidate-scan-failed", parent_rel, "candidate scan not performed: " + message)]
        return insp
    parent_fd, insp.ancestors = value
    try:
        observation, insp.leaf, message = _inspect_leaf(parent_fd, parts[-1], fingerprint)
        if observation["status"] == "eligible":
            ownership = _ownership(root, parts)
            if ownership == "error":
                observation = _obs("error", "ownership-error", "regular", observation["size_bytes"], None, "error")
                insp.errors.append(("ownership-failed", rel, "ownership inspection failed or was refused "
                                    "(Git metadata unavailable, linked or nested)"))
            else:
                observation["ownership"] = ownership
        elif observation["status"] == "error":
            insp.errors.append(("inspection-failed", rel, message or "inspection failed"))
        insp.observation = observation
        insp.scan, insp.candidates, scan_message = _scan_candidates(parent_fd, parent_rel, parts[-1])
        if scan_message:
            insp.errors.append(("candidate-scan-failed", parent_rel, scan_message))
        if keep_parent:
            insp.parent_fd, parent_fd = parent_fd, None
    finally:
        if parent_fd is not None:
            os.close(parent_fd)
    return insp


def _in_scope(ownership, scope):
    return ownership == "local-only" or (scope == "all-matching" and ownership == "project-owned")


def _action(observation, scope):
    if observation["status"] == "absent":
        return "none"
    if observation["status"] == "eligible" and _in_scope(observation["ownership"], scope):
        return "retire"
    return "preserve"


def _entry(artifact_id, rel, insp, scope, result):
    return {"id": artifact_id, "path": rel, "observed": insp.observation, "action": _action(insp.observation, scope),
            "result": result, "after": None, "backup": None, "stale_candidates": insp.candidates,
            "candidate_scan": insp.scan}


def build_report(root, digest, mode, dry_run, scope, run_id, entries, errors):
    states = dict((name, 0) for name in STATES)
    results = dict((name, 0) for name in RESULTS)
    for item in entries:
        states[(item["after"] or item["observed"])["status"]] += 1
        results[item["result"]] += 1
    stale = sum(len(item["stale_candidates"]) for item in entries)
    incomplete = sum(item["candidate_scan"] != "complete" for item in entries)
    attention = (any(states[name] for name in ("eligible", "modified", "unsafe-type", "error"))
                 or stale > 0 or incomplete > 0 or bool(errors))
    return {
        "schema": SCHEMA, "policy_id": POLICY_ID, "policy_sha256": digest, "target": root, "mode": mode,
        "dry_run": dry_run, "scope": scope, "run_id": run_id, "entries": entries,
        "summary": {"states": states, "results": results, "stale_candidate_count": stale,
                    "incomplete_candidate_scans": incomplete, "attention_required": attention},
        "errors": [{"code": code, "path": path, "message": _one_line(message)} for code, path, message in errors],
    }


def _canonical_root(target):
    root = os.path.realpath(os.path.abspath(target))
    try:
        st = os.stat(root)
    except OSError as exc:
        return root, _os_error(exc, "target root inspection")
    if not stat.S_ISDIR(st.st_mode):
        return root, "target root is not a directory"
    return root, None


def _prepare(target):
    """Return (root, digest, fingerprints, failure) where failure stops all inspection."""
    digest, fingerprints, policy_error = load_policy()
    root, root_error = _canonical_root(target)
    if policy_error:
        return root, digest, None, ("policy-invalid", "invalid-policy", policy_error)
    if root_error:
        return root, digest, None, ("root-invalid", "invalid-root", root_error)
    return root, digest, fingerprints, None


def _failed_report(root, digest, mode, dry_run, scope, run_id, failure):
    code, reason, message = failure
    entries = []
    for artifact_id, rel in ARTIFACTS:
        insp = Inspection()
        insp.observation = _obs("error", reason, "unknown")
        insp.scan = "error"
        entries.append(_entry(artifact_id, rel, insp, scope, "error" if mode == "apply" else "planned"))
    return build_report(root, digest, mode, dry_run, scope, run_id, entries, [(code, None, message)])


def plan_report(target, scope, mode, dry_run):
    root, digest, fingerprints, failure = _prepare(target)
    if failure:
        return _failed_report(root, digest, mode, dry_run, scope, None, failure), 1
    entries, errors = [], []
    for artifact_id, rel in ARTIFACTS:
        insp = inspect_entry(root, rel, fingerprints[artifact_id])
        entries.append(_entry(artifact_id, rel, insp, scope, "planned"))
        errors.extend(insp.errors)
    return build_report(root, digest, mode, dry_run, scope, None, entries, errors), (1 if errors else 0)


# --------------------------------------------------------------------------
# Apply


def _make_backup(parent_fd, name, backup_name, checked, fingerprint, progress):
    """Exclusively create, fill and verify the adjacent backup of a checked leaf."""
    try:
        source = os.open(name, LEAF_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        raise BackupError(_os_error(exc, "source open"))
    try:
        before = os.fstat(source)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or (before.st_dev, before.st_ino) != checked.leaf:
            raise BackupError("source identity changed before backup")
        data = _read_all(source, fingerprint["size_bytes"] + 1)
        if len(data) != fingerprint["size_bytes"] or hashlib.sha256(data).hexdigest() != fingerprint["sha256"]:
            raise BackupError("source bytes changed before backup")
        try:
            backup = os.open(backup_name, BACKUP_FLAGS, 0o600, dir_fd=parent_fd)
        except FileExistsError:
            raise BackupCollision()
        except OSError as exc:
            raise BackupError(_os_error(exc, "backup create"))
        progress["created"] = True
        try:
            try:
                _write_all(backup, data)
                os.fchmod(backup, stat.S_IMODE(before.st_mode))
                if os.utime in os.supports_fd:
                    os.utime(backup, ns=(before.st_atime_ns, before.st_mtime_ns))
                else:
                    os.utime(backup_name, ns=(before.st_atime_ns, before.st_mtime_ns), dir_fd=parent_fd,
                             follow_symlinks=False)
                os.fsync(backup)
            finally:
                os.close(backup)
        except OSError as exc:
            raise BackupError(_os_error(exc, "backup write"))
        check = os.open(backup_name, LEAF_FLAGS, dir_fd=parent_fd)
        try:
            written = os.fstat(check)
            copied = _read_all(check, fingerprint["size_bytes"] + 1)
        finally:
            os.close(check)
        if (not stat.S_ISREG(written.st_mode) or written.st_nlink != 1 or copied != data
                or stat.S_IMODE(written.st_mode) != stat.S_IMODE(before.st_mode)
                or written.st_mtime_ns != before.st_mtime_ns):
            raise BackupError("backup verification failed")
        after = os.fstat(source)
        live = os.lstat(name, dir_fd=parent_fd)
        if not (_same_file(after, before) and _same_file(live, before)):
            raise BackupError("source changed while it was copied")
        os.fsync(parent_fd)
    except OSError as exc:
        raise BackupError(_os_error(exc, "backup"))
    finally:
        os.close(source)


def _same_safe_match(checked, current, scope):
    observation = current.observation
    return (observation["status"] == "eligible" and _in_scope(observation["ownership"], scope)
            and current.ancestors == checked.ancestors and current.leaf == checked.leaf)


def _reserve_run_id(root, entries, run_id):
    """Pick a run id whose backup names are all free before any work starts."""
    for _ in range(8):
        if not any(os.path.lexists(os.path.join(root, item["path"] + ".bak.retirement." + run_id))
                   for item in entries if item["action"] == "retire"):
            return run_id
        run_id = _new_run_id()
    return run_id


def _settle_unplanned(root, entry, fingerprint, state, errors):
    """Absent and preserved entries keep their action; record a fresh observation."""
    current = inspect_entry(root, entry["path"], fingerprint)
    entry["after"] = current.observation
    if current.errors:
        entry["result"] = "error"
        errors.extend(current.errors)
        raise StopRun()
    if current.observation["status"] == "absent":
        entry["result"] = "unchanged"
    else:
        entry["result"] = "preserved"
        state["exit"] = 3


def _retire(root, initial, entry, fingerprint, scope, state, errors):
    rel, entry_id = entry["path"], entry["id"]
    parent_rel, name = rel.rsplit("/", 1)
    _barrier("before-recheck", entry_id)
    recheck = inspect_entry(root, rel, fingerprint, keep_parent=True)
    parent_fd = recheck.parent_fd
    try:
        entry["after"] = recheck.observation
        if recheck.errors:
            entry["result"] = "error"
            errors.extend(recheck.errors)
            raise StopRun()
        if recheck.observation["status"] == "absent":
            entry["result"] = "unchanged"
            return
        if recheck.observation["status"] != "eligible" or not _in_scope(recheck.observation["ownership"], scope):
            entry["result"] = "preserved"
            state["exit"] = 3
            return
        if recheck.ancestors != initial.ancestors or recheck.leaf != initial.leaf:
            entry["result"] = "error"
            errors.append(("inspection-failed", rel, "file or parent identity changed since the initial inspection"))
            raise StopRun()
        _barrier("before-backup", entry_id)
        attempts = 0
        while True:
            backup_name = name + ".bak.retirement." + state["run_id"]
            backup_rel = parent_rel + "/" + backup_name
            progress = {"created": False}
            state["partial"] = backup_rel
            try:
                _make_backup(parent_fd, name, backup_name, recheck, fingerprint, progress)
                break
            except BackupCollision:
                state["partial"] = None
                if state["backups"] == 0 and attempts < 8:
                    attempts += 1
                    state["run_id"] = _new_run_id()
                    continue
                entry["result"] = "error"
                errors.append(("backup-failed", rel, "backup name already exists, nothing was overwritten: " + backup_rel))
                raise StopRun()
            except BackupError as exc:
                entry["result"] = "error"
                detail = str(exc)
                if progress["created"]:
                    detail += "; partial backup retained for manual inspection, not usable for recovery: " + backup_rel
                else:
                    state["partial"] = None
                errors.append(("backup-failed", rel, detail + "; original preserved"))
                raise StopRun()
        state["partial"] = None
        state["backups"] += 1
        entry["backup"] = backup_rel
        _barrier("after-backup", entry_id)
    finally:
        if parent_fd is not None:
            os.close(parent_fd)

    final = inspect_entry(root, rel, fingerprint, keep_parent=True)
    parent_fd = final.parent_fd
    try:
        entry["after"] = final.observation
        if final.observation["status"] == "absent":
            entry["result"] = "unchanged"
            return
        if final.errors:
            entry["result"] = "error"
            errors.extend(final.errors)
            errors.append(("changed-before-delete", rel,
                           "recheck after backup failed; live entry preserved, backup kept: " + backup_rel))
            raise StopRun()
        if not _same_safe_match(recheck, final, scope):
            entry["result"] = "error"
            errors.append(("changed-before-delete", rel,
                           "entry or scope changed after backup; live entry preserved, backup kept: " + backup_rel))
            raise StopRun()
        _barrier("before-unlink", entry_id)
        try:
            live = os.lstat(name, dir_fd=parent_fd)
        except FileNotFoundError:
            entry["result"], entry["after"] = "unchanged", _obs("absent", "missing", "absent")
            return
        except OSError as exc:
            entry["result"] = "error"
            errors.append(("delete-failed", rel, _os_error(exc, "pre-unlink lstat") + "; backup kept: " + backup_rel))
            raise StopRun()
        if not stat.S_ISREG(live.st_mode) or live.st_nlink != 1 or (live.st_dev, live.st_ino) != final.leaf:
            entry["result"], entry["after"] = "error", None
            errors.append(("changed-before-delete", rel, "entry changed before unlink; preserved, backup kept: " + backup_rel))
            raise StopRun()
        try:
            os.unlink(name, dir_fd=parent_fd)
        except FileNotFoundError:
            entry["result"], entry["after"] = "unchanged", _obs("absent", "missing", "absent")
            return
        except OSError as exc:
            entry["result"] = "error"
            errors.append(("delete-failed", rel, _os_error(exc, "unlink") + "; original preserved, backup kept: " + backup_rel))
            raise StopRun()
        _barrier("after-unlink", entry_id)
        try:
            os.lstat(name, dir_fd=parent_fd)
            verified = False
        except FileNotFoundError:
            verified = True
        except OSError:
            verified = False
        if not verified:
            entry["result"], entry["after"] = "error", None
            errors.append(("delete-failed", rel, "absence could not be verified after unlink; backup kept: " + backup_rel))
            raise StopRun()
        entry["after"] = _obs("absent", "missing", "absent")
        try:
            os.fsync(parent_fd)
        except OSError as exc:
            entry["result"] = "error"
            errors.append(("delete-failed", rel, _os_error(exc, "directory flush after unlink")
                           + "; the file is absent but durability is unknown, backup kept: " + backup_rel))
            raise StopRun()
        entry["result"] = "retired"
    finally:
        if parent_fd is not None:
            os.close(parent_fd)


def apply_report(target, scope):
    run_id = _new_run_id()
    root, digest, fingerprints, failure = _prepare(target)
    if failure:
        return _failed_report(root, digest, "apply", False, scope, run_id, failure), 1
    inspections, entries, errors = [], [], []
    for artifact_id, rel in ARTIFACTS:
        insp = inspect_entry(root, rel, fingerprints[artifact_id])
        inspections.append(insp)
        entries.append(_entry(artifact_id, rel, insp, scope, "not-attempted"))
        errors.extend(insp.errors)
    if errors:
        # An initial inspection or enumeration error prevents every retirement.
        for insp, item in zip(inspections, entries):
            if insp.errors:
                item["result"] = "error"
        return build_report(root, digest, "apply", False, scope, run_id, entries, errors), 1
    state = {"exit": 0, "backups": 0, "partial": None, "run_id": _reserve_run_id(root, entries, run_id)}
    current = None
    code = 0
    try:
        for insp, item in zip(inspections, entries):
            current = item
            if item["action"] == "retire":
                _retire(root, insp, item, fingerprints[item["id"]], scope, state, errors)
            else:
                _settle_unplanned(root, item, fingerprints[item["id"]], state, errors)
            current = None
        code = state["exit"]
    except StopRun:
        code = 1
    except Interrupted as exc:
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_DFL)
        if current is not None and current["result"] == "not-attempted":
            current["result"] = "error"
        message = "interrupted by %s; completed backups are retained" % signal.Signals(exc.signum).name
        if state["partial"]:
            message += "; partial backup retained for manual inspection: " + state["partial"]
        errors.append(("interrupted", current["path"] if current is not None else None, message))
        code = 128 + exc.signum
    return build_report(root, digest, "apply", False, scope, state["run_id"], entries, errors), code


# --------------------------------------------------------------------------
# Rendering


def _value(value):
    return "-" if value is None else str(value)


def _preservation_note(item, scope):
    observation = item["after"] or item["observed"]
    status = observation["status"]
    if item["result"] not in ("planned", "preserved", "error") or status == "absent":
        return None
    if status == "eligible":
        if _in_scope(observation["ownership"], scope):
            return None
        return ("exact historical bytes, but project-owned (tracked or not ignored); "
                "retired only with --retirement-scope all-matching")
    if status == "modified":
        return ("content differs from the retired release (%s); never retired automatically, review it manually"
                % observation["reason"])
    if status == "unsafe-type":
        return ("unsafe path (%s); links, special files and multi-link files are never followed or removed"
                % observation["reason"])
    return "inspection failed (%s); nothing is changed for this path" % observation["reason"]


def render_human(report, context=None, bootstrap=None):
    mode = report["mode"]
    if context:
        title = ("Retirement status" if context == "status" else "Retirement plan") + " (read-only; nothing was removed)"
    else:
        title = {"plan": "Retirement plan", "status": "Retirement status", "apply": "Retirement apply"}[mode]
    head = "policy=%s policy_sha256=%s scope=%s mode=%s dry_run=%s" % (
        report["policy_id"], report["policy_sha256"] or "unavailable", report["scope"], mode,
        "true" if report["dry_run"] else "false")
    if report["run_id"]:
        head += " run_id=" + report["run_id"]
    # Indented so `key=value` parsers of the preceding status output never see a
    # second top-level target line.
    lines = [title, head, "  target=" + _display(report["target"])]
    for item in report["entries"]:
        observed = item["observed"]
        lines.append("- " + item["path"])
        lines.append("    state=%s (%s) type=%s size=%s ownership=%s" % (
            observed["status"], observed["reason"], observed["file_type"], _value(observed["size_bytes"]),
            _value(observed["ownership"])))
        lines.append("    action=%s result=%s" % (item["action"], item["result"]))
        if item["after"] is not None:
            lines.append("    now: state=%s (%s)" % (item["after"]["status"], item["after"]["reason"]))
        if item["backup"]:
            lines.append("    backup: %s (verified; kept for recovery, see docs/agent-configs/RECOVERY.md)" % _display(item["backup"]))
        note = _preservation_note(item, report["scope"])
        if note:
            lines.append("    preserved: " + note)
        if item["candidate_scan"] == "unsafe-parent":
            lines.append("    stale candidates: scan not performed (unsafe parent directory)")
        elif item["candidate_scan"] == "error":
            lines.append("    stale candidates: scan failed; candidates may exist")
        elif item["stale_candidates"]:
            lines.append("    stale candidates (%d) are preserved and never promoted; review and delete manually if obsolete:"
                         % len(item["stale_candidates"]))
            for candidate in item["stale_candidates"]:
                lines.append("      %s [%s]" % (_display(candidate["path"]), candidate["file_type"]))
        else:
            lines.append("    stale candidates: none")
    summary = report["summary"]
    lines.append("summary: %s; stale_candidates=%d attention_required=%s" % (
        " ".join("%s=%d" % pair for pair in summary["states"].items()), summary["stale_candidate_count"],
        "true" if summary["attention_required"] else "false"))
    for error in report["errors"]:
        lines.append("error: %s %s: %s" % (error["code"], _display(error["path"] or "-"), _display(error["message"])))
    if mode != "apply" and any(item["action"] == "retire" for item in report["entries"]):
        command = "bash %s --target %s --apply-retirements" % (
            shlex.quote(bootstrap or "bootstrap-multi-agent-project.sh"), shlex.quote(report["target"]))
        if report["scope"] == "all-matching":
            command += " --retirement-scope all-matching"
        lines.append("Next: retire the exact matches above explicitly (verified backups are mandatory):")
        lines.append("  " + _display(command))
    if not summary["attention_required"]:
        lines.append("No retired harness artifacts need attention.")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Command line


def _install_signal_handlers():
    def handler(signum, frame):
        raise Interrupted(signum)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, handler)


def _parser():
    parser = argparse.ArgumentParser(prog="retirement.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command")
    commands.required = True
    commands.add_parser("paths", help="print the pinned retired artifact paths")
    for name in ("plan", "status", "apply"):
        sub = commands.add_parser(name)
        sub.add_argument("--target", required=True)
        sub.add_argument("--scope", choices=SCOPES, default="local-only")
        sub.add_argument("--json", action="store_true")
        sub.add_argument("--dry-run", action="store_true")
        sub.add_argument("--bootstrap")
    sub = commands.add_parser("section", help="human read-only plan appended to ordinary actions")
    sub.add_argument("--target", required=True)
    sub.add_argument("--scope", choices=SCOPES, default="local-only")
    sub.add_argument("--context", choices=CONTEXTS, required=True)
    sub.add_argument("--bootstrap")
    sub = commands.add_parser("status-v2", help="merge a v1 status object from stdin into status v2")
    sub.add_argument("--target", required=True)
    sub.add_argument("--scope", choices=SCOPES, default="local-only")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    if args.command == "paths":
        for _, rel in ARTIFACTS:
            sys.stdout.write(rel + "\n")
        return 0
    if args.command == "status-v2":
        try:
            base = json.loads(sys.stdin.read())
        except ValueError:
            base = None
        if not isinstance(base, dict) or base.get("schema") != STATUS_V1:
            sys.stderr.write("retirement: status v2 requires the v1 status object on stdin\n")
            return 1
        report, code = plan_report(args.target, args.scope, "status", False)
        combined = dict(base)
        combined["schema"] = STATUS_V2
        combined["retirement"] = report
        sys.stdout.write(json.dumps(combined, separators=(",", ":")) + "\n")
        return code
    if args.command == "section":
        report, code = plan_report(args.target, args.scope, "status" if args.context == "status" else "plan", False)
        sys.stdout.write(render_human(report, args.context, args.bootstrap))
        return code
    if args.command == "apply" and not args.dry_run:
        _install_signal_handlers()
        report, code = apply_report(args.target, args.scope)
    else:
        mode = "status" if args.command == "status" else "plan"
        report, code = plan_report(args.target, args.scope, mode, args.dry_run)
    if args.json:
        sys.stdout.write(json.dumps(report, separators=(",", ":")) + "\n")
    else:
        sys.stdout.write(render_human(report, None, args.bootstrap))
    sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(main())
