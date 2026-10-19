#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  printf '%s\n' \
    "Usage:" \
    "  scripts/release.sh --check                 verify version pins, changelog, mirrors" \
    "  scripts/release.sh --check-tag vX.Y.Z.N    also require the tag to equal v<VERSION>" \
    "  scripts/release.sh <YYYY.MM.DD.N> [--title TEXT]" \
    "                                             bump VERSION and every pin, release" \
    "                                             '## Unreleased', sync mirrors, verify" \
    "" \
    "A bump also renames agent-bootstrap/migrations/next-*.sh to <version>-*.sh and" \
    "rewrites their MIGRATION_SINCE and MIGRATION_ID (and the ids named in the" \
    "release notes). --check verifies the migrations; --check-tag rejects next-*." \
    "" \
    "agent-bootstrap/VERSION is the single source. This script never commits," \
    "tags or pushes; tags need the owner's authorization and source branch."
}

# Pinned sites: file, then a pattern whose group "v" is the bundle version.
# Each must match exactly once; historical mentions are not pins.
pins() {
  python3 - "$ROOT_DIR" "$@" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
URL = r"harness-kit/v(?P<v>[0-9.]+)/agent-bootstrap/harness-kit-one-shot\.sh"
PINS = [
    ("agent-bootstrap/bootstrap-multi-agent-project.sh", r'^AGENT_BOOTSTRAP_VERSION="(?P<v>[^"]+)"$'),
    ("agent-bootstrap/MANIFEST.md", r"^Version: `(?P<v>[^`]+)`$"),
    ("agent-bootstrap/harness-kit-one-shot-upgrade.sh", r'^DEFAULT_REF="v(?P<v>[^"]+)"$'),
    ("agent-bootstrap/harness-kit-one-shot-upgrade.sh", r"Defaults to v(?P<v>[0-9.]+)\.$"),
    ("agent-bootstrap/harness-kit-one-shot.sh", r'^DEFAULT_REF="v(?P<v>[^"]+)"$'),
    ("agent-bootstrap/harness-kit-one-shot.sh", r"Defaults to v(?P<v>[0-9.]+)\.$"),
    ("README.md", r"^Current release: \[`(?P<v>[^`]+)`\]"),
    ("README.md", URL),
    ("README.md", r"installs release `(?P<v>[^`]+)`"),
    ("agent-bootstrap/README.md", URL),
    ("docs/agent-configs/bootstrap-multi-agent-project/README.md", URL),
]
VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$")
version_file = root / "agent-bootstrap/VERSION"
current = version_file.read_text().splitlines()[0].strip()
changelog_path = root / "CHANGELOG.md"
changelog = changelog_path.read_text()
problems = []
texts = {}
MIG_DIR = root / "agent-bootstrap/migrations"
ID_RE = re.compile(r"""^MIGRATION_ID=["']?([^"'\s]+)["']?\s*$""", re.M)
SINCE_RE = re.compile(r"""^MIGRATION_SINCE=["']?([^"'\s]+)["']?\s*$""", re.M)
KIND_RE = re.compile(r"""^MIGRATION_KIND=["']?([^"'\s]+)["']?\s*$""", re.M)
FUNC_NAMES = ("migration_needed", "migration_describe", "migration_apply")
as_tuple = lambda v: tuple(int(x) for x in v.split("."))


def migration_files():
    return sorted(MIG_DIR.glob("*.sh")) if MIG_DIR.is_dir() else []


def migration_problems():
    found, ids = [], {}
    for path in migration_files():
        rel = f"agent-bootstrap/migrations/{path.name}"
        text = path.read_text()
        ident, since, kind = (r.search(text) for r in (ID_RE, SINCE_RE, KIND_RE))
        if not ident:
            found.append(f"{rel}: MIGRATION_ID is not defined")
            continue
        ident = ident.group(1)
        if ident in ids:
            found.append(f"{rel}: duplicate migration id {ident} (also in {ids[ident]})")
        ids[ident] = path.name
        if ident != path.stem:
            found.append(f"{rel}: MIGRATION_ID {ident} must equal the file name {path.stem}")
        if not kind or kind.group(1) not in ("auto", "decision"):
            found.append(f"{rel}: MIGRATION_KIND must be auto or decision")
        for name in FUNC_NAMES:
            if not re.search(rf"^\s*(function\s+)?{name}\s*\(\)", text, re.M):
                found.append(f"{rel}: function {name} is not defined")
        if not since:
            found.append(f"{rel}: MIGRATION_SINCE is not defined")
            continue
        since = since.group(1)
        if since == "next":
            continue
        if not VERSION_RE.match(since):
            found.append(f"{rel}: MIGRATION_SINCE {since!r} is neither next nor YYYY.MM.DD.N")
        elif VERSION_RE.match(current) and as_tuple(since) > as_tuple(current):
            found.append(f"{rel}: MIGRATION_SINCE {since} is newer than VERSION {current}")
        else:
            section = re.search(rf"^## {re.escape(since)}( — .+)?$\n((?:(?!^## ).*\n?)*)", changelog, re.M)
            if not section:
                found.append(f"{rel}: CHANGELOG.md has no '## {since}' section naming {ident}")
            elif ident not in section.group(2):
                found.append(f"{rel}: CHANGELOG.md section {since} does not name migration {ident}")
    return found



def matches(rel, pattern):
    text = texts.setdefault(rel, (root / rel).read_text())
    found = list(re.finditer(pattern, text, re.M))
    if len(found) != 1:
        problems.append(f"{rel}: pin pattern {pattern!r} matched {len(found)} times (expected 1)")
    return found


if mode == "check":
    for rel, pattern in PINS:
        for m in matches(rel, pattern):
            if m.group("v") != current:
                problems.append(f"{rel}: pins {m.group('v')}, VERSION is {current}")
    entry, legacy = root / "agent-bootstrap/harness-kit-one-shot.sh", root / "agent-bootstrap/harness-kit-one-shot-upgrade.sh"
    if entry.read_bytes() != legacy.read_bytes():
        problems.append("agent-bootstrap/harness-kit-one-shot-upgrade.sh must be a byte-identical copy of harness-kit-one-shot.sh")
    if not re.search(rf"^## {re.escape(current)}( — .+)?$", changelog, re.M):
        problems.append(f"CHANGELOG.md: no '## {current}' heading")
    problems.extend(migration_problems())
    for p in problems:
        print(f"drift: {p}", file=sys.stderr)
    sys.exit(1 if problems else 0)

new, title = sys.argv[3], sys.argv[4]
if not VERSION_RE.match(new):
    sys.exit(f"ERROR: version must look like YYYY.MM.DD.N, got {new!r}")
if VERSION_RE.match(current) and as_tuple(new) <= as_tuple(current):
    sys.exit(f"ERROR: {new} is not newer than the current version {current}")
heading = re.compile(r"^## Unreleased[ \t]*\n((?:(?!^## ).*\n?)*)", re.M)
found = list(heading.finditer(changelog))
if len(found) != 1 or not found[0].group(1).strip():
    sys.exit("ERROR: CHANGELOG.md needs exactly one non-empty '## Unreleased' section with the release notes")


def swap(m):
    whole, offset = m.group(0), m.start()
    return whole[: m.start("v") - offset] + new + whole[m.end("v") - offset :]


updated = {}
for rel, pattern in PINS:
    if len(matches(rel, pattern)) == 1:
        updated[rel] = re.sub(pattern, swap, updated.get(rel, texts[rel]), count=1, flags=re.M)
if problems:
    for p in problems:
        print(f"ERROR: {p}", file=sys.stderr)
    sys.exit(1)
renames, id_map = [], {}
for path in migration_files():
    if not path.stem.startswith("next-"):
        continue
    new_stem = new + path.stem[len("next"):]
    text = path.read_text()
    text, hits_since = SINCE_RE.subn(f"MIGRATION_SINCE={new}", text, count=1)
    text, hits_id = ID_RE.subn(f"MIGRATION_ID={new_stem}", text, count=1)
    if hits_since != 1 or hits_id != 1:
        sys.exit(f"ERROR: {path.name}: MIGRATION_SINCE and MIGRATION_ID must each be defined once")
    renames.append((path, path.with_name(new_stem + ".sh"), text))
    id_map[path.stem] = new_stem
release_heading = f"## {new}" + (f" — {title}" if title else "")
updated["CHANGELOG.md"] = heading.sub(lambda m: f"{release_heading}\n{m.group(1)}", changelog, count=1)
updated["agent-bootstrap/VERSION"] = new + "\n"
for old_id, new_id in id_map.items():
    updated["CHANGELOG.md"] = re.sub(rf"(?<![\w-]){re.escape(old_id)}(?![\w-])", new_id, updated["CHANGELOG.md"])
# The bundle inventories name every migration file.
for rel in ("agent-bootstrap/MANIFEST.md", "agent-bootstrap/install-agent-bootstrap-home.sh", "scripts/test-bootstrap-multi-agent-project.sh"):
    if not id_map or not (root / rel).is_file():
        continue
    text = updated.get(rel, (root / rel).read_text())
    for old_id, new_id in id_map.items():
        text = text.replace(f"migrations/{old_id}.sh", f"migrations/{new_id}.sh")
        if rel == "agent-bootstrap/MANIFEST.md":
            # The row's description names the id and, before release, the rename note.
            note = " (renamed to `<version>-…` by `scripts/release.sh <version>`)"
            text = text.replace(f"Migration `{old_id}`{note}", f"Migration `{new_id}`")
            text = text.replace(f"Migration `{old_id}`", f"Migration `{new_id}`")
    updated[rel] = text
for rel, text in updated.items():
    (root / rel).write_text(text)
for old_path, new_path, text in renames:
    new_path.write_text(text)
    old_path.unlink()
extra = f" and renamed {len(renames)} migration(s)" if renames else ""
print(f"bumped {current} -> {new} in {len(updated)} files{extra}")
PY
}

