#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh"
HOME_INSTALLER="$ROOT_DIR/scripts/install-agent-bootstrap-home.sh"
BOOTSTRAP_BUNDLE="$ROOT_DIR/agent-bootstrap"
SHARED_LIB="$ROOT_DIR/scripts/agent-tech-stack-lib.sh"
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
  if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
    fail "$label missing '$needle' in: $haystack"
  fi
}

need_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    fail "$label unexpectedly contained '$needle' in: $haystack"
  fi
}

need_same_file() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  cmp -s "$expected" "$actual" || fail "$label drifted from ${expected#$ROOT_DIR/}"
}

estimate_tokens_for_file() {
  local file="$1"
  local words
  local chars
  set -- $(wc -w -c < "$file")
  words="$1"
  chars="$2"
  awk -v words="$words" -v chars="$chars" 'BEGIN {
    by_chars = chars / 4
    by_words = words * 1.3
    printf "%d", (by_chars > by_words ? by_chars : by_words)
  }'
}

[[ -x "$BOOTSTRAP" ]] || fail "missing executable bootstrap script: ${BOOTSTRAP#$ROOT_DIR/}"
[[ -x "$HOME_INSTALLER" ]] || fail "missing executable home installer: ${HOME_INSTALLER#$ROOT_DIR/}"
[[ -x "$BOOTSTRAP_BUNDLE/bootstrap-multi-agent-project.sh" ]] || fail "missing bundled bootstrap script"
[[ -x "$BOOTSTRAP_BUNDLE/install-agent-bootstrap-home.sh" ]] || fail "missing bundled home installer"
[[ -f "$BOOTSTRAP_BUNDLE/VERSION" ]] || fail "missing bundled VERSION"
[[ -f "$BOOTSTRAP_BUNDLE/MANIFEST.md" ]] || fail "missing bundled MANIFEST.md"
bash -n "$BOOTSTRAP"
bash -n "$HOME_INSTALLER"
bash -n "$BOOTSTRAP_BUNDLE/bootstrap-multi-agent-project.sh"
bash -n "$BOOTSTRAP_BUNDLE/install-agent-bootstrap-home.sh"

bootstrap_version="$("$BOOTSTRAP" --version)"
bundle_version="$(sed -n '1p' "$BOOTSTRAP_BUNDLE/VERSION")"
need_contains "$bootstrap_version" "bootstrap-multi-agent-project" "bootstrap version"
need_contains "$bootstrap_version" "$bundle_version" "bootstrap version file"
need_not_contains "$bootstrap_version" "payload-sha256=" "solo bootstrap version"

CANONICAL_DIR="$FIXTURE_DIR/agent-bootstrap"
AGENT_BOOTSTRAP_HOME="$CANONICAL_DIR" "$HOME_INSTALLER" --no-git >$TMP_DIR/out/bootstrap-home-install.out
[[ -x "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" ]] || fail "canonical installer did not export bootstrap script"
[[ -x "$CANONICAL_DIR/agent-hook.sh" ]] || fail "canonical installer did not export agent hook snapshot"
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
  detect-agent-tech-stack.sh \
  install-rtk.sh \
  rtk \
  verify-ai-deps.sh \
  lib/core.sh \
  lib/detect.sh \
  lib/render.sh \
  lib/writers-runtime.sh \
  lib/writers-docs.sh \
  lib/onboarding.sh; do
  need_same_file "$BOOTSTRAP_BUNDLE/$canonical_file" "$CANONICAL_DIR/$canonical_file" "canonical export $canonical_file"
done
need_contains "$(cat $TMP_DIR/out/bootstrap-home-install.out)" "agent-init()" "canonical installer shell snippet"

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
inv_manifest="$(grep -E '^\| `[^`]+`' "$BOOTSTRAP_BUNDLE/MANIFEST.md" \
  | sed -E 's/^\| `([^`]+)`.*/\1/' | sort -u || true)"
inv_expected_manifest="$(printf '%s\ninstall-agent-bootstrap-home.sh\n' "$inv_installer" | sort -u)"
inv_diff_ic="$(diff <(printf '%s\n' "$inv_installer") <(printf '%s\n' "$inv_canonical") || true)"
[[ -z "$inv_diff_ic" ]] || fail "bundle inventory drift: installer copy_file set (<) != drift-test canonical_file loop (>):
$inv_diff_ic"
inv_diff_mi="$(diff <(printf '%s\n' "$inv_manifest") <(printf '%s\n' "$inv_expected_manifest") || true)"
[[ -z "$inv_diff_mi" ]] || fail "bundle inventory drift: MANIFEST Source Roles set (<) != installer copy set + install-agent-bootstrap-home.sh (>):
$inv_diff_mi"

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
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TMP_DIR" --workflow full >$TMP_DIR/out/bootstrap-smoke.out
  if ! scripts/agent-hook.sh claude-pretool >$TMP_DIR/out/bootstrap-fresh-claude-hook.out 2>$TMP_DIR/out/bootstrap-fresh-claude-hook.err; then
    fail "fresh checkout Claude hook failed before rtk install: $(cat $TMP_DIR/out/bootstrap-fresh-claude-hook.err)"
  fi
  need_contains "$(cat $TMP_DIR/out/bootstrap-fresh-claude-hook.err)" "pinned rtk binary is not installed" "fresh checkout Claude hook warning"
  if ! .codex/codex-mode.sh doctor >$TMP_DIR/out/bootstrap-fresh-codex-doctor.out 2>$TMP_DIR/out/bootstrap-fresh-codex-doctor.err; then
    fail "fresh checkout Codex doctor failed before rtk install: $(cat $TMP_DIR/out/bootstrap-fresh-codex-doctor.err)"
  fi
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$TMP_DIR" --refresh-lock >$TMP_DIR/out/bootstrap-refresh-lock.out
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
  bash -n scripts/verify-ai-deps.sh
  bash -n .codex/codex-mode.sh
)

