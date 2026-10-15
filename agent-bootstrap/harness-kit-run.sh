#!/usr/bin/env bash
# Harness Kit orchestrator: one install, reinstall or update of the kit version
# this file belongs to, in phases preflight, stage, apply, migrate, verify and
# report. Started by harness-kit-one-shot.sh (scripts/harness-kit.sh in
# installed projects) from <project>/.harness-kit/v<version>/agent-bootstrap/;
# it also runs directly from a kit checkout. Logs and report.json go to
# <project>/.tools/agent-state/upgrades/<STAMP>/; one run at a time holds
# <project>/.tools/agent-state/run.lock/.
# Exit codes: 0 done, 3 needs review, 1 refused or failed, 2 usage error
# (130 when interrupted).
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GENERATOR="$KIT_DIR/bootstrap-multi-agent-project.sh"
KNOWLEDGE_PY="$KIT_DIR/lib/knowledge.py"
KIT_VERSION="$(sed -n '1p' "$KIT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{1,6}$'
STAMP_RE='^[0-9]{8}-[0-9]{6}$'
STATE_REL=".tools/agent-state"
BASELINE_REL="$STATE_REL/harness-baseline/files"
USER_OWNED_RELS="docs/agent-configs/project-agent-context.md docs/agent-configs/project-brief.md docs/superpowers/specs/project-tech-stack.md docs/superpowers/specs/project-tech-stack.json"
PROTECTED_BRANCHES="main master dev develop"
WORK_BRANCH_HINT="feature/harness-kit-$KIT_VERSION"
# shellcheck source=agent-bootstrap/lib/migrations.sh
. "$KIT_DIR/lib/migrations.sh"

TARGET=""
KIT_VERSION_ARG=""
PLAN_ONLY=false
RESET=false
ROLLBACK_ID=""
SHOW_KNOWLEDGE=false
WORKFLOW=""
IGNORE_TARGET=""
BRANCH=""
PROJECT_VERIFY=false
JSON_OUT=false
SKIP_VERIFY=false
APPLY_RETIREMENTS=false
TAKE_ALL=false
ACTION_FLAGS=0
TAKE_KIT=()
RESOLVED=()
REASONS=()
KEEP_LOCAL=()
ACCEPT=()
DECLINE=()
RETRY_ARGS=()
NOTES=()

# Run state.
MODE=""
FROM=""
STAMP=""
RUN_DIR=""
REASON=""
WOULD_REFUSE=""
RESULT=""
ROLLBACK_REF=""
MIG_META=""
KEEPS=()
RUN_STARTED=false
FINISHED=false
APPLY_STARTED=false
LOCK_HELD=false
LOCK_DIR=""
INTERRUPTED=""
CURRENT_PHASE=preflight
PHASE_T0=0
# Phase status and seconds, read indirectly by write_report().
# shellcheck disable=SC2034
{
  PH_preflight="skipped"; PT_preflight=0
  PH_stage="skipped"; PT_stage=0
  PH_apply="skipped"; PT_apply=0
  PH_migrate="skipped"; PT_migrate=0
  PH_verify="skipped"; PT_verify=0
}

usage() {
  cat <<USAGE
Usage: harness-kit-run.sh [--target DIR] [options]

Installs, reinstalls or updates kit $KIT_VERSION in a Git work tree. Usually
started by scripts/harness-kit.sh or harness-kit-one-shot.sh.

Choose the work:
  (no option)              install, reinstall or update, chosen from the installed lock
  --plan                   stop after staging; writes only .harness-kit/ and .tools/agent-state/
  --reset                  kit output wins for every kit-owned file (backups, rollback) and
                           recorded resolutions and pins are cleared; the brief, the
                           tech-stack contract, seats.json and USER overlays stay
  --rollback STAMP         undo the kit file changes of the run recorded as STAMP
  --knowledge              print what the kit knows about this project
First install:
  --workflow infra|full    workflow preset (install default: full; later runs keep the lock's)
  --ignore-target exclude|gitignore
                           where the local-only ignore block goes (default: exclude)
After a run:
  --take-kit PATH|all      replace PATH (or every open conflict except project-owned
                           files) with this kit's output (backups, rollback)
  --resolved PATH [--reason TEXT]
                           keep the local PATH as final; the kit output becomes its baseline
  --keep-local PATH        pin PATH by hash; later runs leave it alone
  --accept ID              apply a pending migration decision
  --decline ID             decline it until its facts change
Other:
  --branch NAME            create or switch to NAME (feature/... or bugfix/...) before writing
  --project-verify         also run the project's fast verification
  --skip-verify            skip the harness checks
  --json                   print report.json (or the rollback result) instead of the summary
  --kit-version VERSION    expected kit version (set by the entry script)
  -h, --help               show this help
Old options --no-branch, --allow-dirty, --apply-candidates, --apply-retirements,
--dry-run, --cache-dir, --home and --retirement-scope are accepted with a note.
Exit codes: 0 done, 3 needs review, 1 refused or failed, 2 usage error, 130
interrupted (Ctrl-C; TERM exits 1). A --plan exits 0 even when it shows
conflicts or decisions (nothing was applied yet) and 3 when the real run would
be refused.
USAGE
}

err() { printf 'harness-kit: %s\n' "$*" >&2; }
usage_error() {
  err "$*"
  err "see --help for the options"
  exit 2
}
fail_early() {
  err "$*"
  exit 1
}
note() {
  NOTES+=("$1")
  printf 'note: %s\n' "$1" >&2
}
need_value() { [ "$#" -ge 2 ] || usage_error "$1 needs a value"; }
act() { ACTION_FLAGS=$((ACTION_FLAGS + 1)); }
in_list() { # needle items...
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" != "$needle" ] || return 0
  done
  return 1
}
is_version() { [[ "$1" =~ $VERSION_RE ]]; }
gitp() { git --literal-pathspecs -C "$TARGET" "$@"; }

# Python helpers (stdlib only): lock reading, stamps, pins, plan views, report.
IFS= read -r -d '' PY_HELPER <<'PY' || true
import datetime, hashlib, json, os, re, shlex, stat, subprocess, sys

STATE = ".tools/agent-state"
STAMP_RE = re.compile(r"^[0-9]{8}-[0-9]{6}$")
MARKER = "# >>> multi-agent bootstrap local state >>>"
END_MARKER = "# <<< multi-agent bootstrap local state <<<"
USER_OWNED = {"docs/agent-configs/project-agent-context.md", "docs/agent-configs/project-brief.md",
              "docs/superpowers/specs/project-tech-stack.md", "docs/superpowers/specs/project-tech-stack.json"}


def sha(path):
    try:
        st = os.lstat(path)
    except OSError:
        return ""
    if not stat.S_ISREG(st.st_mode):
        return ""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def lines(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []


def rows(path, width):
    out = []
    for line in lines(path):
        cells = line.split("\t")
        out.append(cells + [""] * (width - len(cells)))
    return out


def knowledge(root):
    doc = load(os.path.join(root, STATE, "project-knowledge.json"), {})
    return doc if isinstance(doc, dict) else {}


def plan_files(path):
    plan = load(path, {})
    items = plan.get("files", []) if isinstance(plan, dict) else []
    return [item for item in items if isinstance(item, dict) and isinstance(item.get("path"), str)]


def cmd_lock(root):
    # state|version|workflow, with a separator that keeps empty fields.
    path = os.path.join(root, "docs/agent-configs/agent-bootstrap.lock.json")
    if not os.path.lexists(path):
        print("absent||")
        return
    doc = load(path)
    if not isinstance(doc, dict):
        print("invalid||")
        return
    version = doc.get("version") if isinstance(doc.get("version"), str) else ""
    templates = doc.get("templates") if isinstance(doc.get("templates"), dict) else {}
    workflow = templates.get("workflow_preset") if templates.get("workflow_preset") in ("infra", "full") else ""
    print("present|%s|%s" % (version.replace("|", "/").replace("\n", " "), workflow))


def cmd_stamp(root):
    now = datetime.datetime.now().replace(microsecond=0)
    while True:
        stamp = now.strftime("%Y%m%d-%H%M%S")
        taken = [os.path.join(root, STATE, "upgrades", stamp),
                 os.path.join(root, STATE, "harness-baseline", "upgrades", stamp)]
        if not any(os.path.lexists(path) for path in taken):
            print(stamp)
            return
        now += datetime.timedelta(seconds=1)


def cmd_pins(root):
    files = knowledge(root).get("files") or {}
    for rel in sorted(files):
        res = (files[rel] or {}).get("resolution") or {}
        if res.get("kind") != "keep-local":
            continue
        current = sha(os.path.join(root, rel))
        state = "active" if current and current == res.get("local_sha256") else "stale"
        print("%s\t%s" % (state, rel))


def cmd_resolutions(root):
    files = knowledge(root).get("files") or {}
    for rel in sorted(files):
        if isinstance(files[rel], dict) and files[rel].get("resolution"):
            print(rel)


def cmd_writes(plan_path, reset):
    # What apply writes in the project. Under --reset (--force) kept and
    # conflicting kit files are replaced too; project-owned files and unsafe
    # entries are kept (passed as --keep).
    actions = {"create", "update", "merge", "overwrite"}
    if reset == "true":
        actions |= {"kept", "conflict"}
    for item in plan_files(plan_path):
        if item.get("action") in actions and not (reset == "true" and item["path"] in USER_OWNED):
            print(item["path"])


def cmd_unsafe(plan_path):
    for item in plan_files(plan_path):
        if item.get("action") == "unsafe":
            print(item["path"])


def cmd_user_filled(root, rel):
    # Exit 0 when REL is a project-owned file with content (the kit never
    # replaces it, so taking the kit's version writes nothing).
    if rel not in USER_OWNED:
        sys.exit(1)
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, ValueError):
        sys.exit(1)
    if rel.endswith(".json"):
        try:
            unfilled = json.loads(text).get("status") == "unfilled"
        except (ValueError, AttributeError):
            unfilled = False
    else:
        unfilled = "<!-- UNFILLED -->" in text
    sys.exit(1 if unfilled else 0)


def cmd_save_entries(root, out, *rels):
    files = knowledge(root).get("files") or {}
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({rel: files[rel] for rel in rels if isinstance(files.get(rel), dict)}, handle, indent=2)


def cmd_conflicts(source):
    # Open conflicts of a plan JSON or an apply plan log, project-owned files excluded.
    if source.endswith(".json"):
        pairs = [(item.get("action"), item["path"]) for item in plan_files(source)]
    else:
        pairs = [tuple(row) for row in rows(source, 2)]
    seen = set()
    for action, rel in pairs:
        if action == "conflict" and rel not in seen and rel not in USER_OWNED and ".generated." not in rel:
            seen.add(rel)
            print(rel)


def cmd_class(log, rel):
    for action, path in rows(log, 2):
        if path == rel:
            print(action)
            return


def cmd_knowplan(plan_path, out, when):
    # The plan as knowledge reads it: project-owned files tagged, and after
    # apply without the pre-apply hashes so knowledge hashes the files as they are.
    files = []
    for item in plan_files(plan_path):
        entry = dict(item) if when == "stage" else {"path": item["path"], "action": item.get("action", "")}
        if when != "stage" and item.get("new_sha256"):
            entry["new_sha256"] = item["new_sha256"]
        if item["path"] in USER_OWNED:
            entry["owner"] = "user"
        files.append(entry)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"schema": "agent-bootstrap-upgrade-plan/v1", "files": files}, handle)


