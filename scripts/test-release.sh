#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/release.sh on a copy of the tracked tree; the repository is
# never modified.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'release-test: FAIL: %s\n' "$*" >&2
  exit 1
}

need_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"
}

fresh_copy() {
  local dest="$TMP_ROOT/$1"
  mkdir -p "$dest"
  git -C "$ROOT_DIR" ls-files -z --cached --others --exclude-standard -- agent-bootstrap docs scripts README.md CHANGELOG.md |
    (cd "$ROOT_DIR" && tar --null -T - -cf -) | tar -xf - -C "$dest"
  printf '%s\n' "$dest"
}

expect_fail() {
  local label="$1" expected="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    fail "$label: expected failure"
  fi
  need_contains "$out" "$expected" "$label"
}

base="$(fresh_copy base)"
current="$(sed -n '1p' "$base/agent-bootstrap/VERSION")"
bash "$base/scripts/release.sh" --check >/dev/null || fail "--check must pass on the tracked tree"
bash "$base/scripts/release.sh" --check-tag "v$current" >/dev/null || fail "--check-tag must accept v<VERSION>"
expect_fail "tag mismatch" "does not match agent-bootstrap/VERSION" \
  bash "$base/scripts/release.sh" --check-tag "v$current.9"

copy="$(fresh_copy pin-drift)"
sed -i.bak "s/^Version: \`.*\`$/Version: \`1999.01.01.1\`/" "$copy/agent-bootstrap/MANIFEST.md"
expect_fail "pin drift" "agent-bootstrap/MANIFEST.md: pins 1999.01.01.1" bash "$copy/scripts/release.sh" --check

copy="$(fresh_copy snapshot-drift)"
printf '# hand edit\n' >>"$copy/agent-bootstrap/agent-hook.sh"
expect_fail "snapshot drift" "agent-bootstrap/agent-hook.sh differs" bash "$copy/scripts/release.sh" --check
bash "$copy/scripts/sync-runtime-snapshots.sh" >/dev/null
bash "$copy/scripts/release.sh" --check >/dev/null || fail "snapshot sync must repair drift"

copy="$(fresh_copy refusals)"
expect_fail "bad format" "YYYY.MM.DD.N" bash "$copy/scripts/release.sh" 2099.1.1
expect_fail "not newer" "is not newer" bash "$copy/scripts/release.sh" 2000.01.01.1
python3 - "$copy/CHANGELOG.md" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r"^## Unreleased[ \t]*\n(?:(?!^## ).*\n)*", "", p.read_text(), count=1, flags=re.M))
PY
expect_fail "no unreleased" "## Unreleased" bash "$copy/scripts/release.sh" 2099.01.01.1
need_contains "$(sed -n '1p' "$copy/agent-bootstrap/VERSION")" "$current" "refused bump leaves VERSION"

copy="$(fresh_copy bump)"
historical="$(grep -c "$current" "$copy/docs/superpowers/specs/2026-09-12-hk07-retirement-policy-design.md" || true)"
if ! grep -q '^## Unreleased' "$copy/CHANGELOG.md"; then
  printf '# Changelog\n\n## Unreleased\n\n- Test release note.\n\n%s\n' "$(sed '1d' "$copy/CHANGELOG.md")" >"$copy/CHANGELOG.md"
fi
bump_out="$(bash "$copy/scripts/release.sh" 2099.01.01.1 --title "Test release" 2>&1)" ||
  fail "bump failed: $bump_out"
need_contains "$bump_out" "release check: ok (2099.01.01.1)" "bump verifies itself"
need_contains "$bump_out" "--check-tag v2099.01.01.1" "bump prints the tag gate"
[[ "$(sed -n '1p' "$copy/agent-bootstrap/VERSION")" == "2099.01.01.1" ]] || fail "VERSION not bumped"
need_contains "$(bash "$copy/agent-bootstrap/bootstrap-multi-agent-project.sh" --version)" "2099.01.01.1" "entrypoint version"
need_contains "$(cat "$copy/agent-bootstrap/MANIFEST.md")" "Version: \`2099.01.01.1\`" "manifest version"
need_contains "$(cat "$copy/agent-bootstrap/harness-kit-one-shot-upgrade.sh")" 'DEFAULT_REF="v2099.01.01.1"' "one-shot default ref"
need_contains "$(cat "$copy/README.md")" "Current release: [\`2099.01.01.1\`]" "README current release"
for doc in README.md agent-bootstrap/README.md docs/agent-configs/bootstrap-multi-agent-project/README.md; do
  need_contains "$(cat "$copy/$doc")" "harness-kit/v2099.01.01.1/agent-bootstrap/harness-kit-one-shot-upgrade.sh" "$doc one-shot URL"
done
need_contains "$(cat "$copy/CHANGELOG.md")" "## 2099.01.01.1 — Test release" "changelog release heading"
grep -q '^## Unreleased' "$copy/CHANGELOG.md" && fail "changelog still has an Unreleased heading"
need_contains "$(cat "$copy/CHANGELOG.md")" "## $current" "changelog keeps older releases"
[[ "$(grep -c "$current" "$copy/docs/superpowers/specs/2026-09-12-hk07-retirement-policy-design.md" || true)" == "$historical" ]] ||
  fail "historical mentions must not be rewritten"
expect_fail "repeat bump" "is not newer" bash "$copy/scripts/release.sh" 2099.01.01.1

printf 'release-test: ok\n'
