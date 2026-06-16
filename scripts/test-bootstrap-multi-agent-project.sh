#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh"
HOME_INSTALLER="$ROOT_DIR/scripts/install-agent-bootstrap-home.sh"
ONBOARDING_EVAL="$ROOT_DIR/scripts/test-onboarding-fixtures.sh"
BOOTSTRAP_BUNDLE="$ROOT_DIR/agent-bootstrap"
SHARED_LIB="$ROOT_DIR/agent-bootstrap/agent-tech-stack-lib.sh"
TMP_DIR="$(mktemp -d)"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/out"

fail() {
  echo "bootstrap-test: FAIL: $*" >&2
  exit 1
}

need_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$label missing '$needle' in: $haystack"
  fi
}

need_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$label unexpectedly contained '$needle' in: $haystack"
  fi
}

need_same_file() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  cmp -s "$expected" "$actual" || fail "$label drifted from ${expected#"$ROOT_DIR"/}"
}

estimate_tokens_for_file() {
  local file="$1"
  local words
  local chars
  read -r words chars < <(wc -w -c < "$file")
  awk -v words="$words" -v chars="$chars" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

[[ -x "$BOOTSTRAP" ]] || fail "missing executable bootstrap script: ${BOOTSTRAP#"$ROOT_DIR"/}"
[[ -x "$HOME_INSTALLER" ]] || fail "missing executable home installer: ${HOME_INSTALLER#"$ROOT_DIR"/}"
[[ -x "$ONBOARDING_EVAL" ]] || fail "missing executable onboarding fixture eval: ${ONBOARDING_EVAL#"$ROOT_DIR"/}"
[[ -x "$BOOTSTRAP_BUNDLE/bootstrap-multi-agent-project.sh" ]] || fail "missing bundled bootstrap script"
[[ -x "$BOOTSTRAP_BUNDLE/install-agent-bootstrap-home.sh" ]] || fail "missing bundled home installer"
[[ -f "$BOOTSTRAP_BUNDLE/VERSION" ]] || fail "missing bundled VERSION"
[[ -f "$BOOTSTRAP_BUNDLE/MANIFEST.md" ]] || fail "missing bundled MANIFEST.md"
bash -n "$BOOTSTRAP"
bash -n "$HOME_INSTALLER"
bash -n "$ONBOARDING_EVAL"
bash -n "$BOOTSTRAP_BUNDLE/bootstrap-multi-agent-project.sh"
bash -n "$BOOTSTRAP_BUNDLE/install-agent-bootstrap-home.sh"
need_contains "$(cat "$ROOT_DIR/.github/workflows/test.yml")" "Run generated target verifier" "CI generated target verifier gate"
need_contains "$(cat "$ROOT_DIR/.github/workflows/test.yml")" "Install shellcheck on Ubuntu" "CI deterministic Ubuntu shellcheck install"
need_contains "$(cat "$ROOT_DIR/.github/workflows/test.yml")" "Run shellcheck if available" "CI shellcheck gate"
need_contains "$(cat "$ROOT_DIR/.github/workflows/test.yml")" "agent-bootstrap/bootstrap-multi-agent-project.sh" "CI shellcheck bundle entrypoint coverage"
need_contains "$(cat "$ROOT_DIR/.github/workflows/test.yml")" "Run shellcheck on generated target if available" "CI shellcheck generated target coverage"
design_doc="$(cat "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/README.md")"
need_contains "$design_doc" "model-profiles/" "design doc bundle model profile directory"
need_contains "$design_doc" "schemas/" "design doc bundle schema directory"
need_contains "$design_doc" "templates/" "design doc bundle template directory"
need_contains "$design_doc" "provenance/" "design doc bundle provenance directory"
need_contains "$design_doc" "agent-init --apply-candidates" "design doc candidate apply lifecycle"
need_contains "$design_doc" "scripts/test-onboarding-fixtures.sh" "design doc onboarding fixture validation"
need_contains "$design_doc" "agent-guard.sh" "design doc agent guard runtime"
need_contains "$design_doc" "context-policy.json" "design doc context policy contract"
need_contains "$(cat "$ROOT_DIR/README.md")" "multi-agent harness kit" "root README harness kit positioning"

for root_runtime_snapshot in \
  agent-hook.sh \
  agent-guard.sh \
  agent-onboarding.sh \
  agent-tech-stack-lib.sh \
  detect-agent-tech-stack.sh \
  install-rtk.sh \
  rtk \
  verify-ai-deps.sh; do
  [[ ! -e "$ROOT_DIR/scripts/$root_runtime_snapshot" ]] ||
    fail "root scripts must not carry generated runtime snapshots: scripts/$root_runtime_snapshot"
done

bash "$ONBOARDING_EVAL" >"$TMP_DIR"/out/onboarding-fixtures.out
need_contains "$(cat "$TMP_DIR/out/onboarding-fixtures.out")" "onboarding-fixtures: ok" "onboarding fixture eval"
need_contains "$(cat "$TMP_DIR/out/onboarding-fixtures.out")" "filled golden contracts: 3" "onboarding fixture filled contract eval"

need_not_contains \
  "$(cat "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md")" \
  "--workflow three-mode" \
  "source three-mode template"

bootstrap_version="$("$BOOTSTRAP" --version)"
bundle_version="$(sed -n '1p' "$BOOTSTRAP_BUNDLE/VERSION")"
need_contains "$bootstrap_version" "bootstrap-multi-agent-project" "bootstrap version"
need_contains "$bootstrap_version" "$bundle_version" "bootstrap version file"
need_not_contains "$bootstrap_version" "payload-sha256=" "solo bootstrap version"

CANONICAL_DIR="$FIXTURE_DIR/agent-bootstrap"
AGENT_BOOTSTRAP_HOME="$CANONICAL_DIR" "$HOME_INSTALLER" --no-git >"$TMP_DIR"/out/bootstrap-home-install.out
[[ -x "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" ]] || fail "canonical installer did not export bootstrap script"
[[ -x "$CANONICAL_DIR/agent-hook.sh" ]] || fail "canonical installer did not export agent hook snapshot"
[[ -x "$CANONICAL_DIR/agent-onboarding.sh" ]] || fail "canonical installer did not export agent onboarding snapshot"
[[ -x "$CANONICAL_DIR/verify-ai-deps.sh" ]] || fail "canonical installer did not export verifier snapshot"
[[ -f "$CANONICAL_DIR/VERSION" ]] || fail "canonical installer did not export VERSION"
[[ -f "$CANONICAL_DIR/MANIFEST.md" ]] || fail "canonical installer did not export MANIFEST.md"
for canonical_file in \
  README.md \
  VERSION \
  MANIFEST.md \
  bootstrap-multi-agent-project.sh \
  agent-tech-stack-lib.sh \
  agent-hook.sh \
  agent-guard.sh \
  agent-onboarding.sh \
  detect-agent-tech-stack.sh \
  install-rtk.sh \
  rtk \
  verify-ai-deps.sh \
  model-profiles/codex-model-profiles.json \
  policies/agent-context-policy.json \
  provenance/rtk-v0.37.2.sha256 \
  schemas/agent-context-policy-v1.schema.json \
  schemas/agent-model-profiles-v1.schema.json \
  schemas/agent-project-tech-stack-v1.schema.json \
  schemas/agent-bootstrap-lock-v1.schema.json \
  schemas/agent-bootstrap-status-v1.schema.json \
  schemas/agent-bootstrap-verify-report-v1.schema.json \
  templates/base/README.md \
  templates/overlays/android_kotlin.md \
  templates/overlays/generic.md \
  templates/overlays/ios_swift.md \
  templates/overlays/node_js.md \
  templates/overlays/python.md \
  templates/workflows/council/README.md \
  templates/workflows/karpathy/README.md \
  templates/workflows/three-mode/README.md \
  lib/core.sh \
  lib/detect.sh \
  lib/render.sh \
  lib/writers-runtime.sh \
  lib/writers-docs.sh \
  lib/onboarding.sh; do
need_same_file "$BOOTSTRAP_BUNDLE/$canonical_file" "$CANONICAL_DIR/$canonical_file" "canonical export $canonical_file"
done
need_contains "$(cat "$TMP_DIR"/out/bootstrap-home-install.out)" "agent-init()" "canonical installer shell snippet"
need_contains "$(cat "$TMP_DIR"/out/bootstrap-home-install.out)" "agent-next()" "canonical installer first 10 shell snippet"

# --- Bundle inventory cross-check (guard the three independent file enumerations) ---
# installer copy_file dest names MUST equal the canonical_file loop list; the MANIFEST
# Source Roles table MUST equal that set PLUS install-agent-bootstrap-home.sh (the
# installer is documented in MANIFEST but intentionally does not copy itself).
inv_installer="$(grep -E '^[[:space:]]*copy_file "' "$BOOTSTRAP_BUNDLE/install-agent-bootstrap-home.sh" \
  | sed -E 's/.*copy_file +"[^"]*" +"([^"]*)".*/\1/' | sort -u || true)"
inv_canonical="$(awk '
  /^for canonical_file in/ { grab=1; next }
  grab { line=$0; sub(/;[[:space:]]*do.*/,"",line); gsub(/\\/,"",line); gsub(/[[:space:]]/,"",line);
         if (line!="") print line; if ($0 ~ /;[[:space:]]*do/) grab=0 }
' "$ROOT_DIR/scripts/test-bootstrap-multi-agent-project.sh" | sort -u || true)"
inv_manifest="$(grep -E "^\\| \`[^\`]+\`" "$BOOTSTRAP_BUNDLE/MANIFEST.md" \
  | sed -E "s/^\\| \`([^\`]+)\`.*/\\1/" | sort -u || true)"
inv_expected_manifest="$(printf '%s\ninstall-agent-bootstrap-home.sh\n' "$inv_installer" | sort -u)"
inv_diff_ic="$(diff <(printf '%s\n' "$inv_installer") <(printf '%s\n' "$inv_canonical") || true)"
[[ -z "$inv_diff_ic" ]] || fail "bundle inventory drift: installer copy_file set (<) != drift-test canonical_file loop (>):
$inv_diff_ic"
inv_diff_mi="$(diff <(printf '%s\n' "$inv_manifest") <(printf '%s\n' "$inv_expected_manifest") || true)"
[[ -z "$inv_diff_mi" ]] || fail "bundle inventory drift: MANIFEST Source Roles set (<) != installer copy set + install-agent-bootstrap-home.sh (>):
$inv_diff_mi"
inv_actual="$(find "$BOOTSTRAP_BUNDLE" -type f -print \
  | sed "s|^$BOOTSTRAP_BUNDLE/||" \
  | sort -u)"
inv_diff_am="$(diff <(printf '%s\n' "$inv_actual") <(printf '%s\n' "$inv_manifest") || true)"
[[ -z "$inv_diff_am" ]] || fail "bundle inventory drift: actual bundle files (<) != MANIFEST Source Roles set (>):
$inv_diff_am"

mkdir -p "$TMP_DIR/app/src/main/AndroidManifest" "$TMP_DIR/wear/src/main/AndroidManifest"
cat > "$TMP_DIR/settings.gradle.kts" <<'EOF_SETTINGS'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = "bootstrap-smoke"
include(":app", ":wear")
EOF_SETTINGS
cat > "$TMP_DIR/build.gradle.kts" <<'EOF_BUILD'
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
EOF_BUILD
cat > "$TMP_DIR/app/src/main/AndroidManifest/AndroidManifest.xml" <<'EOF_MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
EOF_MANIFEST

(
  cd "$TMP_DIR"
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TMP_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-smoke.out
  if ! scripts/agent-hook.sh claude-pretool >"$TMP_DIR"/out/bootstrap-fresh-claude-hook.out 2>"$TMP_DIR"/out/bootstrap-fresh-claude-hook.err; then
    fail "fresh checkout Claude hook failed before rtk install: $(cat "$TMP_DIR"/out/bootstrap-fresh-claude-hook.err)"
  fi
  need_contains "$(cat "$TMP_DIR"/out/bootstrap-fresh-claude-hook.err)" "pinned rtk binary is not installed" "fresh checkout Claude hook warning"
  if ! .codex/codex-mode.sh doctor >"$TMP_DIR"/out/bootstrap-fresh-codex-doctor.out 2>"$TMP_DIR"/out/bootstrap-fresh-codex-doctor.err; then
    fail "fresh checkout Codex doctor failed before rtk install: $(cat "$TMP_DIR"/out/bootstrap-fresh-codex-doctor.err)"
  fi
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TMP_DIR" --refresh-lock >"$TMP_DIR"/out/bootstrap-refresh-lock.out
  need_contains "$(cat docs/agent-configs/agent-bootstrap.lock.json)" '"workflow_preset": "full"' "refresh-lock preserved workflow preset"
  mkdir -p .tools/rtk/v0.37.2 .tools/bin
  cat > .tools/rtk/v0.37.2/rtk <<'EOF_FAKE_RTK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    echo "rtk 0.37.2"
    ;;
  git)
    shift
    if [[ "${1:-}" == "-C" ]]; then
      shift 2
    fi
    case "${1:-}" in
      ls-files)
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  hook)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF_FAKE_RTK
  chmod +x .tools/rtk/v0.37.2/rtk
  ln -sfn ../rtk/v0.37.2/rtk .tools/bin/rtk
  bash -n scripts/agent-tech-stack-lib.sh
  bash -n scripts/detect-agent-tech-stack.sh
  bash -n scripts/install-rtk.sh
  bash -n scripts/rtk
  bash -n scripts/agent-hook.sh
  bash -n scripts/agent-guard.sh
  bash -n scripts/agent-onboarding.sh
  bash -n scripts/verify-ai-deps.sh
  bash -n .codex/codex-mode.sh
)

ROOT_DIRECT_DIR="$FIXTURE_DIR/root-direct"
mkdir -p "$ROOT_DIRECT_DIR"
bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-root-direct.out
[[ -f "$ROOT_DIRECT_DIR/AGENTS.md" ]] || fail "root bootstrap wrapper did not generate AGENTS.md"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/project-onboarding.md" ]] || fail "root bootstrap wrapper did not generate onboarding procedure"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/first-10-minutes.md" ]] || fail "root bootstrap wrapper did not generate first 10 minutes guide"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/project-brief.md" ]] || fail "root bootstrap wrapper did not generate project brief"
[[ -f "$ROOT_DIRECT_DIR/docs/superpowers/specs/README.md" ]] || fail "root bootstrap wrapper did not generate specs guidance"
[[ -f "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.md" ]] || fail "root bootstrap wrapper did not generate project tech-stack spec"
[[ -f "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.json" ]] || fail "root bootstrap wrapper did not generate project tech-stack machine contract"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/model-profiles.json" ]] || fail "root bootstrap wrapper did not generate model profiles"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/context-policy.json" ]] || fail "root bootstrap wrapper did not generate context policy"
[[ -x "$ROOT_DIRECT_DIR/scripts/agent-guard.sh" ]] || fail "root bootstrap wrapper did not generate executable agent guard"
[[ -x "$ROOT_DIRECT_DIR/scripts/agent-onboarding.sh" ]] || fail "root bootstrap wrapper did not generate executable onboarding helper"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate context policy schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate model profile schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate project tech-stack schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate lock schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate status schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json" ]] || fail "root bootstrap wrapper did not generate verifier schema"
[[ -f "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256" ]] || fail "root bootstrap wrapper did not generate rtk provenance"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/project-onboarding.md")" "project-specific tech-stack" "onboarding tech-stack guidance"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/project-onboarding.md")" "project-tech-stack.json" "onboarding tech-stack machine contract guidance"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/first-10-minutes.md")" "scripts/agent-onboarding.sh check" "first 10 readiness check"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/superpowers/specs/README.md")" "project-tech-stack" "specs tech-stack guidance"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.md")" "<!-- UNFILLED -->" "project tech-stack spec marker"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.json")" '"schema": "agent-project-tech-stack/v1"' "project tech-stack contract schema"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.json")" '"status": "unfilled"' "project tech-stack contract status"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/model-profiles.json")" '"schema": "agent-model-profiles/v1"' "model profiles schema"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/model-profiles.json")" '"planning_model": "gpt-5.5"' "model profiles planning model"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/context-policy.json")" '"schema": "agent-context-policy/v1"' "context policy schema"
need_contains "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/provenance/rtk-v0.37.2.sha256")" "rtk-aarch64-apple-darwin.tar.gz" "rtk provenance darwin arm64 asset"
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/model-profiles.json" >/dev/null ||
    fail "generated model profiles JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/context-policy.json" >/dev/null ||
    fail "generated context policy JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/superpowers/specs/project-tech-stack.json" >/dev/null ||
    fail "generated project tech-stack contract JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" >/dev/null ||
    fail "generated context policy schema JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" >/dev/null ||
    fail "generated model profile schema JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" >/dev/null ||
    fail "generated project tech-stack schema JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-lock-v1.schema.json" >/dev/null ||
    fail "generated lock schema JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-status-v1.schema.json" >/dev/null ||
    fail "generated status schema JSON is invalid"
  python3 -m json.tool "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-bootstrap-verify-report-v1.schema.json" >/dev/null ||
    fail "generated verifier schema JSON is invalid"
fi
need_not_contains \
  "$(cat "$ROOT_DIRECT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/workflows/three-mode/README.md")" \
  "--workflow three-mode" \
  "generated three-mode template"
root_status="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --status)"
need_contains "$root_status" "bundle_version=$bundle_version" "root status bundle version"
need_contains "$root_status" "installed_version=$bundle_version" "root status installed version"
need_contains "$root_status" "workflow_preset=full" "root status workflow"
need_contains "$root_status" "onboarding_status=unfilled" "root status onboarding readiness"
root_status_json="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --status --json)"
need_contains "$root_status_json" '"schema":"agent-bootstrap-status/v1"' "root status json schema"
need_contains "$root_status_json" "\"bundle_version\":\"$bundle_version\"" "root status json bundle version"
need_contains "$root_status_json" '"onboarding_status":"unfilled"' "root status json onboarding readiness"
need_contains "$root_status_json" '"generated_file_drift":"clean"' "root status json generated drift clean"
root_first_10="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --first-10)"
need_contains "$root_first_10" "First 10 Minutes" "root first 10 header"
need_contains "$root_first_10" "scripts/agent-onboarding.sh next" "root first 10 onboarding next"
root_diff="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --diff)"
need_contains "$root_diff" "No generated-file differences." "root diff clean target"
rm -f "$ROOT_DIRECT_DIR/.gitignore"
root_missing_gitignore_diff="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --diff)"
need_contains "$root_missing_gitignore_diff" "--- .gitignore" "root diff missing generated gitignore"
root_missing_gitignore_status="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --status --json)"
need_contains "$root_missing_gitignore_status" '"generated_file_drift":"stale"' "root status missing generated gitignore drift"
bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --force --no-backup --workflow full >"$TMP_DIR"/out/bootstrap-root-direct-restore.out
root_upgrade_plan="$(bash "$BOOTSTRAP" --target "$ROOT_DIRECT_DIR" --upgrade-plan)"
need_contains "$root_upgrade_plan" "Upgrade plan" "root upgrade plan header"
need_contains "$root_upgrade_plan" "bundle_version=$bundle_version" "root upgrade plan bundle version"
need_contains "$root_upgrade_plan" "workflow_preset=full" "root upgrade plan workflow"

cmp -s "$SHARED_LIB" "$TMP_DIR/scripts/agent-tech-stack-lib.sh" || fail "generated tech-stack lib drifted from source lib"
while IFS= read -r source_template; do
  relative_template="${source_template#"$ROOT_DIR"/docs/agent-configs/bootstrap-multi-agent-project/templates/}"
  need_same_file "$source_template" "$BOOTSTRAP_BUNDLE/templates/$relative_template" "bundle template $relative_template"
done < <(find "$ROOT_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates" -type f | sort)
while IFS= read -r bundle_template; do
  relative_template="${bundle_template#"$BOOTSTRAP_BUNDLE"/templates/}"
  need_same_file "$bundle_template" "$TMP_DIR/docs/agent-configs/bootstrap-multi-agent-project/templates/$relative_template" "generated template $relative_template"
done < <(find "$BOOTSTRAP_BUNDLE/templates" -type f | sort)
for runtime_snapshot in \
  agent-tech-stack-lib.sh \
  agent-hook.sh \
  agent-guard.sh \
  agent-onboarding.sh \
  detect-agent-tech-stack.sh \
  install-rtk.sh \
  rtk \
  verify-ai-deps.sh; do
  need_same_file "$BOOTSTRAP_BUNDLE/$runtime_snapshot" "$TMP_DIR/scripts/$runtime_snapshot" "generated runtime snapshot $runtime_snapshot"
done
	[[ -f "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md" ]] || fail "full bootstrap did not generate agentmemory skill"
	[[ -f "$TMP_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" ]] || fail "full bootstrap did not generate agentmemory openai metadata"
	need_contains "$(cat "$TMP_DIR/.claude/settings.json")" '"matcher": "Edit|Write|MultiEdit"' "Claude settings edit/write guard hook"
	need_contains "$(cat "$TMP_DIR/AGENTS.md")" "agentmemory-mcp" "full bootstrap AGENTS agentmemory routing"
need_contains "$(cat "$TMP_DIR/.gitignore")" "!.agents/skills/**" "full bootstrap gitignore tracked skills exception"
need_not_contains "$(cat "$TMP_DIR/.gitignore")" "*.generated.*" "full bootstrap generated candidates must stay visible"
need_not_contains "$(cat "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "/Users/admin/" "generated agentmemory skill must not contain author machine path"
need_not_contains "$(cat "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "codex-cliproxy-provider" "generated agentmemory skill must not name author-only repo"
need_not_contains "$(sed -n '1,20p' "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "Android/iOS" "generated agentmemory skill description must be stack agnostic"
need_contains "$(cat "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "AGENTMEMORY_VERIFY_CMD" "generated agentmemory operational check"
need_contains "$(cat "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "Handoff Format" "generated agentmemory handoff protocol"
[[ -f "$TMP_DIR/.agents/skills/doubt-driven/SKILL.md" ]] || fail "full bootstrap did not generate doubt-driven skill"
need_contains "$(cat "$TMP_DIR/.agents/skills/doubt-driven/SKILL.md")" "CLAIM" "doubt-driven procedure"
need_contains "$(cat "$TMP_DIR/.agents/skills/doubt-driven/SKILL.md")" "addyosmani/agent-skills (MIT)" "doubt-driven attribution"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/llm-council-agent-workflow.md")" "doubt-driven" "council references doubt-driven"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "## Startup Context Budget" "AGENTS token budget section"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "Always read at startup" "AGENTS core startup context"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "Read on demand" "AGENTS lazy context disclosure"
need_not_contains "$(cat "$TMP_DIR/AGENTS.md")" "agents must read and apply:" "AGENTS must not eagerly load all workflow docs"
need_contains "$(cat "$TMP_DIR/CLAUDE.md")" "Read on demand" "CLAUDE lazy context disclosure"
need_not_contains "$(cat "$TMP_DIR/CLAUDE.md")" "Read \`AGENTS.md\` first, then apply:" "CLAUDE must not eagerly load all workflow docs"
startup_tokens=$(( \
  $(estimate_tokens_for_file "$TMP_DIR/AGENTS.md") + \
  $(estimate_tokens_for_file "$TMP_DIR/docs/agent-configs/project-agent-context.md") + \
  $(estimate_tokens_for_file "$TMP_DIR/docs/agent-configs/project-brief.md") \
))
[[ "$startup_tokens" -le 3000 ]] || fail "core startup context too large: ${startup_tokens} estimated tokens"
[[ -f "$TMP_DIR/docs/agent-configs/project-onboarding.md" ]] || fail "full bootstrap did not generate onboarding procedure"
[[ -f "$TMP_DIR/docs/agent-configs/first-10-minutes.md" ]] || fail "full bootstrap did not generate first 10 minutes guide"
[[ -f "$TMP_DIR/.claude/commands/project-onboarding.md" ]] || fail "full bootstrap did not generate onboarding command"
[[ -f "$TMP_DIR/docs/agent-configs/project-brief.md" ]] || fail "full bootstrap did not generate project brief"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/project-brief.md")" "<!-- UNFILLED -->" "project brief unfilled marker"
[[ -f "$TMP_DIR/docs/superpowers/specs/README.md" ]] || fail "full bootstrap did not generate specs skeleton"
[[ -f "$TMP_DIR/docs/superpowers/specs/project-tech-stack.md" ]] || fail "full bootstrap did not generate project tech-stack spec"
[[ -f "$TMP_DIR/docs/superpowers/specs/project-tech-stack.json" ]] || fail "full bootstrap did not generate project tech-stack machine contract"
[[ -f "$TMP_DIR/docs/superpowers/plans/README.md" ]] || fail "full bootstrap did not generate plans skeleton"
[[ -f "$TMP_DIR/docs/agent-configs/model-profiles.json" ]] || fail "full bootstrap did not generate model profiles"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/model-profiles.json")" '"schema": "agent-model-profiles/v1"' "full bootstrap model profiles schema"
[[ -f "$TMP_DIR/docs/agent-configs/context-policy.json" ]] || fail "full bootstrap did not generate context policy"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/context-policy.json")" '"schema": "agent-context-policy/v1"' "full bootstrap context policy schema"
[[ -x "$TMP_DIR/scripts/agent-guard.sh" ]] || fail "full bootstrap did not generate executable agent guard"
[[ -x "$TMP_DIR/scripts/agent-onboarding.sh" ]] || fail "full bootstrap did not generate executable onboarding helper"
[[ -f "$TMP_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-context-policy-v1.schema.json" ]] || fail "full bootstrap did not generate context policy schema"
[[ -f "$TMP_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-model-profiles-v1.schema.json" ]] || fail "full bootstrap did not generate model profile schema"
[[ -f "$TMP_DIR/docs/agent-configs/bootstrap-multi-agent-project/schemas/agent-project-tech-stack-v1.schema.json" ]] || fail "full bootstrap did not generate project tech-stack schema"
need_contains "$(cat "$TMP_DIR/docs/superpowers/specs/project-tech-stack.json")" '"schema": "agent-project-tech-stack/v1"' "full bootstrap project tech-stack contract schema"
need_contains "$("$TMP_DIR/.codex/codex-mode.sh" status)" "Model profile: stable" "Codex status model profile"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/project-agent-context.md")" "project-brief.md" "context references brief"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "project-brief.md" "AGENTS startup references onboarding"

summary="$(cd "$TMP_DIR" && scripts/detect-agent-tech-stack.sh --summary)"
need_contains "$summary" "tech_stacks=android_kotlin wear_os" "tech stack summary"
need_contains "$summary" "modules=:app :wear" "module summary"
need_contains "$summary" "tech_stack_lib_version=" "library version summary"

mkdir -p "$FIXTURE_DIR/node-tooling"
cat > "$FIXTURE_DIR/node-tooling/package.json" <<'EOF_PACKAGE'
{
  "private": true,
  "devDependencies": {
    "prettier": "3.3.3"
  }
}
EOF_PACKAGE
node_tooling_summary="$(cd "$TMP_DIR" && scripts/detect-agent-tech-stack.sh --root "$FIXTURE_DIR/node-tooling" --summary)"
need_not_contains "$node_tooling_summary" "node_js" "tooling-only package.json"
need_not_contains "$node_tooling_summary" "npm test" "tooling-only package.json verification"
need_contains "$node_tooling_summary" "lacks production Node/Web signals" "tooling-only package.json warning"

mkdir -p "$FIXTURE_DIR/ios-app/App.xcodeproj" "$FIXTURE_DIR/ios-app/WatchApp"
cat > "$FIXTURE_DIR/ios-app/Package.swift" <<'EOF_SWIFT_PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Demo")
EOF_SWIFT_PACKAGE
cat > "$FIXTURE_DIR/ios-app/Podfile" <<'EOF_PODFILE'
platform :ios, '16.0'
target 'Demo' do
end
EOF_PODFILE
cat > "$FIXTURE_DIR/ios-app/WatchApp/DemoWatchView.swift" <<'EOF_WATCH'
import SwiftUI
struct DemoWatchView: View { var body: some View { Text("Watch") } }
EOF_WATCH
ios_summary="$(cd "$TMP_DIR" && scripts/detect-agent-tech-stack.sh --root "$FIXTURE_DIR/ios-app" --summary)"
need_contains "$ios_summary" "ios_swift" "iOS detector"
need_contains "$ios_summary" "swift_package" "SPM detector"
need_contains "$ios_summary" "ios_cocoapods" "CocoaPods detector"
need_contains "$ios_summary" "watch_os" "watchOS detector"
need_contains "$ios_summary" "xcodebuild test -scheme <scheme>" "iOS build/test candidate"
need_contains "$ios_summary" "swift test" "Swift package test candidate"

(cd "$TMP_DIR" && scripts/agent-hook.sh codex-preflight reviewing full_flow >"$TMP_DIR"/out/bootstrap-preflight.out)
(cd "$TMP_DIR" && scripts/agent-guard.sh preflight >"$TMP_DIR"/out/bootstrap-agent-guard-preflight.out)
(cd "$TMP_DIR" && scripts/agent-guard.sh pre-edit --advisory agent-bootstrap/lib/render.sh >"$TMP_DIR"/out/bootstrap-agent-guard-pre-edit.out)
(cd "$TMP_DIR" && scripts/agent-onboarding.sh status >"$TMP_DIR"/out/bootstrap-onboarding-status.out)
(cd "$TMP_DIR" && scripts/agent-onboarding.sh next >"$TMP_DIR"/out/bootstrap-onboarding-next.out)
if (cd "$TMP_DIR" && scripts/agent-onboarding.sh check >"$TMP_DIR"/out/bootstrap-onboarding-check.out 2>"$TMP_DIR"/out/bootstrap-onboarding-check.err); then
  fail "fresh generated onboarding check unexpectedly passed"
fi
(cd "$TMP_DIR" && .codex/codex-mode.sh doctor >"$TMP_DIR"/out/bootstrap-codex-doctor.out)
(cd "$TMP_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-verify.out)
(cd "$TMP_DIR" && scripts/verify-ai-deps.sh --json >"$TMP_DIR"/out/bootstrap-verify.json)
(cd "$TMP_DIR" && scripts/agent-hook.sh claude-pretool >"$TMP_DIR"/out/bootstrap-claude-hook.out 2>"$TMP_DIR"/out/bootstrap-claude-hook.err)

if ! grep -Fq "Pass:" "$TMP_DIR"/out/bootstrap-verify.out; then
  fail "generated verifier did not print summary"
fi
need_contains "$(cat "$TMP_DIR/out/bootstrap-codex-doctor.out")" "project brief is unfilled" "Codex doctor project brief readiness warning"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "project brief is unfilled" "generated verifier project brief readiness warning"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "onboarding contract is unfilled" "generated verifier onboarding readiness warning"
need_contains "$(cat "$TMP_DIR/out/bootstrap-onboarding-status.out")" "Onboarding status: unfilled" "onboarding status command"
need_contains "$(cat "$TMP_DIR/out/bootstrap-onboarding-next.out")" "scripts/agent-onboarding.sh check" "onboarding next strict check"
need_contains "$(cat "$TMP_DIR/out/bootstrap-codex-doctor.out")" "core startup context estimate" "Codex doctor token budget report"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "core startup context estimate" "generated verifier token budget report"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "model profile schema is agent-model-profiles/v1" "generated verifier model profile schema check"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "agent context policy schema is agent-context-policy/v1" "generated verifier context policy schema check"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "agent guard check passes" "generated verifier agent guard check"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "rtk provenance manifest exists" "generated verifier rtk provenance check"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "bootstrap JSON contracts validate" "generated verifier JSON contract validation"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "project tech-stack contract validates" "generated verifier project tech-stack contract validation"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.json")" '"schema":"agent-bootstrap-verify-report/v1"' "generated verifier json schema"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.json")" '"fail":0' "generated verifier json fail count"
need_contains "$(cat "$TMP_DIR/out/bootstrap-agent-guard-preflight.out")" "agent-guard: preflight ok" "agent guard preflight output"
[[ -f "$TMP_DIR/.agents/state/context-pack.json" ]] || fail "agent guard did not write context pack"
need_contains "$(cat "$TMP_DIR/.agents/state/context-pack.json")" '"schema":"agent-context-pack/v1"' "agent guard context pack schema"
need_contains "$(cat "$TMP_DIR/out/bootstrap-agent-guard-pre-edit.out")" "protected_path=true" "agent guard protected path classification"
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$TMP_DIR/out/bootstrap-verify.json" >/dev/null ||
    fail "generated verifier --json output is not valid JSON"
fi

GUARD_DIR="$FIXTURE_DIR/guard-regressions"
mkdir -p "$GUARD_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$GUARD_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-guard-regressions.out
	(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >"$TMP_DIR"/out/bootstrap-guard-regressions-preflight.out)
	rm -f "$GUARD_DIR/.agents/state/context-pack.json"
	if (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-final >"$TMP_DIR"/out/bootstrap-guard-prefinal-missing.out 2>"$TMP_DIR"/out/bootstrap-guard-prefinal-missing.err); then
	  fail "agent guard pre-final passed without context pack"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-prefinal-missing.err")" "missing context pack" "pre-final missing context pack error"
	(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >/dev/null)

	printf '\nQA drift marker\n' >> "$GUARD_DIR/AGENTS.md"
	if (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-final >"$TMP_DIR"/out/bootstrap-guard-prefinal-drift.out 2>"$TMP_DIR"/out/bootstrap-guard-prefinal-drift.err); then
	  fail "agent guard pre-final passed after required context drift"
fi
need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-prefinal-drift.err")" "stale" "pre-final required context drift error"
(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >/dev/null)

dotdot_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit docs/../AGENTS.md) 2>&1 || true)"
need_contains "$dotdot_guard_out" "path=AGENTS.md" "pre-edit normalizes dotdot path"
need_contains "$dotdot_guard_out" "protected_path=true" "pre-edit protects dotdot-normalized path"
abs_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit "$GUARD_DIR/AGENTS.md") 2>&1 || true)"
need_contains "$abs_guard_out" "path=AGENTS.md" "pre-edit normalizes project absolute path"
need_contains "$abs_guard_out" "protected_path=true" "pre-edit protects absolute project path"
if (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit ../outside.txt >"$TMP_DIR"/out/bootstrap-guard-path-escape.out 2>"$TMP_DIR"/out/bootstrap-guard-path-escape.err); then
  fail "agent guard pre-edit allowed path escaping project root"
fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-path-escape.err")" "outside project root" "pre-edit path escape error"
	python3 - "$GUARD_DIR/docs/agent-configs/context-policy.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["protected_paths"][0]["pattern"] = "./AGENTS.md"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	if (cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >"$TMP_DIR"/out/bootstrap-guard-dot-pattern.out 2>"$TMP_DIR"/out/bootstrap-guard-dot-pattern.err); then
	  fail "agent guard accepted dot-segment protected path pattern"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-dot-pattern.err")" "unsafe" "dot-segment protected path pattern error"
	python3 - "$GUARD_DIR/docs/agent-configs/context-policy.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["protected_paths"][0]["pattern"] = "AGENTS.md"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >/dev/null)

	foo_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit scripts/foo.sh) 2>&1 || true)"
	need_contains "$foo_guard_out" "protected_path=false" "pre-edit does not overmatch scripts/agent-*.sh"
	hook_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit scripts/agent-hook.sh) 2>&1 || true)"
need_contains "$hook_guard_out" "protected_path=true" "pre-edit matches scripts/agent-*.sh"
codex_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit .codex/codex-mode.sh) 2>&1 || true)"
need_contains "$codex_guard_out" "protected_path=true" "pre-edit protects Codex adapter"
claude_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit .claude/settings.json) 2>&1 || true)"
need_contains "$claude_guard_out" "protected_path=true" "pre-edit protects Claude adapter"
gemini_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit GEMINI.md) 2>&1 || true)"
need_contains "$gemini_guard_out" "protected_path=true" "pre-edit protects Gemini adapter"

if (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit --strict AGENTS.md >"$TMP_DIR"/out/bootstrap-guard-strict.out 2>"$TMP_DIR"/out/bootstrap-guard-strict.err); then
  fail "agent guard strict pre-edit allowed protected path without acknowledgement"
fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-strict.err")" "ack" "strict pre-edit ack guidance"
	(cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit --strict --ack reviewed AGENTS.md >"$TMP_DIR"/out/bootstrap-guard-strict-ack.out)
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-strict-ack.out")" "protected_path=true" "strict pre-edit ack still classifies protected path"
	need_contains "$(cat "$GUARD_DIR/.agents/state/guard-ack.log")" "path=AGENTS.md" "strict pre-edit ack audit log"

python3 - "$GUARD_DIR/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["protected_paths"] = ["src/secret/**"]
doc["generated_files"] = ["generated/openapi/**"]
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >/dev/null)
	project_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit src/secret/config.yml) 2>&1 || true)"
	need_contains "$project_guard_out" "protected_path=true" "pre-edit consumes project-specific protected paths"
	project_exact_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit src/secret) 2>&1 || true)"
	need_contains "$project_exact_guard_out" "protected_path=true" "pre-edit matches project-specific recursive path root"
	project_neighbor_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit src/secrecy/config.yml) 2>&1 || true)"
	need_contains "$project_neighbor_guard_out" "protected_path=false" "pre-edit does not overmatch project-specific protected path neighbor"
	generated_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit generated/openapi/client.ts) 2>&1 || true)"
	need_contains "$generated_guard_out" "protected_path=true" "pre-edit consumes project-specific generated files"
	generated_neighbor_guard_out="$( (cd "$GUARD_DIR" && scripts/agent-guard.sh pre-edit generated/openapi2/client.ts) 2>&1 || true)"
	need_contains "$generated_neighbor_guard_out" "protected_path=false" "pre-edit does not overmatch project-specific generated file neighbor"

	printf '{"tool_name":"Edit","tool_input":{"file_path":"AGENTS.md"}}\n' > "$TMP_DIR/out/bootstrap-claude-edit-protected.json"
	if (cd "$GUARD_DIR" && scripts/agent-hook.sh claude-pretool < "$TMP_DIR/out/bootstrap-claude-edit-protected.json" >"$TMP_DIR"/out/bootstrap-claude-edit-protected.out 2>"$TMP_DIR"/out/bootstrap-claude-edit-protected.err); then
	  fail "Claude edit hook allowed protected path without acknowledgement"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-claude-edit-protected.err")" "ack" "Claude edit hook protected ack guidance"
	(cd "$GUARD_DIR" && AGENT_GUARD_EDIT_ACK=reviewed scripts/agent-hook.sh claude-pretool < "$TMP_DIR/out/bootstrap-claude-edit-protected.json" >"$TMP_DIR"/out/bootstrap-claude-edit-ack.out)
	need_contains "$(cat "$TMP_DIR/out/bootstrap-claude-edit-ack.out")" "protected_path=true" "Claude edit hook ack still classifies protected path"
	printf '{"tool_name":"Write","tool_input":{"file_path":"src/main.txt"}}\n' > "$TMP_DIR/out/bootstrap-claude-edit-unprotected.json"
	(cd "$GUARD_DIR" && scripts/agent-hook.sh claude-pretool < "$TMP_DIR/out/bootstrap-claude-edit-unprotected.json" >"$TMP_DIR"/out/bootstrap-claude-edit-unprotected.out)
	need_contains "$(cat "$TMP_DIR/out/bootstrap-claude-edit-unprotected.out")" "protected_path=false" "Claude edit hook allows unprotected path"

	rm -rf "$GUARD_DIR/.agents/state"
	(cd "$GUARD_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-guard-verify-readonly.out)
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-verify-readonly.out")" "agent guard check passes" "generated verifier uses read-only agent guard check"
[[ ! -e "$GUARD_DIR/.agents/state/context-pack.json" ]] || fail "generated verifier created context-pack side effect"
(cd "$GUARD_DIR" && .codex/codex-mode.sh doctor >"$TMP_DIR"/out/bootstrap-guard-doctor-readonly.out)
need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-doctor-readonly.out")" "agent guard check passes" "Codex doctor uses read-only agent guard check"
[[ ! -e "$GUARD_DIR/.agents/state/context-pack.json" ]] || fail "Codex doctor created context-pack side effect"

python3 - "$GUARD_DIR/docs/agent-configs/context-policy.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
path.write_text(json.dumps(doc, separators=(",", ":")) + "\n", encoding="utf-8")
PY
(cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >/dev/null) ||
  fail "agent guard rejected compact valid context-policy JSON"
(cd "$GUARD_DIR" && scripts/verify-ai-deps.sh >/dev/null) ||
  fail "generated verifier rejected compact valid context-policy JSON"

python3 - "$GUARD_DIR/docs/agent-configs/context-policy.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["required_context"].append("../outside-secret")
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	if (cd "$GUARD_DIR" && scripts/agent-guard.sh preflight >"$TMP_DIR"/out/bootstrap-guard-policy-traversal.out 2>"$TMP_DIR"/out/bootstrap-guard-policy-traversal.err); then
	  fail "agent guard accepted context policy path outside project root"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-guard-policy-traversal.err")" "unsafe" "context policy traversal error"

	SCHEMA_EXTRA_DIR="$FIXTURE_DIR/schema-extra"
	mkdir -p "$SCHEMA_EXTRA_DIR"
	bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$SCHEMA_EXTRA_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-schema-extra.out
	python3 - "$SCHEMA_EXTRA_DIR/docs/agent-configs/context-policy.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["unexpected_extra"] = True
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	if (cd "$SCHEMA_EXTRA_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-schema-extra-verify.out 2>"$TMP_DIR"/out/bootstrap-schema-extra-verify.err); then
	  fail "generated verifier accepted extra context-policy property"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-schema-extra-verify.out")" "bootstrap JSON contracts failed validation" "context policy additional property validation"

	TECH_PATH_DIR="$FIXTURE_DIR/tech-path-contract"
	mkdir -p "$TECH_PATH_DIR"
	bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TECH_PATH_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-tech-path.out
	python3 - "$TECH_PATH_DIR/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["protected_paths"] = ["../outside"]
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	if (cd "$TECH_PATH_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-tech-path-verify.out 2>"$TMP_DIR"/out/bootstrap-tech-path-verify.err); then
	  fail "generated verifier accepted unsafe project tech-stack protected path"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-tech-path-verify.out")" "project tech-stack contract failed validation" "project tech-stack protected path validation"
	python3 - "$TECH_PATH_DIR/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["protected_paths"] = []
doc["generated_files"] = ["../outside-generated"]
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
	if (cd "$TECH_PATH_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-tech-generated-path-verify.out 2>"$TMP_DIR"/out/bootstrap-tech-generated-path-verify.err); then
	  fail "generated verifier accepted unsafe project tech-stack generated file path"
	fi
	need_contains "$(cat "$TMP_DIR/out/bootstrap-tech-generated-path-verify.out")" "project tech-stack contract failed validation" "project tech-stack generated file path validation"

	CANDIDATE_SCOPE_DIR="$FIXTURE_DIR/candidate-scope"
	mkdir -p "$CANDIDATE_SCOPE_DIR"
	bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_SCOPE_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-candidate-scope.out
	mkdir -p "$CANDIDATE_SCOPE_DIR/src"
	printf 'base api\n' > "$CANDIDATE_SCOPE_DIR/src/api"
	printf 'project generated source\n' > "$CANDIDATE_SCOPE_DIR/src/api.generated.ts"
	bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_SCOPE_DIR" --apply-candidates >"$TMP_DIR"/out/bootstrap-candidate-scope-apply.out
	[[ "$(cat "$CANDIDATE_SCOPE_DIR/src/api")" == "base api" ]] || fail "--apply-candidates rewrote non-bootstrap src/api base file"
	[[ "$(cat "$CANDIDATE_SCOPE_DIR/src/api.generated.ts")" == "project generated source" ]] || fail "--apply-candidates moved non-bootstrap generated source file"
	need_not_contains "$(cat "$TMP_DIR/out/bootstrap-candidate-scope-apply.out")" "src/api.generated.ts" "--apply-candidates output"
	candidate_scope_status="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_SCOPE_DIR" --status --json)"
	need_contains "$candidate_scope_status" '"pending_generated_candidates":0' "--status ignores non-bootstrap generated source"
	(cd "$CANDIDATE_SCOPE_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-candidate-scope-verify.out)
	need_not_contains "$(cat "$TMP_DIR/out/bootstrap-candidate-scope-verify.out")" "pending generated candidate requires review" "verifier ignores non-bootstrap generated source"
	(cd "$CANDIDATE_SCOPE_DIR" && scripts/agent-guard.sh preflight >/dev/null && scripts/agent-guard.sh pre-final >"$TMP_DIR"/out/bootstrap-candidate-scope-prefinal.out 2>"$TMP_DIR"/out/bootstrap-candidate-scope-prefinal.err)
	need_not_contains "$(cat "$TMP_DIR/out/bootstrap-candidate-scope-prefinal.err")" "pending generated candidate requires review" "pre-final ignores non-bootstrap generated source"

	CANDIDATE_DIR="$FIXTURE_DIR/candidate-visibility"
	mkdir -p "$CANDIDATE_DIR"
	bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-candidate-first.out
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-candidate-second.out
[[ -n "$(find "$CANDIDATE_DIR" -name '*.generated.*' -print -quit)" ]] || fail "re-run did not create generated candidates"
need_not_contains "$(cat "$CANDIDATE_DIR/.gitignore")" "*.generated.*" "generated candidates must not be ignored"
(cd "$CANDIDATE_DIR" && scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-candidate-verify.out)
need_contains "$(cat "$TMP_DIR/out/bootstrap-candidate-verify.out")" "pending generated candidate" "generated verifier pending candidate warning"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --apply-candidates >"$TMP_DIR"/out/bootstrap-apply-candidates.out
need_contains "$(cat "$TMP_DIR/out/bootstrap-apply-candidates.out")" "Applied generated candidate" "apply-candidates output"
[[ -z "$(find "$CANDIDATE_DIR" -name '*.generated.*' -print -quit)" ]] || fail "--apply-candidates left generated candidates behind"
candidate_status_after_apply="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --status --json)"
need_contains "$candidate_status_after_apply" '"pending_generated_candidates":0' "apply-candidates cleared pending count"
need_contains "$candidate_status_after_apply" '"generated_file_drift":"clean"' "apply-candidates made generated drift clean"

STALE_SKIP_DIR="$FIXTURE_DIR/stale-skip-existing"
mkdir -p "$STALE_SKIP_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$STALE_SKIP_DIR" --workflow full >"$TMP_DIR"/out/bootstrap-stale-first.out
python3 - "$STALE_SKIP_DIR/docs/agent-configs/agent-bootstrap.lock.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["version"] = "1900.01.01.0"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
printf 'custom stale agents\n' > "$STALE_SKIP_DIR/AGENTS.md"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$STALE_SKIP_DIR" --workflow full --skip-existing >"$TMP_DIR"/out/bootstrap-stale-skip.out
stale_status="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$STALE_SKIP_DIR" --status --json)"
need_contains "$stale_status" '"installed_version":"1900.01.01.0"' "--skip-existing must not bump installed lock version"
need_contains "$stale_status" '"generated_file_drift":"stale"' "--status must report stale generated files"
need_contains "$stale_status" '"pending_generated_candidates":0' "--skip-existing should not create hidden candidate signal"

SKIP_DIR="$FIXTURE_DIR/skip-existing"
mkdir -p "$SKIP_DIR"
printf 'custom-ignore\n' > "$SKIP_DIR/.gitignore"
printf 'custom agents\n' > "$SKIP_DIR/AGENTS.md"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$SKIP_DIR" --workflow full --skip-existing >"$TMP_DIR"/out/bootstrap-skip-existing.out
[[ "$(cat "$SKIP_DIR/.gitignore")" == "custom-ignore" ]] || fail "--skip-existing mutated existing .gitignore"
[[ -z "$(find "$SKIP_DIR" -name '.gitignore.bak.*' -print -quit)" ]] || fail "--skip-existing backed up existing .gitignore"

ZSHRC_DIR="$FIXTURE_DIR/zshrc-quote"
WEIRD_HOME="$ZSHRC_DIR/home with \" quote and dollar \$X"
mkdir -p "$ZSHRC_DIR"
AGENT_BOOTSTRAP_HOME="$WEIRD_HOME" "$HOME_INSTALLER" --no-git --write-zshrc --zshrc "$ZSHRC_DIR/zshrc" >"$TMP_DIR"/out/bootstrap-zshrc.out
bash -n "$ZSHRC_DIR/zshrc" || fail "managed shell block is not shell-parseable for quoted home path"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ZSHRC_DIR/zshrc" || fail "managed zsh block is not zsh-parseable for quoted home path"
fi

WEIRD_TARGET_DIR="$FIXTURE_DIR/target with ' quote and dollar \$X"
mkdir -p "$WEIRD_TARGET_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$WEIRD_TARGET_DIR" --project-name "quoted project" --workflow full >"$TMP_DIR"/out/bootstrap-weird-target.out
weird_status_json="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$WEIRD_TARGET_DIR" --status --json)"
need_contains "$weird_status_json" '"schema":"agent-bootstrap-status/v1"' "weird target status json schema"
need_contains "$weird_status_json" '"project":"quoted project"' "weird target explicit project name"
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$weird_status_json" | python3 -m json.tool >/dev/null ||
    fail "weird target status JSON is invalid"
fi
weird_diff="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$WEIRD_TARGET_DIR" --diff)"
need_contains "$weird_diff" "No generated-file differences." "weird target diff clean"
(cd "$WEIRD_TARGET_DIR" && scripts/verify-ai-deps.sh --json >"$TMP_DIR"/out/bootstrap-weird-target-verify.json)
need_contains "$(cat "$TMP_DIR/out/bootstrap-weird-target-verify.json")" '"fail":0' "weird target verifier json fail count"

QUOTED_PROJECT_DIR="$FIXTURE_DIR/quoted-json-project"
QUOTED_PROJECT_NAME='project "quoted" and backslash \ name'
mkdir -p "$QUOTED_PROJECT_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$QUOTED_PROJECT_DIR" --project-name "$QUOTED_PROJECT_NAME" --workflow full >"$TMP_DIR"/out/bootstrap-quoted-project.out
quoted_status_json="$(bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$QUOTED_PROJECT_DIR" --status --json)"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json, sys; expected = sys.argv[1]; actual = json.loads(sys.argv[2])["project"]; raise SystemExit(0 if actual == expected else f"project name mismatch: expected {expected!r}, got {actual!r}")' \
    "$QUOTED_PROJECT_NAME" "$quoted_status_json" ||
    fail "quoted project status JSON did not preserve escaped project name"
fi

INFRA_DIR="$FIXTURE_DIR/infra-only"
mkdir -p "$INFRA_DIR/scripts" "$INFRA_DIR/app/src/main/AndroidManifest"
cat > "$INFRA_DIR/settings.gradle.kts" <<'EOF_INFRA_SETTINGS'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = "bootstrap-infra"
include(":app")
EOF_INFRA_SETTINGS
cat > "$INFRA_DIR/build.gradle.kts" <<'EOF_INFRA_BUILD'
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
EOF_INFRA_BUILD
cat > "$INFRA_DIR/app/src/main/AndroidManifest/AndroidManifest.xml" <<'EOF_INFRA_MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
EOF_INFRA_MANIFEST

(
  cd "$INFRA_DIR"
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$INFRA_DIR" >"$TMP_DIR"/out/bootstrap-infra.out
  mkdir -p .tools/rtk/v0.37.2 .tools/bin
  cp "$TMP_DIR/.tools/rtk/v0.37.2/rtk" .tools/rtk/v0.37.2/rtk
  chmod +x .tools/rtk/v0.37.2/rtk
  ln -sfn ../rtk/v0.37.2/rtk .tools/bin/rtk
  bash -n scripts/agent-hook.sh
  bash -n scripts/agent-guard.sh
  bash -n scripts/verify-ai-deps.sh
  scripts/agent-guard.sh preflight >"$TMP_DIR"/out/bootstrap-infra-agent-guard.out
  scripts/agent-hook.sh codex-preflight planning standard >"$TMP_DIR"/out/bootstrap-infra-preflight.out
  scripts/verify-ai-deps.sh >"$TMP_DIR"/out/bootstrap-infra-verify.out
)

[[ ! -e "$INFRA_DIR/docs/agent-configs/karpathy-llm-coding-agent-config.md" ]] || fail "infra-only bootstrap installed Karpathy workflow"
[[ ! -e "$INFRA_DIR/docs/agent-configs/llm-council-agent-workflow.md" ]] || fail "infra-only bootstrap installed council workflow"
[[ ! -e "$INFRA_DIR/.codex/codex-mode.sh" ]] || fail "infra-only bootstrap installed Codex three-mode helper"
[[ -f "$INFRA_DIR/.agents/skills/agentmemory-mcp/SKILL.md" ]] || fail "infra bootstrap did not generate agentmemory skill"
[[ -f "$INFRA_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" ]] || fail "infra bootstrap did not generate agentmemory openai metadata"
[[ -f "$INFRA_DIR/docs/agent-configs/context-policy.json" ]] || fail "infra bootstrap did not generate context policy"
[[ -x "$INFRA_DIR/scripts/agent-guard.sh" ]] || fail "infra bootstrap did not generate executable agent guard"
need_contains "$(cat "$TMP_DIR/out/bootstrap-infra-agent-guard.out")" "agent-guard: preflight ok" "infra agent guard preflight"
need_contains "$(cat "$INFRA_DIR/docs/agent-configs/agent-bootstrap.lock.json")" '"workflow_preset": "infra"' "infra lock workflow preset"
[[ ! -e "$INFRA_DIR/.agents/skills/doubt-driven/SKILL.md" ]] || fail "infra-only bootstrap installed doubt-driven skill"
[[ ! -e "$INFRA_DIR/docs/agent-configs/project-brief.md" ]] || fail "infra-only bootstrap installed project brief"

printf 'bootstrap-test: ok (%s)\n' "$TMP_DIR"