def cmd_migration_state(root, ident):
    entry = (knowledge(root).get("migrations") or {}).get(ident) or {}
    print("%s\t%s" % (entry.get("status", ""), entry.get("facts_sha256", "")))


def strip_block(text):
    out, skipping = [], False
    for line in text.splitlines(True):
        bare = line.rstrip("\r\n")
        if not skipping and bare.startswith(MARKER):
            skipping = True
            if out and out[-1].strip() == "":
                out.pop()
            continue
        if skipping:
            if bare.startswith(END_MARKER):
                skipping = False
            continue
        out.append(line)
    return "".join(out)


def cmd_gitignore_block_only(root):
    # Exit 0 when the tracked .gitignore differs from HEAD only by the kit's
    # local-only block (so moving the block only cleans the work tree).
    def git(*args):
        return subprocess.run(["git", "--literal-pathspecs", "-C", root] + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if git("diff", "--cached", "--quiet", "HEAD", "--", ".gitignore").returncode != 0:
        sys.exit(1)
    head = git("show", "HEAD:./.gitignore")
    if head.returncode != 0:
        sys.exit(1)
    try:
        with open(os.path.join(root, ".gitignore"), encoding="utf-8") as handle:
            work = handle.read()
    except (OSError, ValueError):
        sys.exit(1)
    committed = head.stdout.decode("utf-8", "replace")
    if MARKER in committed or MARKER not in work:
        sys.exit(1)
    sys.exit(0 if strip_block(work).rstrip() == committed.rstrip() else 1)


def cmd_rollback_id(root, stamp):
    report = load(os.path.join(root, STATE, "upgrades", stamp, "report.json"), {})
    print(report.get("rollback_id", "") if isinstance(report, dict) else "")


def cmd_latest_journal(root):
    base = os.path.join(root, STATE, "harness-baseline", "upgrades")
    try:
        names = os.listdir(base)
    except OSError:
        names = []
    ids = sorted(n for n in names if STAMP_RE.match(n) and os.path.isdir(os.path.join(base, n))
                 and not os.path.islink(os.path.join(base, n))
                 and os.path.isfile(os.path.join(base, n, "journal.tsv"))
                 and not os.path.exists(os.path.join(base, n, "rolled-back")))
    print(ids[-1] if ids else "")


def migration_backups(run_dir):
    base = os.path.join(run_dir, "journal", "migrations")
    try:
        return any(os.path.isdir(os.path.join(base, n)) for n in os.listdir(base))
    except OSError:
        return False


def cmd_prune_runs(root, current, keep):
    # Beyond the newest KEEP run directories, delete plan-only, refused and
    # old applied runs; keep any with migration backups and applied runs
    # younger than 30 days (their journals can still be rolled back).
    base = os.path.join(root, STATE, "upgrades")
    try:
        names = sorted((n for n in os.listdir(base) if STAMP_RE.match(n)), reverse=True)
    except OSError:
        return
    limit = datetime.datetime.now() - datetime.timedelta(days=30)
    import shutil
    for name in names[int(keep):]:
        path = os.path.join(base, name)
        if name == current or os.path.islink(path) or not os.path.isdir(path):
            continue
        if migration_backups(path):
            continue
        if os.path.exists(os.path.join(path, "apply.log")):
            try:
                if datetime.datetime.strptime(name, "%Y%m%d-%H%M%S") > limit:
                    continue
            except ValueError:
                continue
        shutil.rmtree(path, ignore_errors=True)


def newest_candidate(root, rel):
    folder, name = os.path.split(os.path.join(root, rel))
    try:
        names = os.listdir(folder)
    except OSError:
        return ""
    found = sorted(n for n in names if n.startswith(name + ".generated.")
                   and STAMP_RE.match(n[len(name) + len(".generated."):]))
    return os.path.relpath(os.path.join(folder, found[-1]), root) if found else ""


def stamp_of(conflicts):
    stamps = sorted({c["candidate"].rsplit(".generated.", 1)[-1] for c in conflicts if c["candidate"]})
    return stamps[-1] if len(stamps) == 1 else "*"


ORDER = ["conflict", "create", "update", "merge", "overwrite", "take-kit", "resolved", "kept",
         "pinned", "preserved", "unsafe", "unchanged"]


def cmd_report(run_dir):
    env = os.environ
    root, cmd, stamp = env["R_TARGET"], env["R_CMD"], env["R_STAMP"]
    q = shlex.quote
    plan_only = env.get("R_PLAN_ONLY") == "true"
    verify_skipped = env.get("R_SKIP_VERIFY") == "true"
    applied = env.get("R_APPLIED") == "true"
    reason = env.get("R_REASON", "")
    would_refuse = env.get("R_WOULD_REFUSE", "")
    branch_ids = set(filter(None, env.get("R_BRANCH_IDS", "").split()))
    protected = env.get("R_PROTECTED") == "true"
    rel_run = os.path.relpath(run_dir, root)

    phases = []
    for name, status, seconds, log in rows(os.path.join(run_dir, "phases.tsv"), 4):
        phase = {"name": name, "status": status, "seconds": int(seconds or 0)}
        if log:
            phase["log"] = log
        phases.append(phase)

    classes = {}
    source = os.path.join(run_dir, "apply-plan.tsv")
    if os.path.isfile(source):
        for action, rel in rows(source, 2):
            if rel.startswith(".tools/") or ".generated." in rel:
                continue
            classes.setdefault(rel, action)
    else:
        for item in plan_files(os.path.join(run_dir, "plan.json")):
            classes.setdefault(item["path"], item.get("action", ""))
    resolved = lines(os.path.join(run_dir, "resolved.txt"))
    taken = lines(os.path.join(run_dir, "taken.txt"))
    for rel in resolved:
        classes[rel] = "resolved"
    for rel in taken:
        classes[rel] = "take-kit"
    for rel in lines(os.path.join(run_dir, "reset-preserved.txt")):
        if rel in classes:
            classes[rel] = "preserved"
    for rel in lines(os.path.join(run_dir, "pins.txt")):
        if rel in classes or os.path.lexists(os.path.join(root, rel)):
            classes[rel] = "pinned"
    counts = {}
    for action in classes.values():
        counts[action] = counts.get(action, 0) + 1
    conflicts = []
    for rel in sorted(r for r, a in classes.items() if a == "conflict"):
        conflicts.append({"path": rel, "candidate": newest_candidate(root, rel)})
    stale = lines(os.path.join(run_dir, "stale-pins.txt"))
    cleared = lines(os.path.join(run_dir, "cleared.txt"))
    files = {"counts": dict(sorted(counts.items())), "conflicts": conflicts,
             "kept": sorted(r for r, a in classes.items() if a == "kept"),
             "pinned": sorted(r for r, a in classes.items() if a == "pinned"),
             "stale_pins": stale, "resolved": resolved, "taken": taken, "cleared": cleared}

    migrations = {"applied": [], "pending": [], "declined": [], "failed": []}
    for ident, status, summary, facts in rows(os.path.join(run_dir, "migrations.tsv"), 4):
        if status not in migrations:
            continue
        entry = {"id": ident, "summary": summary}
        if facts:
            entry["facts"] = facts
        if status == "pending":
            prefix = "%s --branch %s" % (cmd, q(env.get("R_WORK_BRANCH", ""))) if (protected and ident in branch_ids) else cmd
            entry["accept"] = "%s --accept %s" % (prefix, q(ident))
            entry["decline"] = "%s --decline %s" % (cmd, q(ident))
        migrations[status].append(entry)

    verify = []
    for check, status, log in rows(os.path.join(run_dir, "verify.tsv"), 3):
        entry = {"check": check, "status": status}
        if log:
            entry["log"] = log
        verify.append(entry)

    failed = bool(reason) or any(p["status"] in ("failed", "refused") for p in phases) \
        or migrations["failed"] or any(v["status"] == "fail" for v in verify)
    if failed:
        result = "failed"
    elif would_refuse or ((conflicts or migrations["pending"]) and not plan_only):
        result = "needs review"
    else:
        result = "done"

    # Open items: (console line, next commands).
    items = []
    if would_refuse:
        items.append(("a real run would be refused: " + would_refuse, []))
    for line in lines(os.path.join(run_dir, "next.txt")):
        items.append(("next: " + line, [line]))
    for entry in migrations["failed"]:
        items.append(("migration %s failed: see %s/migrate.log" % (entry["id"], rel_run), []))
    for entry in verify:
        if entry["status"] == "fail":
            items.append(("check failed: %s (see %s)" % (entry["check"], entry.get("log", rel_run)), []))
    for entry in migrations["pending"]:
        items.append(("decision %s (%s): %s" % (entry["id"], entry["summary"], entry["accept"]),
                      [entry["accept"], entry["decline"]]))
    conflict_cmds = []
    if len(conflicts) > 5:
        conflict_cmds.append("%s --take-kit all" % cmd)
    for item in conflicts:
        conflict_cmds += ["%s --resolved %s" % (cmd, q(item["path"])), "%s --take-kit %s" % (cmd, q(item["path"]))]
    if len(conflicts) > 2:
        text = ("%d conflicts (kit versions in *.generated.%s, listed in the report): keep yours with %s --resolved PATH, "
                "or take the kit's with --take-kit PATH" % (len(conflicts), stamp_of(conflicts), cmd))
        if len(conflicts) > 5:
            text += "; --take-kit all takes every one (keeps backups; undo with --rollback <its stamp>)"
        items.append((text, conflict_cmds))
    else:
        for item in conflicts:
            rel = q(item["path"])
            items.append(("conflict %s (kit version: %s): keep yours with %s --resolved %s, or --take-kit %s"
                          % (rel, item["candidate"] or "none", cmd, rel, rel),
                          ["%s --resolved %s" % (cmd, rel), "%s --take-kit %s" % (cmd, rel)]))
    for rel in stale:
        items.append(("stale pin %s (edited after --keep-local): re-pin with %s --keep-local %s" % (rel, cmd, q(rel)),
                      ["%s --keep-local %s" % (cmd, q(rel))]))
    if failed and applied:
        journal = os.path.join(root, STATE, "harness-baseline", "upgrades", stamp)
        if os.path.isfile(os.path.join(journal, "journal.tsv")):
            undo = "%s --rollback %s" % (cmd, stamp)
            items.append(("undo the kit file changes: " + undo, [undo]))
        elif os.path.exists(os.path.join(journal, "entries.tsv")):
            items.append(("generation stopped midway: restore files from their *.bak.%s backups" % stamp, []))
        if migrations["applied"] or migrations["failed"] or migration_backups(run_dir):
            items.append(("--rollback does not undo migration changes (index, .gitignore); "
                          "their backups are in %s/journal/migrations/" % rel_run, []))
    if plan_only and not failed and not would_refuse:
        items.append(("apply: %s" % cmd, [cmd]))
    nexts = []
    for _, commands in items:
        for command in commands:
            if command not in nexts:
                nexts.append(command)

    project = os.path.basename(root)
    open_bits = []
    if conflicts:
        open_bits.append("%d conflict%s" % (len(conflicts), "" if len(conflicts) == 1 else "s"))
    if migrations["pending"]:
        open_bits.append("%d pending decision%s" % (len(migrations["pending"]), "" if len(migrations["pending"]) == 1 else "s"))
    memo = ["%s: harness-kit %s %s -> %s %s (run %s)" % (project, env["R_MODE"], env.get("R_FROM") or "-",
                                                          env["R_TO"], result, stamp),
            "open: " + (", ".join(open_bits) if open_bits else "nothing") + ("; " + (reason or would_refuse) if (reason or would_refuse) else "")]
    if nexts:
        memo.append("next: " + nexts[0])

    report = {"schema": "harness-kit-run-report/v1", "mode": env["R_MODE"], "from": env.get("R_FROM", ""),
              "to": env["R_TO"], "stamp": stamp, "result": result, "plan_only": plan_only,
              "verify_skipped": verify_skipped, "phases": phases, "files": files,
              "migrations": migrations, "verify": verify, "next": nexts,
              "notes": lines(os.path.join(run_dir, "notes.txt")), "memory_note": "\n".join(memo)}
    if reason:
        report["reason"] = reason
    if would_refuse:
        report["would_refuse"] = would_refuse
    rollback_id = env.get("R_ROLLBACK_ID", "")
    if rollback_id and rollback_id != stamp:
        report["rollback_id"] = rollback_id
    with open(os.path.join(run_dir, "report.json.tmp"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
    os.replace(os.path.join(run_dir, "report.json.tmp"), os.path.join(run_dir, "report.json"))

    # Console summary; the mode line was printed first, so at most 11 more lines.
    out = []
    for phase in phases:
        if phase["status"] == "skipped":
            continue
        extra = ""
        if phase["name"] in ("apply", "stage") and (phase["name"] == "apply" or plan_only) and counts:
            ranked = sorted(counts.items(), key=lambda kv: ORDER.index(kv[0]) if kv[0] in ORDER else len(ORDER))
            extra = ": " + ", ".join("%d %s" % (n, a) for a, n in ranked)
        elif phase["name"] == "migrate":
            bits = ["%d %s" % (len(migrations[k]), k) for k in ("applied", "pending", "declined", "failed") if migrations[k]]
            extra = ": " + (", ".join(bits) if bits else "nothing to do")
        elif phase["name"] == "verify" and verify:
            bad = sum(1 for v in verify if v["status"] == "fail")
            extra = ": %d of %d checks failed" % (bad, len(verify)) if bad else ": %d checks passed" % len(verify)
        out.append("%-9s %s %ds%s" % (phase["name"], phase["status"], phase["seconds"], extra))
    tail = ""
    if plan_only:
        tail = " (plan only, nothing applied)"
    elif verify_skipped and result != "failed":
        tail = " (verify skipped)"
    out.append("RESULT: %s%s%s" % (result, tail, ": " + reason if reason else ""))
    budget = 11 - len(out) - 1
    if len(items) > budget:
        shown = items[:max(budget - 1, 0)]
        out.extend(text for text, _ in shown)
        out.append("... %d more open items: see the report" % (len(items) - len(shown)))
    else:
        out.extend(text for text, _ in items)
    out.append("report: %s/report.json" % rel_run)
    with open(os.path.join(run_dir, "summary.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")
    print(result)


def cmd_rollback_summary(log, rc, as_json, stamp, ident, rel_log):
    text = lines(log)
    restored = [l[len("restored "):] for l in text if l.startswith("restored ")]
    removed = [l[len("removed "):] for l in text if l.startswith("removed ")]
    kept = [l[len("kept "):] for l in text if l.startswith("kept ")]
    errors = [l for l in text if l.startswith("ERROR")]
    rc = int(rc)
    result = "done" if rc == 0 else ("needs review" if rc == 3 else "failed")
    if as_json == "true":
        print(json.dumps({"schema": "harness-kit-rollback/v1", "stamp": stamp, "rollback_id": ident,
                          "result": result, "restored": restored + removed, "kept": kept,
                          "errors": errors, "log": rel_log}, indent=2))
        return
    out = [l for l in text if l.startswith("Rollback ")][:1] + errors[:2]
    shown = kept[:6]
    out += ["kept " + k for k in shown]
    if len(kept) > len(shown):
        out.append("... %d more kept: see the log" % (len(kept) - len(shown)))
    out.append("RESULT: %s" % result)
    out.append("log: " + rel_log)
    print("\n".join(out[:11]))


def main(argv):
    handlers = {"unsafe": cmd_unsafe, "user-filled": cmd_user_filled, "save-entries": cmd_save_entries,
                "lock": cmd_lock, "stamp": cmd_stamp, "pins": cmd_pins, "resolutions": cmd_resolutions,
                "writes": cmd_writes, "conflicts": cmd_conflicts, "class": cmd_class, "knowplan": cmd_knowplan,
                "migration-state": cmd_migration_state, "gitignore-block-only": cmd_gitignore_block_only,
                "rollback-id": cmd_rollback_id, "latest-journal": cmd_latest_journal,
                "prune-runs": cmd_prune_runs, "report": cmd_report, "rollback-summary": cmd_rollback_summary}
    if argv[1] not in handlers:
        sys.exit("unknown helper command: " + argv[1])
    handlers[argv[1]](*argv[2:])


main(sys.argv)
PY
py() { python3 -I -B -c "$PY_HELPER" "$@"; }
know() { python3 -I -B "$KNOWLEDGE_PY" --target "$TARGET" "$@"; }

# clean_relpath PATH: a normalized target-relative path, or failure.
clean_relpath() {
  # Leading ./ is dropped; then, as in knowledge.py, no empty, . or .. part.
  local path="$1"
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done
  case "/$path/" in
    // | */./* | */../* | *//*) return 1 ;;
  esac
  printf '%s\n' "$path"
}

migration_file() { printf '%s/migrations/%s.sh\n' "$KIT_DIR" "$1"; }

parse_args() {
  local rel id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) need_value "$@"; TARGET="$2"; shift 2 ;;
      --kit-version) need_value "$@"; KIT_VERSION_ARG="${2#v}"; shift 2 ;;
      --branch) need_value "$@"; act; BRANCH="$2"; shift 2 ;;
      --json) JSON_OUT=true; shift ;;
      --plan) act; PLAN_ONLY=true; RETRY_ARGS+=("$1"); shift ;;
      --reset) act; RESET=true; RETRY_ARGS+=("$1"); shift ;;
      --rollback) need_value "$@"; ROLLBACK_ID="$2"; shift 2 ;;
      --knowledge) SHOW_KNOWLEDGE=true; shift ;;
      --workflow) need_value "$@"; act; WORKFLOW="$2"; RETRY_ARGS+=("$1" "$2"); shift 2 ;;
      --ignore-target) need_value "$@"; act; IGNORE_TARGET="$2"; RETRY_ARGS+=("$1" "$2"); shift 2 ;;
      --take-kit | --resolved | --keep-local)
        need_value "$@"
        act
        if [ "$1" = --take-kit ] && [ "$2" = all ]; then
          TAKE_ALL=true
          RETRY_ARGS+=("$1" all)
          shift 2
          continue
        fi
        rel="$(clean_relpath "$2")" || usage_error "$1 needs a path relative to the project root: $2"
        case "$1" in
          --take-kit) in_list "$rel" ${TAKE_KIT[@]+"${TAKE_KIT[@]}"} || TAKE_KIT+=("$rel") ;;
          --resolved) RESOLVED+=("$rel"); REASONS+=("") ;;
          --keep-local) in_list "$rel" ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"} || KEEP_LOCAL+=("$rel") ;;
        esac
        RETRY_ARGS+=("$1" "$rel")
        shift 2
        ;;
      --reason)
        need_value "$@"
        [ "${#RESOLVED[@]}" -gt 0 ] || usage_error "--reason follows a --resolved PATH"
        REASONS[${#REASONS[@]} - 1]="$2"
        RETRY_ARGS+=("$1" "$2")
        shift 2
        ;;
      --accept) need_value "$@"; act; ACCEPT+=("$2"); RETRY_ARGS+=("$1" "$2"); shift 2 ;;
      --decline) need_value "$@"; act; DECLINE+=("$2"); RETRY_ARGS+=("$1" "$2"); shift 2 ;;
      --project-verify) act; PROJECT_VERIFY=true; RETRY_ARGS+=("$1"); shift ;;
      --skip-verify) act; SKIP_VERIFY=true; RETRY_ARGS+=("$1"); shift ;;
      --to | --ref)
        need_value "$@"
        if [ "$2" != latest ] && [ "${2#v}" != "$KIT_VERSION" ]; then
          usage_error "this is kit $KIT_VERSION; to change versions run the entry script (scripts/harness-kit.sh --to ${2#v})"
        fi
        shift 2
        ;;
      --source-dir | --repo) need_value "$@"; note "$1 is used only by the entry script; ignored here"; shift 2 ;;
      --no-branch) note "--no-branch is now the default: branches change only with --branch NAME"; shift ;;
      --allow-dirty) note "--allow-dirty is now the default: only tracked files this run writes must be clean"; shift ;;
      --apply-candidates) note "--apply-candidates is replaced by --take-kit PATH|all (use the kit's file) and --resolved PATH (keep yours)"; shift ;;
      --apply-retirements) act; APPLY_RETIREMENTS=true; RETRY_ARGS+=("$1"); shift ;;
      --dry-run) act; PLAN_ONLY=true; RETRY_ARGS+=(--plan); note "--dry-run now means --plan"; shift ;;
      --cache-dir | --home) need_value "$@"; note "$1 is no longer used: the kit copy lives in .harness-kit/"; shift 2 ;;
      --retirement-scope)
        need_value "$@"
        case "$2" in local-only | all-matching) ;; *) usage_error "--retirement-scope must be local-only or all-matching" ;; esac
        note "--retirement-scope is no longer used: the retire-files decision removes local-only files"
        shift 2
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done

  case "$WORKFLOW" in "" | infra | full) ;; *) usage_error "--workflow must be infra or full" ;; esac
  case "$IGNORE_TARGET" in "" | exclude | gitignore) ;; *) usage_error "--ignore-target must be exclude or gitignore" ;; esac
  [ -z "$KIT_VERSION_ARG" ] || is_version "$KIT_VERSION_ARG" || usage_error "--kit-version must look like YYYY.MM.DD.N: $KIT_VERSION_ARG"
  if [ -n "$BRANCH" ]; then
    case "$BRANCH" in feature/?* | bugfix/?*) ;; *) usage_error "--branch must start with feature/ or bugfix/: $BRANCH" ;; esac
    git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || usage_error "--branch is not a valid branch name: $BRANCH"
  fi
  if [ -n "$ROLLBACK_ID" ]; then
    [[ "$ROLLBACK_ID" =~ $STAMP_RE ]] || usage_error "--rollback needs a run stamp like 20261016-101500"
  fi
  # Contradictions.
  if [ -n "$ROLLBACK_ID" ] || [ "$SHOW_KNOWLEDGE" = true ]; then
    [ -z "$ROLLBACK_ID" ] || [ "$SHOW_KNOWLEDGE" = false ] || usage_error "--rollback and --knowledge cannot be combined"
    [ "$ACTION_FLAGS" -eq 0 ] || usage_error "--rollback and --knowledge take no other action options"
  fi
  if [ "$PLAN_ONLY" = true ]; then
    if [ "$TAKE_ALL" = true ] || [ "${#TAKE_KIT[@]}" -gt 0 ] || [ "${#RESOLVED[@]}" -gt 0 ] ||
      [ "${#KEEP_LOCAL[@]}" -gt 0 ] || [ "${#ACCEPT[@]}" -gt 0 ] || [ "${#DECLINE[@]}" -gt 0 ]; then
      usage_error "--plan only previews; give --take-kit, --resolved, --keep-local, --accept and --decline to a real run"
    fi
    if [ "$APPLY_RETIREMENTS" = true ]; then
      note "--apply-retirements is ignored with --plan"
      APPLY_RETIREMENTS=false
    fi
  fi
  for rel in ${TAKE_KIT[@]+"${TAKE_KIT[@]}"}; do
    if in_list "$rel" ${RESOLVED[@]+"${RESOLVED[@]}"} || in_list "$rel" ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"}; then
      usage_error "$rel is named by --take-kit and by --resolved or --keep-local; choose one"
    fi
  done
  for rel in ${RESOLVED[@]+"${RESOLVED[@]}"}; do
    in_list "$rel" ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"} && usage_error "$rel is named by --resolved and by --keep-local; choose one"
  done
  if [ "$SKIP_VERIFY" = true ] && [ "$PROJECT_VERIFY" = true ]; then
    usage_error "--skip-verify and --project-verify contradict each other"
  fi
  if [ "$JSON_OUT" = true ] && [ "$SHOW_KNOWLEDGE" = true ]; then
    usage_error "--knowledge prints text only; drop --json"
  fi
  if [ "${#RESOLVED[@]}" -gt 1 ]; then
    [ "$(printf '%s\n' "${RESOLVED[@]}" | sort | uniq -d | head -n 1)" = "" ] || usage_error "a path is named twice by --resolved"
  fi
  if [ "$APPLY_RETIREMENTS" = true ]; then
    local file retire=""
    for file in "$KIT_DIR"/migrations/*-retire-files.sh; do
      [ -f "$file" ] && retire="$(basename "$file" .sh)"
    done
    if [ -n "$retire" ]; then
      in_list "$retire" ${ACCEPT[@]+"${ACCEPT[@]}"} || ACCEPT+=("$retire")
      note "--apply-retirements means --accept $retire"
    else
      note "--apply-retirements: this kit has no retire-files migration"
    fi
  fi
  for id in ${ACCEPT[@]+"${ACCEPT[@]}"} ${DECLINE[@]+"${DECLINE[@]}"}; do
    case "$id" in */* | .* | "") usage_error "not a migration id: $id" ;; esac
    [ -f "$(migration_file "$id")" ] || usage_error "unknown migration id: $id (see $KIT_DIR/migrations/)"
  done
  for id in ${ACCEPT[@]+"${ACCEPT[@]}"}; do
    in_list "$id" ${DECLINE[@]+"${DECLINE[@]}"} && usage_error "$id is both accepted and declined"
  done
  for id in ${DECLINE[@]+"${DECLINE[@]}"}; do
    [ "$(migration_meta_kind "$id")" != auto ] || usage_error "$id runs automatically; only decisions can be declined"
  done
  return 0
}

