#!/usr/bin/env python3
"""Change tiers for a harness-kit project.

Generated projects get this file as scripts/agent-tier.py. Run it through
`scripts/agent-guard.sh tier ...`. One evaluator holds the tier rules, so
`tier suggest` and pre-final judge a change the same way. Only this program
writes .agents/tasks/<id>/tier.json. Stdlib only; Python 3.8 or newer.

Exit codes: 0 done; 1 bad input, policy or file; 70 a bug in this program.
"""
import argparse
import contextlib
import datetime
import errno
import fnmatch
import json
import os
import posixpath
import re
import stat
import subprocess
import sys
import tempfile
import time


class TierError(Exception):
    """Bad input, policy or file: exit 1. Anything else is a bug: exit 70."""


_warned = set()


def warn(message):
    if message not in _warned:
        _warned.add(message)
        print(f"agent-guard: warn: {message}", file=sys.stderr)


# Set by configure() from --root.
ROOT = TASKS_DIR = ACTIVE_PATH = SEATS_PATH = ""


def configure(root):
    global ROOT, TASKS_DIR, ACTIVE_PATH, SEATS_PATH
    if not os.path.isdir(root):
        raise TierError(f"--root is not a directory: {root}")
    ROOT = root
    TASKS_DIR = os.path.join(root, ".agents", "tasks")
    ACTIVE_PATH = os.path.join(TASKS_DIR, "ACTIVE")
    SEATS_PATH = os.path.join(root, "docs", "agent-configs", "seats.json")


def display(path):
    """A path inside the project, relative to it; any other path as is."""
    path = str(path)
    if ROOT:
        relative = os.path.relpath(path, ROOT)
        if relative != ".." and not relative.startswith("../"):
            return relative
    return path


_MISSING = object()


