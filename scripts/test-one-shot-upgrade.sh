#!/usr/bin/env bash
set -euo pipefail

# Full tier: the one-shot entry script (harness-kit-one-shot.sh and its
# byte-identical old name harness-kit-one-shot-upgrade.sh) driving the
# orchestrator on real projects, offline (--source-dir) and through the clone
# path, with the old flags; then the historical migration selectors and the
# HK-07 one-shot retirement boundaries.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENTRY="$ROOT_DIR/agent-bootstrap/harness-kit-one-shot.sh"
ONE_SHOT="$ROOT_DIR/agent-bootstrap/harness-kit-one-shot-upgrade.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "one-shot-upgrade-test: FAIL: $*" >&2
  exit 1
}

need_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label missing '$needle'" ;;
  esac
}

new_target() { # a repository on main with one commit
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email "one-shot@example.invalid"
  git -C "$1" config user.name "One Shot Test"
  printf '# %s\n' "$(basename "$1")" >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -qm "seed $(basename "$1")"
}

for script in "$ENTRY" "$ONE_SHOT"; do
  [[ -x "$script" ]] || fail "missing executable entry script: ${script#"$ROOT_DIR"/}"
  bash -n "$script"
done
cmp -s "$ENTRY" "$ONE_SHOT" || fail "harness-kit-one-shot-upgrade.sh must be a byte-identical copy of harness-kit-one-shot.sh"
version="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION")"

help_out="$("$ENTRY" --help)"
need_contains "$help_out" "Usage: harness-kit-one-shot.sh" "entry help usage"
need_contains "$help_out" "--to VERSION|latest" "entry help --to"
need_contains "$help_out" "--source-dir DIR" "entry help --source-dir"
need_contains "$help_out" "Defaults to v$version." "entry help default version matches the bundle"
run_help="$(bash "$ROOT_DIR/agent-bootstrap/harness-kit-run.sh" --help)"
need_contains "$run_help" "--take-kit PATH|all" "orchestrator help --take-kit"
need_contains "$run_help" "--skip-verify" "orchestrator help --skip-verify"
need_contains "$run_help" "--apply-retirements" "orchestrator help old flags"

# A legacy project with a hand-written AGENTS.md, through the old entry name:
# the run keeps AGENTS.md, writes a kit candidate beside it and ends needs
# review; no branch is created and git status shows no harness file.
target_dir="$TMP_ROOT/target"
new_target "$target_dir"
printf '# Legacy Project\n\nKeep this repo-specific overlay.\n' >"$target_dir/AGENTS.md"
git -C "$target_dir" add AGENTS.md
git -C "$target_dir" commit -qm "seed legacy harness overlay"
run_rc=0
run_out="$("$ONE_SHOT" --source-dir "$ROOT_DIR" --target "$target_dir" --skip-verify 2>&1)" || run_rc=$?
[[ "$run_rc" -eq 3 ]] || fail "legacy AGENTS.md run must end needs review (exit 3), got $run_rc:
$run_out"
need_contains "$run_out" "mode: install $version" "legacy run mode line"
need_contains "$run_out" "RESULT: needs review" "legacy run result"
need_contains "$(cat "$target_dir/AGENTS.md")" "Keep this repo-specific overlay." "legacy AGENTS.md overwritten"
[[ -n "$(find "$target_dir" -maxdepth 1 -name 'AGENTS.md.generated.*' -print -quit)" ]] ||
  fail "the run did not write a kit candidate beside AGENTS.md"
[[ -f "$target_dir/docs/agent-configs/agent-bootstrap.lock.json" ]] || fail "the run did not generate the lock"
[[ "$(git -C "$target_dir" branch --format='%(refname:short)')" == "main" ]] || fail "the run created or switched a branch"
[[ -z "$(git -C "$target_dir" status --porcelain)" ]] ||
  fail "git status must show no harness file: $(git -C "$target_dir" status --porcelain)"