# The kind a migration declares, read through the runner (quoted values work).
migration_meta_kind() {
  (
    TARGET_DIR="${TARGET:-$PWD}" STAMP=x JOURNAL_DIR=/nonexistent
    export TARGET_DIR KIT_DIR STAMP JOURNAL_DIR
    _mig_exec "$(migration_file "$1")" meta 2>/dev/null | cut -f3
  ) || true
}

# check_user_path OPTION PATH [file]: a project file, not harness or Git state,
# not a candidate, with no symbolic link below the target.
check_user_path() {
  local option="$1" rel="$2" current part
  local -a parts
  case "$rel" in
    .git | .git/* | .tools | .tools/* | .harness-kit | .harness-kit/*)
      usage_error "$option: $rel is harness or Git state, not a project file" ;;
    *.generated.*) usage_error "$option: name the project file, not its candidate: $rel" ;;
  esac
  current="$TARGET"
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    current="$current/$part"
    [ ! -L "$current" ] || usage_error "$option: $rel goes through a symbolic link"
  done
  if [ "${3:-}" = file ] && [ ! -f "$TARGET/$rel" ]; then
    usage_error "$option: no such regular file in the project: $rel"
  fi
  return 0
}

resolve_target() {
  local rel
  [ -n "$TARGET" ] || TARGET="$(pwd -P)"
  [ -d "$TARGET" ] || fail_early "target is not a directory: $TARGET"
  TARGET="$(cd "$TARGET" && pwd -P)"
  [ "$(git -C "$TARGET" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ] ||
    fail_early "target is not inside a Git work tree: $TARGET (run 'git init' first)"
  is_version "$KIT_VERSION" || fail_early "the kit at $KIT_DIR has no valid VERSION (${KIT_VERSION:-empty})"
  if [ -n "$KIT_VERSION_ARG" ] && [ "$KIT_VERSION_ARG" != "$KIT_VERSION" ]; then
    fail_early "the kit at $KIT_DIR is $KIT_VERSION, expected $KIT_VERSION_ARG; remove that copy and retry"
  fi
  for rel in ${TAKE_KIT[@]+"${TAKE_KIT[@]}"}; do
    check_user_path --take-kit "$rel"
  done
  for rel in ${RESOLVED[@]+"${RESOLVED[@]}"}; do
    check_user_path --resolved "$rel" file
  done
  for rel in ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"}; do
    check_user_path --keep-local "$rel" file
  done
}

# The command that runs this kit again, for next steps (relative to the target).
next_cmd() {
  if [ -f "$TARGET/scripts/harness-kit.sh" ]; then
    printf 'scripts/harness-kit.sh --to %s' "$KIT_VERSION"
  elif [ "$KIT_DIR" = "$TARGET/.harness-kit/v$KIT_VERSION/agent-bootstrap" ]; then
    printf 'bash .harness-kit/v%s/agent-bootstrap/harness-kit-run.sh' "$KIT_VERSION"
  else
    printf 'bash %q --target %q' "$KIT_DIR/harness-kit-run.sh" "$TARGET"
  fi
}

retry_cmd() { # extra args...
  local out arg
  out="$(next_cmd)"
  for arg in "$@" ${RETRY_ARGS[@]+"${RETRY_ARGS[@]}"}; do
    out="$out $(printf '%q' "$arg")"
  done
  printf '%s\n' "$out"
}

ensure_excludes() {
  local prefix exclude entry
  prefix="$(git -C "$TARGET" rev-parse --show-prefix)"
  exclude="$(git -C "$TARGET" rev-parse --git-path info/exclude)"
  case "$exclude" in /*) ;; *) exclude="$TARGET/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  for entry in "/${prefix}.harness-kit/" "/${prefix}.tools/"; do
    grep -qxF -- "$entry" "$exclude" || printf '%s\n' "$entry" >>"$exclude"
  done
}

state_dir_is_safe() {
  local current="$TARGET" part
  for part in .tools agent-state upgrades; do
    current="$current/$part"
    [ ! -L "$current" ] || return 1
  done
  [ ! -L "$TARGET/$STATE_REL/run.lock" ]
}

# One run per project: an exclusive lock directory holding the pid and stamp.
# A pid is alive when kill -0 succeeds or ps still lists it (kill -0 fails
# with EPERM for another user's live process).
pid_alive() {
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

acquire_lock() {
  local pid stamp stale
  LOCK_DIR="$TARGET/$STATE_REL/run.lock"
  mkdir -p "$TARGET/$STATE_REL"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    stamp="$(sed -n '1p' "$LOCK_DIR/stamp" 2>/dev/null || true)"
    if [ -n "$pid" ] && pid_alive "$pid"; then
      fail_early "another harness-kit run (pid $pid${stamp:+, stamp $stamp}) holds ${LOCK_DIR#"$TARGET"/}; wait for it to finish, or remove that directory if the process is gone"
    fi
    if [ -z "$pid" ] && [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      fail_early "another harness-kit run is starting (${LOCK_DIR#"$TARGET"/} was just created); retry in a minute"
    fi
    # Take over atomically: only one rename of the stale lock wins.
    stale="$LOCK_DIR.stale.$$"
    mv "$LOCK_DIR" "$stale" 2>/dev/null ||
      fail_early "another harness-kit run is taking over ${LOCK_DIR#"$TARGET"/}; retry in a minute"
    mkdir "$LOCK_DIR" 2>/dev/null || {
      rm -rf "$stale"
      fail_early "another harness-kit run took ${LOCK_DIR#"$TARGET"/}; retry when it ends"
    }
    rm -rf "$stale"
    note "taking over a stale run lock (pid ${pid:-unknown} is gone)"
  fi
  LOCK_HELD=true
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

# Removes the lock only while it is still ours.
release_lock() {
  if [ "$LOCK_HELD" = true ]; then
    if [ "$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$LOCK_DIR"
    fi
    LOCK_HELD=false
  fi
  return 0
}

new_run_dir() {
  local tries=0
  mkdir -p "$TARGET/$STATE_REL/upgrades"
  while :; do
    STAMP="$(py stamp "$TARGET")"
    RUN_DIR="$TARGET/$STATE_REL/upgrades/$STAMP"
    mkdir "$RUN_DIR" 2>/dev/null && break
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || fail_early "could not create a run directory under $STATE_REL/upgrades"
  done
  printf '%s\n' "$STAMP" >"$LOCK_DIR/stamp"
}

current_branch() { git -C "$TARGET" symbolic-ref -q --short HEAD 2>/dev/null || true; }

# Default branches of every remote (refs/remotes/<remote>/HEAD).
remote_default_branches() {
  local ref target remote
  git -C "$TARGET" for-each-ref --format='%(refname) %(symref)' 'refs/remotes/' 2>/dev/null |
    while read -r ref target; do
      case "$ref" in refs/remotes/*/HEAD) ;; *) continue ;; esac
      [ -n "$target" ] || continue
      remote="${ref#refs/remotes/}"
      remote="${remote%/HEAD}"
      printf '%s\n' "${target#refs/remotes/"$remote"/}"
    done
}