def read_json(path, missing=_MISSING):
    """The parsed file. A missing file gives `missing` when it is passed. Any
    other failure (unreadable, not JSON, nested too deep) is a TierError."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        if missing is _MISSING:
            raise TierError(f"cannot read {display(path)}: the file is missing")
        return missing
    except (OSError, ValueError, RecursionError) as exc:
        raise TierError(f"cannot read {display(path)}: {exc}")


def plural(count, word):
    return f"{count} {word}" + ("" if count == 1 else "s")


def shown(path):
    return path.replace("\n", "\\n").replace("\r", "\\r")


def string_list(value):
    return isinstance(value, list) and all(isinstance(item, str) and item for item in value)


def whole_number(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


# ---- rules: kit lists from the context policy, plus the project's own ----
def load_rules(policy_path, contract_path):
    policy = read_json(policy_path)
    if not isinstance(policy, dict):
        raise TierError(f"{display(policy_path)} is not a JSON object")

    def bad(key):
        return TierError(f"context policy {key} is missing or not valid; update the kit, then run scripts/verify-ai-deps.sh")

    tier_rules = policy.get("tier_rules")
    limits = {}
    for name in ("small", "medium"):
        entry = tier_rules.get(name) if isinstance(tier_rules, dict) else None
        if not (isinstance(entry, dict) and whole_number(entry.get("max_files")) and whole_number(entry.get("max_lines"))):
            raise bad("tier_rules")
        limits[name] = {"max_files": entry["max_files"], "max_lines": entry["max_lines"]}
    lists = {}
    for key in ("risk_tokens", "risk_paths", "dependency_manifests", "dependency_locks"):
        if not string_list(policy.get(key)):
            raise bad(key)
        lists[key] = list(policy[key])
    test_patterns = policy.get("test_patterns")
    if not (isinstance(test_patterns, dict) and string_list(test_patterns.get("dirs"))
            and string_list(test_patterns.get("names"))):
        raise bad("test_patterns")

    project = {"risk_paths": [], "generated_files": []}
    if os.path.isfile(contract_path):
        try:
            contract = read_json(contract_path)
        except TierError:
            # Unreadable, not JSON or nested too deep: bad user JSON, ignored.
            contract = None
            warn("project-tech-stack.json is not valid JSON; its risk_paths and generated_files are ignored")
        if isinstance(contract, dict):
            for key in project:
                if key not in contract:
                    continue
                if string_list(contract[key]):
                    project[key] = list(contract[key])
                else:
                    warn(f"project-tech-stack.json {key} is not a list of paths; it is ignored")

    return {
        "limits": limits,
        "risk_tokens": {token.lower() for token in lists["risk_tokens"]},
        "risk_paths": list(dict.fromkeys(lists["risk_paths"] + project["risk_paths"])),
        "manifests": lists["dependency_manifests"],
        "locks": set(lists["dependency_locks"]),
        "test_dirs": {name.lower() for name in test_patterns["dirs"]},
        # A name pattern with a capital ("*Test.kt") matches case-sensitively,
        # so "Latest.kt" is not a test; the others ignore case.
        "test_names": [(name, name != name.lower()) for name in test_patterns["names"]],
        "generated": project["generated_files"],
    }


# ---- path matching: gitignore-style ----
# "**/" is zero or more directories; "dir/**" is everything under dir;
# "*", "?" and "[...]" stay inside one segment; a pattern with no "/" matches
# a file or folder name in any directory. As in .gitignore, a pattern that
# matches a folder covers what is in it. A pattern that does not compile is
# skipped.
_regex_cache = {}


def _translate(pattern):
    out = []
    i, n = 0, len(pattern)
    while i < n:
        segment_start = i == 0 or pattern[i - 1] == "/"
        if segment_start and pattern.startswith("**", i) and (i + 2 == n or pattern[i + 2] == "/"):
            if i + 2 == n:
                out.append(".*")
                i += 2
            else:
                out.append("(?:[^/]+/)*")
                i += 3
            continue
        char = pattern[i]
        if char == "*":
            while i < n and pattern[i] == "*":
                i += 1
            out.append("[^/]*")
            continue
        if char == "?":
            out.append("[^/]")
            i += 1
            continue
        if char == "[":
            j = i + 1
            if j < n and pattern[j] in "!^":
                j += 1
            if j < n and pattern[j] == "]":
                j += 1
            while j < n and pattern[j] != "]":
                j += 1
            if j < n:
                body = pattern[i + 1:j]
                negate = body[:1] in ("!", "^")
                if negate:
                    body = body[1:]
                body = "".join("\\" + c if c in "\\[]&~|^" else c for c in body)
                out.append("(?!/)[" + ("^" if negate else "") + body + "]")
                i = j + 1
                continue
        out.append(re.escape(char))
        i += 1
    return "".join(out)


def bad_pattern(pattern, exc):
    warn(f"pattern {pattern!r} is not valid ({exc}); it is skipped")


def path_match(pattern, path, icase=False):
    original = pattern
    if pattern.endswith("/"):
        stem = pattern.rstrip("/")
        pattern = (stem if "/" in stem else "**/" + stem) + "/**"
    anchored = "/" in pattern
    if anchored:
        pattern = pattern.lstrip("/")
    key = (pattern, icase)
    if key not in _regex_cache:
        try:
            _regex_cache[key] = re.compile(_translate(pattern), re.IGNORECASE if icase else 0)
        except re.error as exc:
            bad_pattern(original, exc)
            _regex_cache[key] = None
    regex = _regex_cache[key]
    if regex is None:
        return False
    # As in .gitignore, a pattern that matches a folder also matches what is
    # in it: app/ledger matches app/ledger/post.py.
    parts = path.split("/")
    for end in range(len(parts), 0, -1):
        subject = "/".join(parts[:end]) if anchored else parts[end - 1]
        if regex.fullmatch(subject) is not None:
            return True
    return False


def name_match(name, pattern, exact=True):
    try:
        if exact:
            return fnmatch.fnmatchcase(name, pattern)
        return fnmatch.fnmatchcase(name.lower(), pattern.lower())
    except re.error as exc:
        bad_pattern(pattern, exc)
        return False


_WORD = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+")


def name_words(name):
    # "AuthService.swift" -> auth, service, swift; "useAuth.ts" -> use, auth, ts.
    # Each pair of neighbouring words joined is added too: "signIn" -> signin.
    words = []
    for part in re.split(r"[-_.]+", name):
        words.extend(word.lower() for word in _WORD.findall(part))
    return words + [first + second for first, second in zip(words, words[1:])]


def risk_of(path, rules):
    """Returns {"path", "kind", "match"} when the path is risky, else None."""
    if path.lower().endswith((".md", ".mdx")):
        return None
    for pattern in rules["risk_paths"]:
        if path_match(pattern, path, icase=True):
            return {"path": path, "kind": "pattern", "match": pattern}
    for segment in path.split("/"):
        for word in name_words(segment):
            if word in rules["risk_tokens"]:
                return {"path": path, "kind": "token", "match": word}
    return None


def is_test(path, rules):
    parts = path.split("/")
    if any(part.lower() in rules["test_dirs"] for part in parts[:-1]):
        return True
    return any(name_match(parts[-1], pattern, exact) for pattern, exact in rules["test_names"])


def is_lock(path, rules):
    return posixpath.basename(path) in rules["locks"]


def is_generated(path, rules):
    return any(path_match(pattern, path) for pattern in rules["generated"])


def is_manifest(path, rules):
    name = posixpath.basename(path)
    return any(name_match(name, pattern) for pattern in rules["manifests"])


def normalize(raw):
    if not isinstance(raw, str) or not raw:
        raise TierError("a path is empty")
    path = raw
    if path.startswith("/"):
        # Resolve the directory like pre-edit does, so /var/... matches a
        # /private/var/... root; the file itself need not exist.
        real_root = os.path.realpath(ROOT)
        real = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
        if not real.startswith(real_root.rstrip("/") + "/"):
            raise TierError(f"path is outside the project: {shown(raw)}")
        path = real[len(real_root.rstrip("/")) + 1:]
    path = posixpath.normpath(path)
    if path in (".", "..") or path.startswith("../"):
        raise TierError(f"path is outside the project: {shown(raw)}")
    return path


# ---- classify ----
# Request: {"files": [{"path", "old_path"?, "lines"?, "binary"?, "submodule"?}],
#           "lines"?: int|null, "data"?, "access"?, "dependency"?, "unclear"?: bool}
#   A rename is one entry: risk checks both path and old_path. Per-file lines
#   are summed for counted files only; a top-level "lines" (tier suggest)
#   replaces that sum. No files means "files unknown".
# Result:  {"tier", "reasons": [str], "counted_files": int,
#           "counted_lines": int|null, "excluded": {"tests", "locks",
#           "generated", "lines": int}, "risky": [{"path", "kind", "match"}]}
FLAG_REASONS = {
    "data": "--data: changes stored or sent data",
    "access": "--access: changes who may do what",
    "dependency": "--dependency: adds or upgrades a library",
    "unclear": "--unclear: the request is not clear yet",
}
REQUEST_KEYS = {"files", "lines", "data", "access", "dependency", "unclear"}
FILE_KEYS = {"path", "old_path", "lines", "binary", "submodule", "moved_from"}
MAX_RISKY_LINES = 5


def item_paths(item):
    """Every path a file entry had in the measured snapshots: its path, the
    rename source and the paths a move absorbed (spec rule 2)."""
    return [name for name in [item["path"], item.get("old_path")] + list(item.get("moved_from") or []) if name]


def read_files(raw_files):
    if not isinstance(raw_files, list):
        raise TierError("tier request files must be a list")
    files, seen = [], set()
    for entry in raw_files:
        if not isinstance(entry, dict) or "path" not in entry:
            raise TierError("each tier request file needs a path")
        unknown = sorted(set(entry) - FILE_KEYS)
        if unknown:
            raise TierError(f"tier request file has unknown keys: {', '.join(unknown)}")
        item = {"path": normalize(entry["path"])}
        if entry.get("old_path") is not None:
            item["old_path"] = normalize(entry["old_path"])
        if entry.get("moved_from") is not None:
            # Other paths the file had in the measured snapshots (spec rule 2).
            if not string_list(entry["moved_from"]):
                raise TierError("file moved_from must be a list of paths")
            item["moved_from"] = list(dict.fromkeys(normalize(name) for name in entry["moved_from"]))
        if "lines" in entry:
            if not whole_number(entry["lines"]):
                raise TierError("file lines must be a whole number, 0 or more")
            item["lines"] = entry["lines"]
        for key in ("binary", "submodule"):
            if not isinstance(entry.get(key, False), bool):
                raise TierError(f"file {key} must be true or false")
            item[key] = entry.get(key, False)
        if item["path"] not in seen:
            seen.add(item["path"])
            files.append(item)
    return files


def classify(request, rules):
    if not isinstance(request, dict):
        raise TierError("tier request must be a JSON object")
    unknown = sorted(set(request) - REQUEST_KEYS)
    if unknown:
        raise TierError(f"tier request has unknown keys: {', '.join(unknown)}")
    files = read_files(request.get("files") or [])
    total_lines = request.get("lines")
    if total_lines is not None and not whole_number(total_lines):
        raise TierError("lines must be a whole number, 0 or more")
    flags = {}
    for key in FLAG_REASONS:
        if not isinstance(request.get(key, False), bool):
            raise TierError(f"tier request {key} must be true or false")
        flags[key] = request.get(key, False)

    excluded = {"tests": 0, "locks": 0, "generated": 0, "lines": 0}
    counted, counted_sum = 0, 0
    risky, manifests, locks, binaries, submodules = [], [], [], [], []
    for item in files:
        names = item_paths(item)
        risk = next((r for r in (risk_of(name, rules) for name in names) if r), None)
        if risk:
            risky.append(risk)
        manifest = next((name for name in names if is_manifest(name, rules)), None)
        if manifest:
            manifests.append(manifest)
        lock = next((name for name in names if is_lock(name, rules)), None)
        if lock:
            locks.append(lock)
        if item["binary"]:
            binaries.append(item["path"])
        if item["submodule"]:
            submodules.append(item["path"])
        lines = item.get("lines", 0)
        path = item["path"]
        if is_test(path, rules):
            excluded["tests"] += 1
        elif is_lock(path, rules):
            excluded["locks"] += 1
        elif is_generated(path, rules):
            excluded["generated"] += 1
        else:
            counted += 1
            counted_sum += lines
            continue
        excluded["lines"] += lines

    if total_lines is not None:
        counted_lines = total_lines
    elif any("lines" in item for item in files):
        counted_lines = counted_sum
    else:
        counted_lines = None

    small, medium = rules["limits"]["small"], rules["limits"]["medium"]
    line_count = counted_lines or 0
    large_reasons = [f"risky path: {shown(r['path'])} ({r['kind']} {r['match']})" for r in risky[:MAX_RISKY_LINES]]
    if len(risky) > MAX_RISKY_LINES:
        large_reasons.append(f"… and {len(risky) - MAX_RISKY_LINES} more risky paths")
    medium_reasons = []
    if counted > medium["max_files"]:
        large_reasons.append(f"{plural(counted, 'counted file')} (medium allows {medium['max_files']})")
    elif counted > small["max_files"]:
        medium_reasons.append(f"{plural(counted, 'counted file')} (small allows {small['max_files']})")
    if line_count > medium["max_lines"]:
        large_reasons.append(f"{plural(line_count, 'counted line')} (medium allows {medium['max_lines']})")
    elif line_count > small["max_lines"]:
        medium_reasons.append(f"{plural(line_count, 'counted line')} (small allows {small['max_lines']})")
    for key in ("data", "access"):
        if flags[key]:
            large_reasons.append(FLAG_REASONS[key])
    medium_reasons.extend(f"dependency manifest changed: {shown(path)}" for path in manifests)
    medium_reasons.extend(f"dependency lock changed: {shown(path)}" for path in locks)
    if flags["dependency"]:
        medium_reasons.append(FLAG_REASONS["dependency"])
    medium_reasons.extend(f"binary file changed: {shown(path)}" for path in binaries)
    medium_reasons.extend(f"submodule changed: {shown(path)}" for path in submodules)
    if flags["unclear"]:
        medium_reasons.append(FLAG_REASONS["unclear"])
    if not files:
        medium_reasons.append("files unknown")

    notes = []
    for key, word in (("tests", "test file"), ("locks", "lock file"), ("generated", "generated file")):
        if excluded[key]:
            notes.append(f"{plural(excluded[key], word)} not counted")

    tier = "large" if large_reasons else "medium" if medium_reasons else "small"
    return {
        "tier": tier,
        "reasons": large_reasons + medium_reasons + notes,
        "counted_files": counted,
        "counted_lines": counted_lines,
        "excluded": excluded,
        "risky": risky,
    }


# ---- task records: .agents/tasks/<id>/tier.json, state.json and ACTIVE ----
TIERS = ("small", "medium", "large")
TASK_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# "active" would clash with .agents/tasks/ACTIVE on a case-insensitive disk.
RESERVED_IDS = {"active"}
SEAT = re.compile(r"^(user|@[a-z][a-z0-9-]*)$")
ANSWERS = ("keep", "switch", "scope")
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
TIER_SCHEMA = "harness-tier/v1"
READ_ONLY = (errno.EACCES, errno.EPERM, errno.EROFS)
LOCK_SECONDS = 10
STALE_TMP_SECONDS = 3600
# requested_action of a state.json this program writes, by tier. While the
# phase is still analysis, a later set refreshes a text that is one of these.
ACTIONS = {
    "small": "implement, then run pre-final (small: no @gate, task.md optional)",
    "medium": "write task.md, answer the tier check, then implement; @verify reviews",
    "large": "prepare spec for @gate",
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# A caller's repository settings (a hook sets some) must not point git away
# from the project.
GIT_ENV_DROP = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR")


def git_env():
    env = {key: value for key, value in os.environ.items() if key not in GIT_ENV_DROP}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


def git(*args, raw=False):
    """stdout as text (bytes with raw=True), or None when git fails."""
    try:
        result = subprocess.run(
            ["git", "-C", ROOT, *args],
            env=git_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    return result.stdout if raw else result.stdout.decode("utf-8", "surrogateescape")


def git_run(*args):
    """(exit code, stdout text) of a git command; (None, "") when git cannot run."""
    try:
        result = subprocess.run(["git", "-C", ROOT, *args], env=git_env(), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return result.returncode, result.stdout.decode("utf-8", "surrogateescape")


def merge_base(one, other):
    """The merge-base of two commits, or None when they share no history.
    Any other git failure is an error, not a partial measure (spec rule 4)."""
    code, out = git_run("merge-base", one, other)
    if code == 0 and out.strip():
        return out.strip()
    if code == 1:
        return None
    raise TierError("cannot read the history from git")


def repo_state():
    """(branch, or None when detached; HEAD, or the empty tree with no commit)."""
    if git("rev-parse", "--git-dir") is None:
        raise TierError("tier needs a Git repository at the project root")
    branch = (git("symbolic-ref", "-q", "--short", "HEAD") or "").strip() or None
    head = (git("rev-parse", "--verify", "-q", "HEAD^{commit}") or "").strip() or EMPTY_TREE
    return branch, head


BASE_REF_PREFIXES = ("refs/heads/", "refs/remotes/", "refs/tags/")


def commit_of(name):
    return (git("rev-parse", "--verify", "-q", name + "^{commit}") or "").strip() or None


def check_base(base, branch):
    """What tier.json stores for --base: the full refname of a branch or tag,
    or a full commit id. A position like HEAD~1 moves with HEAD: refused."""
    if not base.strip() or base.startswith("-") or "\n" in base:
        raise TierError(f"--base is not a branch or commit: {shown(base)}")
    commit = commit_of(base)
    if commit is None:
        raise TierError(f"--base does not name a commit here: {shown(base)}")
    if OBJECT_ID.fullmatch(base.lower()):
        return commit
    full = (git("rev-parse", "--symbolic-full-name", base) or "").strip()
    if full == "HEAD" or (branch is not None and full == "refs/heads/" + branch):
        raise TierError(f"--base is the current branch ({branch or 'HEAD'}); give the branch this work starts from")
    upstream = (git("rev-parse", "--symbolic-full-name", "@{u}") or "").strip() if branch is not None else ""
    if upstream.startswith("refs/remotes/") and full == upstream:
        raise TierError(f"--base is the upstream of the current branch ({shown(upstream)}); it moves with each push. "
                        "Give the branch this work starts from")
    if not full.startswith(BASE_REF_PREFIXES) or "\n" in full or commit_of(full) != commit:
        raise TierError(f"--base must name a branch or tag (like main or origin/main) or a full commit id; "
                        f"a position like HEAD~1 moves with HEAD (got: {shown(base)})")
    return full


# ---- measure: the change since the task's base ----
# The change since the base: commits on the branch, staged, unstaged and
# untracked files (only the commits for a push). .agents/ is left out. Paths
# are relative to the project, also when it is a subdirectory of the Git top
# level (--relative).
# Result of measure(): the classify result plus
#   {"files": [classify file entries], "base": {"sha", "subject",
#    "commits_since", "kind": merge-base|start|head|empty, "ref"},
#    "status": open|stale|none, "stale_reason", "partial": bool,
#    "partial_reason", "task", "default_ref", "default_name"}.
# partial: the full scope cannot be known; partial_reason names the cause
# (spec rule 4). A partial or stale result is never a reason to fail
# pre-final.
SCOPE = ("--", ".", ":(exclude).agents")
# --ignore-submodules=dirty: config or .gitmodules cannot hide a gitlink
# change, and a dirty submodule checkout is not a change.
PATCH_FLAGS = ("--relative", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=dirty")
DIFF_FLAGS = PATCH_FLAGS + ("--no-abbrev", "-z")
HASH_CHUNK = 100
TEXT_CHUNK = 200
C_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
GITLINK = "160000"
SNIFF_BYTES = 8192
OBJECT_ID = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
NO_TIER = "no tier declared"
START_REWRITTEN = "the start commit is no longer in this branch's history, after a rebase or reset"
STACK_MIXED = "the branch took in default-branch commits that its --base does not have"
DEFAULT_UNKNOWN = ("the default branch is unknown (no origin/HEAD, main or master), so measured since tier set; "
                   "git remote set-head origin --auto sets it")
MERGED_BEFORE = "commits from before the task were merged with pulled commits"
BASE_MISSING = "the base commit is not here, so uncommitted changes only"


def default_branch():
    """(full refname for merge-base, default_ref like origin/main, default_name
    like main to compare with the current branch); all None when none."""
    origin_head = "refs/remotes/origin/HEAD"
    candidates = ("refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master")
    out = git("for-each-ref", "--format=%(refname)%00%(symref)", origin_head, *candidates) or ""
    refs = dict(line.partition("\0")[::2] for line in out.splitlines())
    target = refs.get(origin_head, "")
    if target.startswith("refs/remotes/origin/"):
        return target, target[len("refs/remotes/"):], target[len("refs/remotes/origin/"):]
    for full in candidates:
        if full in refs:
            ref = full.split("/", 2)[2]
            return full, ref, ref.split("/", 1)[-1]
    return None, None, None


def short_ref(full):
    for prefix in ("refs/remotes/", "refs/heads/", "refs/tags/"):
        if full.startswith(prefix):
            return full[len(prefix):]
    return full


def is_ancestor(older, newer):
    code, _ = git_run("merge-base", "--is-ancestor", older, newer)
    if code in (0, 1):
        return code == 0
    raise TierError("cannot read the history from git")


def start_base(start, branch, head, default_full, default_name):
    """The base of a task measured from its start commit (on the default
    branch, or with no default branch): (sha, kind, ref, partial cause)."""
    if not OBJECT_ID.fullmatch(start) or start == EMPTY_TREE or git("cat-file", "-e", start + "^{commit}") is None:
        return start, "start", None, None  # collect reports a missing start as stale
    remote = branch is not None and branch == default_name and (default_full or "").startswith("refs/remotes/")
    shared = (merge_base("HEAD", default_full) or "") if remote else ""
    if not is_ancestor(start, "HEAD"):
        # Rebased or reset: the task's own commits cannot be told apart any
        # more. Measured from the remote branch, pulled commits still never count.
        if shared:
            return shared, "merge-base", default_full, START_REWRITTEN
        common = merge_base("HEAD", start)
        return (common, "merge-base", None, START_REWRITTEN) if common else (head, "head", None, START_REWRITTEN)
    if shared and shared != start and not is_ancestor(shared, start):
        if is_ancestor(start, shared):
            # Teammates' commits pulled since the start are not this task's:
            # measure from the newest commit shared with the remote branch.
            # Commits already pushed there are left out too; the pre-push
            # hook, when installed, measured them as they were pushed.
            return shared, "merge-base", default_full, None
        # A merge pull on top of commits made before the task.
        return shared, "merge-base", default_full, MERGED_BEFORE
    return start, "start", None, None


def choose_base(record, branch, head, default_full, default_name):
    """(sha, kind, ref, partial cause or None) for a task with a declared
    tier, or for the no-tier rule when record is None or has no declared
    tier. A cause means the measure is partial (spec rule 4)."""
    has_tier = record is not None and record["declared"] is not None
    if head == EMPTY_TREE:
        return EMPTY_TREE, "empty", None, None if has_tier else NO_TIER
    target = (record.get("base_ref") if has_tier else None) or default_full
    if target is not None and target.startswith("-"):
        target = None
    if (branch is not None and branch == default_name) or target is None:
        if not has_tier:
            return head, "head", None, NO_TIER
        sha, kind, ref, cause = start_base(record["start_commit"], branch, head, default_full, default_name)
        if default_full is None:
            # Pulled commits cannot be told apart without a default branch.
            cause = cause or DEFAULT_UNKNOWN
        return sha, kind, ref, cause
    if has_tier and record.get("base_ref") and commit_of(target) is None:
        # A --base that no longer resolves (a merged parent branch after
        # git fetch --prune): only the work since tier set can be measured.
        gone = target[:12] if OBJECT_ID.fullmatch(target) else short_ref(target)
        return record["start_commit"], "start", None, f"the --base {gone} is gone, so measured since tier set"
    found = merge_base("HEAD", target)
    if found and has_tier and record.get("base_ref") and default_full and default_full != target:
        # A stacked branch: once the default branch holds the parent's work
        # (rebased onto it, or merged with it), only the branch's own work
        # counts. Commits from both sides that neither holds: partial.
        newer = merge_base("HEAD", default_full)
        if newer and newer != found:
            if is_ancestor(found, newer):
                return newer, "merge-base", default_full, None
            if not is_ancestor(newer, found):
                return found, "merge-base", target, STACK_MIXED
    if found:
        return found, "merge-base", target, None if has_tier else NO_TIER
    if not has_tier:
        return head, "head", target, NO_TIER
    return head, "head", target, f"no shared history with {short_ref(target)}, so uncommitted changes only"


def read_diff(out):
    """Parses `git diff --raw [--numstat] -z`: raw records, then numstat ones.
    Gives ({path: raw entry}, {path: counted lines, None when binary})."""
    tokens = out.split("\0")
    raw, counts, index = {}, {}, 0
    try:
        while index < len(tokens):
            head = tokens[index]
            index += 1
            if not head:
                continue
            if head.startswith(":"):
                old_mode, new_mode, old_sha, new_sha, status = head[1:].split()[:5]
                old_path = None
                if status[:1] in ("R", "C"):
                    old_path = tokens[index]
                    index += 1
                path = tokens[index]
                index += 1
                raw[path] = {"status": status[:1], "old_path": old_path, "old_sha": old_sha,
                             "new_sha": new_sha, "submodule": GITLINK in (old_mode, new_mode)}
            else:
                added, deleted, path = head.split("\t", 2)
                if not path:  # a rename: the old and new paths follow
                    path = tokens[index + 1]
                    index += 2
                counts[path] = None if "-" in (added, deleted) else max(int(added), int(deleted))
    except (IndexError, ValueError):
        raise TierError("cannot read the git diff output")
    return raw, counts


def file_facts(path):
    """(lines, binary) of an untracked file: its newlines, plus one for a last
    line with no newline. Binary when the first 8 KB hold a NUL byte."""
    full = os.path.join(ROOT, path)
    lines, last = 0, b""
    try:
        if os.path.islink(full):
            return 1, False
        with open(full, "rb") as handle:
            chunk = handle.read(SNIFF_BYTES)
            if b"\0" in chunk:
                return 0, True
            while chunk:
                lines += chunk.count(b"\n")
                last = chunk[-1:]
                chunk = handle.read(1 << 20)
    except OSError:
        return 0, False
    return lines + (1 if last not in (b"", b"\n") else 0), False


def file_entry(path, lines=0, old_path=None, binary=False, submodule=False, moved_from=()):
    """A classify file entry. moved_from: the other paths the file had in the
    measured snapshots, kept for the risk check (spec rule 2); left out when
    there are none."""
    entry = {"path": path, "old_path": old_path, "lines": lines, "binary": binary, "submodule": submodule}
    others = [name for name in dict.fromkeys(moved_from) if name and name not in (path, old_path)]
    if others:
        entry["moved_from"] = others
    return entry


def moved_files(gone, untracked):
    """An unstaged mv: {untracked path: gone path} for each untracked file
    whose content equals a blob of a tracked file that is missing from the
    working tree (gone: {path: [blob ids]})."""
    blobs = {}
    for path, shas in gone.items():
        for sha in shas:
            if sha and sha.strip("0") and path not in blobs.get(sha, []):
                blobs.setdefault(sha, []).append(path)
    if not blobs or not untracked:
        return {}
    moved, used = {}, set()
    for path, sha in hash_files(untracked).items():
        old = next((name for name in blobs.get(sha, []) if name not in used and name != path), None)
        if old is not None:
            used.add(old)
            moved[path] = old
    return moved


def hash_files(paths):
    """{path: blob id} from git hash-object, names passed as arguments so no
    name needs quoting. A file it cannot read is left out."""
    hashes = {}
    for start in range(0, len(paths), HASH_CHUNK):
        chunk = paths[start:start + HASH_CHUNK]
        out = (git("hash-object", "--", *chunk) or "").split()
        if len(out) == len(chunk):
            hashes.update(zip(chunk, out))
            continue
        for path in chunk:  # one unreadable file: hash the rest one by one
            one = (git("hash-object", "--", path) or "").split()
            if len(one) == 1:
                hashes[path] = one[0]
    return hashes


def has_nul(path):
    """A NUL byte in the first 8 KB of a working-tree file (not a symlink)."""
    full = os.path.join(ROOT, path)
    try:
        if os.path.islink(full):
            return False
        with open(full, "rb") as handle:
            return b"\0" in handle.read(SNIFF_BYTES)
    except OSError:
        return False


def blob_heads(shas):
    """{blob id: its first 8 KB}, from one git cat-file --batch. A blob git
    cannot read is left out."""
    wanted = sorted({sha for sha in shas if sha and sha.strip("0")})
    heads = {}
    if not wanted:
        return heads
    with tempfile.TemporaryFile() as listing:
        listing.write("".join(sha + "\n" for sha in wanted).encode("ascii"))
        listing.seek(0)
        try:
            proc = subprocess.Popen(["git", "-C", ROOT, "cat-file", "--batch"], stdin=listing,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git_env())
        except OSError:
            return heads
        with proc:
            for _ in wanted:
                header = proc.stdout.readline().split()
                if len(header) == 2 and header[1] == b"missing":
                    continue
                if len(header) != 3 or not header[2].isdigit():
                    break
                size = int(header[2])
                head = proc.stdout.read(min(size, SNIFF_BYTES))
                left = size - len(head)
                while left > 0:  # read past the rest of a big blob
                    chunk = proc.stdout.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    left -= len(chunk)
                proc.stdout.read(1)
                heads[header[0].decode("ascii")] = head
    return heads


def patch_name(text):
    """The file name on a ---/+++ line: a/ or b/ removed, C quotes undone.
    None for /dev/null."""
    if text.startswith('"'):
        data, index = bytearray(), 1
        while index < len(text) and text[index] != '"':
            char = text[index]
            if char == "\\" and index + 1 < len(text):
                code = text[index + 1]
                if code in C_ESCAPES:
                    data.append(C_ESCAPES[code])
                    index += 2
                    continue
                if text[index + 1:index + 4].isdigit():
                    data.append(int(text[index + 1:index + 4], 8) & 0xFF)
                    index += 4
                    continue
            data.extend(char.encode("utf-8", "surrogateescape"))
            index += 1
        name = data.decode("utf-8", "surrogateescape")
    else:
        name = text[:-1] if text.endswith("\t") else text  # git adds a tab after a name with a space
        if name == "/dev/null":
            return None
    return name[2:] if name.startswith(("a/", "b/")) else name


def patch_counts(out):
    """{path: max(added, deleted)} from a -U0 patch, split at each diff --git
    header. The ---/+++ header lines name the file and are not counted."""
    counts = {}
    old = new = None
    added = deleted = 0
    in_hunk = False
    for line in out.split("\n") + ["diff --git "]:
        if line.startswith("diff --git "):
            name = new or old
            if name is not None:
                counts[name] = max(added, deleted)
            old = new = None
            added = deleted = 0
            in_hunk = False
        elif in_hunk:
            if line.startswith("+"):
                added += 1
            elif line.startswith("-"):
                deleted += 1
        elif line.startswith("--- "):
            old = patch_name(line[4:])
        elif line.startswith("+++ "):
            new = patch_name(line[4:])
        elif line.startswith("@@"):
            in_hunk = True
    return counts


def text_lines(args, entries):
    """{path: counted lines} for text files that numstat calls binary (a -diff
    or binary attribute). numstat ignores --text, so this counts a --text
    patch of the same side (args, see SIDES), one git diff per TEXT_CHUNK
    files."""
    counted = {}
    for start in range(0, len(entries), TEXT_CHUNK):
        chunk = entries[start:start + TEXT_CHUNK]
        names = [name for entry in chunk for name in (entry["path"], entry["old_path"]) if name]
        out = git("-c", "core.quotePath=false", "diff", "--text", "-U0", "-M", "--src-prefix=a/", "--dst-prefix=b/",
                  *PATCH_FLAGS, *args, "--", *(":(literal)" + name for name in names))
        if out is None:
            continue
        found = patch_counts(out)
        for entry in chunk:
            counted[entry["path"]] = found.get(entry["path"], 0)
    return counted


# The sides of a change since base, as git diff arguments: the commits, the
# index and the working tree. A file staged and then undone in the working
# tree, or committed and then undone, still counts: it is pushed.
SIDES = {"head": lambda base: (base, "HEAD"), "index": lambda base: ("--cached", base), "worktree": lambda base: (base,)}


def diff_side(base, side):
    """One side of the change: ({path: raw entry}, {path: counted lines, None
    when binary})."""
    args = SIDES[side](base)
    out = git("diff", "--raw", "--numstat", "-M", *DIFF_FLAGS, *args, *SCOPE)
    if out is None:
        raise TierError("cannot read the change from git")
    raw, counts = read_diff(out)
    # numstat "-": binary when either side has a NUL in its first 8 KB, as in
    # git; otherwise a text file with a -diff or binary attribute.
    pending = {path: entry for path, entry in raw.items() if counts.get(path, 0) is None and not entry["submodule"]}
    if pending:
        heads = blob_heads(entry["old_sha"] for entry in pending.values())

        def binary_blob(sha):
            return bool(sha.strip("0")) and (sha not in heads or b"\0" in heads[sha])

        # The new side only where the old one is text. A working-tree file
        # has no blob id in the raw diff (all zeros): its file is read.
        texts = {path: entry for path, entry in pending.items() if not binary_blob(entry["old_sha"])}
        heads.update(blob_heads(entry["new_sha"] for entry in texts.values()))
        texts = [{"path": path, "old_path": entry["old_path"]} for path, entry in texts.items()
                 if not (binary_blob(entry["new_sha"]) if entry["new_sha"].strip("0") else has_nul(path))]
        counts.update(text_lines(args, texts))
    return raw, counts


def diff_files(base, committed=False, has_head=True):
    """The changed files against base, as classify file entries, each with the
    largest count any side shows and binary when any side is. committed: the
    commits alone (what a push sends); otherwise also the index, the working
    tree and untracked files."""
    sides = [side for side in ("head", "index", "worktree")
             if (side != "head" or has_head) and (side == "head" or not committed)]
    found = {}
    for side in sides:
        if side == "index" and "head" in found and git("diff", "--cached", "--quiet", PATCH_FLAGS[-1], "HEAD",
                                                       *SCOPE) is not None:
            found[side] = found["head"]  # nothing staged: the index side is the commits side
        else:
            found[side] = diff_side(base, side)
    files = {}
    for side in sides:
        raw, counts = found[side]
        for path, entry in raw.items():
            item = files.setdefault(path, file_entry(path))
            if item["old_path"] is None:
                item["old_path"] = entry["old_path"]
            elif entry["old_path"] not in (None, item["old_path"]):
                # Another side renamed it from somewhere else: keep that path too.
                item["moved_from"] = list(dict.fromkeys(item.get("moved_from", []) + [entry["old_path"]]))
            lines = counts.get(path, 0)
            if entry["submodule"]:
                item["submodule"] = True
            elif lines is None:
                item["binary"] = True
            else:
                item["lines"] = max(item["lines"], lines)
    linked, staged_new = set(), set()
    if not committed and has_head:
        # A staged git mv (or an mv then git add) of a file the commits have:
        # git's rename from the commits to the index links the two paths, so
        # the file counts once, with the larger count (spec rule 2).
        staged = git("diff", "--cached", "--raw", "-M", "--diff-filter=AR", *DIFF_FLAGS, "HEAD", *SCOPE)
        if staged is None:
            raise TierError("cannot read the change from git")
        for path, entry in read_diff(staged)[0].items():
            if entry["status"] == "A":
                staged_new.add(path)  # new since HEAD: the move hint's new side
                continue
            old = entry["old_path"]
            if old and old != path and old in files and path in files:
                gone, item = files.pop(old), files[path]
                linked.add(old)
                item["lines"] = max(item["lines"], gone["lines"])
                item["binary"] = item["binary"] or gone["binary"]
                item["submodule"] = item["submodule"] or gone["submodule"]
                item["moved_from"] = list(dict.fromkeys(
                    item.get("moved_from", []) + [old, gone["old_path"]] + gone.get("moved_from", [])))
    for item in files.values():
        if item["submodule"]:  # a gitlink has no lines of its own
            item.update(lines=0, binary=False)
        if "moved_from" in item:
            item["moved_from"] = [name for name in item["moved_from"]
                                  if name and name not in (item["path"], item["old_path"])]
            if not item["moved_from"]:
                del item["moved_from"]
    if committed:
        return [files[path] for path in sorted(files)], False
    others = git("ls-files", "--others", "--exclude-standard", "-z", *SCOPE)
    if others is None:
        raise TierError("cannot read the change from git")
    raw, index_raw = found["worktree"][0], found["index"][0]
    untracked = [path for path in others.split("\0") if path]
    deleted = {path: entry for path, entry in raw.items() if entry["status"] == "D" and not entry["submodule"]}
    # What an unstaged mv may have moved away: a deleted base file (its base
    # or index blob), or a file added or renamed on the branch that is gone
    # from the working tree; the base lacks it, so no D shows for it.
    # Branch paths come first: after a pure rename both have the same blob,
    # and the move continues the rename.
    away = {}
    for side in ("index", "head"):
        for path, entry in found.get(side, ({}, {}))[0].items():
            if (path not in away and path not in deleted and path not in linked and entry["status"] != "D"
                    and not entry["submodule"] and not os.path.lexists(os.path.join(ROOT, path))):
                away[path] = [entry["new_sha"]]
    away.update((path, [entry["old_sha"], index_raw.get(path, {}).get("new_sha")]) for path, entry in deleted.items())
    moved = moved_files(away, [path for path in untracked if not path.endswith("/")]) if away else {}
    for path in untracked:
        if path.endswith("/"):  # a nested repository
            files[path.rstrip("/")] = file_entry(path.rstrip("/"), submodule=True)
        elif path in moved:
            # An unstaged mv changes no line. Binary stays binary, and every
            # path the file had stays for the risk check (spec rule 2).
            old = moved[path]
            item = files.pop(old, None) or file_entry(old)
            binary = item["binary"] or has_nul(path)
            paths = [old, item["old_path"]] + item.get("moved_from", [])
            if old in deleted:
                # A base file: the commits and the index may have changed it.
                kept = [found[side][1].get(old) for side in ("head", "index") if old in found.get(side, ({}, {}))[0]]
                lines, origin = max([count for count in kept if count is not None], default=0), old
            else:
                # Added or renamed on the branch: that change, under the new name.
                lines, origin = item["lines"], item["old_path"]
                if origin in deleted:  # the rename's source is the same deletion
                    source = files.pop(origin, None) or file_entry(origin)
                    binary = source["binary"] or binary
                    paths += [source["old_path"]] + source.get("moved_from", [])
            files[path] = file_entry(path, lines, old_path=origin, binary=binary, moved_from=paths)
        else:
            lines, binary = file_facts(path)
            gone = files.get(path) if path in deleted else None
            if gone:  # deleted, then made again: the larger total, both facts
                lines, binary = max(lines, gone["lines"]), binary or gone["binary"]
            files[path] = file_entry(path, lines, binary=binary, moved_from=(gone or {}).get("moved_from", []))
    # A plain mv with edits is not paired; git add pairs it (git's rename
    # detection). The hint says so when a file gone from the working tree and
    # a new file are both left unpaired.
    # New files: untracked, or added to the index since HEAD (with no commit
    # yet, the whole index side is new).
    staged_new = staged_new if has_head else {path for path, entry in index_raw.items() if entry["status"] == "A"}
    fresh = set(untracked) | staged_new
    hint = any(path in files for path in away) and any(
        path in fresh and path not in deleted and item.get("old_path") is None for path, item in files.items())
    return [files[path] for path in sorted(files)], hint


def base_facts(sha, kind, ref, head):
    subject = None
    if head == EMPTY_TREE:
        since = "0"
    elif sha == EMPTY_TREE:
        since = git("rev-list", "--count", "HEAD", "--")
    else:
        subject = (git("log", "-1", "--no-show-signature", "--format=%s", sha, "--") or "").strip() or None
        since = git("rev-list", "--count", sha + "..HEAD", "--")
    since = (since or "0").strip()
    return {"sha": sha, "subject": subject, "commits_since": int(since) if since.isdigit() else 0,
            "kind": kind, "ref": ref}


def branch_name(branch):
    return shown(branch) if branch is not None else "a detached HEAD"


def follows_branch(record, branch, default_name):
    """Spec rule 5: a task started on the default branch, or on a branch
    since renamed (its ref is gone), can move to the current branch when
    that branch's history holds the start. Only tier set moves it; until then
    it is stale, with a hint."""
    start, old = record.get("start_commit") or "", record.get("branch")
    if old is None or branch is None or branch == default_name or old == branch:
        return False
    if old != default_name and git_run("rev-parse", "--verify", "-q", "refs/heads/" + old)[0] != 1:
        return False  # the old branch is still there: another branch
    if not OBJECT_ID.fullmatch(start) or start == EMPTY_TREE or git("cat-file", "-e", start + "^{commit}") is None:
        return False  # a start that is not here (collect calls it stale)
    return is_ancestor(start, "HEAD")


def collect(record, branch, head, committed=False):
    """The change since the base without the rules: files, base, status
    (open, stale or none) and partial. record None means no task.
    committed: count the commits alone (see diff_files)."""
    default_full, default_ref, default_name = default_branch()
    sha, kind, ref, cause = choose_base(record, branch, head, default_full, default_name)
    has_tier = record is not None and record["declared"] is not None
    stale = None
    if record is not None and record["status"] == "closed":
        stale = "the task is closed"
    elif has_tier and branch != record.get("branch"):
        stale = f"on {branch_name(branch)}, not the task branch {branch_name(record.get('branch'))}"
        if follows_branch(record, branch, default_name):
            stale += "; run tier set on this branch to move the task"
    if kind == "start" and (not OBJECT_ID.fullmatch(sha) or git("cat-file", "-e", sha + "^{tree}") is None):
        stale = stale or f"the base commit {shown(sha[:12])} is not here (shallow clone or gc)"
        sha, kind, cause = head, "head", BASE_MISSING
    files, move_hint = diff_files(sha, committed, head != EMPTY_TREE)
    return {
        "files": files,
        "move_hint": move_hint,
        "base": base_facts(sha, kind, ref, head),
        "status": "stale" if stale else "open" if has_tier else "none",
        "stale_reason": stale,
        "partial": cause is not None,
        "partial_reason": cause,
        "task": record["task_id"] if record is not None else None,
        "default_ref": default_ref,
        "default_name": default_name,
    }


def judge(found, rules):
    """classify on the collected files, plus what collect found."""
    result = classify({"files": found["files"]}, rules)
    if not found["files"]:
        # No change is small; classify reads no files as "files unknown".
        result.update(tier="small", reasons=[], counted_lines=0)
    result.update(found)
    return result


def measure(record, rules):
    """The change since the base of record (None: no task), judged by rules."""
    branch, head = repo_state()
    return judge(collect(record, branch, head), rules)


def write_text(path, text):
    """Atomic: a temp file in the same directory, fsync, os.replace, then
    fsync the directory. Our own temp files older than an hour are removed."""
    directory, name = os.path.split(path)
    prefix = "." + name + "."
    cutoff = time.time() - STALE_TMP_SECONDS
    with contextlib.suppress(OSError):
        for entry in os.listdir(directory):
            if entry.startswith(prefix) and entry.endswith(".tmp"):
                stale = os.path.join(directory, entry)
                with contextlib.suppress(OSError):
                    if os.lstat(stale).st_mtime < cutoff:
                        os.unlink(stale)
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=prefix, suffix=".tmp")
    except OSError as exc:
        raise OSError(exc.errno, exc.strerror, path) from None
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        # A replaced file keeps its mode; a new one stays private (0600).
        with contextlib.suppress(OSError):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    with contextlib.suppress(OSError):
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)


def write_json(path, data):
    text = json.dumps(data, indent=2, ensure_ascii=False)
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        # A path or branch that is not valid UTF-8: escape it, keep valid JSON.
        text = json.dumps(data, indent=2)
    write_text(path, text + "\n")


def lock_seconds():
    if os.environ.get("HARNESS_KIT_TEST_HOOKS") == "1":
        with contextlib.suppress(ValueError):
            return float(os.environ.get("AGENT_GUARD_TEST_TIER_LOCK_SECONDS", LOCK_SECONDS))
    return LOCK_SECONDS


@contextlib.contextmanager
def packet_lock(packet):
    """One tier command per packet at a time; waits up to LOCK_SECONDS. With
    no file locks here, it warns and runs unlocked."""
    fd = None
    try:
        import fcntl
    except ImportError:
        fcntl = None
        warn("file locks are not available here; running without a lock")
    if fcntl is not None:
        try:
            fd = os.open(packet, os.O_RDONLY)
        except OSError as exc:
            warn(f"cannot lock {display(packet)} ({exc.strerror}); running without a lock")
    try:
        if fd is not None:
            wait = lock_seconds()
            deadline = time.monotonic() + wait
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exc:
                    if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                        warn(f"this file system has no file locks ({exc.strerror}); running without a lock")
                        break
                    if time.monotonic() >= deadline:
                        raise TierError(f"another tier command still holds {display(packet)} after {wait:g} s; try again")
                    time.sleep(0.05)
        yield
    finally:
        if fd is not None:
            os.close(fd)


def packet_paths(task):
    packet = os.path.join(TASKS_DIR, task)
    return packet, os.path.join(packet, "tier.json"), os.path.join(packet, "state.json")


def load_tier(path, task):
    record = read_json(path, missing=None)
    if record is None:
        return None
    if not (isinstance(record, dict) and record.get("schema") == TIER_SCHEMA
            and record.get("task_id") == task and record.get("status") in ("open", "closed")
            and isinstance(record.get("start_commit"), str)
            and record.get("declared") in TIERS + (None,) and record.get("suggested") in TIERS + (None,)
            and isinstance(record.get("history"), list)
            and all(isinstance(entry, dict) for entry in record["history"])):
        raise TierError(f"{display(path)} is not a valid tier record; only the tier commands may write it")
    return record


def new_record(task, branch, head):
    return {
        "schema": TIER_SCHEMA, "task_id": task, "branch": branch, "base_ref": None,
        "start_commit": head, "declared": None, "suggested": None, "suggestion_inputs": {},
        "reason": None, "coding_started_tier": None, "coding_started_at": None,
        "status": "open", "closed_at": None, "closed_by": None, "history": [],
    }


def history_entry(event, tier, printed_by, recorded_by=None, answer=None, reason=None, base=None, overrode=()):
    entry = {
        "at": now(), "event": event, "tier": tier, "printed_by": printed_by,
        "recorded_by": recorded_by or printed_by,
        "host_session": os.environ.get("AGENT_HOST_SESSION_ID") or None,
        "answer": answer, "reason": reason,
    }
    if base is not None:
        entry["base"] = base  # the --base this set gave
    if overrode:
        entry["overrode"] = list(overrode)  # the negative reviews this lowering went past
    return entry


def spec_owner():
    """state.json owner for phase analysis: the host class of the @spec
    occupant in docs/agent-configs/seats.json; claude when unknown."""
    try:
        host = read_json(SEATS_PATH)["seats"]["spec"]["occupant"]["host"]
    except (TierError, KeyError, TypeError):
        return "claude", None
    if host in ("claude", "codex"):
        return host, None
    if host == "human":
        return "user", None
    if isinstance(host, str) and host:
        return "agent", {"host": host}
    return "claude", None


def minimal_state(task, tier, base_commit):
    """The handoff schema's initial state, with base_commit = start_commit."""
    owner, occupant = spec_owner()
    state = {
        "protocol_version": "claude-codex-collaboration/v1", "task_id": task,
        "status": "open", "phase": "analysis", "seat": "@spec", "owner": owner,
    }
    if occupant:
        state["occupant"] = occupant
    state.update({
        "requested_action": ACTIONS[tier], "base_commit": base_commit,
        "source_task": None, "blocks": [], "revision_rounds": 0,
        "spec_sufficiency": {"verdict": "not_reviewed", "sufficient_for_coding_model": "not_reviewed"},
        "escalation_reason": None,
        "verification": {"runner": "none", "status": "not_run", "reason": None, "report": None},
        "updated_at": now(),
    })
    return state