# An installed infra project keeps --workflow infra; --branch creates the branch.
infra_target_dir="$TMP_ROOT/infra-target"
new_target "$infra_target_dir"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$infra_target_dir" --workflow infra >/dev/null
infra_rc=0
infra_out="$("$ENTRY" --source-dir "$ROOT_DIR" --target "$infra_target_dir" --skip-verify --branch feature/x 2>&1)" ||
  infra_rc=$?
[[ "$infra_rc" -eq 0 ]] || fail "infra reinstall failed ($infra_rc):
$infra_out"
need_contains "$infra_out" "mode: reinstall $version" "infra run mode line"
[[ "$(git -C "$infra_target_dir" branch --show-current)" == "feature/x" ]] || fail "--branch feature/x must create and switch to the branch"
python3 -I -B - "$infra_target_dir/docs/agent-configs/agent-bootstrap.lock.json" <<'PY' ||
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["templates"]["workflow_preset"] == "infra" else 1)
PY
  fail "the one-shot must not convert an infra project to full"

# Old flags are accepted with their notes (--dry-run is --plan, so nothing is
# applied and --apply-retirements is ignored).
old_home="$TMP_ROOT/old-home"
old_cache="$TMP_ROOT/old-cache"
old_rc=0
old_out="$("$ONE_SHOT" --source-dir "$ROOT_DIR" --target "$infra_target_dir" --no-branch --allow-dirty \
  --apply-candidates --apply-retirements --skip-verify --home "$old_home" --cache-dir "$old_cache" --dry-run 2>&1)" ||
  old_rc=$?
[[ "$old_rc" -eq 0 ]] || fail "old flags run failed ($old_rc):
$old_out"
for old_note in "--no-branch is now the default" "--allow-dirty is now the default" \
  "--apply-candidates is replaced by --take-kit" "--apply-retirements is ignored with --plan" \
  "--home is no longer used" "--cache-dir is no longer used" "--dry-run now means --plan"; do
  need_contains "$old_out" "note: $old_note" "old flag note"
done
need_contains "$old_out" "RESULT: done (plan only, nothing applied)" "old --dry-run is a plan"
[[ ! -e "$old_home" && ! -e "$old_cache" ]] || fail "--home and --cache-dir must not create anything"

# The clone path: --repo <local repo tagged v$version> --ref v$version.
source_repo="$TMP_ROOT/source-repo"
clone_target_dir="$TMP_ROOT/clone-target"
mkdir -p "$source_repo"
cp -R "$ROOT_DIR/agent-bootstrap" "$source_repo/agent-bootstrap"
git -C "$source_repo" init -q
git -C "$source_repo" config user.email "one-shot@example.invalid"
git -C "$source_repo" config user.name "One Shot Test"
git -C "$source_repo" add agent-bootstrap
git -C "$source_repo" commit -qm "fixture harness release"
git -C "$source_repo" tag "v$version"
new_target "$clone_target_dir"
clone_rc=0
clone_out="$("$ENTRY" --repo "$source_repo" --ref "v$version" --target "$clone_target_dir" --skip-verify 2>&1)" ||
  clone_rc=$?
[[ "$clone_rc" -eq 0 ]] || fail "clone path run failed ($clone_rc):
$clone_out"
need_contains "$clone_out" "mode: install $version" "clone path mode line"
[[ "$(sed -n '1p' "$clone_target_dir/.harness-kit/v$version/agent-bootstrap/VERSION")" == "$version" ]] ||
  fail "the clone path must keep the kit copy in .harness-kit/v$version/"
[[ "$(git -C "$clone_target_dir" branch --show-current)" == "main" && -z "$(git -C "$clone_target_dir" status --porcelain)" ]] ||
  fail "the clone path run must stay on main with a clean status"

# Historical selector and archive-boundary negatives are disposable and fail
# before migration generation, so corrupt or missing history cannot be skipped.
make_migration_negative_source() {
  local name="$1"
  local source="$TMP_ROOT/migration-negative-$name"
  mkdir -p "$source/scripts/fixtures"
  cp -R "$ROOT_DIR/agent-bootstrap" "$source/"
  cp "$ROOT_DIR/scripts/test-agent-seats-migration.py" "$source/scripts/"
  cp -R "$ROOT_DIR/scripts/fixtures/historical-bundles" "$source/scripts/fixtures/"
  printf '%s\n' "$source"
}