branch_is_protected() {
  local branch="$1"
  [ -n "$branch" ] || return 1
  case " $PROTECTED_BRANCHES " in *" $branch "*) return 0 ;; esac
  # No grep -q: an early exit would fail the pipeline under pipefail.
  remote_default_branches | grep -Fx -- "$branch" >/dev/null
}

# The branch this run writes on: --branch, else the current one (empty when detached).
write_branch() {
  if [ -n "$BRANCH" ]; then
    printf '%s\n' "$BRANCH"
  else
    current_branch
  fi
}

gitignore_tracked() { gitp ls-files --error-unmatch -- .gitignore >/dev/null 2>&1; }

load_migration_meta() {
  MIG_META="$(
    TARGET_DIR="$TARGET"
    JOURNAL_DIR="$RUN_DIR/journal"
    export TARGET_DIR KIT_DIR STAMP JOURNAL_DIR
    _mig_rows 2>/dev/null | cut -f3,5
  )" || MIG_META=""
}

migration_kind() { printf '%s\n' "$MIG_META" | awk -F '\t' -v id="$1" '$1 == id { print $2; exit }'; }

# Accepted decisions that would change tracked files or the index. Any kind
# other than auto counts, unless the decision is known to touch neither.
decision_needs_branch() {
  local kind
  kind="$(migration_kind "$1")"
  [ "$kind" != auto ] || return 1
  if [ "$kind" = decision ]; then
    case "$1" in
      *-retire-files) return 1 ;; # deletes only ignored harness files
      *-ignore-block-to-exclude)
        gitignore_tracked || return 1
        # Only the kit block is uncommitted: moving it only cleans the work tree.
        if py gitignore-block-only "$TARGET"; then
          return 1
        fi
        return 0
        ;;
    esac
  fi
  return 0
}