def state_for_set(state_path, task, tier, start_commit):
    """Writes the minimal state when there is none. Otherwise fills a null
    base_commit with start_commit (a state without the key stays as it is),
    and refreshes requested_action while phase is analysis and the text is
    still a kit one."""
    if not os.path.lexists(state_path):
        write_json(state_path, minimal_state(task, tier, start_commit))
        return
    try:
        state = read_json(state_path)
    except TierError as exc:
        warn(f"{exc}; its requested_action is not refreshed")
        return
    if not isinstance(state, dict):
        return
    changed = False
    if "base_commit" in state and not state["base_commit"]:
        state["base_commit"] = start_commit  # the handoff schema: tier set fills a null one
        changed = True
    action = state.get("requested_action")
    if state.get("phase") == "analysis" and action in ACTIONS.values() and action != ACTIONS[tier]:
        state["requested_action"] = ACTIONS[tier]
        changed = True
    if changed:
        state["updated_at"] = now()
        write_json(state_path, state)


def read_active():
    try:
        with open(ACTIVE_PATH, encoding="utf-8") as handle:
            return handle.read().strip() or None
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise TierError(f"cannot read .agents/tasks/ACTIVE: {exc}")


def needs_reason(record, tier):
    """A tier below the last suggestion needs --reason. Re-confirming the same
    lowered tier does not, while a reason is stored and no suggestion came
    after the last set."""
    suggested = record["suggested"]
    if not suggested or TIERS.index(tier) >= TIERS.index(suggested):
        return False
    if tier == record["declared"] and record.get("reason"):
        events = [entry.get("event") for entry in record["history"]]
        last_set = max((i for i, event in enumerate(events) if event in ("set", "checkpoint")), default=-1)
        last_suggest = max((i for i, event in enumerate(events) if event == "suggest"), default=-1)
        if last_set > last_suggest:
            return False
    return True


