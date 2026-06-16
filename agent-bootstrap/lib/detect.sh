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
# Shared tech-stack detection library for agent bootstrap/runtime scripts.
# Keep this file portable: bash 3.2 compatible, no repo-specific paths.

AGENT_TECH_STACK_LIB_VERSION="2026.05.12.3"

agent_reset_detection() {
  AGENT_TECH_STACKS=()
  AGENT_MODULES=()
  AGENT_VERIFY_COMMANDS=()
  AGENT_WARNINGS=()
}

agent_has_file() {
  local root="$1"
  local relative="$2"
  [[ -f "$root/$relative" ]]
}

agent_find_name() {
  local root="$1"
  local maxdepth="$2"
  local name="$3"
  find "$root" -maxdepth "$maxdepth" \
    \( -type d \( -name .git -o -name .gradle -o -name .idea -o -name .next -o -name build -o -name dist -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name "$name" -print -quit 2>/dev/null
}

agent_find_name_pattern() {
  local root="$1"
  local maxdepth="$2"
  local pattern="$3"
  find "$root" -maxdepth "$maxdepth" \
    \( -type d \( -name .git -o -name .gradle -o -name .idea -o -name .next -o -name build -o -name dist -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
    -name "$pattern" -print -quit 2>/dev/null
}

agent_any_named_file_contains() {
  local root="$1"
  local maxdepth="$2"
  local regex="$3"
  shift 3

  local name file
  for name in "$@"; do
    while IFS= read -r file; do
      if grep -Eq "$regex" "$file" 2>/dev/null; then
        return 0
      fi
    done < <(
      find "$root" -maxdepth "$maxdepth" \
        \( -type d \( -name .git -o -name .gradle -o -name .idea -o -name .next -o -name build -o -name dist -o -name node_modules -o -name Pods -o -name vendor \) -prune \) -o \
        -type f -name "$name" -print 2>/dev/null
    )
  done
  return 1
}

agent_package_json_has() {
  local root="$1"
  local regex="$2"
  grep -Eq "$regex" "$root/package.json" 2>/dev/null
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
      grep -Eo ':[A-Za-z0-9_.-]+' |
      sort -u
  )
}

agent_detect_tech_stack() {
  local root="$1"
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
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew test"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew assembleDebug"
  elif agent_has_file "$root" "settings.gradle" || agent_has_file "$root" "settings.gradle.kts" || agent_has_file "$root" "build.gradle" || agent_has_file "$root" "build.gradle.kts"; then
    if agent_any_named_file_contains "$root" 4 'org\.jetbrains\.kotlin|kotlin\("jvm"\)|kotlin\("multiplatform"\)' "build.gradle" "build.gradle.kts"; then
      agent_add_unique AGENT_TECH_STACKS "kotlin_gradle"
    else
      agent_add_unique AGENT_TECH_STACKS "java_gradle"
    fi
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew test"
  fi

  if [[ -d "$root/wear" || -d "$root/wear-api" ]]; then
    agent_add_unique AGENT_TECH_STACKS "wear_os"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew :wear:compileDebugKotlin"
  fi

  if [[ -d "$root/health-core" ]] || agent_has_detected_module ":health-core"; then
    agent_add_unique AGENT_TECH_STACKS "kotlin_domain_module"
    agent_add_unique AGENT_VERIFY_COMMANDS "./gradlew :health-core:test"
  elif [[ -d "$root/hiit-core" ]] || agent_has_detected_module ":hiit-core"; then
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
    agent_add_unique AGENT_TECH_STACKS "flutter_dart"
    agent_add_unique AGENT_VERIFY_COMMANDS "flutter test"
    agent_add_unique AGENT_VERIFY_COMMANDS "flutter analyze"
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

  local has_xcode_project=false
  if [[ -n "$(agent_find_name_pattern "$root" 3 "*.xcodeproj")" || -n "$(agent_find_name_pattern "$root" 3 "*.xcworkspace")" ]]; then
    has_xcode_project=true
    agent_add_unique AGENT_TECH_STACKS "ios_swift"
    agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild -list"
    agent_add_unique AGENT_VERIFY_COMMANDS "xcodebuild test -scheme <scheme> -destination 'platform=iOS Simulator,name=iPhone 15'"
    agent_add_unique AGENT_WARNINGS "xcodebuild -list is discovery only; replace <scheme> with a real shared scheme before claiming iOS build/test verification."
  fi

  if agent_has_file "$root" "Package.swift"; then
    agent_add_unique AGENT_TECH_STACKS "swift_package"
    agent_add_unique AGENT_VERIFY_COMMANDS "swift test"
  fi

  if agent_has_file "$root" "Podfile"; then
    agent_add_unique AGENT_TECH_STACKS "ios_cocoapods"
    agent_add_unique AGENT_WARNINGS "Podfile detected; inspect CocoaPods workspace and do not assume xcodeproj-only verification."
  fi

  if [[ -n "$(agent_find_name_pattern "$root" 5 "*Watch*.swift")" || -n "$(agent_find_name_pattern "$root" 5 "*WatchKit*")" ]]; then
    agent_add_unique AGENT_TECH_STACKS "watch_os"
    agent_add_unique AGENT_WARNINGS "watchOS signals detected; include watch target/scheme verification when relevant."
  fi

  if [[ -n "$(agent_find_name_pattern "$root" 3 "*.csproj")" || -n "$(agent_find_name_pattern "$root" 3 "*.sln")" ]]; then
    agent_add_unique AGENT_TECH_STACKS "dotnet"
    agent_add_unique AGENT_VERIFY_COMMANDS "dotnet test"
  fi

  if agent_has_file "$root" "composer.json"; then
    if grep -Eq '"laravel/framework"[[:space:]]*:' "$root/composer.json" 2>/dev/null; then
      agent_add_unique AGENT_TECH_STACKS "php_laravel"
    else
      agent_add_unique AGENT_TECH_STACKS "php"
    fi
    agent_add_unique AGENT_VERIFY_COMMANDS "composer test"
  fi

  if agent_has_file "$root" "local.properties"; then
    agent_add_unique AGENT_WARNINGS "local.properties exists and must remain local-only."
  fi

  if agent_has_file "$root" "keystore.properties"; then
    agent_add_unique AGENT_WARNINGS "keystore.properties exists; never print or commit secrets."
  fi

  if [[ ${#AGENT_TECH_STACKS[@]} -eq 0 ]]; then
    agent_add_unique AGENT_TECH_STACKS "generic"
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