phase_set() { # name status seconds
  printf -v "PH_$1" '%s' "$2"
  printf -v "PT_$1" '%s' "$3"
}

start_phase() {
  CURRENT_PHASE="$1"
  PHASE_T0=$SECONDS
}

refuse() { # phase message
  REASON="$2"
  phase_set "$1" refused "$((SECONDS - PHASE_T0))"
  finish
}

fail_phase() { # phase message
  REASON="$2"
  phase_set "$1" failed "$((SECONDS - PHASE_T0))"
  finish
}

# Internal test hook: with HARNESS_KIT_TEST_HOOKS=1, HARNESS_KIT_TEST_FAIL=
# <phase>[:INT] fails (or interrupts) the run at the end of that phase, to
# exercise the failure report. Without HARNESS_KIT_TEST_HOOKS=1 it does nothing.
TEST_HOOK_FIRED=false
test_hook() {
  [ "${HARNESS_KIT_TEST_HOOKS:-}" = 1 ] || return 0
  case "${HARNESS_KIT_TEST_FAIL:-}" in
    "$1")
      TEST_HOOK_FIRED=true
      false
      ;;
    "$1:INT") kill -INT "$$" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- preflight

begin_run() {
  state_dir_is_safe || fail_early "refusing a linked .tools/agent-state path in $TARGET"
  ensure_excludes
  acquire_lock
  new_run_dir
  : >"$RUN_DIR/next.txt"
  : >"$RUN_DIR/notes.txt"
  [ "${#NOTES[@]}" -eq 0 ] || printf '%s\n' "${NOTES[@]}" >>"$RUN_DIR/notes.txt"
  RUN_STARTED=true
}

preflight() {
  local lock_state lock_version lock_workflow
  start_phase preflight
  IFS='|' read -r lock_state lock_version lock_workflow <<<"$(py lock "$TARGET")"
  FROM=""
  case "$lock_state" in
    absent) MODE=install ;;
    present | invalid)
      FROM="$lock_version"
      if [ "$lock_state" = invalid ] || ! is_version "$FROM"; then
        MODE=unknown
      elif [ "$(_mig_key "$FROM")" = "$(_mig_key "$KIT_VERSION")" ]; then
        MODE=reinstall
      elif [[ "$(_mig_key "$FROM")" < "$(_mig_key "$KIT_VERSION")" ]]; then
        MODE=update
      else
        MODE=downgrade
      fi
      ;;
    *) MODE=unknown ;; # the lock could not be read at all: never run as an update
  esac
  # Generation does not read the lock's preset, so it is always passed.
  [ -n "$WORKFLOW" ] || WORKFLOW="${lock_workflow:-full}"
  print_mode_line
  if [ "$MODE" = unknown ]; then
    refuse preflight "the installed lock docs/agent-configs/agent-bootstrap.lock.json has no valid kit version (${FROM:-none}); restore it from Git or a backup, or remove it to install afresh"
  fi
  if [ "$MODE" = downgrade ]; then
    local journal
    journal="$(py latest-journal "$TARGET")"
    if [ -n "$journal" ]; then
      printf '%s --rollback %s\n' "$(next_cmd)" "$journal" >>"$RUN_DIR/next.txt"
    fi
    refuse preflight "installed kit $FROM is newer than $KIT_VERSION; run the newer kit (scripts/harness-kit.sh) or undo its last update with --rollback${journal:+ $journal}"
  fi
  if [ -n "$BRANCH" ] && [ "$PLAN_ONLY" = true ]; then
    printf -- '--plan does not switch branches; --branch %s is checked only\n' "$BRANCH" >>"$RUN_DIR/notes.txt"
  fi
  load_migration_meta
  gate_check request
  test_hook preflight
  phase_set preflight ok "$((SECONDS - PHASE_T0))"
}

print_mode_line() {
  local line
  case "$MODE" in
    install) line="mode: install $KIT_VERSION" ;;
    reinstall) line="mode: reinstall $KIT_VERSION" ;;
    update) line="mode: update $FROM -> $KIT_VERSION" ;;
    downgrade) line="mode: refused (installed $FROM is newer than kit $KIT_VERSION)" ;;
    *) line="mode: refused (installed lock version '${FROM:-none}' is not a kit version)" ;;
  esac
  [ "$PLAN_ONLY" = false ] || line="$line (plan only)"
  if [ "$JSON_OUT" = true ]; then
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
}