# ---- review files ----
# The review files of a packet, in the formats of the handoff schema. Only the
# latest attempt of each counts: lowering needs a reason while one is negative,
# and a raise after coding needs the new tier's reviews to pass.
# seat: (file, key, negative values, passing values, what to fix)
REVIEWS = {
    "@gate": ("gate-review.md", "sufficient_for_coding_model", ("no",), ("yes",), "fix the spec"),
    "@verify": ("verify-review.md", "verdict", ("changes_required", "blocked"), ("pass",), "fix the change"),
    "@audit": ("audit-review.md", "verdict", ("changes_required",), ("pass",), "fix what it found"),
}
# Older packets: codex-review.md holds the @gate and @verify attempts in two
# sections, claude-review.md the @audit ones. seat: (file, section or None)
LEGACY_REVIEWS = {
    "@gate": ("codex-review.md", "pre-coding technical review"),
    "@verify": ("codex-review.md", "final technical review"),
    "@audit": ("claude-review.md", None),
}
# The reviews a tier needs when it was raised after coding started.
RAISE_NEEDS = {"small": (), "medium": ("@verify",), "large": ("@gate", "@verify", "@audit")}
ATTEMPT_HEADER = re.compile(r" {0,3}#{2,6}[ \t]+attempt[ \t]+[0-9]+\b.*", re.I)
CROSS_ATTEMPT_HEADER = re.compile(r" {0,3}#{2,6}[ \t]+cross-review[ \t]+attempt[ \t]+[0-9]+\b.*", re.I)
HEADING = re.compile(r" {0,3}(#{1,6})(?:[ \t].*)?")
FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")
COMMENT = re.compile(r"<!--.*?-->")
# key: value, also as a list item (- * +) or with a bold key (**key:** or **key**:).
KEY_LINE = re.compile(r"[ \t]*(?:[-*+][ \t]+)?(?:\*\*|__)?([A-Za-z][A-Za-z0-9_-]*)(?:\*\*|__)?[ \t]*:"
                      r"(?:\*\*|__)?[ \t]*(.*?)[ \t]*")
