# shellcheck shell=bash
# Migration: remove GEMINI.md, .windsurfrules and the Cursor conventions rule
# that older kits generated, when they are still exactly what a kit wrote.
# Those hosts read AGENTS.md. Edited, tracked, linked or outside copies stay.
MIGRATION_ID=2026.11.04.1-remove-legacy-entrypoints
MIGRATION_SINCE=2026.11.04.1
MIGRATION_KIND=auto
MIGRATION_SUMMARY="Remove GEMINI.md, .windsurfrules and the Cursor rule left by older kits (unedited, untracked copies; backups are kept)"

# Bytes of every copy a kit wrote: full and infra presets of the first commit
# and of each release tag (2026.06.17.1 to 2026.10.24.1).
_LEGACY_PRINTS="GEMINI.md 3a891c28d6bbeff21be833ec1ab934b631792ca201891822ab32dd28020caaee
GEMINI.md 404300350ba3c1b0b83435385970d9c2ea16e6cc283d84d249f00226f39b7c15
GEMINI.md 41d9107a0446c94a1cd69930dc4b9781de186985b2e8032d8761a2c8d8daada0
GEMINI.md 5068433c47b75daa577b13db901a29819a3895d5ec46388a8eec63887d9bb7a6
GEMINI.md 677385c98ad8eb8a8933d47f4985406af209b9c5a53f116180a7602b453aac15
GEMINI.md 8da612cb851c77d8a4c930fb5184a2129ad8319c29554196f087acdf3e5ff793
GEMINI.md 9763474142669e85fbf0cd20c2d61edc943b6f65654ad9788533f15a4439cabe
GEMINI.md b950bf4d436c943914e49c52de154f7895a95838ec32bd221738566fc3dd55cd
GEMINI.md ba0c285e25791a24eac666384eb60e7e2b74c1dbcf21d52aae32931eaf4ccb5c
GEMINI.md df46a74c507ea28e2b30ea2bbbe18b578ff394692e02609727679c439910134e
GEMINI.md ecf8fe9c251f71906cd29f06dac5bf758645973e37d195fa0328d90f0e876d47
.windsurfrules 05c9d417a4f9f82e9e8298751ca5ac8e8b923e4c676208f9f19fca29451b61a9
.windsurfrules 35555177708370f364653b5327894c5be056dc3859635bcc36ba79e90a1bd844
.windsurfrules 53792926d10bfbd51dbfae31756c2bb00e08175b3920c00c4766a2c570809afa
.windsurfrules 76ddd31d9548341c9dc9f3850fa4c7fe9c5586e6519f6110544289ff99519096
.windsurfrules 89ff48908f4f763350d55ef3f17b8d36b8abb4eda0cdb4997f348e50b4331153
.windsurfrules 9212ea68b2eeaf8263111c7b3a6bf7cbd832f626fb152716d3787a41ae1d9910
.windsurfrules be9668e8ad04d58aaeba4580ab0682f2b0e91344b459eba2736530343756b49c
.windsurfrules dc8d8570d07a2e49f0453ec55902d2ee3697f6a4710e443165c2ba08be14c6e1
.windsurfrules dfc576f08e4614b581f58ff84142cd66e8e9f347eb5393aca16025d426c602ba
.windsurfrules e323132bc7be94905bad79cd3dcdb9981974401c986c4d687c49ea0b37910217
.cursor/rules/agent-conventions.mdc 46aa866ed7498d8c3af37723f94dccf673fcddf2174397c2c19487601c6eb420
.cursor/rules/agent-conventions.mdc 57ec09c46fe76a49180a01f6aadd3d0acda1c54a028deb7bde342835e10d9429
.cursor/rules/agent-conventions.mdc 6bd352d3a13d1c1fd44685ec9da03916c1ebf938eed674be6df5536e1e831108
.cursor/rules/agent-conventions.mdc 70714eab103bef5bbdccb9eb58e5c118991421d38568be65a8a13f6a45b23bd6
.cursor/rules/agent-conventions.mdc 897e46c52caa5d8c064dc73ff802ba4c445a300e93d983af025e438717c19040
.cursor/rules/agent-conventions.mdc 9fb74003a6b9074b853a9f5df85460d85163de71e858bab4d357430ba21aab0f
.cursor/rules/agent-conventions.mdc b2f6fff4e4b1ceed817d9b09464fe6d194d76b8637daf43bab85febf74569232
.cursor/rules/agent-conventions.mdc b73eb369ea701144e6c2b15aadf0ac63d1ac3730737540d70769fa2f52ae9d5b
.cursor/rules/agent-conventions.mdc c1999dd7133dbc09e92f6d252c4efbe44a016831b58538f852ad70b5743eaa82
.cursor/rules/agent-conventions.mdc c9d73d63007d1506eeac48137d7db92a2a774a297904d4b4c996763a9f29d1cd"

# One line per path: remove<TAB>PATH or keep<TAB>PATH<TAB>REASON; then base<TAB>PATH
# for a baseline copy to remove and rmdir<TAB>DIR for a folder this run may empty.
_legacy_plan() {
  python3 -I -B - "$TARGET_DIR" "$_LEGACY_PRINTS" <<'PY'
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


removed = []
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
            print(f"keep\t{rel}\ttracked by git")
        else:
            print(f"remove\t{rel}")
            if base:
                print(f"base\t{BASE}/{rel}")
            removed.append(rel)
# Only folders this run empties, and only real ones.
if ".cursor/rules/agent-conventions.mdc" in removed:
    for top in ("", BASE + "/"):
        for rel in (top + ".cursor/rules", top + ".cursor"):
            if os.path.isdir(os.path.join(root, rel)) and plain(rel):
                print(f"rmdir\t{rel}")
PY
}

migration_needed() {
  local plan
  plan="$(_legacy_plan)" || return 2
  printf '%s\n' "$plan" | grep -q '^remove	'
}

migration_describe() {
  local plan
  plan="$(_legacy_plan)" || return 1
  printf '%s\n' "$plan" | awk -F'\t' '
    $1 == "remove" { out = out sep "remove " $2; sep = "; " }
    $1 == "keep" { out = out sep "keep " $2 " (" $3 ")"; sep = "; " }
    END { print out }'
}

migration_apply() {
  local plan action rel _reason
  plan="$(_legacy_plan)" || return 1
  while IFS=$'\t' read -r action rel _reason; do
    case "$action" in
      remove | base)
        migration_backup "$rel"
        rm -f "${TARGET_DIR:?}/$rel"
        ;;
      rmdir) rmdir "$TARGET_DIR/$rel" 2>/dev/null || true ;;
    esac
  done <<EOF
$plan
EOF
}