run_migration_negative() {
  local label="$1"
  local source="$2"
  local needle="$3"
  shift 3
  local output expected_rc=1 rc=0
  [[ "$label" == "unknown ref" ]] && expected_rc=2
  if output="$(python3 "$source/scripts/test-agent-seats-migration.py" --source-dir "$source" --historical-source fixtures "$@" 2>&1)"; then
    fail "migration negative $label unexpectedly passed"
  else
    rc=$?
    [[ "$rc" -eq "$expected_rc" ]] || fail "migration negative $label expected rc=$expected_rc, got $rc"
  fi
  need_contains "$output" "$needle" "migration negative $label"
}

unknown_source="$(make_migration_negative_source unknown-ref)"
run_migration_negative "unknown ref" "$unknown_source" "unsupported historical ref(s)" --legacy-ref v2026.99.99
duplicate_source="$(make_migration_negative_source duplicate-ref)"
duplicate_git="$TMP_ROOT/duplicate-ref-git"
duplicate_git_calls="$TMP_ROOT/duplicate-ref-git.calls"
mkdir -p "$duplicate_git"
cat > "$duplicate_git/git" <<'EOF_DUPLICATE_REF_GIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DUPLICATE_REF_GIT_CALLS:?}"
exit 1
EOF_DUPLICATE_REF_GIT
chmod +x "$duplicate_git/git"
if duplicate_output="$(PATH="$duplicate_git:$PATH" DUPLICATE_REF_GIT_CALLS="$duplicate_git_calls" python3 "$duplicate_source/scripts/test-agent-seats-migration.py" --source-dir "$duplicate_source" --historical-source tags --legacy-ref v2026.08.10.1 --legacy-ref v2026.08.10.1 2>&1)"; then
  fail "duplicate historical refs unexpectedly passed without history"
else
  negative_rc=$?
  [[ "$negative_rc" -eq 1 ]] || fail "historical refusal expected rc=1, got $negative_rc"
fi
need_contains "$duplicate_output" "required historical tag is missing" "duplicate ref missing-history refusal"
[[ "$(wc -l <"$duplicate_git_calls" | tr -d ' ')" == "1" ]] || fail "duplicate ref was not deduplicated before history lookup"
tags_source="$(make_migration_negative_source missing-tags)"
if tags_output="$(python3 "$tags_source/scripts/test-agent-seats-migration.py" --source-dir "$tags_source" --historical-source tags --legacy-ref v2026.08.10.1 2>&1)"; then
  fail "forced tags source unexpectedly passed without pinned history"
else
  negative_rc=$?
  [[ "$negative_rc" -eq 1 ]] || fail "historical refusal expected rc=1, got $negative_rc"
fi
need_contains "$tags_output" "required historical tag is missing" "forced tags missing-history refusal"
# Build an independent Git repository so a worktree .git file cannot redirect
# the partial-history mutation back into the source repository.
partial_auto_repo="$TMP_ROOT/migration-negative-partial-auto-repo"
source_refs_before="$(git -C "$ROOT_DIR" for-each-ref --format='%(refname) %(objectname)')"
git clone --no-local "$ROOT_DIR" "$partial_auto_repo" >/dev/null
[[ -d "$partial_auto_repo/.git" ]] || fail "partial history needs independent Git metadata"
cp -R "$ROOT_DIR/agent-bootstrap/." "$partial_auto_repo/agent-bootstrap/"
cp "$ROOT_DIR/scripts/test-agent-seats-migration.py" "$partial_auto_repo/scripts/"
mkdir -p "$partial_auto_repo/scripts/fixtures/historical-bundles"
cp -R "$ROOT_DIR/scripts/fixtures/historical-bundles/." "$partial_auto_repo/scripts/fixtures/historical-bundles/"
partial_auto_source="$partial_auto_repo"
git -C "$partial_auto_source" update-ref -d refs/tags/v2026.09.07.1
partial_auto_evidence="$TMP_ROOT/partial-auto-evidence"
if ! partial_auto_output="$(HARNESS_MIGRATION_HISTORICAL_SOURCE=tags python3 \
  - \
  "$partial_auto_source/scripts/test-agent-seats-migration.py" \
  "$partial_auto_source" "$partial_auto_evidence" 2>&1 <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