# The verdict word a value starts with; a note may follow ("no (2 blockers)").
REVIEW_WORD = re.compile(r"(pass|changes_required|blocked|yes|no)(?![a-z0-9])")
HUMAN = re.compile(r"human(?![a-z0-9])")
# A pr: value that names a pull request: a link anywhere in it, or a number
# at its start ("12", "#12", "PR #12", "o/r#12"). "TBD" and "0" do not.
PR_URL = re.compile(r"https?://[^\s>)\]]+")
PR_NUMBER = re.compile(r"\[?(?:pr[ \t]*)?(?:[\w.-]+/[\w.-]+)?#?[1-9][0-9]*(?![0-9A-Za-z])", re.I)
CROSS_REVIEW_FILES = ("audit-review.md", "claude-review.md")


def attempts(path, part=None):
    """The attempt sections of a review file, oldest first, each a list of
    (key, value) pairs with the keys in lower case; None when the file is
    missing. audit-review.md and claude-review.md have `## Cross-review
    attempt <n>` sections, the others `### Attempt <n>`. A section ends at the
    next attempt or at a heading of its level or higher. part: only attempts
    under the `## <part>` heading (any case). Code fences and HTML comments
    are skipped."""
    header = CROSS_ATTEMPT_HEADER if os.path.basename(path) in CROSS_REVIEW_FILES else ATTEMPT_HEADER
    in_part = part is None
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as handle:
            lines = handle.read().splitlines()
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as exc:
        raise TierError(f"cannot read {display(path)}: {exc.strerror or exc}")
    sections, level, inside, fence, comment = [], 0, False, None, False
    for line in lines:
        if fence is not None:
            # A fence ends with the same character, at least as long, and nothing after it.
            mark = FENCE.fullmatch(line)
            if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence) and not mark.group(2).strip():
                fence = None
            continue
        if comment:
            end = line.find("-->")
            if end < 0:
                continue
            line, comment = line[end + 3:], False
        else:
            mark = FENCE.fullmatch(line)
            if mark and not (mark.group(1)[0] == "`" and "`" in mark.group(2)):
                fence = mark.group(1)
                continue
        line = COMMENT.sub("", line)
        if "<!--" in line:
            line, comment = line[:line.index("<!--")], True
        heading = HEADING.fullmatch(line)
        if heading:
            if part is not None and len(heading.group(1)) <= 2:
                in_part = " ".join(line.strip().lstrip("#").split()).lower() == part
            if in_part and header.fullmatch(line):
                sections.append([])
                level, inside = len(heading.group(1)), True
            elif len(heading.group(1)) <= level:
                inside = False
            continue
        pair = KEY_LINE.fullmatch(line) if inside else None
        if pair:
            sections[-1].append((pair.group(1).lower(), pair.group(2)))
    return sections


