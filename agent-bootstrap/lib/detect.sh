#!/usr/bin/env bash
# agent-bootstrap/lib/detect.sh
# Sourced by bootstrap-multi-agent-project.sh. Tech-stack detection.
# Do not execute directly. No `set` here; inherits the entrypoint's shell options.
# Relies on entrypoint-owned globals; see lib/core.sh header for the contract.

emit_tech_stack_lib() {
  # The embedded heredoc below is the single source of truth for the emitted
  # tech-stack library, pinned byte-identical to agent-tech-stack-lib.sh by
  # scripts/test-bootstrap-multi-agent-project.sh (canonical + generated cmp).
  cat <<'EOF_TECH_STACK_LIB'
#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
# Shared tech-stack detection library for agent bootstrap/runtime scripts.
# Keep this file portable: bash 3.2 compatible, no repo-specific paths.

AGENT_TECH_STACK_LIB_VERSION="2026.10.13.2"

agent_reset_detection() {
  AGENT_TECH_STACKS=()
  AGENT_MODULES=()
  AGENT_VERIFY_COMMANDS=()
  AGENT_WARNINGS=()
}

agent_has_file() {
  local root="$1"
  local relative="$2"
  agent_is_real_regular_file "$root" "$root/$relative"
}

# Presence only (stat, never opened). Sensitive files are outside the read
# policy, so agent_has_file can never report them.
agent_sensitive_file_present() {
  local path="$1/$2"
  [[ -e "$path" || -L "$path" ]] && [[ ! -d "$path" ]]
}

agent_find_name() {
  local root="$1"
  local maxdepth="$2"
  local name="$3"
  local search_root="${4:-$root}"
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    agent_is_real_regular_file "$root" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$search_root" -maxdepth "$maxdepth" \
    \( -type d \( -name .git -o -name .tools -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name "$name" -print 2>/dev/null)
  return 1
}

agent_find_name_pattern() {
  local root="$1"
  local maxdepth="$2"
  local pattern="$3"
  local search_root="${4:-$root}"
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ -f "$candidate" || -d "$candidate" ]] || continue
    agent_path_is_eligible "$root" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$search_root" -maxdepth "$maxdepth" \
    \( -type d \( -name .git -o -name .tools -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name "$pattern" -print 2>/dev/null)
  return 1
}

agent_find_file_pattern() {
  local root="$1"
  local maxdepth="$2"
  local pattern="$3"
  local search_root="${4:-$root}"
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    agent_is_real_regular_file "$root" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$search_root" -maxdepth "$maxdepth" \
    \( -type d \( -name .git -o -name .tools -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name "$pattern" -print 2>/dev/null)
  return 1
}

