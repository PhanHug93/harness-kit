# shellcheck shell=bash
# Migration: remove the rtk files older kits generated or installed, when they
# are still exactly what a kit wrote. Edited, tracked or referenced copies stay.
MIGRATION_ID=2026.11.04.1-remove-rtk
MIGRATION_SINCE=2026.11.04.1
MIGRATION_KIND=auto
MIGRATION_SUMMARY="Remove rtk files left by older kits (unedited, untracked copies; backups are kept)"

# Bytes of every rtk file a kit wrote: each version in this repository's
# history (2026.06.14.6 to 2026.10.24.1), plus the installer of the 2026.05 kit
# that predates it (byte-identical in two projects that never edited it).
_RTK_PRINTS="scripts/rtk f3ceb17366230f8b2a2256592276757830403d1141308f688791f40ce8803af7
scripts/rtk d4442098b00f79f9e28cbc962479aac514fb4955ef8b74e741a2f36723425794
scripts/install-rtk.sh 3b856c4667a20719cbf1801020cce85f029140a8fde0564d887f0d9a508b5a3a
scripts/install-rtk.sh 76879f8e42cfba1a2d7cdf8bd1b5ce025e509b15965b65bf3ca476b6053329de
scripts/install-rtk.sh aca3c45dfa1d677433287cdb62b8795a59be5ff2960b1700e4d5e077bbbbc578
scripts/install-rtk.sh 24ab69864ef6939103c564abafaaa59d6726521f91e6a0587cc8c2e3808c30f1
scripts/install-rtk.sh ec98b8c667d720a30d8c24a13cc845f1f30825bb7b7fa38fa9205b07bbdcd38e
docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256 3208557b7b1274a4b2e2d93e8ad776e5777fc85c34503a7d6747a6ca5740b01a"

