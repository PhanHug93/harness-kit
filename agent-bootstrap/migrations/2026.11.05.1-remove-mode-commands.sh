# shellcheck shell=bash
# Migration: remove the /planning, /coding and /reviewing commands (and their
# -full-flow aliases) that older kits generated, when they are still exactly
# what a kit wrote. The seat commands /spec, /gate, /build, /verify and /audit
# replace them. Edited, tracked, linked or outside copies stay.
MIGRATION_ID=2026.11.05.1-remove-mode-commands
MIGRATION_SINCE=2026.11.05.1
MIGRATION_KIND=auto
MIGRATION_SUMMARY="Remove the /planning, /coding and /reviewing commands left by older kits (unedited, untracked copies; backups are kept)"

# Bytes of every copy a kit wrote: the full preset of each release tag
# (2026.06.17.1 to 2026.11.04.2); the infra preset never wrote them.
_MODE_PRINTS=".claude/commands/planning.md 310e199f196c168412284530edbf765f97332ca8f57a00fcb4db45c8cbe850b5
.claude/commands/planning.md 63ba8a97baaa1f14c1b00fa2262d84733e069cf6914b2f5338560cd463cf4b01
.claude/commands/planning.md 779fb1a99a467186bd7d238acac2710fab03be9184ba8e6d56071addc1ce6423
.claude/commands/planning.md b7f3967416a20a1b469ca1e5c557cc0413fd31a353d92adaffab4f10a3a20bf0
.claude/commands/planning.md bbd6cf5e99520d3a0edf8bf6652f3c56cdcf7c9802711c0c23ddcb2b373563be
.claude/commands/coding.md 29277d662de428ddc9f97f571794e5970b76867016785ac0d5a3bb14b684d48d
.claude/commands/coding.md 457c78d376bfb2c049383bd4cf00dba711512e87c0612371ad7a95230ffee8d4
.claude/commands/coding.md 5ff13b8c78f2330284b9e1dbce720dd505a7258baf150a3366bc78f0ae03d729
.claude/commands/coding.md 6356a2217b1495ed3d4de4f2b8f92ba590f165e1de9cdaf840ac6098c2e0c028
.claude/commands/coding.md 6f0e46b1edba5fc7333ef44a38d9d725f5c7d8d5a7cbf7c699074fcc5ca503c9
.claude/commands/coding.md 92505f1eb632c43f300d033a0ade9cadb59169bb82869ae16ce2c67ff264a6f8
.claude/commands/reviewing.md 45431ae0745bc41eb66cd90e873341ab34c7824fecc7dd23a66919850a614542
.claude/commands/reviewing.md bc6a0899bc564ccf41368a52ce8bc7935f1f3fea1f5071973b567cf3667aeaf6
.claude/commands/reviewing.md eb91c48ca5b4a86bb1f530f3d038c2a54795eb1438cca25de5f952a2d5a55945
.claude/commands/reviewing.md f45ab34970457a8d89c09a5ed33d2ea418d1cd2f9a077c5079a1ee36fe8f6002
.claude/commands/planning-full-flow.md 3d96305cea51ff74e7ca486df7434cea212a475c1dd6ae2a9f175be27c5d5512
.claude/commands/planning-full-flow.md a20825428193d4b6ee576b29685bda372875a6072bb825da70a6c0a959609dc6
.claude/commands/planning-full-flow.md bc4bf9336c35e83ecdfbe55d0c24c57cf4dd62ff682479d4b2a52e6297848d41
.claude/commands/coding-full-flow.md 2a238c16174ff25fbae155a42e2e8c64940f8fef788dda4105ffc98bf73389f5
.claude/commands/coding-full-flow.md 377b422742e5c5dc15f1151c8e3dfe66fc8c0be04a27fb36bea315419977b556
.claude/commands/coding-full-flow.md c731cd9b6066086dff6010ee286d3aa3496356107c4d802809e2c66be9216829
.claude/commands/reviewing-full-flow.md 0c10721a2e21070ee012c8500b3fbdf1b0986785e6d0a2e54ed2cf68085b1cb9
.claude/commands/reviewing-full-flow.md 0c87ece70a65d49da0fbf7e738e069bde7cad8207a796eee74f37931755d26f3
.claude/commands/reviewing-full-flow.md 9d44cfc93f7ba5225ccebfd46b0f929d10bcca7f3cc1c4d0a389c6bff57427f7"

# One line per path: remove<TAB>PATH or keep<TAB>PATH<TAB>REASON; then base<TAB>PATH
# for a baseline copy to remove.
_mode_plan() {
  python3 -I -B - "$TARGET_DIR" "$_MODE_PRINTS" <<'PY'
import hashlib, os, subprocess, sys
root, prints = os.path.realpath(sys.argv[1]), {}
for line in sys.argv[2].splitlines():
    rel, digest = line.split()
    prints.setdefault(rel, set()).add(digest)
BASE = ".tools/agent-state/harness-baseline/files"


def tracked(rel):
    # Exit 0 answers the question; anything else (not a repository, a broken
    # index) must not read as "untracked".
    done = subprocess.run(["git", "-C", root, "ls-files", "--", rel], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"git ls-files failed ({done.returncode}): {done.stderr.strip()}")
    return bool(done.stdout.strip())


def plain(rel):
    # The path names itself: no component is a link, so git and rm see one file.
    path = os.path.join(root, rel)
    return os.path.realpath(path) == path


for rel, digests in prints.items():
    path = os.path.join(root, rel)
    if not os.path.lexists(path):
        continue
    if os.path.islink(path):
        print(f"keep\t{rel}\ta link")
    elif not os.path.realpath(path).startswith(root + os.sep):
        print(f"keep\t{rel}\toutside the project")
    elif not plain(rel):
        print(f"keep\t{rel}\tbehind a link")
    elif not os.path.isfile(path):
        print(f"keep\t{rel}\tnot a regular file")
    else:
        data = open(path, "rb").read()
        copy = os.path.join(root, BASE, rel)
        base = os.path.isfile(copy) and plain(os.path.join(BASE, rel))
        unedited = hashlib.sha256(data).hexdigest() in digests or (base and open(copy, "rb").read() == data)
        if not unedited:
            print(f"keep\t{rel}\tedited")
        elif tracked(rel):
            print(f"keep\t{rel}\ttracked by git, unedited: git rm it")
        else:
            print(f"remove\t{rel}")
            if base:
                print(f"base\t{BASE}/{rel}")
PY
}

migration_needed() {
  local plan
  plan="$(_mode_plan)" || return 2
  grep -q '^remove	' <<<"$plan"
}

migration_describe() {
  local plan
  plan="$(_mode_plan)" || return 1
  printf '%s\n' "$plan" | awk -F'\t' '
    $1 == "remove" { out = out sep "remove " $2; sep = "; " }
    $1 == "keep" { out = out sep "keep " $2 " (" $3 ")"; sep = "; " }
    END { print out }'
}

migration_apply() {
  local plan action rel _reason
  plan="$(_mode_plan)" || return 1
  while IFS=$'\t' read -r action rel _reason; do
    case "$action" in
      remove | base)
        migration_backup "$rel"
        rm -f "${TARGET_DIR:?}/$rel"
        ;;
    esac
  done <<EOF
$plan
EOF
}