cmp -s "$SHARED_LIB" "$TMP_DIR/scripts/agent-tech-stack-lib.sh" || fail "generated tech-stack lib drifted from source lib"
for runtime_snapshot in \
  agent-tech-stack-lib.sh \
  agent-hook.sh \
  detect-agent-tech-stack.sh \
  install-rtk.sh \
  rtk \
  verify-ai-deps.sh; do
  need_same_file "$BOOTSTRAP_BUNDLE/$runtime_snapshot" "$TMP_DIR/scripts/$runtime_snapshot" "generated runtime snapshot $runtime_snapshot"
done
[[ -f "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md" ]] || fail "full bootstrap did not generate agentmemory skill"
[[ -f "$TMP_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" ]] || fail "full bootstrap did not generate agentmemory openai metadata"
need_contains "$(cat "$TMP_DIR/AGENTS.md")" "agentmemory-mcp" "full bootstrap AGENTS agentmemory routing"
need_contains "$(cat "$TMP_DIR/.gitignore")" "!.agents/skills/**" "full bootstrap gitignore tracked skills exception"
need_not_contains "$(cat "$TMP_DIR/.gitignore")" "*.generated.*" "full bootstrap generated candidates must stay visible"
need_contains "$(cat "$TMP_DIR/.agents/skills/agentmemory-mcp/SKILL.md")" "verify-agentmemory.sh" "generated agentmemory operational check"
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
need_not_contains "$(cat "$TMP_DIR/CLAUDE.md")" 'Read `AGENTS.md` first, then apply:' "CLAUDE must not eagerly load all workflow docs"
startup_tokens=$(( \
  $(estimate_tokens_for_file "$TMP_DIR/AGENTS.md") + \
  $(estimate_tokens_for_file "$TMP_DIR/docs/agent-configs/project-agent-context.md") + \
  $(estimate_tokens_for_file "$TMP_DIR/docs/agent-configs/project-brief.md") \
))
[[ "$startup_tokens" -le 3000 ]] || fail "core startup context too large: ${startup_tokens} estimated tokens"
[[ -f "$TMP_DIR/docs/agent-configs/project-onboarding.md" ]] || fail "full bootstrap did not generate onboarding procedure"
[[ -f "$TMP_DIR/.claude/commands/project-onboarding.md" ]] || fail "full bootstrap did not generate onboarding command"
[[ -f "$TMP_DIR/docs/agent-configs/project-brief.md" ]] || fail "full bootstrap did not generate project brief"
need_contains "$(cat "$TMP_DIR/docs/agent-configs/project-brief.md")" "<!-- UNFILLED -->" "project brief unfilled marker"
[[ -f "$TMP_DIR/docs/superpowers/specs/README.md" ]] || fail "full bootstrap did not generate specs skeleton"
[[ -f "$TMP_DIR/docs/superpowers/plans/README.md" ]] || fail "full bootstrap did not generate plans skeleton"
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

(cd "$TMP_DIR" && scripts/agent-hook.sh codex-preflight reviewing full_flow >$TMP_DIR/out/bootstrap-preflight.out)
(cd "$TMP_DIR" && .codex/codex-mode.sh doctor >$TMP_DIR/out/bootstrap-codex-doctor.out)
(cd "$TMP_DIR" && scripts/verify-ai-deps.sh >$TMP_DIR/out/bootstrap-verify.out)
(cd "$TMP_DIR" && scripts/agent-hook.sh claude-pretool >$TMP_DIR/out/bootstrap-claude-hook.out 2>$TMP_DIR/out/bootstrap-claude-hook.err)

if ! grep -Fq "Pass:" $TMP_DIR/out/bootstrap-verify.out; then
  fail "generated verifier did not print summary"
