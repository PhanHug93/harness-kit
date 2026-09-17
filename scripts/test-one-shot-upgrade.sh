#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

[[ -x "$ONE_SHOT" ]] || fail "missing executable one-shot upgrader: ${ONE_SHOT#"$ROOT_DIR"/}"
bash -n "$ONE_SHOT"
version="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION")"

help_out="$("$ONE_SHOT" --help)"
need_contains "$help_out" "Usage: harness-kit-one-shot-upgrade.sh" "one-shot help usage"
need_contains "$help_out" "--source-dir DIR" "one-shot help source-dir option"
need_contains "$help_out" "--skip-verify" "one-shot help skip-verify option"
need_contains "$help_out" "--apply-candidates" "one-shot help apply-candidates option"
need_contains "$help_out" "Defaults to v$version." "one-shot help default ref matches bundle version"

diff_fail_source="$TMP_ROOT/diff-fail-source"
diff_fail_home="$TMP_ROOT/diff-fail-home"
diff_fail_target="$TMP_ROOT/diff-fail-target"
mkdir -p "$diff_fail_source/agent-bootstrap" "$diff_fail_target"
printf '%s\n' "$version" > "$diff_fail_source/agent-bootstrap/VERSION"
cat > "$diff_fail_source/agent-bootstrap/install-agent-bootstrap-home.sh" <<'EOF_DIFF_FAIL_INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
home=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      home="${2:?missing --home value}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$home" ]] || { echo "missing --home" >&2; exit 2; }
mkdir -p "$home"
cat > "$home/bootstrap-multi-agent-project.sh" <<'EOF_FAKE_BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
target=""
action="generate"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="${2:?missing --target value}"
      shift 2
      ;;
    --status)
      action="status"
      shift
      ;;
    --upgrade-plan)
      action="upgrade-plan"
      shift
      ;;
    --diff)
      action="diff"
      shift
      ;;
    --workflow)
      shift 2
      ;;
    --json|--apply-candidates)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
case "$action" in
  status)
    printf '%s\n' '{"schema":"agent-bootstrap-status/v1","generated_file_drift":"unknown"}'
    ;;
  upgrade-plan)
    printf '%s\n' "Upgrade plan"
    ;;
  diff)
    printf '%s\n' "fixture diff failure" >&2
    exit 64
    ;;
  generate)
    mkdir -p "$target/docs/agent-configs"
    printf '%s\n' "{}" > "$target/docs/agent-configs/agent-bootstrap.lock.json"
    printf '%s\n' "Generated multi-agent files."
    ;;
esac
EOF_FAKE_BOOTSTRAP
chmod +x "$home/bootstrap-multi-agent-project.sh"
printf '%s\n' "fixture" > "$home/VERSION"
EOF_DIFF_FAIL_INSTALLER
chmod +x "$diff_fail_source/agent-bootstrap/install-agent-bootstrap-home.sh"
git -C "$diff_fail_target" init -b main >/dev/null
git -C "$diff_fail_target" config user.email "one-shot@example.invalid"
git -C "$diff_fail_target" config user.name "One Shot Test"
printf '# Diff Failure Target\n' > "$diff_fail_target/README.md"
git -C "$diff_fail_target" add README.md
git -C "$diff_fail_target" commit -m "seed diff failure target" >/dev/null
if ! diff_fail_out="$("$ONE_SHOT" \
  --source-dir "$diff_fail_source" \
  --target "$diff_fail_target" \
  --home "$diff_fail_home" \
  --branch feature/test-one-shot-diff-failure \
  --skip-verify 2>&1)"; then
  fail "one-shot should continue after informational diff failure:
$diff_fail_out"
fi
need_contains "$diff_fail_out" "WARN: generated diff preview failed; continuing" "one-shot non-fatal diff warning"
need_contains "$diff_fail_out" "Generated multi-agent files." "one-shot generated after diff failure"

home_dir="$TMP_ROOT/home"
target_dir="$TMP_ROOT/target"
mkdir -p "$target_dir"

git -C "$target_dir" init -b main >/dev/null
git -C "$target_dir" config user.email "one-shot@example.invalid"
git -C "$target_dir" config user.name "One Shot Test"
printf '# Legacy Project\n\nKeep this repo-specific overlay.\n' > "$target_dir/AGENTS.md"
git -C "$target_dir" add AGENTS.md
git -C "$target_dir" commit -m "seed legacy harness overlay" >/dev/null

if ! run_out="$("$ONE_SHOT" \
  --source-dir "$ROOT_DIR" \
  --target "$target_dir" \
  --home "$home_dir" \
  --branch feature/test-one-shot-upgrade \
  --skip-verify 2>&1)"; then
  fail "one-shot source-dir run failed:
$run_out"
fi

need_contains "$run_out" "harness-kit one-shot upgrade" "one-shot run banner"
need_contains "$run_out" "safe default: candidates were not auto-applied" "one-shot safe default"
need_contains "$run_out" "Review generated candidates before applying them" "one-shot review guidance"
need_contains "$run_out" "retrofit: wrap custom sections" "one-shot retrofit hint for pre-overlay files"
need_contains "$run_out" "workflow=full (no harness lock found)" "one-shot defaults pre-lock projects to full"