# One line per path: remove<TAB>PATH or keep<TAB>PATH<TAB>REASON.
_rtk_plan() {
  python3 -I -B - "$TARGET_DIR" "$_RTK_PRINTS" <<'PY'
import hashlib, os, re, subprocess, sys
root, prints = os.path.realpath(sys.argv[1]), {}
for line in sys.argv[2].splitlines():
    rel, digest = line.split()
    prints.setdefault(rel, set()).add(digest)
base = os.path.join(root, ".tools/agent-state/harness-baseline/files")


def git(*args):
    # Exit 0 or 1 answer the question; anything else (not a repository, a
    # broken index) must not read as "untracked, unreferenced".
    done = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    if done.returncode > 1:
        sys.exit(f"git {args[0]} failed ({done.returncode}): {done.stderr.strip()}")
    return done


def tracked(rel):
    return bool(git("ls-files", "--", rel).stdout.strip())


def inside(path):
    real = os.path.realpath(path)
    return real == root or real.startswith(root + os.sep)


def references(rel):
    # A tracked file other than Markdown may run it (CI, Makefile); journals
    # and packets only mention it, and an old local-only block in .gitignore
    # only lists it. The rtk files themselves do not count.
    if not rel.startswith("scripts/"):
        return []
    skip = [f":(exclude){p}" for p in prints]
    return git("grep", "-l", "-F", "-e", rel, "--", ".", ":(exclude)*.md", ":(exclude)*.mdc",
               ":(exclude)*.gitignore", *skip).stdout.split()


kept = set()


def keep(rel, reason):
    kept.add(rel)
    print(f"keep\t{rel}\t{reason}")


for rel, digests in prints.items():
    path = os.path.join(root, rel)
    if not os.path.lexists(path):
        continue
    if os.path.islink(path) or not os.path.isfile(path) or not inside(path):
        keep(rel, "not a regular file")
        continue
    data = open(path, "rb").read()
    copy = os.path.join(base, rel)
    unedited = hashlib.sha256(data).hexdigest() in digests or (
        os.path.isfile(copy) and not os.path.islink(copy) and open(copy, "rb").read() == data)
    refs = references(rel) if unedited else []
    if not unedited:
        keep(rel, "edited")
    elif tracked(rel):
        keep(rel, "tracked by git")
    elif refs:
        keep(rel, f"referenced by {', '.join(refs[:3])}")
    else:
        print(f"remove\t{rel}")


# The installer downloaded one pinned archive into the version folder and
# extracted the binary next to it.
ASSETS = {"rtk-aarch64-apple-darwin.tar.gz", "rtk-x86_64-apple-darwin.tar.gz",
          "rtk-aarch64-unknown-linux-gnu.tar.gz", "rtk-x86_64-unknown-linux-musl.tar.gz"}


def regular(path):
    return os.path.isfile(path) and not os.path.islink(path)


def kit_layout(tools):
    # .tools/rtk/v<x.y.z>/ holding the rtk binary and at most one pinned archive.
    if not os.path.isdir(tools) or os.path.islink(tools):
        return False
    for name in os.listdir(tools):
        version = os.path.join(tools, name)
        if not re.fullmatch(r"v\d+\.\d+\.\d+", name) or not os.path.isdir(version) or os.path.islink(version):
            return False
        entries = set(os.listdir(version))
        archives = entries - {"rtk"}
        if "rtk" not in entries or len(archives) > 1 or not archives <= ASSETS:
            return False
        if not all(regular(os.path.join(version, entry)) for entry in entries):
            return False
    return True


# A kept wrapper still runs the pinned binary (a project Makefile may call it).
wrapper_kept = "scripts/rtk" in kept
tools = os.path.join(root, ".tools/rtk")
if os.path.lexists(tools):
    if tracked(".tools/rtk"):
        keep(".tools/rtk", "tracked by git")
    elif not kit_layout(tools):
        keep(".tools/rtk", "not the kit's install layout")
    elif wrapper_kept:
        keep(".tools/rtk", "scripts/rtk is kept and runs it")
    else:
        print("remove\t.tools/rtk")
link = os.path.join(root, ".tools/bin/rtk")
if os.path.lexists(link):
    target = os.readlink(link) if os.path.islink(link) else ""
    if tracked(".tools/bin/rtk"):
        keep(".tools/bin/rtk", "tracked by git")
    elif not re.fullmatch(r"\.\./rtk/v\d+\.\d+\.\d+/rtk", target):
        keep(".tools/bin/rtk", "not the kit's link")
    elif wrapper_kept:
        keep(".tools/bin/rtk", "scripts/rtk is kept and runs it")
    else:
        print("remove\t.tools/bin/rtk")
PY
}

migration_needed() {
  local plan
  plan="$(_rtk_plan)" || return 2
  grep -q '^remove	' <<<"$plan"
}

migration_describe() {
  local plan
  plan="$(_rtk_plan)" || return 1
  printf '%s\n' "$plan" | awk -F'\t' '
    $1 == "remove" { out = out sep "remove " $2; sep = "; " }
    $1 == "keep" { out = out sep "keep " $2 " (" $3 ")"; sep = "; " }
    END { print out }'
}

migration_apply() {
  local plan action rel _reason
  plan="$(_rtk_plan)" || return 1
  while IFS=$'\t' read -r action rel _reason; do
    [ "$action" = remove ] || continue
    migration_backup "$rel"
    rm -rf "${TARGET_DIR:?}/$rel"
    rel=".tools/agent-state/harness-baseline/files/$rel"
    if [ -e "$TARGET_DIR/$rel" ] || [ -L "$TARGET_DIR/$rel" ]; then
      migration_backup "$rel"
      rm -rf "${TARGET_DIR:?}/$rel"
    fi
  done <<EOF
$plan
EOF
  for rel in docs/agent-configs/bootstrap-multi-agent-project/provenance .tools/bin \
    .tools/agent-state/harness-baseline/files/docs/agent-configs/bootstrap-multi-agent-project/provenance; do
    rmdir "$TARGET_DIR/$rel" 2>/dev/null || true
  done
}