# gate_check request|plan: tracked files and index changes of this run (A2,
# A3). `request` covers what the options ask for (before stage), `plan` the
# files the staged plan writes. A run that would write a tracked file with
# uncommitted changes, or change tracked files or the index on a protected or
# detached branch, is refused (a --plan records it and ends needs review).
gate_check() {
  local check="$1" writes=() tracked=() dirty="" why="" rel id status_out branch refusal="" hint=""
  if [ "$check" = plan ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] && writes+=("$rel")
    done < <(
      py writes "$RUN_DIR/plan.json" "$RESET"
      [ "$TAKE_ALL" = false ] || py conflicts "$RUN_DIR/plan.json"
    )
  else
    for rel in ${TAKE_KIT[@]+"${TAKE_KIT[@]}"}; do
      py user-filled "$TARGET" "$rel" || writes+=("$rel")
    done
  fi
  if [ "${#writes[@]}" -gt 0 ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] && tracked+=("$rel")
    done < <(gitp ls-files -- "${writes[@]}" 2>/dev/null || true)
  fi
  [ "${#tracked[@]}" -eq 0 ] || why="it writes ${#tracked[@]} tracked file(s), e.g. ${tracked[0]}"
  if [ "$check" = request ]; then
    if [ "$IGNORE_TARGET" = gitignore ] && ! grep -Fq '# >>> multi-agent bootstrap local state >>>' "$TARGET/.gitignore" 2>/dev/null; then
      why="${why:+$why; }--ignore-target gitignore writes .gitignore"
      gitignore_tracked && tracked+=(.gitignore)
    fi
    for id in ${ACCEPT[@]+"${ACCEPT[@]}"}; do
      if decision_needs_branch "$id"; then
        why="${why:+$why; }--accept $id changes tracked files or the index"
        case "$id" in *-ignore-block-to-exclude) tracked+=(.gitignore) ;; esac
      fi
    done
  fi
  if [ "${#tracked[@]}" -gt 0 ]; then
    status_out="$(gitp status --porcelain --untracked-files=no -- "${tracked[@]}" 2>/dev/null || true)"
    [ -z "$status_out" ] || dirty="$(printf '%s\n' "$status_out" | head -n 5 | cut -c4- | paste -sd, - | sed 's/,/, /g')"
  fi
  branch="$(write_branch)"
  if [ -n "$dirty" ]; then
    refusal="tracked files this run would write have uncommitted changes: $dirty; commit or stash them first"
  elif [ -n "$why" ] && [ -z "$branch" ]; then
    refusal="HEAD is detached and this run would change tracked files or the index ($why); rerun with --branch feature/<name>"
    hint="$(branch_hint)"
  elif [ -n "$why" ] && branch_is_protected "$branch"; then
    refusal="$branch is protected and this run would change tracked files or the index ($why); rerun with --branch feature/<name>"
    hint="$(branch_hint)"
  fi
  [ -n "$refusal" ] || return 0
  if [ "$PLAN_ONLY" = true ]; then
    if [ -z "$WOULD_REFUSE" ]; then
      WOULD_REFUSE="$refusal"
      [ -z "$hint" ] || printf '%s\n' "${hint/ --plan/}" >>"$RUN_DIR/next.txt"
    fi
    return 0
  fi
  [ -z "$hint" ] || printf '%s\n' "$hint" >>"$RUN_DIR/next.txt"
  refuse preflight "$refusal"
}

# The retry command with a work branch; when the suggested branch already
# exists at another commit, the command switches to it first (a --branch
# rerun would be refused there).
branch_hint() {
  local head other
  if git -C "$TARGET" show-ref --verify --quiet "refs/heads/$WORK_BRANCH_HINT"; then
    head="$(git -C "$TARGET" rev-parse -q --verify HEAD 2>/dev/null || true)"
    other="$(git -C "$TARGET" rev-parse -q --verify "refs/heads/$WORK_BRANCH_HINT" 2>/dev/null || true)"
    if [ "$head" != "$other" ]; then
      # It exists at another commit: switch to it first, then rerun there.
      printf 'git switch %s && %s\n' "$WORK_BRANCH_HINT" "$(retry_cmd)"
      return 0
    fi
  fi
  retry_cmd --branch "$WORK_BRANCH_HINT"
}

# Creates or switches to --branch right before apply (after every refusal check).
switch_branch() {
  local head target_commit
  [ -n "$BRANCH" ] && [ "$(current_branch)" != "$BRANCH" ] || return 0
  if git -C "$TARGET" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    head="$(git -C "$TARGET" rev-parse -q --verify HEAD 2>/dev/null || true)"
    target_commit="$(git -C "$TARGET" rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null || true)"
    if [ "$head" != "$target_commit" ]; then
      refuse preflight "branch $BRANCH exists at another commit; switch to it first (git switch $BRANCH) and rerun without --branch"
    fi
    git -C "$TARGET" checkout -q "$BRANCH" >>"$RUN_DIR/preflight.log" 2>&1 ||
      refuse preflight "could not switch to $BRANCH (see ${RUN_DIR#"$TARGET"/}/preflight.log)"
  else
    git -C "$TARGET" checkout -q -b "$BRANCH" >>"$RUN_DIR/preflight.log" 2>&1 ||
      refuse preflight "could not create $BRANCH (see ${RUN_DIR#"$TARGET"/}/preflight.log)"
  fi
}

# -------------------------------------------------------------------- stage

stage() {
  local state rel gen_args=()
  start_phase stage
  : >"$RUN_DIR/pins.txt"
  : >"$RUN_DIR/stale-pins.txt"
  : >"$RUN_DIR/cleared.txt"
  KEEPS=()
  if [ "$RESET" = true ]; then
    # The kit wins: recorded resolutions and pins are cleared after apply.
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      in_list "$rel" ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"} ${RESOLVED[@]+"${RESOLVED[@]}"} ${TAKE_KIT[@]+"${TAKE_KIT[@]}"} && continue
      printf '%s\n' "$rel" >>"$RUN_DIR/cleared.txt"
    done < <(py resolutions "$TARGET")
  else
    while IFS=$'\t' read -r state rel; do
      [ -n "$rel" ] || continue
      in_list "$rel" ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"} ${TAKE_KIT[@]+"${TAKE_KIT[@]}"} && continue
      if [ "$state" = active ]; then
        KEEPS+=("$rel")
        printf '%s\n' "$rel" >>"$RUN_DIR/pins.txt"
      else
        printf '%s\n' "$rel" >>"$RUN_DIR/stale-pins.txt"
      fi
    done < <(py pins "$TARGET")
  fi
  for rel in ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"}; do
    KEEPS+=("$rel")
    printf '%s\n' "$rel" >>"$RUN_DIR/pins.txt"
  done
  # --resolved keeps the local file as it is in this run too.
  for rel in ${RESOLVED[@]+"${RESOLVED[@]}"}; do
    KEEPS+=("$rel")
  done
  gen_args=(--target "$TARGET" --upgrade-plan --json --workflow "$WORKFLOW")
  for rel in ${KEEPS[@]+"${KEEPS[@]}"}; do
    gen_args+=(--keep "$rel")
  done
  if ! bash "$GENERATOR" "${gen_args[@]}" >"$RUN_DIR/plan.json" 2>"$RUN_DIR/stage.log"; then
    fail_phase stage "the upgrade plan failed (see ${RUN_DIR#"$TARGET"/}/stage.log)"
  fi
  if [ "$RESET" = true ]; then
    # --force must never replace a link or an unsafe entry (A5).
    while IFS= read -r rel; do
      [ -n "$rel" ] && KEEPS+=("$rel")
    done < <(py unsafe "$RUN_DIR/plan.json")
  fi
  test_hook stage
  phase_set stage ok "$((SECONDS - PHASE_T0))"
}

