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

help_out="$("$ONE_SHOT" --help)"
need_contains "$help_out" "Usage: harness-kit-one-shot-upgrade.sh" "one-shot help usage"
need_contains "$help_out" "--source-dir DIR" "one-shot help source-dir option"
need_contains "$help_out" "--skip-verify" "one-shot help skip-verify option"
need_contains "$help_out" "--apply-candidates" "one-shot help apply-candidates option"

version="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION")"
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
  --branch codex/test-one-shot-upgrade \
  --skip-verify 2>&1)"; then
  fail "one-shot source-dir run failed:
$run_out"
fi

need_contains "$run_out" "harness-kit one-shot upgrade" "one-shot run banner"
need_contains "$run_out" "safe default: candidates were not auto-applied" "one-shot safe default"
need_contains "$run_out" "Review generated candidates before applying them" "one-shot review guidance"

[[ "$(git -C "$target_dir" branch --show-current)" == "codex/test-one-shot-upgrade" ]] ||
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
  --branch codex/test-one-shot-clone \
  --skip-verify 2>&1)"; then
  fail "one-shot clone/cache run failed:
$clone_out"
fi

need_contains "$clone_out" "cloning source cache" "one-shot clone path"
need_contains "$clone_out" "safe default: candidates were not auto-applied" "one-shot clone safe default"
[[ "$(git -C "$clone_target_dir" branch --show-current)" == "codex/test-one-shot-clone" ]] ||
  fail "one-shot clone path did not switch target onto upgrade branch"
[[ "$(sed -n '1p' "$clone_home_dir/VERSION")" == "$version" ]] ||
  fail "one-shot clone path did not install expected harness version"

echo "one-shot-upgrade-test: ok ($TMP_ROOT)"