from unittest.mock import patch

script = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve()
evidence = Path(sys.argv[3]).resolve()
argv = [
    "--source-dir", str(source),
    "--historical-source", "auto",
    "--evidence-dir", str(evidence),
    "--legacy-ref", "v2026.08.10.1",
    "--legacy-ref", "v2026.09.07.1",
]
spec = importlib.util.spec_from_file_location("migration_selector", script)
migration = importlib.util.module_from_spec(spec)
# Consumer arguments and environment must not start the CLI or fixtures.
with patch.object(sys, "argv", ["consumer", "--unrelated-option"]), \
        patch("tempfile.mkdtemp", side_effect=AssertionError("import created fixture")), \
        patch("subprocess.run", side_effect=AssertionError("import ran subprocess")):
    spec.loader.exec_module(migration)
assert not evidence.exists(), "import created evidence"
migration.configure(argv)

expected = [
    ("v2026.08.10.1", "tags", "b1907f5fe7caf9d9e401606a93fa0815739b6df0"),
    ("v2026.09.07.1", "fixtures", "cf8f326b61788ed3ed8577eb12511613303dc44a"),
]
checks = []
for ref, expected_source, expected_commit in expected:
    before = len(migration.historical_provenance)
    destination = migration.historical_export(ref)
    provenance = migration.historical_provenance[before:]
    ok = (
        destination.is_dir()
        and (destination / "agent-bootstrap").is_dir()
        and provenance == [{"ref": ref, "source": expected_source, "commit": expected_commit}]
    )
    checks.append({"ref": ref, "expected_source": expected_source, "ok": ok, "provenance": provenance})
    assert ok, checks[-1]

(evidence / "selector-summary.json").write_text(json.dumps({
    "historical_source": migration.HISTORICAL_SOURCE,
    "historical_provenance": migration.historical_provenance,
    "checks": checks,
}, indent=2) + "\n", encoding="utf-8")
assert migration.HISTORICAL_SOURCE == "auto"
assert all(item["ok"] for item in checks)
PY
)"; then
  fail "auto partial-tags source did not use mixed tag/fixture history:
$partial_auto_output"
fi
[[ "$(git -C "$ROOT_DIR" for-each-ref --format='%(refname) %(objectname)')" == "$source_refs_before" ]] || fail "partial history fixture changed source refs"
need_contains "$partial_auto_output" "HISTORICAL ref=v2026.08.10.1 source=tags commit=b1907f5fe7caf9d9e401606a93fa0815739b6df0" "auto partial-tags present ref provenance"
need_contains "$partial_auto_output" "HISTORICAL ref=v2026.09.07.1 source=fixtures commit=cf8f326b61788ed3ed8577eb12511613303dc44a" "auto partial-tags missing ref provenance"
python3 - "$partial_auto_evidence/selector-summary.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
assert summary["historical_source"] == "auto", summary
assert summary["historical_provenance"] == [
    {"ref": "v2026.08.10.1", "source": "tags", "commit": "b1907f5fe7caf9d9e401606a93fa0815739b6df0"},
    {"ref": "v2026.09.07.1", "source": "fixtures", "commit": "cf8f326b61788ed3ed8577eb12511613303dc44a"},
], summary
assert summary["checks"] and all(item["ok"] for item in summary["checks"]), summary
PY