[[ "$(git -C "$target_dir" branch --show-current)" == "feature/test-one-shot-upgrade" ]] ||
  fail "one-shot did not switch target onto upgrade branch"
[[ "$(sed -n '1p' "$home_dir/VERSION")" == "$version" ]] ||
  fail "one-shot did not install expected harness version into home"
[[ -f "$target_dir/docs/agent-configs/agent-bootstrap.lock.json" ]] ||
  fail "one-shot did not generate bootstrap lock"
[[ -n "$(find "$target_dir" -name 'AGENTS.md.generated.*' -print -quit)" ]] ||
  fail "one-shot did not preserve existing AGENTS.md as a generated candidate"
need_contains "$(cat "$target_dir/AGENTS.md")" "Keep this repo-specific overlay." \
  "one-shot overwrote legacy AGENTS overlay"

status_json="$(bash "$home_dir/bootstrap-multi-agent-project.sh" --target "$target_dir" --status --json)"
need_contains "$status_json" "\"bundle_version\":\"$version\"" "one-shot status bundle version"
need_contains "$status_json" '"generated_file_drift":"stale"' "one-shot status generated drift"

# An installed infra project keeps its workflow, and the default upgrade branch
# follows the feature/<slug> convention.
infra_target_dir="$TMP_ROOT/infra-target"
mkdir -p "$infra_target_dir"
git -C "$infra_target_dir" init -b main >/dev/null
git -C "$infra_target_dir" config user.email "one-shot@example.invalid"
git -C "$infra_target_dir" config user.name "One Shot Test"
printf '# Infra Project\n' > "$infra_target_dir/README.md"
git -C "$infra_target_dir" add README.md
git -C "$infra_target_dir" commit -m "seed infra target" >/dev/null
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$infra_target_dir" --workflow infra >/dev/null
if ! infra_out="$("$ONE_SHOT" \
  --source-dir "$ROOT_DIR" \
  --target "$infra_target_dir" \
  --home "$TMP_ROOT/infra-home" \
  --allow-dirty \
  --skip-verify 2>&1)"; then
  fail "one-shot infra run failed:
$infra_out"
fi
need_contains "$infra_out" "workflow=infra (installed)" "one-shot reads the installed workflow"
need_contains "$infra_out" "generating infra workflow candidates" "one-shot keeps an infra project infra"
[[ "$(git -C "$infra_target_dir" branch --show-current)" == "feature/upgrade-harness-kit" ]] ||
  fail "one-shot default upgrade branch must be feature/upgrade-harness-kit"
python3 - "$infra_target_dir/docs/agent-configs/agent-bootstrap.lock.json" <<'PY' ||
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["templates"]["workflow_preset"] == "infra" else 1)
PY
  fail "one-shot must not convert an infra project to full"

source_repo="$TMP_ROOT/source-repo"
cache_dir="$TMP_ROOT/cache"
clone_home_dir="$TMP_ROOT/clone-home"
clone_target_dir="$TMP_ROOT/clone-target"
mkdir -p "$source_repo" "$clone_target_dir"
cp -R "$ROOT_DIR/agent-bootstrap" "$source_repo/agent-bootstrap"
git -C "$source_repo" init -b main >/dev/null
git -C "$source_repo" config user.email "one-shot@example.invalid"
git -C "$source_repo" config user.name "One Shot Test"
git -C "$source_repo" add agent-bootstrap
git -C "$source_repo" commit -m "fixture harness release" >/dev/null
git -C "$source_repo" tag "v$version"

git -C "$clone_target_dir" init -b main >/dev/null
git -C "$clone_target_dir" config user.email "one-shot@example.invalid"
git -C "$clone_target_dir" config user.name "One Shot Test"
printf '# Clone Path Project\n' > "$clone_target_dir/README.md"
git -C "$clone_target_dir" add README.md
git -C "$clone_target_dir" commit -m "seed clone path target" >/dev/null

if ! clone_out="$("$ONE_SHOT" \
  --repo "$source_repo" \
  --ref "v$version" \
  --cache-dir "$cache_dir" \
  --target "$clone_target_dir" \
  --home "$clone_home_dir" \
  --branch feature/test-one-shot-clone \
  --skip-verify 2>&1)"; then
  fail "one-shot clone/cache run failed:
$clone_out"
fi

need_contains "$clone_out" "cloning source cache" "one-shot clone path"
need_contains "$clone_out" "safe default: candidates were not auto-applied" "one-shot clone safe default"
[[ "$(git -C "$clone_target_dir" branch --show-current)" == "feature/test-one-shot-clone" ]] ||
  fail "one-shot clone path did not switch target onto upgrade branch"
[[ "$(sed -n '1p' "$clone_home_dir/VERSION")" == "$version" ]] ||
  fail "one-shot clone path did not install expected harness version"

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