def review_word(value):
    """The verdict word a value starts with, or None. Case, backticks and *
    around it do not matter; spaces and hyphens count as _. A template with
    choices ("pass | changes_required") is not a verdict."""
    text = re.sub(r"[\s-]+", "_", value.strip("`* \t").lower())
    word = None if "|" in text else REVIEW_WORD.match(text)
    return word.group(1) if word else None


def verify_human_ok(pairs, push=False):
    """A human @verify review counts only with a pr: line that names the pull
    request (a link or a number). At push, pr: pending counts too: the PR
    needs the push (spec rule 3)."""
    human = any(HUMAN.match(value.strip("`* \t").lower()) for name, value in pairs if name == "reviewer_model")
    return not human or any(PR_URL.search(value) or PR_NUMBER.match(value.strip("`*<> \t"))
                            or (push and value.strip("`*<> \t").lower() == "pending")
                            for name, value in pairs if name == "pr")


def file_review_state(path, part, seat, push=False):
    """absent, pending, negative or passed for one review file (spec rule 3).
    absent: no file, or no attempt in it. The latest attempt with a verdict
    for the seat's key decides: negative, or passed when it is also the
    newest attempt; anything else is pending. A value that is not a verdict
    word (a note in the findings, a template line) is ignored."""
    _, key, negative, passing, _ = REVIEWS[seat]
    sections = attempts(path, part)
    if not sections:
        return "absent"
    pairs = next((found for found in reversed(sections)
                  if any(name == key and review_word(value) for name, value in found)), None)
    if pairs is None:
        return "pending"
    words = [word for word in (review_word(value) for name, value in pairs if name == key) if word]
    if any(word in negative for word in words):
        return "negative"
    # A pass counts only from the very last attempt: a newer attempt with no
    # verdict yet (a re-review under way) makes it pending.
    if (pairs is sections[-1] and all(word in passing for word in words)
            and (seat != "@verify" or verify_human_ok(pairs, push))):
        return "passed"
    return "pending"


def review_state(packet, seat, push=False):
    """absent, pending, negative or passed for one review (spec rule 3): the
    seat's own file once it has an attempt, else its older file
    (LEGACY_REVIEWS). A pending own file keeps the older file's negative for
    lowering, and never borrows its pass."""
    own = file_review_state(os.path.join(packet, REVIEWS[seat][0]), None, seat, push)
    name, part = LEGACY_REVIEWS[seat]
    older = file_review_state(os.path.join(packet, name), part, seat, push)
    if own == "absent":
        return older
    if own == "pending" and older == "negative":
        return "negative"
    return own


def negative_reviews(packet):
    """The seats whose latest review attempt is negative."""
    return [seat for seat in REVIEWS if review_state(packet, seat) == "negative"]


def joined_seats(seats):
    return seats[0] if len(seats) == 1 else ", ".join(seats[:-1]) + " and " + seats[-1]


def review_override(packet, action, reason):
    """Spec rule 1: a lowering while a latest review is negative needs
    --reason; it then warns, and the PR line shows it. Returns the negative
    seats and the warning to print once the set is written ([] and None when
    no review is negative)."""
    negative = negative_reviews(packet)
    if not negative:
        return [], None
    names = joined_seats(negative)
    review = "review is" if len(negative) == 1 else "reviews are"
    if reason is None:
        fix = REVIEWS[negative[0]][4] if len(negative) == 1 else "fix what they found"
        raise TierError(f"latest {names} {review} negative; {fix}, or give --reason TEXT for {action} anyway")
    return negative, f"{action} although the latest {names} {review} negative (reason: {one_line(reason)})"


def missing_reviews(packet, tier, push=False):
    """The reviews tier needs after a raise whose latest attempt does not pass.
    A file that cannot be read does not pass."""
    missing = []
    for seat in RAISE_NEEDS[tier]:
        try:
            passed = review_state(packet, seat, push) == "passed"
        except TierError as exc:
            warn(f"{exc}; it counts as not passed")
            passed = False
        if not passed:
            missing.append(seat)
    return missing


def stored_request(task):
    """The facts of the task's last suggestion as a classify request, or None."""
    record = load_tier(packet_paths(task)[1], task)
    inputs = (record or {}).get("suggestion_inputs")
    if not isinstance(inputs, dict):
        return None
    paths = inputs.get("paths") if string_list(inputs.get("paths")) else []
    flags = inputs.get("flags") if string_list(inputs.get("flags")) else []
    lines = inputs.get("lines") if whole_number(inputs.get("lines")) else None
    if not (paths or flags or lines is not None):
        return None
    request = {"files": [{"path": path} for path in paths], "lines": lines}
    request.update({flag: flag in flags for flag in FLAG_REASONS})
    return request