# Same verdict as the Python policy without a process per path: a normalized
# absolute path under a normalized root, with no linked component below the
# root, resolves to resolved-root + the same relative path, so only the
# excluded-component rule applies. Links and unusual spellings use Python.
agent_path_is_eligible() {
  local root="$1"
  local path="$2"
  local rel current part i count exists=true
  local -a parts
  case "$root" in
    /*) ;;
    *) agent_path_policy_python "$root" "$path"; return ;;
  esac
  case "$root/" in
    */../*|*/./*|*//*|*$'\n'*) agent_path_policy_python "$root" "$path"; return ;;
  esac
  case "$path" in
    "$root"/*) rel="${path#"$root"/}" ;;
    *) agent_path_policy_python "$root" "$path"; return ;;
  esac
  case "/$rel/" in
    */../*|*/./*|*//*|*$'\n'*) agent_path_policy_python "$root" "$path"; return ;;
  esac
  IFS=/ read -r -a parts <<<"$rel"
  count=${#parts[@]}
  current="$root"
  for ((i = 0; i < count; i++)); do
    part="${parts[$i]}"
    case "$part" in
      .git|.tools|.idea|.next|node_modules|Pods|vendor|build|dist|out|local.properties|keystore.properties|\
      .gradle*|.env*|*.jks|*.keystore|*.pem|*.p8|*.key)
        return 1
        ;;
      .agents)
        case "${parts[$((i + 1))]:-}" in runtime|state|cache) return 1 ;; esac
        ;;
    esac
    if [[ "$exists" == "true" ]]; then
      current="$current/$part"
      if [[ -L "$current" ]]; then
        agent_path_policy_python "$root" "$path"
        return
      fi
      [[ -e "$current" ]] || exists=false
    fi
  done
  return 0
}

agent_path_policy_python() {
  local root="$1"
  local path="$2"
  AGENT_POLICY_ROOT="$root" AGENT_POLICY_PATH="$path" python3 - <<'PY'
import os
import pathlib
import sys

root = os.path.abspath(os.environ["AGENT_POLICY_ROOT"])
path = os.path.abspath(os.environ["AGENT_POLICY_PATH"])
resolved_root = os.path.realpath(root)
resolved_path = os.path.realpath(path)


def is_descendant(candidate, parent):
    if candidate == parent:
        return False
    try:
        return os.path.commonpath((candidate, parent)) == parent
    except ValueError:
        return False


def has_excluded_component(candidate, parent):
    relative = os.path.relpath(candidate, parent)
    if relative == "." or relative == os.pardir or relative.startswith(os.pardir + os.sep):
        return True
    parts = pathlib.PurePath(relative).parts
    excluded = {
        ".git", ".tools", ".idea", ".next", "node_modules", "Pods", "vendor",
        "build", "dist", "out", "local.properties", "keystore.properties",
    }
    for part in parts:
        if part in excluded or part.startswith(".gradle") or part.startswith(".env"):
            return True
        if part.endswith((".jks", ".keystore", ".pem", ".p8", ".key")):
            return True
    for index, part in enumerate(parts[:-1]):
        if part == ".agents" and parts[index + 1] in {"runtime", "state", "cache"}:
            return True
    return False


if (
    not is_descendant(path, root)
    or not is_descendant(resolved_path, resolved_root)
    or has_excluded_component(path, root)
    or has_excluded_component(resolved_path, resolved_root)
):
    sys.exit(1)
PY
}

agent_is_real_directory() {
  local root="$1"
  local path="$2"
  [[ -d "$path" ]] && agent_path_is_eligible "$root" "$path"
}

agent_is_real_regular_file() {
  local root="$1"
  local path="$2"
  [[ -f "$path" ]] && agent_path_is_eligible "$root" "$path"
}

agent_flutter_android_module_has_evidence() {
  local root="$1"
  local module_dir="$2"
  local manifest
  agent_is_real_directory "$root" "$module_dir" || return 1
  if agent_is_real_regular_file "$root" "$module_dir/build.gradle" ||
    agent_is_real_regular_file "$root" "$module_dir/build.gradle.kts"; then
    return 0
  fi
  while IFS= read -r manifest; do
    if [[ -n "$manifest" ]] && agent_is_real_regular_file "$root" "$manifest"; then
      return 0
    fi
  done < <(
    find -H "$module_dir" -maxdepth 6 \
      \( -type d \( -name .git -o -name .tools -o -name .gradle -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
      -name AndroidManifest.xml -print 2>/dev/null
  )
  return 1
}

agent_flutter_android_module_is_kotlin() {
  local root="$1"
  local module_dir="$2"
  local source_file
  if agent_is_real_regular_file "$root" "$module_dir/build.gradle" &&
    grep -Eq 'kotlin-android|org\.jetbrains\.kotlin\.|kotlin\("?(android|jvm|multiplatform)' "$module_dir/build.gradle" 2>/dev/null; then
    return 0
  fi
  if agent_is_real_regular_file "$root" "$module_dir/build.gradle.kts" &&
    grep -Eq 'kotlin-android|org\.jetbrains\.kotlin\.|kotlin\("?(android|jvm|multiplatform)' "$module_dir/build.gradle.kts" 2>/dev/null; then
    return 0
  fi
  source_file="$(find -H "$module_dir" -maxdepth 6 \
    \( -type d \( -name .git -o -name .tools -o -name .gradle -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name '*.kt' -print 2>/dev/null | while IFS= read -r source_file; do
      if agent_is_real_regular_file "$root" "$source_file"; then printf '%s\n' "$source_file"; break; fi
    done)"
  [[ -n "$source_file" ]] && agent_is_real_regular_file "$root" "$source_file"
}

agent_detect_flutter_android_verification() {
  local root="$1"
  local android="$root/android"
  local settings_file=""
  local module module_dir
  local has_evidence=false
  local has_kotlin=false
  local nested_modules=()

  agent_is_real_directory "$root" "$android" || return 1
  if agent_is_real_regular_file "$root" "$android/settings.gradle.kts"; then
    settings_file="$android/settings.gradle.kts"
  elif agent_is_real_regular_file "$root" "$android/settings.gradle"; then
    settings_file="$android/settings.gradle"
  else
    return 1
  fi

  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    agent_gradle_module_name_is_safe "$module" || continue
    module_dir="$(agent_gradle_module_dir "$android" "$module")"
    if agent_flutter_android_module_has_evidence "$root" "$module_dir"; then
      agent_add_unique AGENT_MODULES "$module"
      nested_modules+=("$module")
      has_evidence=true
      if agent_flutter_android_module_is_kotlin "$root" "$module_dir"; then
        has_kotlin=true
      fi
    fi
  done < <(
    grep -E '^[[:space:]]*include[[:space:]]*(\(|[[:space:]])' "$settings_file" 2>/dev/null |
      grep -Eo ':[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)*' |
      sort -u
  )

  [[ "$has_evidence" == "true" ]] || {
    agent_add_unique AGENT_WARNINGS "Flutter Android platform skipped: no eligible Gradle module build/manifest evidence under android/."
    return 1
  }

  if [[ "$has_kotlin" == "true" ]]; then
    agent_add_unique AGENT_TECH_STACKS "android_kotlin"
  else
    agent_add_unique AGENT_TECH_STACKS "android_java"
  fi
  agent_add_unique AGENT_WARNINGS "Flutter Android module paths are relative to android/: ${nested_modules[*]}"
  agent_add_unique AGENT_VERIFY_COMMANDS "flutter build appbundle --release"
  if agent_is_real_regular_file "$root" "$android/gradlew" && [[ -x "$android/gradlew" ]]; then
    agent_add_unique AGENT_VERIFY_COMMANDS "./android/gradlew -p android testDebugUnitTest"
  fi
  return 0
}

agent_posix_shell_quote() {
  AGENT_QUOTE_VALUE="$1" python3 - <<'PY'
import os
import shlex

print(shlex.quote(os.environ["AGENT_QUOTE_VALUE"]), end="")
PY
}

agent_find_eligible_xcode_containers() {
  local root="$1"
  local candidate relative
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" == "$root/"* ]] || continue
    [[ -d "$candidate" ]] || continue
    agent_path_is_eligible "$root" "$candidate" || continue
    relative="${candidate#"$root/"}"
    case "$relative" in
      *.xcodeproj/project.xcworkspace) continue ;;
    esac
    printf '%s\n' "$relative"
  done < <(
    find "$root" -maxdepth 3 \
      \( -type d \( -name .git -o -name .tools -o -name .gradle -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
      \( -type d -o -type l \) \( -name '*.xcworkspace' -o -name '*.xcodeproj' \) -print 2>/dev/null |
      sort
  )
}

agent_any_named_file_contains() {
  local root="$1"
  local maxdepth="$2"
  local regex="$3"
  shift 3

  local name file
  for name in "$@"; do
    while IFS= read -r file; do
      if agent_is_real_regular_file "$root" "$file" && grep -Eq "$regex" "$file" 2>/dev/null; then
        return 0
      fi
    done < <(
      find "$root" -maxdepth "$maxdepth" \
        \( -type d \( -name .git -o -name .tools -o -name '.gradle*' -o -name .idea -o -name .next -o -name build -o -name dist -o -name out -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
        -name "$name" -print 2>/dev/null
    )
  done
  return 1
}

agent_manifest_file_has() {
  local root="$1"
  local relative="$2"
  local regex="$3"
  agent_is_real_regular_file "$root" "$root/$relative" || return 1
  grep -Eq "$regex" "$root/$relative" 2>/dev/null
}

agent_package_json_has() {
  local root="$1"
  local regex="$2"
  agent_manifest_file_has "$root" "package.json" "$regex"
}

agent_composer_json_has() {
  local root="$1"
  local regex="$2"
  agent_manifest_file_has "$root" "composer.json" "$regex"
}

agent_package_json_has_script() {
  local root="$1"
  local script="$2"
  agent_package_json_has "$root" "\"$script\"[[:space:]]*:"
}

agent_add_npm_script_commands() {
  local root="$1"
  local found=false

  if agent_package_json_has_script "$root" "test"; then
    agent_add_unique AGENT_VERIFY_COMMANDS "npm test"
    found=true
  fi
  if agent_package_json_has_script "$root" "lint"; then
    agent_add_unique AGENT_VERIFY_COMMANDS "npm run lint"
    found=true
  fi
  if agent_package_json_has_script "$root" "build"; then
    agent_add_unique AGENT_VERIFY_COMMANDS "npm run build"
    found=true
  fi

  if [[ "$found" != "true" ]]; then
    agent_add_unique AGENT_WARNINGS "package.json has no test/lint/build scripts; do not invent npm verification commands."
  fi
}

agent_add_unique() {
  local array_name="$1"
  local value="$2"
  local existing
  local items=()
  if eval "[[ \${#${array_name}[@]} -gt 0 ]]"; then
    eval "items=(\"\${${array_name}[@]}\")"
  fi
  if [[ ${#items[@]} -gt 0 ]]; then
    for existing in "${items[@]}"; do
      [[ "$existing" == "$value" ]] && return
    done
  fi
  eval "${array_name}+=(\"\$value\")"
}

agent_has_detected_module() {
  local expected="$1"
  local existing
  if [[ ${#AGENT_MODULES[@]} -gt 0 ]]; then
    for existing in "${AGENT_MODULES[@]}"; do
      [[ "$existing" == "$expected" ]] && return 0
    done
  fi
  return 1
}

agent_gradle_module_dir() {
  local root="$1"
  local module="$2"
  local rel="${module#:}"
  # Bash replacement syntax: replace Gradle path separators with directories.
  rel="${rel//://}"
  printf '%s/%s' "$root" "$rel"
}

agent_gradle_module_name_is_safe() {
  local module="$1"
  [[ ! "$module" =~ (^|:)(\.|\.\.)(:|$) ]]
}

agent_gradle_module_file_contains() {
  local root="$1"
  local module="$2"
  local regex="$3"
  local module_dir
  module_dir="$(agent_gradle_module_dir "$root" "$module")"
  if agent_is_real_regular_file "$root" "$module_dir/build.gradle" &&
    grep -Eq "$regex" "$module_dir/build.gradle" 2>/dev/null; then
    return 0
  fi
  if agent_is_real_regular_file "$root" "$module_dir/build.gradle.kts" &&
    grep -Eq "$regex" "$module_dir/build.gradle.kts" 2>/dev/null; then
    return 0
  fi
  return 1
}

agent_gradle_module_has_build_file() {
  local root="$1"
  local module="$2"
  local module_dir
  module_dir="$(agent_gradle_module_dir "$root" "$module")"
  agent_is_real_regular_file "$root" "$module_dir/build.gradle" ||
    agent_is_real_regular_file "$root" "$module_dir/build.gradle.kts"
}

agent_gradle_module_has_android_signal() {
  local root="$1"
  local module="$2"
  local module_dir
  module_dir="$(agent_gradle_module_dir "$root" "$module")"
  [[ -d "$module_dir" ]] || return 1
  if agent_gradle_module_file_contains "$root" "$module" 'com\.android\.(application|library)'; then
    return 0
  fi
  [[ -n "$(agent_find_name "$root" 6 AndroidManifest.xml "$module_dir")" ]]
}

agent_android_module_variant_prefix() {
  local root="$1"
  local module="$2"
  if agent_gradle_module_file_contains "$root" "$module" 'create\("prod"\)|prod[[:space:]]*[{]'; then
    printf '%s' "Prod"
  fi
}

agent_add_gradle_module_verification_commands() {
  local root="$1"
  local android_project="$2"
  local module module_prefix added_any=false

  if [[ ${#AGENT_MODULES[@]} -gt 0 ]]; then
    for module in "${AGENT_MODULES[@]}"; do
      case "$module" in
        ""|"No Gradle modules detected") continue ;;
      esac
      if [[ "$android_project" == "true" ]] && agent_gradle_module_has_android_signal "$root" "$module"; then
        module_prefix="$(agent_android_module_variant_prefix "$root" "$module")"
        if [[ -n "$module_prefix" ]]; then
          agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew $module:test${module_prefix}DebugUnitTest"
          agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew $module:assemble${module_prefix}Debug"
        else
          agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew $module:testDebugUnitTest"
          agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew $module:assembleDebug"
        fi
        added_any=true
      elif agent_gradle_module_has_build_file "$root" "$module"; then
        agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew $module:test"
        added_any=true
      fi
    done
  fi

  if [[ "$added_any" != "true" ]]; then
    if [[ "$android_project" == "true" ]]; then
      agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew test"
      agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew assembleDebug"
    else
      agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew test"
    fi
  fi
}

agent_detect_gradle_modules() {
  local root="$1"
  local settings_file=""
  if agent_has_file "$root" "settings.gradle.kts"; then
    settings_file="$root/settings.gradle.kts"
  elif agent_has_file "$root" "settings.gradle"; then
    settings_file="$root/settings.gradle"
  else
    return 0
  fi

  local module
  while IFS= read -r module; do
    [[ -n "$module" ]] && agent_add_unique AGENT_MODULES "$module"
  done < <(
    grep -E '^[[:space:]]*include[[:space:]]*(\(|[[:space:]])' "$settings_file" 2>/dev/null |
      grep -Eo ':[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)*' |
      sort -u
  )
}

agent_detect_tech_stack() {
  local root="$1"
  local is_flutter=false
  agent_reset_detection
  agent_detect_gradle_modules "$root"

  if { agent_has_file "$root" "settings.gradle" || agent_has_file "$root" "settings.gradle.kts"; } &&
    { [[ -n "$(agent_find_name "$root" 5 AndroidManifest.xml)" ]] ||
      agent_any_named_file_contains "$root" 4 'com\.android\.(application|library)' "build.gradle" "build.gradle.kts"; }; then
    if agent_any_named_file_contains "$root" 4 'kotlin-android|org\.jetbrains\.kotlin\.android|kotlin\("android"\)' "build.gradle" "build.gradle.kts"; then
      agent_add_unique AGENT_TECH_STACKS "android_kotlin"
    else
      agent_add_unique AGENT_TECH_STACKS "android_java"
    fi
    agent_add_gradle_module_verification_commands "$root" true
  elif agent_has_file "$root" "settings.gradle" || agent_has_file "$root" "settings.gradle.kts" || agent_has_file "$root" "build.gradle" || agent_has_file "$root" "build.gradle.kts"; then
    if agent_any_named_file_contains "$root" 4 'org\.jetbrains\.kotlin|kotlin\("jvm"\)|kotlin\("multiplatform"\)' "build.gradle" "build.gradle.kts"; then
      agent_add_unique AGENT_TECH_STACKS "kotlin_gradle"
    else
      agent_add_unique AGENT_TECH_STACKS "java_gradle"
    fi
    agent_add_gradle_module_verification_commands "$root" false
  fi

  if agent_is_real_directory "$root" "$root/wear" || agent_is_real_directory "$root" "$root/wear-api"; then
    agent_add_unique AGENT_TECH_STACKS "wear_os"
  fi
  if agent_has_detected_module ":wear"; then
    local wear_prefix
    wear_prefix="$(agent_android_module_variant_prefix "$root" ":wear")"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew :wear:compile${wear_prefix}DebugKotlin"
  fi

  if agent_is_real_directory "$root" "$root/health-core" || agent_has_detected_module ":health-core"; then
    agent_add_unique AGENT_TECH_STACKS "kotlin_domain_module"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew :health-core:test"
  elif agent_is_real_directory "$root" "$root/hiit-core" || agent_has_detected_module ":hiit-core"; then
    agent_add_unique AGENT_TECH_STACKS "kotlin_domain_module"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew :hiit-core:test"
  fi

  if agent_has_file "$root" "pom.xml"; then
    agent_add_unique AGENT_TECH_STACKS "java_maven"
    agent_add_unique AGENT_VERIFY_COMMANDS "mvn test"
  fi

  if agent_has_file "$root" "package.json"; then
    local node_stack_detected=false
    if agent_package_json_has "$root" '"next"[[:space:]]*:'; then
      agent_add_unique AGENT_TECH_STACKS "nextjs"
      node_stack_detected=true
    elif agent_package_json_has "$root" '"react"[[:space:]]*:'; then
      agent_add_unique AGENT_TECH_STACKS "react"
      node_stack_detected=true
    elif agent_package_json_has "$root" '"vue"[[:space:]]*:'; then
      agent_add_unique AGENT_TECH_STACKS "vue"
      node_stack_detected=true
    elif agent_package_json_has "$root" '"svelte"[[:space:]]*:'; then
      agent_add_unique AGENT_TECH_STACKS "svelte"
      node_stack_detected=true
    elif agent_package_json_has "$root" '"(main|module|exports|bin|workspaces|type)"[[:space:]]*:' ||
      agent_has_file "$root" "server.js" ||
      agent_has_file "$root" "index.js" ||
      [[ -d "$root/src" && -n "$(agent_find_name_pattern "$root/src" 3 "*.js")$(agent_find_name_pattern "$root/src" 3 "*.ts")" ]]; then
      agent_add_unique AGENT_TECH_STACKS "node_js"
      node_stack_detected=true
    fi

    if [[ "$node_stack_detected" == "true" ]]; then
      agent_add_npm_script_commands "$root"
    else
      agent_add_unique AGENT_WARNINGS "package.json exists but lacks production Node/Web signals; treat it as tooling until confirmed."
    fi
  fi

  if agent_has_file "$root" "pubspec.yaml"; then
    is_flutter=true
    agent_add_unique AGENT_TECH_STACKS "flutter_dart"
    agent_add_unique AGENT_VERIFY_COMMANDS "flutter test"
    agent_add_unique AGENT_VERIFY_COMMANDS "flutter analyze"
    agent_detect_flutter_android_verification "$root" || true
  fi

  if agent_has_file "$root" "pyproject.toml" || agent_has_file "$root" "requirements.txt" || agent_has_file "$root" "poetry.lock"; then
    if agent_any_named_file_contains "$root" 5 'fastapi' "pyproject.toml" "requirements.txt"; then
      agent_add_unique AGENT_TECH_STACKS "python_fastapi"
    elif agent_any_named_file_contains "$root" 5 'django' "pyproject.toml" "requirements.txt"; then
      agent_add_unique AGENT_TECH_STACKS "python_django"
    else
      agent_add_unique AGENT_TECH_STACKS "python"
    fi
    agent_add_unique AGENT_VERIFY_COMMANDS "python -m pytest"
    agent_add_unique AGENT_VERIFY_COMMANDS "ruff check ."
  fi

  if agent_has_file "$root" "go.mod"; then
    agent_add_unique AGENT_TECH_STACKS "go"
    agent_add_unique AGENT_VERIFY_COMMANDS "go test ./..."
  fi

  if agent_has_file "$root" "Cargo.toml"; then
    agent_add_unique AGENT_TECH_STACKS "rust"
    agent_add_unique AGENT_VERIFY_COMMANDS "cargo test"
    agent_add_unique AGENT_VERIFY_COMMANDS "cargo clippy --all-targets --all-features"
  fi

  local selected_xcode=""
  local workspace_xcode=""
  local project_xcode=""
  local flutter_runner_ios=false
  local xcode_container
  local xcode_containers=()
  if [[ "$is_flutter" == "true" ]]; then
    if agent_is_real_directory "$root" "$root/ios/Runner.xcodeproj" ||
      agent_is_real_directory "$root" "$root/ios/Runner.xcworkspace"; then
      flutter_runner_ios=true
    fi
  fi
  while IFS= read -r xcode_container; do
    [[ -n "$xcode_container" ]] && xcode_containers+=("$xcode_container")
  done < <(agent_find_eligible_xcode_containers "$root")
  if [[ ${#xcode_containers[@]} -gt 0 ]]; then
    for xcode_container in "${xcode_containers[@]}"; do
      case "$xcode_container" in
        *.xcworkspace)
          [[ -n "$workspace_xcode" ]] || workspace_xcode="$xcode_container"
          ;;
        *.xcodeproj)
          [[ -n "$project_xcode" ]] || project_xcode="$xcode_container"
          ;;
      esac
    done
  fi
  if [[ -n "$workspace_xcode" ]]; then
    selected_xcode="$workspace_xcode"
  else
    selected_xcode="$project_xcode"
  fi
  if [[ -n "$selected_xcode" ]]; then
    agent_add_unique AGENT_TECH_STACKS "ios_swift"
    local selected_xcode_arg
    selected_xcode_arg="$(agent_posix_shell_quote "$selected_xcode")"
    if [[ -n "$workspace_xcode" ]]; then
      agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild -list -workspace $selected_xcode_arg"
    else
      agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild -list -project $selected_xcode_arg"
    fi
    if [[ "$flutter_runner_ios" == "true" ]]; then
      agent_add_unique AGENT_VERIFY_COMMANDS "flutter build ios --release --no-codesign"
      agent_add_unique AGENT_WARNINGS "Flutter iOS release build verifies native compilation; RunnerTests build/execution remains explicit in project docs."
    else
      if [[ -n "$workspace_xcode" ]]; then
        agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild test -scheme <scheme> -destination 'platform=iOS Simulator,name=iPhone 15' -workspace $selected_xcode_arg"
      else
        agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild test -scheme <scheme> -destination 'platform=iOS Simulator,name=iPhone 15' -project $selected_xcode_arg"
      fi
      agent_add_unique AGENT_WARNINGS "xcodebuild -list is discovery only; replace <scheme> with a real shared scheme before claiming iOS build/test verification."
    fi
    if [[ ${#xcode_containers[@]} -gt 1 ]]; then
      agent_add_unique AGENT_WARNINGS "multiple eligible Xcode containers found; selected $selected_xcode (workspace preferred over project)."
    fi
  fi

  if agent_has_file "$root" "Package.swift"; then
    agent_add_unique AGENT_TECH_STACKS "swift_package"
    agent_add_unique AGENT_VERIFY_COMMANDS "swift test"
  fi

  if agent_has_file "$root" "Podfile"; then
    agent_add_unique AGENT_TECH_STACKS "ios_cocoapods"
    agent_add_unique AGENT_WARNINGS "Podfile detected; inspect CocoaPods workspace and do not assume xcodeproj-only verification."
  fi

  if [[ -n "$(agent_find_file_pattern "$root" 5 "*Watch*.swift")" || -n "$(agent_find_name_pattern "$root" 5 "*WatchKit*")" ]]; then
    agent_add_unique AGENT_TECH_STACKS "watch_os"
    agent_add_unique AGENT_WARNINGS "watchOS signals detected; include watch target/scheme verification when relevant."
  fi

  if [[ -n "$(agent_find_file_pattern "$root" 3 "*.csproj")" || -n "$(agent_find_file_pattern "$root" 3 "*.sln")" ]]; then
    agent_add_unique AGENT_TECH_STACKS "dotnet"
    agent_add_unique AGENT_VERIFY_COMMANDS "dotnet test"
  fi

  if agent_has_file "$root" "composer.json"; then
    if agent_composer_json_has "$root" '"laravel/framework"[[:space:]]*:'; then
      agent_add_unique AGENT_TECH_STACKS "php_laravel"
    else
      agent_add_unique AGENT_TECH_STACKS "php"
    fi
    agent_add_unique AGENT_VERIFY_COMMANDS "composer test"
  fi

  if agent_sensitive_file_present "$root" "local.properties"; then
    agent_add_unique AGENT_WARNINGS "local.properties exists and must remain local-only."
  fi

  if agent_sensitive_file_present "$root" "keystore.properties"; then
    agent_add_unique AGENT_WARNINGS "keystore.properties exists; never print or commit secrets."
  fi

  if [[ ${#AGENT_TECH_STACKS[@]} -eq 0 ]]; then
    agent_add_unique AGENT_TECH_STACKS "generic"
    agent_add_unique AGENT_VERIFY_COMMANDS "Add project-specific build/test commands in docs/agent-configs/project-agent-context.md"
  fi

  # A detected stack without runnable commands (for example wear/ without
  # Gradle settings) still needs a pointer; callers expand the list under set -u.
  if [[ ${#AGENT_VERIFY_COMMANDS[@]} -eq 0 ]]; then
    agent_add_unique AGENT_VERIFY_COMMANDS "Add project-specific build/test commands in docs/agent-configs/project-agent-context.md"
  fi

  if [[ ${#AGENT_MODULES[@]} -eq 0 ]]; then
    agent_add_unique AGENT_MODULES "No Gradle modules detected"
  fi
}

agent_print_items() {
  local item
  for item in "$@"; do
    printf -- '- %s\n' "\`$item\`"
  done
}

agent_print_summary() {
  printf 'tech_stack_lib_version=%s\n' "$AGENT_TECH_STACK_LIB_VERSION"
  printf 'tech_stacks=%s\n' "${AGENT_TECH_STACKS[*]}"
  printf 'modules=%s\n' "${AGENT_MODULES[*]}"
  printf 'verification_commands=%s\n' "${AGENT_VERIFY_COMMANDS[*]}"
  printf 'warnings=%s\n' "${AGENT_WARNINGS[*]:-}"
}

agent_json_escape() {
  JSON_ESCAPE_VALUE="$1" python3 - <<'PY'
import json
import os
print(json.dumps(os.environ.get("JSON_ESCAPE_VALUE", ""), ensure_ascii=False)[1:-1], end="")
PY
}

agent_print_json_array() {
  local first=true
  local item
  printf '['
  for item in "$@"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(agent_json_escape "$item")"
  done
  printf ']'
}

agent_print_json() {
  printf '{"schema":"agent-tech-stack-detection/v1"'
  printf ',"tech_stack_lib_version":"%s"' "$(agent_json_escape "$AGENT_TECH_STACK_LIB_VERSION")"
  printf ',"tech_stacks":'
  agent_print_json_array ${AGENT_TECH_STACKS[@]+"${AGENT_TECH_STACKS[@]}"}
  printf ',"modules":'
  agent_print_json_array ${AGENT_MODULES[@]+"${AGENT_MODULES[@]}"}
  printf ',"verification_commands":'
  agent_print_json_array ${AGENT_VERIFY_COMMANDS[@]+"${AGENT_VERIFY_COMMANDS[@]}"}
  printf ',"warnings":'
  agent_print_json_array ${AGENT_WARNINGS[@]+"${AGENT_WARNINGS[@]}"}
  printf '}\n'
}

agent_print_markdown() {
  local root="$1"
  printf '# Detected Agent Tech Stack\n\n'
  printf "Detector library version: \`%s\`\n\n" "$AGENT_TECH_STACK_LIB_VERSION"
  printf "Project root: \`%s\`\n\n" "$root"
  printf '## Tech Stacks\n\n'
  agent_print_items "${AGENT_TECH_STACKS[@]}"
  printf '\n## Gradle Modules\n\n'
  agent_print_items "${AGENT_MODULES[@]}"
  printf '\n## Verification Candidates\n\n'
  agent_print_items "${AGENT_VERIFY_COMMANDS[@]}"
  if [[ ${#AGENT_WARNINGS[@]} -gt 0 ]]; then
    printf '\n## Safety Warnings\n\n'
    agent_print_items "${AGENT_WARNINGS[@]}"
  fi
  printf "\nDetection is file-signature based. Apply \`docs/agent-configs/project-agent-context.md\` for repo-specific rules.\n"
}
EOF_TECH_STACK_LIB
}

load_embedded_tech_stack_lib() {
  local tmp_lib
  tmp_lib="$(mktemp)"
  emit_tech_stack_lib > "$tmp_lib"
  # shellcheck source=/dev/null
  source "$tmp_lib"
  rm -f "$tmp_lib"
}

detect_tech_stack() {
  load_embedded_tech_stack_lib
  agent_detect_tech_stack "$TARGET_DIR"
  TECH_STACKS=()
  MODULES=()
  VERIFY_COMMANDS=()
  WARNINGS=()
  if [[ ${#AGENT_TECH_STACKS[@]} -gt 0 ]]; then
    TECH_STACKS=("${AGENT_TECH_STACKS[@]}")
  fi
  if [[ ${#AGENT_MODULES[@]} -gt 0 ]]; then
    MODULES=("${AGENT_MODULES[@]}")
  fi
  if [[ ${#AGENT_VERIFY_COMMANDS[@]} -gt 0 ]]; then
    VERIFY_COMMANDS=("${AGENT_VERIFY_COMMANDS[@]}")
  fi
  if [[ ${#AGENT_WARNINGS[@]} -gt 0 ]]; then
    WARNINGS=("${AGENT_WARNINGS[@]}")
  fi
}

detector_summary_for_lock() {
  printf 'tech_stack_lib_version=%s\n' "${AGENT_TECH_STACK_LIB_VERSION:-unknown}"
  printf 'tech_stacks=%s\n' "${TECH_STACKS[*]}"
  printf 'modules=%s\n' "${MODULES[*]}"
  printf 'verification_commands=%s\n' "${VERIFY_COMMANDS[*]}"
  printf 'warnings=%s\n' "${WARNINGS[*]:-}"
}
