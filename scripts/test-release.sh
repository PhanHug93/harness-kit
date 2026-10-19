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

# Writes a valid migration file: dir, id, since.
write_migration() {
  mkdir -p "$1"
  cat >"$1/$2.sh" <<MIG
MIGRATION_ID=$2
MIGRATION_SINCE=$3
MIGRATION_KIND=decision
MIGRATION_SUMMARY="fixture"
migration_needed() { return 1; }
migration_describe() { echo fixture; }
migration_apply() { :; }
MIG
}

base="$(fresh_copy base)"
current="$(sed -n '1p' "$base/agent-bootstrap/VERSION")"
bash "$base/scripts/release.sh" --check >/dev/null || fail "--check must pass on the tracked tree"
write_migration "$base/agent-bootstrap/migrations" next-zz-fixture next
bash "$base/scripts/release.sh" --check >/dev/null || fail "--check must accept next-* migrations"
expect_fail "next migration blocks the tag" "next-zz-fixture.sh" bash "$base/scripts/release.sh" --check-tag "v$current"
rm -f "$base"/agent-bootstrap/migrations/next-*.sh
bash "$base/scripts/release.sh" --check-tag "v$current" >/dev/null || fail "--check-tag must accept v<VERSION>"
expect_fail "tag mismatch" "does not match agent-bootstrap/VERSION" \
  bash "$base/scripts/release.sh" --check-tag "v$current.9"

copy="$(fresh_copy pin-drift)"
sed -i.bak "s/^Version: \`.*\`$/Version: \`1999.01.01.1\`/" "$copy/agent-bootstrap/MANIFEST.md"
expect_fail "pin drift" "agent-bootstrap/MANIFEST.md: pins 1999.01.01.1" bash "$copy/scripts/release.sh" --check

copy="$(fresh_copy entry-drift)"
printf '# drift\n' >>"$copy/agent-bootstrap/harness-kit-one-shot-upgrade.sh"
expect_fail "entry copy drift" "byte-identical copy" bash "$copy/scripts/release.sh" --check

copy="$(fresh_copy snapshot-drift)"
printf '# hand edit\n' >>"$copy/agent-bootstrap/agent-hook.sh"
expect_fail "snapshot drift" "agent-bootstrap/agent-hook.sh differs" bash "$copy/scripts/release.sh" --check
bash "$copy/scripts/sync-runtime-snapshots.sh" >/dev/null
bash "$copy/scripts/release.sh" --check >/dev/null || fail "snapshot sync must repair drift"