def op_suggest(args):
    request = {"files": [{"path": path} for path in args.paths], "lines": args.lines}
    request.update({flag: getattr(args, flag) for flag in FLAG_REASONS})
    reused = None
    if args.task is not None and not args.paths and args.lines is None and not any(request[f] for f in FLAG_REASONS):
        # A call with no facts (a checkpoint that forgot them) keeps the
        # facts already known instead of wiping them.
        reused = stored_request(args.task)
        request = reused or request
    result = classify(request, load_rules(args.policy, args.tech_stack))
    print(f"Suggested: {result['tier']}")
    if reused:
        print("- facts from the last suggestion (none were given)")
    for reason in result["reasons"]:
        print(f"- {reason}")
    sys.stdout.flush()
    if args.task is None:
        return
    packet, tier_path, _ = packet_paths(args.task)
    try:
        os.makedirs(packet, exist_ok=True)
        with packet_lock(packet):
            record = load_tier(tier_path, args.task)
            if record is None:
                record = new_record(args.task, *repo_state())
            elif record["status"] == "closed":
                print(f"tier suggest: not recorded (task {args.task} is closed)", file=sys.stderr)
                return
            record["suggested"] = result["tier"]
            record["suggestion_inputs"] = {
                "paths": [item["path"] for item in read_files(request["files"])],
                "lines": request["lines"],
                "flags": [flag for flag in FLAG_REASONS if request[flag]],
            }
            record["history"].append(history_entry("suggest", result["tier"], args.by))
            write_json(tier_path, record)
    except OSError as exc:
        if exc.errno not in READ_ONLY:
            raise
        print("tier suggest: not recorded (packet is read-only)", file=sys.stderr)


def op_set(args):
    task, tier = args.task, args.tier
    branch, head = repo_state()
    base = check_base(args.base, branch) if args.base is not None else None
    packet, tier_path, state_path = packet_paths(task)
    os.makedirs(packet, exist_ok=True)
    with packet_lock(packet):
        record = load_tier(tier_path, task)
        if record is not None and record["status"] == "closed":
            raise TierError(f"task {task} is closed; use a new task id for new work")
        if record is None:
            record = new_record(task, branch, head)
        first = record["declared"] is None
        if first:
            # The first set starts the task, also when a suggestion made the
            # record: branch, base and start commit are the ones of now.
            record.update(branch=branch, base_ref=base, start_commit=head)
        base_changed, overrode, notes = False, [], []
        if not first and base is not None and base != record["base_ref"]:
            # A branch that does not start from the default branch gets its
            # base later. It changes what is measured, so while a review is
            # negative it warns, like a lowering.
            negative = negative_reviews(packet)
            if negative:
                notes.append(f"changing the --base although the latest {joined_seats(negative)} "
                             f"{'review is' if len(negative) == 1 else 'reviews are'} negative")
            record["base_ref"], base_changed = base, True
        moved = None
        if not first and follows_branch(record, branch, default_branch()[2]):
            moved, record["branch"] = record["branch"], branch
        # Lowering (spec rule 1): below the higher of the declared tier and
        # the current suggestion, also on the first set and as a checkpoint
        # keep (a packet can be reviewed before it, or the scope can grow).
        known = [name for name in (record["declared"], record["suggested"]) if name in TIERS]
        ceiling = max(known, key=TIERS.index) if known else None
        if ceiling is not None and TIERS.index(tier) < TIERS.index(ceiling):
            if record["declared"] in TIERS and TIERS.index(tier) < TIERS.index(record["declared"]):
                overrode, note = review_override(packet, "lowering the tier", args.reason)
            else:
                overrode, note = review_override(packet, f"setting the tier below the suggested {ceiling}", args.reason)
            notes += [note] if note else []
        if args.reason is None and needs_reason(record, tier):
            raise TierError(f"{tier} is below the suggested {record['suggested']}; this needs --reason TEXT")
        found = None
        try:
            # Measured as declared: on the first set, from the new base.
            found = collect(dict(record, declared=record["declared"] or tier), branch, head)
        except TierError as exc:
            warn(f"{exc}; the change is not measured")
        if found and found["status"] == "open" and has_code(found) and record["coding_started_tier"] is None:
            record["coding_started_tier"] = record["declared"] or tier
            record["coding_started_at"] = now()
        if args.reason is not None:
            record["reason"] = args.reason
        elif tier != record["declared"]:
            record["reason"] = None
        record["declared"] = tier
        event = "checkpoint" if args.answer is not None else "set"
        record["history"].append(history_entry(event, tier, args.by, args.recorded_by, args.answer, args.reason,
                                               base if first or base_changed else None, overrode))
        write_json(tier_path, record)
        state_for_set(state_path, task, tier, record["start_commit"])
        write_text(ACTIVE_PATH, task + "\n")
    for note in notes:  # only once the set is written
        warn(note)
    print(f"Tier set: {tier} (task {task})")
    if base_changed:
        print(f"The base is now {shown(short_ref(base))}.")
    if moved is not None:
        print(f"The task moved to branch {shown(branch)} (it was started on {shown(moved)}).")
    count = len(found["files"]) if first and found else 0
    hint = "" if base is not None else " If this branch starts from another branch, run tier set again with --base <that branch>."
    if count == 1:
        print("1 file is already changed; it counts toward this task. "
              "Commit or stash it on another branch first if it belongs to other work." + hint)
    elif count:
        print(f"{count} files are already changed; they count toward this task. "
              "Commit or stash them on another branch first if they belong to other work." + hint)


def one_line(text):
    return " ".join(text.split())


def tier_outcome(record, result, packet):
    """(over, missing) for the PR line, as pre-final judges them: the measure
    above the allowed tier (the declared one, or the suggestion a reason
    covers), and the reviews a raise after coding still needs. A stale
    result has neither."""
    declared = record["declared"]
    if declared not in TIERS or result["status"] != "open":
        return False, []
    covers = reason_covers(record)
    allowed = covers if covers and record.get("reason") and TIERS.index(declared) < TIERS.index(covers) else declared
    started = record.get("coding_started_tier")
    raised = started in TIERS and TIERS.index(declared) > TIERS.index(started)
    return TIERS.index(result["tier"]) > TIERS.index(allowed), missing_reviews(packet, declared) if raised else []


def op_show(args):
    task = args.task
    if task is None:
        task = read_active()
        if task is None:
            raise TierError("no active task; use --task <id>")
        if not TASK_ID.fullmatch(task) or task.lower() in RESERVED_IDS:
            raise TierError(f".agents/tasks/ACTIVE does not hold a task id (got: {shown(task)}); use --task <id>")
    _, tier_path, _ = packet_paths(task)
    record = load_tier(tier_path, task)
    if record is None:
        raise TierError(f"task {task} has no tier record; run tier set first")
    found = result = None
    try:
        found = collect(record, *repo_state())
        note_coding_start(record, found)
        result, problem = judge(found, load_rules(args.policy, args.tech_stack)), None
    except TierError as exc:
        problem = str(exc)
    declared, suggested, reason = record["declared"], record["suggested"], record.get("reason")
    last = last_set_index(record)
    overrode = record["history"][last].get("overrode") or [] if last >= 0 else []
    if args.pr_line:
        line = f"Tier: {declared or 'not set'}"
        covers = reason_covers(record) if reason else None

        def below(name):
            return name in TIERS and (declared is None or TIERS.index(declared) < TIERS.index(name))

        if below(suggested) or below(covers):
            covered = f"; the reason covers {covers}" if covers and covers != suggested else ""
            line += f" (suggested {suggested}{covered}" + (f": {one_line(reason)}" if reason else "") + ")"
        if result:
            notes = [word for word, on in (("stale", result["status"] == "stale"), ("partial", result["partial"])) if on]
            line += f" · {measured_size(result)}" + (f" ({', '.join(notes)})" if notes else "")
        else:
            line += f" · measured: n/a ({problem})"
        if result:
            over, missing = tier_outcome(record, result, packet_paths(task)[0])
            if over:
                line += f" · measured {result['tier']}, above the tier"
            if missing:
                line += f" · {joined_seats(missing)} review{'s' if len(missing) > 1 else ''} still needed"
        if overrode:
            line += f" · lowered despite a negative {joined_seats(overrode)} review"
        print(line)
        return
    count = len(record["history"])
    print(f"task: {task}")
    print(f"declared: {declared or 'none'}")
    print(f"suggested: {suggested or 'none'}")
    print(f"reason: {shown(reason) if reason else 'none'}")
    if overrode:
        print(f"note: lowered despite a negative {joined_seats(overrode)} review")
    stale = found is not None and found["status"] == "stale"
    print(f"status: stale ({found['stale_reason']})" if stale else f"status: {record['status']}")
    print(f"history: {count} {'entry' if count == 1 else 'entries'}")
    if result is None:
        print(f"measured: n/a ({problem})")
        return
    label = f"measured (partial: {result['partial_reason']})" if result["partial"] else "measured"
    print(f"{label}: {result['tier']} ({measured_size(result)})")
    for item in result["reasons"]:
        print(f"- {item}")
    base = result["base"]
    since = plural(base["commits_since"], "commit") + " since"
    if base["sha"] == EMPTY_TREE:
        print(f"base: empty tree ({since})")
    else:
        subject = f' "{shown(base["subject"])}"' if base["subject"] else ""
        print(f"base: {base['sha'][:7]}{subject} ({since})")


def measured_size(result):
    return f"{plural(result['counted_files'], 'file')}, {plural(result['counted_lines'], 'line')}"


DOC_SUFFIXES = (".md", ".mdx")


def has_code(found):
    """True when the change has a file that is not *.md or *.mdx (every path
    of the file counts, a moved one included): a change of docs alone does
    not start coding."""
    return any(not path.lower().endswith(DOC_SUFFIXES) for item in found["files"] for path in item_paths(item))


def note_coding_start(record, found):
    """The first time an open task has a change that is not docs only (see
    has_code), records the declared tier as coding_started_tier, with the
    time. Never changed later. A read-only packet skips it. Returns the
    coding_started_tier now on record."""
    if record["coding_started_tier"] is not None or found["status"] != "open" or not has_code(found):
        return record["coding_started_tier"]
    task = record["task_id"]
    packet, tier_path, _ = packet_paths(task)
    try:
        with packet_lock(packet):
            record = load_tier(tier_path, task)
            if (record is None or record["status"] != "open" or record["declared"] is None
                    or record["coding_started_tier"] is not None):
                return None if record is None else record["coding_started_tier"]
            record["coding_started_tier"] = record["declared"]
            record["coding_started_at"] = now()
            write_json(tier_path, record)
            return record["coding_started_tier"]
    except OSError as exc:
        if exc.errno not in READ_ONLY:
            raise
    return None