unexpected_tag_source="$(make_migration_negative_source unexpected-tag)"
git -C "$unexpected_tag_source" init -q
git -C "$unexpected_tag_source" config user.email "migration-negative@example.invalid"
git -C "$unexpected_tag_source" config user.name "Migration Negative"
git -C "$unexpected_tag_source" add agent-bootstrap
git -C "$unexpected_tag_source" commit -qm "wrong historical tag"
git -C "$unexpected_tag_source" tag v2026.08.10.1
if unexpected_tag_output="$(python3 "$unexpected_tag_source/scripts/test-agent-seats-migration.py" --source-dir "$unexpected_tag_source" --historical-source tags --legacy-ref v2026.08.10.1 2>&1)"; then
  fail "unexpected historical tag commit unexpectedly passed"
else
  negative_rc=$?
  [[ "$negative_rc" -eq 1 ]] || fail "historical refusal expected rc=1, got $negative_rc"
fi
need_contains "$unexpected_tag_output" "resolves to" "unexpected historical tag commit refusal"

forced_fixture_source="$(make_migration_negative_source forced-fixtures)"
forced_fixture_missing="$forced_fixture_source/scripts/fixtures/historical-bundles/manifest.json"
python3 - "$forced_fixture_missing" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
doc["fixtures"]["v2026.08.10.1"]["archive"] = "missing.tar"
path.write_text(json.dumps(doc) + "\n")
PY
forced_fixture_git="$TMP_ROOT/forced-fixture-git"
mkdir -p "$forced_fixture_git"
forced_fixture_git_marker="$TMP_ROOT/forced-fixture-git.called"
cat > "$forced_fixture_git/git" <<'EOF_FORCED_FIXTURE_GIT'
#!/usr/bin/env bash
printf '%s\n' called > "${FORCED_FIXTURE_GIT_MARKER:?}"
exit 97
EOF_FORCED_FIXTURE_GIT
chmod +x "$forced_fixture_git/git"
if forced_fixture_output="$(PATH="$forced_fixture_git:$PATH" FORCED_FIXTURE_GIT_MARKER="$forced_fixture_git_marker" python3 "$forced_fixture_source/scripts/test-agent-seats-migration.py" --source-dir "$forced_fixture_source" --historical-source fixtures --legacy-ref v2026.08.10.1 2>&1)"; then
  fail "forced fixtures source unexpectedly passed with a missing archive"
else
  negative_rc=$?
  [[ "$negative_rc" -eq 1 ]] || fail "historical refusal expected rc=1, got $negative_rc"
fi
need_contains "$forced_fixture_output" "historical fixture archive is missing" "forced fixtures missing archive refusal"
[[ ! -e "$forced_fixture_git_marker" ]] || fail "forced fixtures unexpectedly consulted Git history"

export_failure_source="$(make_migration_negative_source export-failure)"
export_failure_git="$TMP_ROOT/export-failure-git"
mkdir -p "$export_failure_git"
cat > "$export_failure_git/git" <<'EOF_EXPORT_FAILURE_GIT'
#!/usr/bin/env bash
case "${1:-}" in
  rev-parse) printf '%s\n' b1907f5fe7caf9d9e401606a93fa0815739b6df0; exit 0 ;;
  archive) exit 42 ;;
  *) exit 43 ;;
esac
EOF_EXPORT_FAILURE_GIT
chmod +x "$export_failure_git/git"
if export_failure_output="$(PATH="$export_failure_git:$PATH" python3 "$export_failure_source/scripts/test-agent-seats-migration.py" --source-dir "$export_failure_source" --historical-source tags --legacy-ref v2026.08.10.1 2>&1)"; then
  fail "historical export failure unexpectedly passed"
else
  negative_rc=$?
  [[ "$negative_rc" -eq 1 ]] || fail "historical refusal expected rc=1, got $negative_rc"
fi
need_contains "$export_failure_output" "historical tag export failed" "historical export failure refusal"

missing_manifest_source="$(make_migration_negative_source missing-manifest)"
python3 - "$missing_manifest_source/scripts/fixtures/historical-bundles/manifest.json" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).unlink()
PY
run_migration_negative "missing manifest" "$missing_manifest_source" "historical fixture manifest is missing"