kit_source() {
  case "$KIT_DIR" in
    "$TARGET"/*) printf '%s\n' "${KIT_DIR#"$TARGET"/}" ;;
    *) printf '%s\n' "$KIT_DIR" ;;
  esac
}

# -------------------------------------------------------------------- apply

newest_candidate() {
  local file best="" suffix
  for file in "$TARGET/$1".generated.*; do
    { [ -f "$file" ] && [ ! -L "$file" ]; } || continue
    suffix="${file##*.generated.}"
    [[ "$suffix" =~ $STAMP_RE ]] || continue
    if [ -z "$best" ] || [[ "$file" > "$best" ]]; then
      best="$file"
    fi
  done
  printf '%s' "$best"
}

# drop_candidates PATH [KEEP_STAMP]: moves the candidates of PATH (except the
# one of KEEP_STAMP) out of the project into the run directory.
drop_candidates() {
  local file dest
  for file in "$TARGET/$1".generated.*; do
    { [ -f "$file" ] && [ ! -L "$file" ]; } || continue
    [[ "${file##*.generated.}" =~ $STAMP_RE ]] || continue # never x.generated.example
    [ -z "${2:-}" ] || [ "$file" != "$TARGET/$1.generated.$2" ] || continue
    dest="$RUN_DIR/dropped-candidates/${file#"$TARGET"/}"
    mkdir -p "$(dirname "$dest")"
    mv "$file" "$dest"
  done
}

record_baseline() { # rel source
  local rel="$1" source="$2" base current part
  local -a parts
  base="$TARGET/$BASELINE_REL/$rel"
  current="$TARGET"
  IFS=/ read -r -a parts <<<"$BASELINE_REL/$rel"
  for part in "${parts[@]}"; do
    current="$current/$part"
    [ ! -L "$current" ] || return 1
  done
  if [ -f "$base" ]; then
    mkdir -p "$(dirname "$RUN_DIR/baseline-pre/$rel")"
    cp -p "$base" "$RUN_DIR/baseline-pre/$rel"
  fi
  mkdir -p "$(dirname "$base")"
  cp "$source" "$base.tmp.$$" && mv "$base.tmp.$$" "$base"
}

# --take-kit: promote this run's kit output (the candidate of this stamp, or
# the generator's staged output for a file without one) in one guarded call.
take_kit_step() {
  local rel cand new copied list=() only=()
  : >"$RUN_DIR/take-kit.tsv"
  if [ "$TAKE_ALL" = true ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] && list+=("$rel")
    done < <(py conflicts "$RUN_DIR/apply-plan.tsv")
  fi
  for rel in ${TAKE_KIT[@]+"${TAKE_KIT[@]}"}; do
    in_list "$rel" ${list[@]+"${list[@]}"} || list+=("$rel")
  done
  for rel in ${list[@]+"${list[@]}"}; do
    cand="$TARGET/$rel.generated.$STAMP"
    new="$RUN_DIR/apply-plan.tsv.new/$rel"
    copied=no
    if py user-filled "$TARGET" "$rel"; then
      printf -- '--take-kit %s: a filled project-owned file is never replaced by the kit; nothing to take\n' \
        "$rel" >>"$RUN_DIR/notes.txt"
      drop_candidates "$rel"
      continue
    fi
    if [ ! -f "$cand" ]; then
      if [ -f "$new" ] && [ -f "$TARGET/$rel" ] && ! cmp -s "$new" "$TARGET/$rel"; then
        cp "$new" "$cand"
        copied=yes
      else
        printf -- '--take-kit %s: the file already matches the kit output (or the kit does not write it); nothing to take\n' \
          "$rel" >>"$RUN_DIR/notes.txt"
        continue
      fi
    fi
    drop_candidates "$rel" "$STAMP"
    only+=(--only "$rel")
    printf '%s\t%s\t%s\n' "$rel" "$cand" "$copied" >>"$RUN_DIR/take-kit.tsv"
  done
  [ "${#only[@]}" -gt 0 ] || return 0
  if ! AGENT_BOOTSTRAP_STAMP="$STAMP" bash "$GENERATOR" --target "$TARGET" --apply-candidates "${only[@]}" \
    >>"$RUN_DIR/apply.log" 2>&1; then
    fail_phase apply "--take-kit failed (see ${RUN_DIR#"$TARGET"/}/apply.log)"
  fi
  while IFS=$'\t' read -r rel cand copied; do
    [ -n "$rel" ] || continue
    if [ -e "$cand" ]; then
      [ "$copied" != yes ] || rm -f "$cand" # never leave a candidate this run made up
      printf -- '--take-kit %s: the generator did not replace it (see %s)\n' "$rel" "${RUN_DIR#"$TARGET"/}/apply.log" >>"$RUN_DIR/notes.txt"
    else
      printf '%s\n' "$rel" >>"$RUN_DIR/taken.txt"
    fi
  done <"$RUN_DIR/take-kit.tsv"
}

apply_phase() {
  local args=() rel i src reason
  start_phase apply
  APPLY_STARTED=true
  : >"$RUN_DIR/reset-preserved.txt"
  : >"$RUN_DIR/resolved.txt"
  : >"$RUN_DIR/taken.txt"
  args=(--target "$TARGET" --workflow "$WORKFLOW")
  [ -z "$IGNORE_TARGET" ] || args+=(--ignore-target "$IGNORE_TARGET")
  for rel in ${KEEPS[@]+"${KEEPS[@]}"}; do
    args+=(--keep "$rel")
  done
  if [ "$RESET" = true ]; then
    # Saved before anything changes: --rollback of this run puts them back.
    local -a saved=()
    while IFS= read -r rel; do
      [ -n "$rel" ] && saved+=("$rel")
    done <"$RUN_DIR/cleared.txt"
    py save-entries "$TARGET" "$RUN_DIR/cleared-knowledge.json" ${saved[@]+"${saved[@]}"}
    args+=(--force)
    for rel in $USER_OWNED_RELS; do
      if [ -e "$TARGET/$rel" ]; then
        args+=(--keep "$rel")
        printf '%s\n' "$rel" >>"$RUN_DIR/reset-preserved.txt"
      fi
    done
  fi
  if ! AGENT_BOOTSTRAP_PLAN_LOG="$RUN_DIR/apply-plan.tsv" AGENT_BOOTSTRAP_STAMP="$STAMP" \
    bash "$GENERATOR" "${args[@]}" >"$RUN_DIR/apply.log" 2>&1; then
    capture_rollback_ref
    fail_phase apply "generation failed (see ${RUN_DIR#"$TARGET"/}/apply.log)"
  fi
  take_kit_step
  capture_rollback_ref

  # Knowledge follows the files as they are now (the first knowledge write).
  py knowplan "$RUN_DIR/plan.json" "$RUN_DIR/post-apply.json" post
  know refresh --plan-json "$RUN_DIR/post-apply.json" --kit-version "$KIT_VERSION" --kit-source "$(kit_source)" \
    >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "project knowledge could not be updated (see ${RUN_DIR#"$TARGET"/}/apply.log)"
  if [ -s "$RUN_DIR/cleared.txt" ]; then
    local -a cleared=()
    while IFS= read -r rel; do
      [ -n "$rel" ] && cleared+=("$rel")
    done <"$RUN_DIR/cleared.txt"
    know clear -- "${cleared[@]}" >>"$RUN_DIR/apply.log" 2>&1 ||
      fail_phase apply "could not clear the recorded resolutions (see ${RUN_DIR#"$TARGET"/}/apply.log)"
    printf -- '--reset cleared %s recorded resolution(s) and pin(s)\n' "$(grep -c . "$RUN_DIR/cleared.txt")" >>"$RUN_DIR/notes.txt"
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    know resolve "$rel" --kind take-kit >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "could not record --take-kit $rel"
  done <"$RUN_DIR/taken.txt"
  i=0
  while [ "$i" -lt "${#RESOLVED[@]}" ]; do
    rel="${RESOLVED[$i]}"
    reason="${REASONS[$i]}"
    i=$((i + 1))
    # The kit output of this run (staged by the generator), else its candidate.
    src="$RUN_DIR/apply-plan.tsv.new/$rel"
    [ -f "$src" ] && [ ! -L "$src" ] || src="$(newest_candidate "$rel")"
    if [ -n "$src" ]; then
      record_baseline "$rel" "$src" || fail_phase apply "refusing a linked harness baseline path for $rel"
    fi
    drop_candidates "$rel"
    if [ -n "$reason" ]; then
      know resolve "$rel" --kind resolved --reason "$reason" >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "could not record --resolved $rel"
    else
      know resolve "$rel" --kind resolved >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "could not record --resolved $rel"
    fi
    printf '%s\n' "$rel" >>"$RUN_DIR/resolved.txt"
  done
  for rel in ${KEEP_LOCAL[@]+"${KEEP_LOCAL[@]}"}; do
    drop_candidates "$rel"
    know resolve "$rel" --kind keep-local >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "could not record --keep-local $rel"
  done
  if [ -n "$IGNORE_TARGET" ]; then
    know ignore-target "$IGNORE_TARGET" >>"$RUN_DIR/apply.log" 2>&1 || fail_phase apply "could not record the ignore target"
  fi
  rm -rf "$RUN_DIR/apply-plan.tsv.new"
  test_hook apply
  phase_set apply ok "$((SECONDS - PHASE_T0))"
}

capture_rollback_ref() {
  local id
  id="$(sed -n 's/.*Upgrade id: \([0-9]\{8\}-[0-9]\{6\}\).*/\1/p' "$RUN_DIR/apply.log" 2>/dev/null | tail -n 1)"
  [ -z "$id" ] || ROLLBACK_REF="$id"
}

# ------------------------------------------------------------------ migrate

migrate_phase() {
  local to="$KIT_VERSION" file rc=0 id state sha
  start_phase migrate
  for file in "$KIT_DIR"/migrations/next-*.sh; do
    [ -f "$file" ] && to=next
  done
  # An explicit --accept overrides an earlier --decline: ask again.
  for id in ${ACCEPT[@]+"${ACCEPT[@]}"}; do
    IFS=$'\t' read -r state sha <<<"$(py migration-state "$TARGET" "$id")"
    if [ "$state" = declined ]; then
      know decision "$id" --status pending --facts-sha256 "$sha" >>"$RUN_DIR/migrate.log" 2>&1 ||
        fail_phase migrate "could not reopen the declined decision $id"
    fi
  done
  (
    TARGET_DIR="$TARGET"
    JOURNAL_DIR="$RUN_DIR/journal"
    export TARGET_DIR KIT_DIR STAMP JOURNAL_DIR
    migrations_run "$FROM" "$to" "$MODE" "${ACCEPT[*]-}" "${DECLINE[*]-}"
  ) >>"$RUN_DIR/migrate.log" 2>&1 || rc=$?
  if [ -f "$RUN_DIR/journal/migrations/results.tsv" ]; then
    cp "$RUN_DIR/journal/migrations/results.tsv" "$RUN_DIR/migrations.tsv"
  else
    : >"$RUN_DIR/migrations.tsv"
  fi
  for id in ${ACCEPT[@]+"${ACCEPT[@]}"} ${DECLINE[@]+"${DECLINE[@]}"}; do
    cut -f1 "$RUN_DIR/migrations.tsv" | grep -Fxq -- "$id" ||
      printf '%s: not needed in this project; nothing to do\n' "$id" >>"$RUN_DIR/notes.txt"
  done
  if [ "$rc" -ne 0 ]; then
    fail_phase migrate "a migration failed (see ${RUN_DIR#"$TARGET"/}/migrate.log)"
  fi
  test_hook migrate
  if cut -f2 "$RUN_DIR/migrations.tsv" | grep -Fxq pending; then
    phase_set migrate "needs review" "$((SECONDS - PHASE_T0))"
  else
    phase_set migrate ok "$((SECONDS - PHASE_T0))"
  fi
}

# ------------------------------------------------------------------- verify

run_check() { # name script args...
  local name="$1" script="$2" log status=fail
  shift 2
  log="$RUN_DIR/verify-$name.log"
  if [ -f "$TARGET/$script" ] && (cd "$TARGET" && bash "$script" "$@") >"$log" 2>&1; then
    status=pass
  fi
  printf '%s\t%s\t%s\n' "$script${*:+ $*}" "$status" "${log#"$TARGET"/}" >>"$RUN_DIR/verify.tsv"
  [ "$status" = pass ]
}

