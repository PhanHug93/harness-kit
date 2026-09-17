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
URL = r"harness-kit/v(?P<v>[0-9.]+)/agent-bootstrap/harness-kit-one-shot-upgrade\.sh"
PINS = [
    ("agent-bootstrap/bootstrap-multi-agent-project.sh", r'^AGENT_BOOTSTRAP_VERSION="(?P<v>[^"]+)"$'),
    ("agent-bootstrap/MANIFEST.md", r"^Version: `(?P<v>[^`]+)`$"),
    ("agent-bootstrap/harness-kit-one-shot-upgrade.sh", r'^DEFAULT_REF="v(?P<v>[^"]+)"$'),
    ("agent-bootstrap/harness-kit-one-shot-upgrade.sh", r"Defaults to v(?P<v>[0-9.]+)\.$"),
    ("README.md", r"^Current release: \[`(?P<v>[^`]+)`\]"),
    ("README.md", r"^## Upgrade an existing project to (?P<v>[0-9.]+)$"),
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
    if not re.search(rf"^## {re.escape(current)}( — .+)?$", changelog, re.M):
        problems.append(f"CHANGELOG.md: no '## {current}' heading")
    for p in problems:
        print(f"drift: {p}", file=sys.stderr)
    sys.exit(1 if problems else 0)

new, title = sys.argv[3], sys.argv[4]
if not VERSION_RE.match(new):
    sys.exit(f"ERROR: version must look like YYYY.MM.DD.N, got {new!r}")
as_tuple = lambda v: tuple(int(x) for x in v.split("."))
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
release_heading = f"## {new}" + (f" — {title}" if title else "")
updated["CHANGELOG.md"] = heading.sub(lambda m: f"{release_heading}\n{m.group(1)}", changelog, count=1)
updated["agent-bootstrap/VERSION"] = new + "\n"
for rel, text in updated.items():
    (root / rel).write_text(text)
print(f"bumped {current} -> {new} in {len(updated)} files")
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