missing_archive_source="$(make_migration_negative_source missing-archive)"
python3 - "$missing_archive_source/scripts/fixtures/historical-bundles/manifest.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
doc["fixtures"]["v2026.08.10.1"]["archive"] = "missing.tar"
path.write_text(json.dumps(doc) + "\n")
PY
run_migration_negative "missing archive" "$missing_archive_source" "historical fixture archive is missing" --legacy-ref v2026.08.10.1

corrupt_archive_source="$(make_migration_negative_source corrupt-archive)"
python3 - "$corrupt_archive_source/scripts/fixtures/historical-bundles/v2026.08.10.1.tar" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[123] ^= 0x01
path.write_bytes(data)
PY
run_migration_negative "corrupt archive" "$corrupt_archive_source" "historical archive digest/size mismatch" --legacy-ref v2026.08.10.1

for archive_case in prefix-member unexpected-directory unexpected-file duplicate-member special-member; do
  archive_source="$(make_migration_negative_source "$archive_case")"
  python3 - "$archive_source/scripts/fixtures/historical-bundles/manifest.json" "$archive_source/scripts/fixtures/historical-bundles/v2026.08.10.1.tar" "$archive_case" <<'PY'
import hashlib
import io
import json
import pathlib
import sys
import tarfile

manifest_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
case = sys.argv[3]
source = archive_path.read_bytes()
out = io.BytesIO()
with tarfile.open(fileobj=io.BytesIO(source), mode="r:") as src, tarfile.open(fileobj=out, mode="w") as dst:
    members = src.getmembers()
    for member in members:
        dst.addfile(member, src.extractfile(member) if member.isfile() else None)
    if case == "prefix-member":
        info = tarfile.TarInfo("prefix/agent-bootstrap/extra")
        info.size = 1
        dst.addfile(info, io.BytesIO(b"x"))
    elif case == "unexpected-directory":
        info = tarfile.TarInfo("agent-bootstrap/unlisted-empty")
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        dst.addfile(info)
    elif case == "unexpected-file":
        info = tarfile.TarInfo("agent-bootstrap/unlisted-file")
        info.size = 1
        dst.addfile(info, io.BytesIO(b"x"))
    elif case == "duplicate-member":
        member = next(item for item in members if item.isfile())
        dst.addfile(member, io.BytesIO(src.extractfile(member).read()))
    elif case == "special-member":
        info = tarfile.TarInfo("agent-bootstrap/unlisted-device")
        info.type = tarfile.CHRTYPE
        info.devmajor = 1
        info.devminor = 3
        dst.addfile(info)
archive = out.getvalue()
archive_path.write_bytes(archive)
doc = json.loads(manifest_path.read_text())
entry = doc["fixtures"]["v2026.08.10.1"]
entry["archive_bytes"] = len(archive)
entry["archive_sha256"] = hashlib.sha256(archive).hexdigest()
manifest_path.write_text(json.dumps(doc) + "\n")
PY
  case "$archive_case" in
    prefix-member) archive_needle="archive member outside agent-bootstrap" ;;
    unexpected-directory) archive_needle="unexpected archive directory" ;;
    unexpected-file) archive_needle="unexpected archive file" ;;
    duplicate-member) archive_needle="duplicate archive member" ;;
    special-member) archive_needle="unsupported archive member type" ;;
  esac
  run_migration_negative "$archive_case" "$archive_source" "$archive_needle" --legacy-ref v2026.08.10.1
done

HARNESS_MIGRATION_HISTORICAL_SOURCE="${HARNESS_MIGRATION_HISTORICAL_SOURCE-auto}" \
  python3 "$ROOT_DIR/scripts/test-agent-seats-migration.py"

# HK-07 one-shot retirement boundaries: default/explicit flags and exit propagation.
python3 "$ROOT_DIR/scripts/test-agent-retirement.py" --tier one-shot

echo "one-shot-upgrade-test: ok ($TMP_ROOT)"