verify_phase() {
  local failed=0
  start_phase verify
  : >"$RUN_DIR/verify.tsv"
  run_check doctor scripts/agent-hook.sh doctor || failed=1
  run_check preflight scripts/agent-guard.sh preflight || failed=1
  # doctor already runs verify-ai-deps when the generated hook calls it.
  if ! grep -q 'verify-ai-deps' "$TARGET/scripts/agent-hook.sh" 2>/dev/null; then
    run_check verify-ai-deps scripts/verify-ai-deps.sh --json || failed=1
  fi
  if [ "$PROJECT_VERIFY" = true ]; then
    run_check pre-final scripts/agent-guard.sh pre-final --run-verify --verify-scope fast || failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    fail_phase verify "a harness check failed"
  fi
  test_hook verify
  phase_set verify ok "$((SECONDS - PHASE_T0))"
}

# ------------------------------------------------------------------- report

branch_ids() {
  local file id out=""
  for file in "$KIT_DIR"/migrations/*.sh; do
    [ -f "$file" ] || continue
    id="$(basename "$file" .sh)"
    decision_needs_branch "$id" && out="$out $id"
  done
  printf '%s\n' "$out"
}

prune_kit_copies() {
  local root="$TARGET/.harness-kit" dir version key current_key previous="" previous_key=""
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  current_key="$(_mig_key "$KIT_VERSION")"
  if is_version "$FROM" && [ "$FROM" != "$KIT_VERSION" ] && [ -d "$root/v$FROM" ] && [[ "$(_mig_key "$FROM")" < "$current_key" ]]; then
    previous="$FROM"
  else
    for dir in "$root"/v*; do
      { [ -d "$dir" ] && [ ! -L "$dir" ]; } || continue
      version="${dir##*/v}"
      is_version "$version" || continue
      key="$(_mig_key "$version")"
      if [[ "$key" < "$current_key" ]] && { [ -z "$previous_key" ] || [[ "$key" > "$previous_key" ]]; }; then
        previous="$version"
        previous_key="$key"
      fi
    done
  fi
  for dir in "$root"/v*; do
    { [ -d "$dir" ] && [ ! -L "$dir" ]; } || continue
    version="${dir##*/v}"
    is_version "$version" || continue # never a copy whose name does not parse
    { [ "$version" != "$KIT_VERSION" ] && [ "$version" != "$previous" ]; } || continue
    [[ "$(_mig_key "$version")" < "$current_key" ]] || continue # never newer copies
    rm -rf "$dir"
  done
}

RUN_KEEP=10

phase_log() {
  local file="$RUN_DIR/$1.log"
  [ "$1" != verify ] || return 0
  [ -f "$file" ] && printf '%s\n' "${file#"$TARGET"/}"
  return 0
}

# Writes report.json and summary.txt; sets RESULT.
write_report() {
  local protected=false name status_var time_var branch
  {
    for name in preflight stage apply migrate verify; do
      status_var="PH_$name"
      time_var="PT_$name"
      printf '%s\t%s\t%s\t%s\n' "$name" "${!status_var}" "${!time_var}" "$(phase_log "$name")"
    done
    printf 'report\tok\t0\t\n'
  } >"$RUN_DIR/phases.tsv"
  branch="$(write_branch)"
  if [ -z "$branch" ] || branch_is_protected "$branch"; then
    protected=true
  fi
  RESULT="$(R_TARGET="$TARGET" R_CMD="$(next_cmd)" R_STAMP="$STAMP" R_MODE="$MODE" R_FROM="$FROM" \
    R_TO="$KIT_VERSION" R_PLAN_ONLY="$PLAN_ONLY" R_SKIP_VERIFY="$SKIP_VERIFY" R_REASON="$REASON" \
    R_WOULD_REFUSE="$WOULD_REFUSE" R_APPLIED="$APPLY_STARTED" \
    R_BRANCH_IDS="$(branch_ids)" R_PROTECTED="$protected" R_WORK_BRANCH="$WORK_BRANCH_HINT" \
    R_ROLLBACK_ID="$ROLLBACK_REF" py report "$RUN_DIR")"
}

show_summary() {
  if [ "$JSON_OUT" = true ]; then
    cat "$RUN_DIR/report.json"
  else
    cat "$RUN_DIR/summary.txt"
  fi
}

finish() {
  local rc
  if ! write_report; then
    FINISHED=true
    err "could not write the report in ${RUN_DIR#"$TARGET"/}"
    exit 1
  fi
  FINISHED=true
  show_summary
  if [ "$APPLY_STARTED" = true ]; then
    know record-run --stamp "$STAMP" --mode "$MODE" --from "$FROM" --to "$KIT_VERSION" --result "$RESULT" \
      >>"$RUN_DIR/report.log" 2>&1 || err "could not record the run in project knowledge (see ${RUN_DIR#"$TARGET"/}/report.log)"
    if [ "$RESULT" != failed ]; then
      prune_kit_copies >>"$RUN_DIR/report.log" 2>&1 || true
    fi
  fi
  py prune-runs "$TARGET" "$STAMP" "$RUN_KEEP" >>"$RUN_DIR/report.log" 2>&1 || true
  case "$RESULT" in
    done) rc=0 ;;
    "needs review") rc=3 ;;
    *) rc=1 ;;
  esac
  exit "$rc"
}

# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
# EXIT trap: an unexpected failure or an interrupt after the run started still
# writes report.json (result failed) with the failing phase and the undo command.
on_exit() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM # a second Ctrl-C must not skip the report or release_lock
  if [ "$RUN_STARTED" = true ] && [ "$FINISHED" = false ]; then
    FINISHED=true
    if [ -n "$INTERRUPTED" ]; then
      REASON="interrupted ($INTERRUPTED) during $CURRENT_PHASE"
      rc=1
      [ "$INTERRUPTED" != INT ] || rc=130
    elif [ "$TEST_HOOK_FIRED" = true ]; then
      REASON="test hook failure during $CURRENT_PHASE"
      rc=1
    else
      REASON="unexpected failure (exit $rc) during $CURRENT_PHASE"
      rc=1
    fi
    phase_set "$CURRENT_PHASE" failed "$((SECONDS - PHASE_T0))"
    if write_report 2>>"$RUN_DIR/report.log"; then
      show_summary || true
      if [ "$APPLY_STARTED" = true ]; then
        know record-run --stamp "$STAMP" --mode "$MODE" --from "$FROM" --to "$KIT_VERSION" --result failed \
          >>"$RUN_DIR/report.log" 2>&1 || true
      fi
    else
      err "$REASON; the report could not be written (see ${RUN_DIR#"$TARGET"/}/report.log)"
    fi
  fi
  release_lock
  exit "$rc"
}

# --------------------------------------------------------------------- main

do_rollback() {
  local id="$ROLLBACK_ID" mapped rc=0 dir log line
  line="mode: rollback $ROLLBACK_ID"
  if [ "$JSON_OUT" = true ]; then printf '%s\n' "$line" >&2; else printf '%s\n' "$line"; fi
  state_dir_is_safe || fail_early "refusing a linked .tools/agent-state path in $TARGET"
  acquire_lock
  dir="$TARGET/$STATE_REL/upgrades/$ROLLBACK_ID"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    fail_early "refusing an unsafe run directory: ${dir#"$TARGET"/}"
  fi
  mkdir -p "$dir"
  log="$dir/rollback.log"
  [ ! -L "$log" ] || fail_early "refusing a linked rollback log: ${log#"$TARGET"/}"
  printf '== rollback %s at %s\n' "$ROLLBACK_ID" "$(date +%Y%m%d-%H%M%S)" >>"$log"
  mapped="$(py rollback-id "$TARGET" "$ROLLBACK_ID")"
  [ -z "$mapped" ] || id="$mapped"
  bash "$GENERATOR" --target "$TARGET" --rollback "$id" >>"$log" 2>&1 || rc=$?
  # Knowledge follows the restored files (hashes only; nothing is generated),
  # under the version of the restored lock; resolutions a --reset cleared return.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    printf 'note: the rollback failed; project knowledge was left as it was\n' >>"$log"
  elif [ ! -f "$dir/plan.json" ]; then
    printf 'note: the run directory of %s is gone; project knowledge refreshes on the next run\n' "$ROLLBACK_ID" | tee -a "$log" >&2
  else
    local lock_state lock_version lock_workflow
    IFS='|' read -r lock_state lock_version lock_workflow <<<"$(py lock "$TARGET")"
    { py knowplan "$dir/plan.json" "$dir/rollback-knowledge.json" post &&
      know refresh --plan-json "$dir/rollback-knowledge.json" --kit-version "${lock_version:-$KIT_VERSION}" --kit-source "$(kit_source)" &&
      { [ ! -f "$dir/cleared-knowledge.json" ] || know restore --entries "$dir/cleared-knowledge.json"; }; } \
      >>"$log" 2>&1 || printf 'warn: project knowledge was not refreshed\n' >>"$log"
  fi
  py rollback-summary "$log" "$rc" "$JSON_OUT" "$ROLLBACK_ID" "$id" "${log#"$TARGET"/}"
  release_lock
  case "$rc" in
    0) exit 0 ;;
    3) exit 3 ;;
    *) exit 1 ;;
  esac
}

main() {
  parse_args "$@"
  resolve_target
  trap on_exit EXIT
  trap 'INTERRUPTED=INT; exit 130' INT
  trap 'INTERRUPTED=TERM; exit 1' TERM
  if [ -n "$ROLLBACK_ID" ]; then
    do_rollback
  fi
  if [ "$SHOW_KNOWLEDGE" = true ]; then
    know summary
    exit $?
  fi
  begin_run
  preflight
  stage
  start_phase preflight
  gate_check plan
  PT_preflight=$((PT_preflight + SECONDS - PHASE_T0))
  if [ "$PLAN_ONLY" = true ]; then
    finish
  fi
  switch_branch
  apply_phase
  migrate_phase
  if [ "$SKIP_VERIFY" = true ]; then
    printf 'verify skipped (--skip-verify)\n' >>"$RUN_DIR/notes.txt"
  else
    verify_phase
  fi
  finish
}

main "$@"