fi
need_contains "$(cat "$TMP_DIR/out/bootstrap-codex-doctor.out")" "project brief is unfilled" "Codex doctor project brief readiness warning"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "project brief is unfilled" "generated verifier project brief readiness warning"
need_contains "$(cat "$TMP_DIR/out/bootstrap-codex-doctor.out")" "core startup context estimate" "Codex doctor token budget report"
need_contains "$(cat "$TMP_DIR/out/bootstrap-verify.out")" "core startup context estimate" "generated verifier token budget report"

CANDIDATE_DIR="$FIXTURE_DIR/candidate-visibility"
mkdir -p "$CANDIDATE_DIR"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --workflow full >$TMP_DIR/out/bootstrap-candidate-first.out
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$CANDIDATE_DIR" --workflow full >$TMP_DIR/out/bootstrap-candidate-second.out
[[ -n "$(find "$CANDIDATE_DIR" -name '*.generated.*' -print -quit)" ]] || fail "re-run did not create generated candidates"
need_not_contains "$(cat "$CANDIDATE_DIR/.gitignore")" "*.generated.*" "generated candidates must not be ignored"
(cd "$CANDIDATE_DIR" && scripts/verify-ai-deps.sh >$TMP_DIR/out/bootstrap-candidate-verify.out)
need_contains "$(cat "$TMP_DIR/out/bootstrap-candidate-verify.out")" "pending generated candidate" "generated verifier pending candidate warning"

SKIP_DIR="$FIXTURE_DIR/skip-existing"
mkdir -p "$SKIP_DIR"
printf 'custom-ignore\n' > "$SKIP_DIR/.gitignore"
printf 'custom agents\n' > "$SKIP_DIR/AGENTS.md"
bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$SKIP_DIR" --workflow full --skip-existing >$TMP_DIR/out/bootstrap-skip-existing.out
[[ "$(cat "$SKIP_DIR/.gitignore")" == "custom-ignore" ]] || fail "--skip-existing mutated existing .gitignore"
[[ -z "$(find "$SKIP_DIR" -name '.gitignore.bak.*' -print -quit)" ]] || fail "--skip-existing backed up existing .gitignore"

ZSHRC_DIR="$FIXTURE_DIR/zshrc-quote"
WEIRD_HOME="$ZSHRC_DIR/home with \" quote and dollar \$X"
mkdir -p "$ZSHRC_DIR"
AGENT_BOOTSTRAP_HOME="$WEIRD_HOME" "$HOME_INSTALLER" --no-git --write-zshrc --zshrc "$ZSHRC_DIR/zshrc" >$TMP_DIR/out/bootstrap-zshrc.out
bash -n "$ZSHRC_DIR/zshrc" || fail "managed shell block is not shell-parseable for quoted home path"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ZSHRC_DIR/zshrc" || fail "managed zsh block is not zsh-parseable for quoted home path"
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
  bash "$CANONICAL_DIR/bootstrap-multi-agent-project.sh" --target "$INFRA_DIR" >$TMP_DIR/out/bootstrap-infra.out
  mkdir -p .tools/rtk/v0.37.2 .tools/bin
  cp "$TMP_DIR/.tools/rtk/v0.37.2/rtk" .tools/rtk/v0.37.2/rtk
  chmod +x .tools/rtk/v0.37.2/rtk
  ln -sfn ../rtk/v0.37.2/rtk .tools/bin/rtk
  bash -n scripts/agent-hook.sh
  bash -n scripts/verify-ai-deps.sh
  scripts/agent-hook.sh codex-preflight planning standard >$TMP_DIR/out/bootstrap-infra-preflight.out
  scripts/verify-ai-deps.sh >$TMP_DIR/out/bootstrap-infra-verify.out
)

[[ ! -e "$INFRA_DIR/docs/agent-configs/karpathy-llm-coding-agent-config.md" ]] || fail "infra-only bootstrap installed Karpathy workflow"
[[ ! -e "$INFRA_DIR/docs/agent-configs/llm-council-agent-workflow.md" ]] || fail "infra-only bootstrap installed council workflow"
[[ ! -e "$INFRA_DIR/.codex/codex-mode.sh" ]] || fail "infra-only bootstrap installed Codex three-mode helper"
[[ -f "$INFRA_DIR/.agents/skills/agentmemory-mcp/SKILL.md" ]] || fail "infra bootstrap did not generate agentmemory skill"
[[ -f "$INFRA_DIR/.agents/skills/agentmemory-mcp/agents/openai.yaml" ]] || fail "infra bootstrap did not generate agentmemory openai metadata"
need_contains "$(cat "$INFRA_DIR/docs/agent-configs/agent-bootstrap.lock.json")" '"workflow_preset": "infra"' "infra lock workflow preset"
[[ ! -e "$INFRA_DIR/.agents/skills/doubt-driven/SKILL.md" ]] || fail "infra-only bootstrap installed doubt-driven skill"
[[ ! -e "$INFRA_DIR/docs/agent-configs/project-brief.md" ]] || fail "infra-only bootstrap installed project brief"

printf 'bootstrap-test: ok (%s)\n' "$TMP_DIR"
