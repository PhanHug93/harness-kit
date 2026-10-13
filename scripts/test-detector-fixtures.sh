#!/usr/bin/env bash
set -euo pipefail

# Detector fixtures from the 2026.10.13.1 Android + Wear OS report: the wear
# compile command follows the module's product flavor, and sensitive-file
# warnings fire from presence alone (the files are never read).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detector-fixtures-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'chmod -R u+rw "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'detector-fixtures-test: FAIL: %s\n' "$*" >&2
  exit 1
}

android_project() {
  local root="$1" modules="$2" module
  mkdir -p "$root"
  printf 'include(%s)\n' "$modules" > "$root/settings.gradle.kts"
  for module in app wear wear-api; do
    [[ "$modules" == *"\":$module\""* ]] || continue
    mkdir -p "$root/$module/src/main"
    printf '<manifest/>\n' > "$root/$module/src/main/AndroidManifest.xml"
    printf 'plugins { id("com.android.application") }\nandroid { }\n' > "$root/$module/build.gradle.kts"
  done
}

detect() {
  (
    # shellcheck source=/dev/null
    source "$ROOT_DIR/agent-bootstrap/agent-tech-stack-lib.sh"
    agent_detect_tech_stack "$1"
    printf 'commands=%s\n' "${AGENT_VERIFY_COMMANDS[*]:-}"
    printf 'warnings=%s\n' "${AGENT_WARNINGS[*]:-}"
  )
}

flavored="$TMP_ROOT/flavored"
android_project "$flavored" '":app", ":wear"'
printf 'plugins { id("com.android.application") }\nandroid { productFlavors { create("prod") } }\n' \
  > "$flavored/wear/build.gradle.kts"
out="$(detect "$flavored")"
[[ "$out" == *"./gradlew :wear:compileProdDebugKotlin"* ]] || fail "flavored wear needs compileProdDebugKotlin: $out"
[[ "$out" != *":wear:compileDebugKotlin"* ]] || fail "flavored wear must not get the ambiguous compileDebugKotlin: $out"

plain="$TMP_ROOT/plain"
android_project "$plain" '":app", ":wear"'
out="$(detect "$plain")"
[[ "$out" == *"./gradlew :wear:compileDebugKotlin"* ]] || fail "unflavored wear needs compileDebugKotlin: $out"

api_only="$TMP_ROOT/api-only"
android_project "$api_only" '":app", ":wear-api"'
out="$(detect "$api_only")"
[[ "$out" != *":wear:compile"* ]] || fail "wear-api alone must not emit a :wear: command: $out"

# wear/ without Gradle settings: no :wear: task, but the list is never empty.
bare_wear="$TMP_ROOT/bare-wear"
mkdir -p "$bare_wear/wear/src"
out="$(detect "$bare_wear")"
[[ "$out" != *":wear:compile"* ]] || fail "wear/ without a :wear module must not emit a :wear: command: $out"
[[ "$out" == *"commands=Add project-specific build/test commands"* ]] || fail "empty command list needs the pointer: $out"

sensitive="$TMP_ROOT/sensitive"
android_project "$sensitive" '":app"'
printf 'sdk.dir=/secret\n' > "$sensitive/local.properties"
printf 'storePassword=secret\n' > "$sensitive/keystore.properties"
chmod 000 "$sensitive/local.properties" "$sensitive/keystore.properties"
out="$(detect "$sensitive" 2>&1)"
[[ "$out" == *"local.properties exists and must remain local-only."* ]] || fail "local.properties warning missing: $out"
[[ "$out" == *"keystore.properties exists; never print or commit secrets."* ]] || fail "keystore.properties warning missing: $out"
[[ "$out" != *"Permission denied"* ]] || fail "sensitive files must not be opened: $out"

printf 'detector-fixtures-test: ok\n'