copy="$(fresh_copy migration-checks)"
mig="$copy/agent-bootstrap/migrations"
write_migration "$mig" next-zz-fixture next
write_migration "$mig" next-zz-copy next
sed -i.bak 's/^MIGRATION_ID=.*/MIGRATION_ID=next-zz-fixture/' "$mig/next-zz-copy.sh"
rm -f "$mig"/*.bak
expect_fail "duplicate ids" "duplicate migration id next-zz-fixture" bash "$copy/scripts/release.sh" --check
rm "$mig/next-zz-copy.sh"
bash "$copy/scripts/release.sh" --check >/dev/null || fail "one fixture must pass --check"
write_migration "$mig" "$current-zz-released" "$current"
expect_fail "released id missing from CHANGELOG" "does not name migration $current-zz-released" bash "$copy/scripts/release.sh" --check
python3 - "$copy/CHANGELOG.md" "$current" "$current-zz-released" <<'PY'
import pathlib, re, sys
p, version, ident = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
p.write_text(re.sub(rf"^(## {re.escape(version)}.*\n)", lambda m: m.group(1) + f"\n- Migration `{ident}`.\n", p.read_text(), count=1, flags=re.M))
PY
bash "$copy/scripts/release.sh" --check >/dev/null || fail "a released id named in its CHANGELOG section must pass"
write_migration "$mig" 2099.01.01.1-zz-future 2099.01.01.1
expect_fail "SINCE newer than VERSION" "is newer than VERSION" bash "$copy/scripts/release.sh" --check
rm "$mig/2099.01.01.1-zz-future.sh"
sed -i.bak '/^migration_apply/d' "$mig/next-zz-fixture.sh"; rm -f "$mig"/*.bak
expect_fail "missing function" "function migration_apply is not defined" bash "$copy/scripts/release.sh" --check

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
write_migration "$copy/agent-bootstrap/migrations" next-zz-fixture next
# The inventories name every migration file. A fixture row checks the rename
# whatever the shipped migrations are called (next-* only before a release).
printf '| %s | Migration %s (renamed to %s by %s). | Test only. |\n' "\`migrations/next-zz-fixture.sh\`" \
  "\`next-zz-fixture\`" "\`<version>-…\`" "\`scripts/release.sh <version>\`" >>"$copy/agent-bootstrap/MANIFEST.md"
printf '# migrations/next-zz-fixture.sh\n' >>"$copy/agent-bootstrap/install-agent-bootstrap-home.sh"
printf '# migrations/next-zz-fixture.sh\n' >>"$copy/scripts/test-bootstrap-multi-agent-project.sh"
notes=""
for f in "$copy"/agent-bootstrap/migrations/next-*.sh; do notes="$notes- Migration \`$(basename "$f" .sh)\`.\n"; done
python3 - "$copy/CHANGELOG.md" "$notes" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
notes = sys.argv[2].replace("\\n", "\n")
p.write_text(re.sub(r"^(## Unreleased[ \t]*\n)", lambda m: m.group(1) + "\n" + notes, p.read_text(), count=1, flags=re.M))
PY
bump_out="$(bash "$copy/scripts/release.sh" 2099.01.01.1 --title "Test release" 2>&1)" ||
  fail "bump failed: $bump_out"
need_contains "$bump_out" "release check: ok (2099.01.01.1)" "bump verifies itself"
need_contains "$bump_out" "--check-tag v2099.01.01.1" "bump prints the tag gate"
[[ ! -e "$copy/agent-bootstrap/migrations/next-zz-fixture.sh" ]] || fail "bump must rename next-* migrations"
renamed="$copy/agent-bootstrap/migrations/2099.01.01.1-zz-fixture.sh"
[[ -f "$renamed" ]] || fail "bump must create 2099.01.01.1-zz-fixture.sh"
need_contains "$(cat "$renamed")" "MIGRATION_SINCE=2099.01.01.1" "bump rewrites MIGRATION_SINCE"
need_contains "$(cat "$renamed")" "MIGRATION_ID=2099.01.01.1-zz-fixture" "bump rewrites MIGRATION_ID"
need_contains "$(cat "$copy/CHANGELOG.md")" "Migration \`2099.01.01.1-zz-fixture\`" "bump rewrites the id in the notes"
for inventory in agent-bootstrap/MANIFEST.md agent-bootstrap/install-agent-bootstrap-home.sh scripts/test-bootstrap-multi-agent-project.sh; do
  need_contains "$(cat "$copy/$inventory")" "migrations/2099.01.01.1-zz-fixture.sh" "bump renames migrations in $inventory"
  ! grep -q 'migrations/next-' "$copy/$inventory" || fail "bump left a next-* migration name in $inventory"
done
# The MANIFEST description of a released migration names its new id, without the "renamed to" note.
need_contains "$(cat "$copy/agent-bootstrap/MANIFEST.md")" "Migration \`2099.01.01.1-zz-fixture\`." "bump rewrites the MANIFEST description"
! grep -qF "Migration \`next-zz-fixture\`" "$copy/agent-bootstrap/MANIFEST.md" || fail "bump left a next-* description in MANIFEST.md"
bash "$copy/scripts/release.sh" --check-tag v2099.01.01.1 >/dev/null || fail "--check-tag must accept the bumped tree"
[[ "$(sed -n '1p' "$copy/agent-bootstrap/VERSION")" == "2099.01.01.1" ]] || fail "VERSION not bumped"
need_contains "$(bash "$copy/agent-bootstrap/bootstrap-multi-agent-project.sh" --version)" "2099.01.01.1" "entrypoint version"
need_contains "$(cat "$copy/agent-bootstrap/MANIFEST.md")" "Version: \`2099.01.01.1\`" "manifest version"
need_contains "$(cat "$copy/agent-bootstrap/harness-kit-one-shot-upgrade.sh")" 'DEFAULT_REF="v2099.01.01.1"' "one-shot default ref"
need_contains "$(cat "$copy/agent-bootstrap/harness-kit-one-shot.sh")" 'DEFAULT_REF="v2099.01.01.1"' "entry default ref"
need_contains "$(cat "$copy/agent-bootstrap/harness-kit-one-shot.sh")" "Defaults to v2099.01.01.1." "entry help pin"
cmp -s "$copy/agent-bootstrap/harness-kit-one-shot.sh" "$copy/agent-bootstrap/harness-kit-one-shot-upgrade.sh" || fail "bump must keep entry files identical"
need_contains "$(cat "$copy/README.md")" "Current release: [\`2099.01.01.1\`]" "README current release"
for doc in README.md agent-bootstrap/README.md docs/agent-configs/bootstrap-multi-agent-project/README.md; do
  need_contains "$(cat "$copy/$doc")" "harness-kit/v2099.01.01.1/agent-bootstrap/harness-kit-one-shot.sh" "$doc one-shot URL"
done
need_contains "$(cat "$copy/CHANGELOG.md")" "## 2099.01.01.1 — Test release" "changelog release heading"
grep -q '^## Unreleased' "$copy/CHANGELOG.md" && fail "changelog still has an Unreleased heading"
need_contains "$(cat "$copy/CHANGELOG.md")" "## $current" "changelog keeps older releases"
[[ "$(grep -c "$current" "$copy/docs/superpowers/specs/2026-09-12-hk07-retirement-policy-design.md" || true)" == "$historical" ]] ||
  fail "historical mentions must not be rewritten"
expect_fail "repeat bump" "is not newer" bash "$copy/scripts/release.sh" 2099.01.01.1

printf 'release-test: ok\n'