check() {
  local status=0
  pins check || status=1
  bash "$ROOT_DIR/scripts/sync-template-catalog.sh" --check >/dev/null 2>&1 || {
    echo "drift: template mirror differs; run scripts/sync-template-catalog.sh" >&2
    status=1
  }
  bash "$ROOT_DIR/scripts/sync-runtime-snapshots.sh" --check || status=1
  [[ "$status" == 0 ]] && echo "release check: ok ($(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION"))"
  return "$status"
}

case "${1:-}" in
  --check)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    check
    ;;
  --check-tag)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    version="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION")"
    pending_migrations="$(find "$ROOT_DIR/agent-bootstrap/migrations" -maxdepth 1 -name 'next-*.sh' 2>/dev/null | sort || true)"
    if [[ -n "$pending_migrations" ]]; then
      echo "ERROR: unreleased migrations (next-*) must be renamed by a version bump before tagging:" >&2
      printf '  %s\n' "$pending_migrations" >&2
      exit 1
    fi
    if [[ "$2" != "v$version" ]]; then
      echo "ERROR: tag $2 does not match agent-bootstrap/VERSION ($version); expected v$version" >&2
      exit 1
    fi
    check
    ;;
  -h|--help)
    usage
    ;;
  ''|-*)
    usage >&2
    exit 2
    ;;
  *)
    new_version="$1"
    shift
    title=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) title="${2:?missing value for --title}"; shift 2 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
      esac
    done
    pins bump "$new_version" "$title"
    bash "$ROOT_DIR/scripts/sync-template-catalog.sh"
    bash "$ROOT_DIR/scripts/sync-runtime-snapshots.sh"
    check
    printf '%s\n' \
      "Next: review the diff, commit on the release branch and open a PR to the" \
      "target the owner names. Tag only with the owner's authorization and source" \
      "branch, after: scripts/release.sh --check-tag v$new_version"
    ;;
esac