def op_close(args):
    task = args.task
    packet, tier_path, state_path = packet_paths(task)
    if not os.path.isdir(packet):
        raise TierError(f"task {task} has no tier record; nothing to close")
    with packet_lock(packet):
        record = load_tier(tier_path, task)
        if record is None:
            raise TierError(f"task {task} has no tier record; nothing to close")
        if record["status"] == "closed":
            print(f"Tier already closed (task {task})")
            return
        try:
            state = read_json(state_path, missing=None)
        except TierError as exc:
            raise TierError(f"{exc}; fix it, then close again")
        if state is None:
            state = minimal_state(task, record["declared"] or "large", record["start_commit"])
        if not isinstance(state, dict):
            raise TierError(f"{display(state_path)} is not a JSON object; fix it, then close again")
        at = now()
        # The state contract: closed goes with phase closed and closed_by user;
        # a seat tag, when present, follows the phase (closed -> @owner).
        state.update({"phase": "closed", "status": "closed", "closed_by": "user", "updated_at": at})
        if "seat" in state:
            state["seat"] = "@owner"
        record.update({"status": "closed", "closed_at": at, "closed_by": "user"})
        record["history"].append(history_entry("close", record["declared"], "user"))
        # state.json first: if a write fails, the tier stays open and close can run again.
        write_json(state_path, state)
        write_json(tier_path, record)
        if read_active() == task:
            with contextlib.suppress(FileNotFoundError):
                os.remove(ACTIVE_PATH)
    print(f"Tier closed: {record['declared'] or 'not set'} (task {task})")


def op_classify(args):
    """Hidden, for tests and pre-final: prints the classify result as JSON."""
    try:
        request = json.loads(args.request)
    except ValueError as exc:
        raise TierError(f"tier request is not valid JSON: {exc}")
    if isinstance(request, dict) and args.paths:
        request["files"] = list(request.get("files") or []) + [{"path": path} for path in args.paths]
    print(json.dumps(classify(request, load_rules(args.policy, args.tech_stack)), ensure_ascii=False))


def last_set_index(record):
    events = [entry.get("event") for entry in record["history"]]
    return max((i for i, event in enumerate(events) if event in ("set", "checkpoint")), default=-1)


def reason_covers(record):
    """Spec rule 1: the suggestion a stored reason was given against, the one
    in force at the tier set that gave it (the last suggest event before
    it); None with no reason or no such suggestion. A later suggestion, lower
    or higher, does not change it."""
    reason, history = record.get("reason"), record["history"]
    given = max((i for i, entry in enumerate(history)
                 if entry.get("event") in ("set", "checkpoint") and entry.get("reason") == reason), default=-1)
    if not reason or given < 0:
        return None
    found = next((entry.get("tier") for entry in reversed(history[:given]) if entry.get("event") == "suggest"), None)
    return found if found in TIERS else None


def suggested_after_set(record):
    """A suggestion came after the last tier set: the user has not confirmed
    the tier against it yet."""
    last = last_set_index(record)
    return last >= 0 and any(entry.get("event") == "suggest" for entry in record["history"][last + 1:])


def op_measure(args):
    """Hidden, for tests and pre-final: prints the measure result as JSON, with
    the record's declared, suggested, reason and coding_started_tier (all null
    with no record). Without --task it measures the ACTIVE task; --committed
    counts the commits alone (the pre-push hook). A task with no
    tier record is measured with the no-tier rule (status none).
    raised_after_coding: the declared tier is above coding_started_tier;
    missing_reviews then lists the reviews that tier needs whose latest
    attempt does not pass (empty otherwise)."""
    task = args.task
    if task is None:
        with contextlib.suppress(TierError):
            active = read_active()
            if active and TASK_ID.fullmatch(active) and active.lower() not in RESERVED_IDS:
                task = active
    record = load_tier(packet_paths(task)[1], task) if task else None
    rules = load_rules(args.policy, args.tech_stack)
    found = collect(record, *repo_state(), committed=args.committed)
    started = note_coding_start(record, found) if record is not None else None
    result = judge(found, rules)
    record = record or {}
    declared = record.get("declared")
    raised = started in TIERS and declared in TIERS and TIERS.index(declared) > TIERS.index(started)
    result.update(declared=declared, suggested=record.get("suggested"), reason=record.get("reason"),
                  reason_covers=reason_covers(record) if record else None,
                  suggested_after_set=suggested_after_set(record) if record else False,
                  coding_started_tier=started, raised_after_coding=raised,
                  missing_reviews=missing_reviews(packet_paths(task)[0], declared, args.committed) if raised else [],
                  base_ref=record.get("base_ref"), branch=repo_state()[0])
    print(json.dumps(result, ensure_ascii=False))


# ---- command line ----
SYNOPSIS = (
    "tier suggest [--task <id>] [--by @seat] [--paths <file>...] [--lines N] [--data] [--access] [--dependency] [--unclear]",
    "tier set <small|medium|large> --task <id> [--reason TEXT] [--base <ref>] [--by @seat] [--recorded-by @seat] [--answer keep|switch|scope]",
    "tier show [--task <id>] [--pr-line]",
    "tier close --task <id>",
)
USAGE = "".join(("Usage: " if index == 0 else "       ") + "scripts/agent-guard.sh " + line + "\n"
                for index, line in enumerate(SYNOPSIS))
HELP = USAGE + "\n".join((
    "",
    "suggest prints a tier (small, medium or large) and the reasons for it.",
    "  --paths takes every argument up to the next -- option. Leave it out when the files are unknown.",
    "  --lines is your estimate of changed lines, without tests, lock files and generated files.",
    "  --data: changes stored or sent data. --access: changes who may do what.",
    "  --dependency: adds or upgrades a library. --unclear: the request is not clear yet.",
    "  With --task, it also records the suggestion in .agents/tasks/<id>/tier.json.",
    "set records the tier the user confirmed. A tier below the suggestion needs --reason.",
    "  --base names the branch a stacked branch starts from. --answer records a checkpoint answer.",
    "show prints the task record and the change since its base; --pr-line prints one line for the PR body.",
    "close closes the task. Run it only when the user says the task is done.",
)) + "\n"


class TierParser(argparse.ArgumentParser):
    """Usage errors exit 1 through TierError; help is the tier help text."""

    def format_help(self):
        return HELP

    def format_usage(self):
        return USAGE

    def error(self, message):
        sys.stderr.write(USAGE)
        raise TierError(message)


def utf8_text(value, option):
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise argparse.ArgumentTypeError(f"{option} is not valid UTF-8 text")
    return value


def task_id(value):
    if value.lower() in RESERVED_IDS:
        raise argparse.ArgumentTypeError(f"task id {shown(value)} is reserved: it clashes with .agents/tasks/ACTIVE")
    if not TASK_ID.fullmatch(value):
        raise argparse.ArgumentTypeError(
            f"task id must be lowercase letters, digits and single dashes, like fix-logout (got: {shown(value)})")
    return value


def seat(value):
    if not SEAT.fullmatch(value):
        raise argparse.ArgumentTypeError(f"must be user or a seat like @build (got: {shown(value)})")
    return value


def reason_text(value):
    if not value.strip():
        raise argparse.ArgumentTypeError("needs some text; it is blank")
    return utf8_text(value, "--reason")


def base_ref(value):
    return utf8_text(value, "--base")


def line_count(value):
    if not re.fullmatch(r"[0-9]+", value):
        raise argparse.ArgumentTypeError(f"must be a whole number, 0 or more (got: {shown(value)})")
    return int(value)


def command_parsers():
    def parser(name):
        return TierParser(prog=f"scripts/agent-guard.sh tier {name}", allow_abbrev=False)

    def paths(command):
        command.add_argument("--paths", nargs="*", action="extend", default=[])

    suggest = parser("suggest")
    suggest.add_argument("--task", type=task_id)
    suggest.add_argument("--by", type=seat, default="user")
    paths(suggest)
    suggest.add_argument("--lines", type=line_count)
    for flag in FLAG_REASONS:
        suggest.add_argument("--" + flag, action="store_true")

    set_ = parser("set")
    set_.add_argument("tier", choices=TIERS)
    set_.add_argument("--task", type=task_id, required=True)
    set_.add_argument("--reason", type=reason_text)
    set_.add_argument("--base", type=base_ref)
    set_.add_argument("--by", type=seat, default="user")
    set_.add_argument("--recorded-by", type=seat)
    set_.add_argument("--answer", choices=ANSWERS)

    show = parser("show")
    show.add_argument("--task", type=task_id)
    show.add_argument("--pr-line", action="store_true")

    close = parser("close")
    close.add_argument("--task", type=task_id, required=True)

    classify_ = parser("classify")  # hidden: not in SYNOPSIS or HELP
    classify_.add_argument("--request", required=True)
    paths(classify_)

    measure_ = parser("measure")  # hidden: not in SYNOPSIS or HELP
    measure_.add_argument("--task", type=task_id)
    measure_.add_argument("--committed", action="store_true")

    return {
        "suggest": (suggest, op_suggest), "set": (set_, op_set), "show": (show, op_show),
        "close": (close, op_close), "classify": (classify_, op_classify), "measure": (measure_, op_measure),
    }


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="surrogateescape")
    default_root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    top = TierParser(prog="scripts/agent-guard.sh tier", allow_abbrev=False)
    top.add_argument("--root", default=default_root)
    top.add_argument("--policy")
    top.add_argument("--tech-stack")
    top.add_argument("command", nargs="?")
    top.add_argument("args", nargs=argparse.REMAINDER)
    options = top.parse_args(argv)
    configure(options.root)
    commands = command_parsers()
    if options.command == "help":
        top.print_help()
        return
    if options.command is None:
        sys.stderr.write(USAGE)
        raise TierError("tier needs a command: suggest, set, show or close")
    if options.command not in commands:
        sys.stderr.write(USAGE)
        raise TierError(f"unknown tier command: {shown(options.command)}")
    parser, run = commands[options.command]
    args = parser.parse_args(options.args)
    args.policy = options.policy or os.path.join(ROOT, "docs", "agent-configs", "context-policy.json")
    args.tech_stack = options.tech_stack or os.path.join(ROOT, "docs", "superpowers", "specs", "project-tech-stack.json")
    if os.environ.get("HARNESS_KIT_TEST_HOOKS") == "1" and os.environ.get("AGENT_GUARD_TEST_TIER_CRASH") == "1":
        raise RuntimeError("test hook AGENT_GUARD_TEST_TIER_CRASH")
    run(args)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except TierError as exc:
        print(f"agent-guard: ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        where = f"{display(exc.filename)}: " if exc.filename else ""
        print(f"agent-guard: ERROR: {where}{exc.strerror or exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001 - any other failure is a bug here
        print(f"agent-guard: ERROR: tier evaluator failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(70)
