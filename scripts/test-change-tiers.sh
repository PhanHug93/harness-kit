#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { printf 'change-tiers-test: FAIL: %s\n' "$*" >&2; exit 1; }
TMP_ROOT="$(mktemp -d)"
# A test makes a packet read-only; give write access back before removing.
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

fresh_target() {
  local dir
  dir="$(mktemp -d "$TMP_ROOT/target.XXXXXX")"
  git -C "$dir" init -q -b main || fail "git init failed in $dir"
  git -C "$dir" config user.name "Test" || fail "git config user.name failed in $dir"
  git -C "$dir" config user.email "test@example.invalid" || fail "git config user.email failed in $dir"
  mkdir -p "$dir/src"
  printf 'export const a = 1;\n' >"$dir/src/app.ts"
  git -C "$dir" add src/app.ts || fail "git add failed in $dir"
  git -C "$dir" commit -q -m init || fail "git commit failed in $dir"
  bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" \
    --target "$dir" --workflow full --project-name budget-fixture >/dev/null \
    || fail "bootstrap failed"
  printf '%s\n' "$dir"
}

# failing_checks <target>: prints one JSON line per failing verifier check.
failing_checks() {
  local dir="$1" out
  out="$({ cd "$dir" && scripts/verify-ai-deps.sh --json 2>"${2:-/dev/null}"; } || true)"
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for c in d["checks"]:
    if c.get("status") == "fail":
        print(json.dumps(c))
'
}

target="$(fresh_target)"
policy="$target/docs/agent-configs/context-policy.json"

python3 - "$policy" <<'PY' || fail "context policy lists are wrong"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["tier_rules"] == {"small": {"max_files": 3, "max_lines": 60}, "medium": {"max_files": 15, "max_lines": 500}}, d["tier_rules"]
assert d["risk_tokens"] == ["auth","oauth","login","signin","session","sessions","permission","permissions","payment","payments","billing","checkout","secret","secrets","credential","credentials","authentication","authorization","authorize","password","passwords","jwt"], d["risk_tokens"]
assert d["risk_paths"] == ["**/migrations/**","**/migrate/**","**/migration/**","**/*.sql","**/schema.*","**/.env*","**/*.pem","**/*.key",".github/workflows/**","**/Dockerfile","**/Dockerfile.*","**/*.dockerfile","**/*.tf","**/*.tfvars"], d["risk_paths"]
assert d["dependency_manifests"] == ["package.json","Podfile","Package.swift","Gemfile","go.mod","Cargo.toml","requirements*.txt","pyproject.toml","Pipfile","pubspec.yaml","composer.json","build.gradle","build.gradle.kts","libs.versions.toml",".gitmodules"], d["dependency_manifests"]
assert d["dependency_locks"] == ["package-lock.json","yarn.lock","pnpm-lock.yaml","Podfile.lock","Package.resolved","Gemfile.lock","go.sum","Cargo.lock","poetry.lock","uv.lock","Pipfile.lock","pubspec.lock","composer.lock"], d["dependency_locks"]
assert d["test_patterns"]["dirs"] == ["test","tests","__tests__","spec"], d["test_patterns"]
assert d["test_patterns"]["names"] == ["*_test.*","*.test.*","*.spec.*","test_*.py","*Tests.swift","*Test.kt","*Test.java"], d["test_patterns"]
assert d["binary_asset_extensions"] == ["png","jpg","jpeg","gif","webp","avif","heic","bmp","tif","tiff","ico","icns","ttf","otf","woff","woff2","eot","mp3","wav","ogg","m4a","aac","flac","mp4","mov","webm","m4v","pdf"], d["binary_asset_extensions"]
PY

[[ -f "$target/docs/agent-configs/bootstrap-multi-agent-project/schemas/harness-tier-v1.schema.json" ]] \
  || fail "tier schema missing from the target schema catalog"

# The tier program: compiles, ships executable and unchanged into targets.
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$ROOT_DIR/agent-bootstrap/agent-tier.py" \
  || fail "agent-tier.py does not compile"
[[ -x "$target/scripts/agent-tier.py" ]] || fail "target scripts/agent-tier.py is missing or not executable"
cmp -s "$ROOT_DIR/agent-bootstrap/agent-tier.py" "$target/scripts/agent-tier.py" \
  || fail "target scripts/agent-tier.py differs from the bundle"
exclude_file="$(git -C "$target" rev-parse --git-path info/exclude)"
case "$exclude_file" in /*) ;; *) exclude_file="$target/$exclude_file" ;; esac
grep -qxF 'scripts/agent-tier.py' "$exclude_file" || fail "scripts/agent-tier.py is not in the local-only ignore block"
git -C "$target" add -f scripts/agent-tier.py || fail "git add -f failed in the target"
local_only_out="$(cd "$target" && bash scripts/agent-local-only-check.sh status 2>&1)" || true
git -C "$target" rm -q --cached scripts/agent-tier.py || fail "git rm --cached failed in the target"
grep -q 'scripts/agent-tier.py.*agent runtime script' <<<"$local_only_out" \
  || fail "a tracked scripts/agent-tier.py is not reported as local-only: $local_only_out"

# Fresh target: no failing checks (warnings are expected).
fails="$(failing_checks "$target")"
[[ -z "$fails" ]] || fail "fresh target has failing checks: $fails"

# Bad type for tier_rules in the context policy fails.
python3 - "$policy" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["tier_rules"] = {"small": 1}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target" "$TMP_ROOT/verify.err")"
grep -q 'bootstrap JSON contracts failed validation' <<<"$fails" || fail "bad tier_rules type not rejected: $fails"
grep -q 'tier_rules' "$TMP_ROOT/verify.err" || fail "stderr does not name tier_rules: $(cat "$TMP_ROOT/verify.err")"

# Old project: new keys absent still passes.
python3 - "$policy" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for k in ("tier_rules", "risk_tokens", "risk_paths", "dependency_manifests", "dependency_locks", "test_patterns",
          "binary_asset_extensions"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
PY
fails="$(failing_checks "$target")"
[[ -z "$fails" ]] || fail "old-style policy has failing checks: $fails"

# Tech-stack contract accepts optional risk_paths.
contract="$target/docs/superpowers/specs/project-tech-stack.json"
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["risk_paths"] = ["app/billing/**"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target")"
[[ -z "$fails" ]] || fail "risk_paths in tech-stack failed: $fails"

# Bad type for risk_paths in the tech-stack contract fails.
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["risk_paths"] = 5
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target")"
grep -q 'project tech-stack contract failed validation' <<<"$fails" || fail "bad risk_paths type not rejected: $fails"
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["risk_paths"] = ["app/billing/**"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

# Tech-stack contract accepts optional binary_asset_extensions; a bad value fails.
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = ["psd"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target")"
[[ -z "$fails" ]] || fail "binary_asset_extensions in tech-stack failed: $fails"
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = [1]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target" "$TMP_ROOT/verify.err")"
grep -q 'project tech-stack contract failed validation' <<<"$fails" || fail "bad binary_asset_extensions not rejected: $fails"
grep -q 'binary_asset_extensions must be an array of non-empty strings' "$TMP_ROOT/verify.err" \
  || fail "stderr does not name binary_asset_extensions: $(cat "$TMP_ROOT/verify.err")"
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = ["."]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target" "$TMP_ROOT/verify.err")"
grep -q 'binary_asset_extensions must hold extensions like png' "$TMP_ROOT/verify.err" \
  || fail "a '.' asset extension is not rejected: $fails $(cat "$TMP_ROOT/verify.err")"
python3 - "$contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("binary_asset_extensions")
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

# Unknown key is still rejected.
python3 - "$policy" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["bogus"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fails="$(failing_checks "$target" "$TMP_ROOT/verify.err")"
grep -q 'bootstrap JSON contracts failed validation' <<<"$fails" || fail "unknown key not rejected: $fails"
grep -q 'unexpected keys: bogus' "$TMP_ROOT/verify.err" || fail "stderr lacks 'unexpected keys: bogus': $(cat "$TMP_ROOT/verify.err")"

# ---- tier suggest ----------------------------------------------------------
tier_target="$(fresh_target)"
TIER_OUT=""
TIER_RC=0

# run_tier <args...>: runs `scripts/agent-guard.sh tier <args...>` in
# tier_target. Sets TIER_OUT (stdout) and TIER_RC; stderr goes to tier.err.
run_tier() {
  TIER_RC=0
  TIER_OUT="$(cd "$tier_target" && scripts/agent-guard.sh tier "$@" 2>"$TMP_ROOT/tier.err")" || TIER_RC=$?
}

# expect_tier <tier> [<reason text>...] -- <suggest args...>: the first line
# is "Suggested: <tier>" and each reason text is part of some "- " line.
expect_tier() {
  local want="$1" reason first
  local reasons=()
  shift
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    reasons+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] || fail "expect_tier needs -- before the suggest args"
  shift
  run_tier suggest "$@"
  [[ "$TIER_RC" -eq 0 ]] || fail "tier suggest $* exited $TIER_RC: $(cat "$TMP_ROOT/tier.err")"
  first="$(printf '%s\n' "$TIER_OUT" | head -n1)"
  [[ "$first" == "Suggested: $want" ]] || fail "tier suggest $*: want $want, got: $TIER_OUT"
  for reason in ${reasons[@]+"${reasons[@]}"}; do
    printf '%s\n' "$TIER_OUT" | sed -n 's/^- //p' | grep -qF -- "$reason" \
      || fail "tier suggest $*: no reason with '$reason' in: $TIER_OUT"
  done
}

# expect_only_tier_line: the last output is the tier line and nothing else.
expect_only_tier_line() {
  [[ "$TIER_OUT" == "$(printf '%s\n' "$TIER_OUT" | head -n1)" ]] \
    || fail "expected no reason lines, got: $TIER_OUT"
}

find_tasks() { (cd "$tier_target" && find .agents/tasks 2>/dev/null | sort) || true; }
mkdir -p "$tier_target/.agents/tasks/earlier-task"
printf '{}\n' >"$tier_target/.agents/tasks/earlier-task/state.json"
tasks_before="$(find_tasks)"

expect_tier small -- --paths app/settings/SettingsView.swift --lines 12
expect_only_tier_line
expect_tier large "risky path: app/payment/Momo.kt (token payment)" -- --paths app/payment/Momo.kt
expect_tier small -- --paths src/author.ts --lines 5
expect_only_tier_line
expect_tier large "risky path: src/hooks/useAuth.ts (token auth)" -- --paths src/hooks/useAuth.ts
expect_tier large "risky path: App/Features/Auth/AuthService.swift (token auth)" -- \
  --paths App/Features/Auth/AuthService.swift
expect_tier large "risky path: Dockerfile (pattern **/Dockerfile)" -- --paths Dockerfile
expect_tier large "risky path: db/schema.sql (pattern **/*.sql)" -- --paths db/schema.sql
expect_tier small -- --paths docs/oauth-notes.md
expect_only_tier_line
expect_tier small -- --paths docs/schema-docs.md
expect_only_tier_line
expect_tier small -- --paths src/latest.ts --lines 10
expect_only_tier_line
if grep -q 'test file' <<<"$TIER_OUT"; then fail "src/latest.ts was called a test: $TIER_OUT"; fi
# Test-name patterns with capitals match case-sensitively; the rest ignore case.
expect_tier small -- --paths src/Latest.kt --lines 5
expect_only_tier_line
expect_tier small -- --paths src/Contest.java --lines 5
expect_only_tier_line
expect_tier small "4 test files not counted" -- \
  --paths src/LatestTest.kt ios/AppTests.swift src/A.TEST.ts Tests/c.ts src/a.ts --lines 5
# Neighbouring words joined: signIn -> signin, logIn -> login.
expect_tier large "risky path: src/signIn.ts (token signin)" -- --paths src/signIn.ts
expect_tier large "risky path: ios/logIn.swift (token login)" -- --paths ios/logIn.swift
expect_tier small -- --paths src/blogInfo.ts --lines 3
expect_only_tier_line
expect_tier medium "4 counted files (small allows 3)" -- --paths a.ts b.ts c.ts d.ts
expect_tier medium "61 counted lines (small allows 60)" -- --paths a.ts --lines 61
many=()
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do many+=("f$n.ts"); done
expect_tier large "16 counted files (medium allows 15)" -- --paths "${many[@]}"
expect_tier large "501 counted lines (medium allows 500)" -- --paths a.ts --lines 501
expect_tier medium "dependency manifest changed: package.json" "1 lock file not counted" -- \
  --paths package.json package-lock.json --lines 3
expect_tier small "2 test files not counted" -- --paths src/a.ts src/a.test.ts tests/b.ts --lines 50
expect_tier medium "files unknown" --
expect_tier large "--data" -- --paths a.ts --data
expect_tier large "--access" -- --paths a.ts --access
expect_tier medium "--dependency" -- --paths a.ts --dependency
expect_tier medium "--unclear" -- --paths a.ts --unclear
expect_tier large "--handoff: the work passes between agents (one plans, another codes)" -- --paths a.ts --handoff
# --paths stops at the next option; --by is accepted. Without --task nothing
# is recorded (checked below); with --task, see "tier set, show and close".
expect_tier large "--data" -- --by @build --paths a.ts b.ts --lines 2 --data

# Every path segment is split into words, joined pairs included.
expect_tier large "risky path: packages/auth-service/src/index.ts (token auth)" -- \
  --paths packages/auth-service/src/index.ts
expect_tier large "risky path: src/payment-gateway/client.ts (token payment)" -- --paths src/payment-gateway/client.ts
expect_tier large "risky path: src/user_sessions/store.ts (token sessions)" -- --paths src/user_sessions/store.ts
# Policy defaults.
expect_tier small -- --paths src/DockerfileParser.ts
expect_only_tier_line
expect_tier large "risky path: deploy/app.dockerfile (pattern **/*.dockerfile)" -- --paths deploy/app.dockerfile
expect_tier large "risky path: db/migration/V1__init.sql (pattern **/migration/**)" -- --paths db/migration/V1__init.sql
expect_tier large "risky path: infra/prod.tfvars (pattern **/*.tfvars)" -- --paths infra/prod.tfvars
expect_tier small -- --paths docs/auth.mdx
expect_only_tier_line
expect_tier large "risky path: src/AuthenticationService.ts (token authentication)" -- --paths src/AuthenticationService.ts
expect_tier medium "4 counted files (small allows 3)" -- --paths docs/superpowers/specs/x.md a.ts b.ts c.ts
expect_tier medium "dependency lock changed: ios/Pods/Podfile.lock" "1 lock file not counted" -- \
  --paths ios/Pods/Podfile.lock
# Boundaries.
expect_tier small -- --paths a.ts b.ts c.ts --lines 60
expect_only_tier_line
fifteen=()
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do fifteen+=("f$n.ts"); done
expect_tier medium "15 counted files (small allows 3)" "500 counted lines (small allows 60)" -- \
  --paths "${fifteen[@]}" --lines 500
# At most 5 risky-path lines; a newline in a path prints as \n.
expect_tier large "… and 2 more" -- --paths auth/1.ts auth/2.ts auth/3.ts auth/4.ts auth/5.ts auth/6.ts auth/7.ts
[[ "$(grep -c '^- risky path:' <<<"$TIER_OUT")" == 5 ]] || fail "expected 5 risky-path lines: $TIER_OUT"
expect_tier large 'risky path: auth/a\nb.ts (token auth)' -- --paths "$(printf 'auth/a\nb.ts')"
[[ "$(grep -c '' <<<"$TIER_OUT")" == 2 ]] || fail "a newline in a path split the output: $TIER_OUT"
# Paths: ../x is refused; absolute paths inside the project are accepted,
# also through the unresolved TMPDIR spelling and a symlinked root.
run_tier suggest --paths ../x.ts
[[ "$TIER_RC" -eq 1 ]] || fail "../x.ts: want exit 1, got $TIER_RC"
grep -q 'outside the project' "$TMP_ROOT/tier.err" || fail "../x.ts message: $(cat "$TMP_ROOT/tier.err")"
expect_tier small -- --paths "$tier_target/src/abs.ts" --lines 1
expect_only_tier_line
ln -s "$tier_target" "$TMP_ROOT/target-link"
expect_tier small -- --paths "$TMP_ROOT/target-link/src/abs.ts" --lines 1
expect_only_tier_line

[[ "$(find_tasks)" == "$tasks_before" ]] || fail "tier suggest changed .agents/tasks"

run_tier suggest --paths a.ts --lines abc
[[ "$TIER_RC" -ne 0 ]] || fail "--lines abc was accepted"
grep -q -- '--lines' "$TMP_ROOT/tier.err" || fail "--lines abc message is unclear: $(cat "$TMP_ROOT/tier.err")"
run_tier suggest --paths a.ts --lines -1
[[ "$TIER_RC" -ne 0 ]] || fail "--lines -1 was accepted"

run_tier
[[ "$TIER_RC" -ne 0 ]] || fail "tier without a subcommand exited 0"
grep -q 'Usage' "$TMP_ROOT/tier.err" || fail "tier without a subcommand printed no usage: $(cat "$TMP_ROOT/tier.err")"

# The main usage shows the same tier synopsis as `tier --help`.
main_synopsis="$(cd "$tier_target" && scripts/agent-guard.sh --help | grep -o 'scripts/agent-guard.sh tier .*')" || true
tier_synopsis="$(cd "$tier_target" && scripts/agent-guard.sh tier --help | grep -o 'scripts/agent-guard.sh tier .*')" || true
[[ -n "$tier_synopsis" && "$main_synopsis" == "$tier_synopsis" ]] \
  || fail "main usage tier synopsis differs: [$main_synopsis] vs [$tier_synopsis]"
for want in 'tier suggest [--task <id>] [--by @seat] [--paths <file>...] [--lines N] [--data] [--access] [--dependency] [--unclear] [--handoff]' \
  'tier stats [--since YYYY-MM-DD] [--json]' \
  'tier set <small|medium|large> --task <id> [--reason TEXT] [--base <ref>] [--by @seat] [--recorded-by @seat] [--answer keep|switch|scope]' \
  'tier show [--task <id>] [--pr-line]' 'tier close --task <id>'; do
  grep -qF -- "$want" <<<"$tier_synopsis" || fail "tier synopsis lacks '$want': $tier_synopsis"
done

# Project risk_paths and generated_files from the tech-stack contract.
python3 - "$tier_target/docs/superpowers/specs/project-tech-stack.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["risk_paths"] = ["src/core/**", "app/*.ts", "keys.yml", "src/[z-a]/x", "app/ledger"]
d["generated_files"] = ["src/gen/**", "generated"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
expect_tier large "risky path: SRC/Core/x.ts (pattern src/core/**)" -- --paths SRC/Core/x.ts --lines 1
expect_tier small "1 generated file not counted" -- --paths src/gen/a.ts src/b.ts --lines 2
# A pattern with no "/" also names a folder anywhere, and covers what is in it.
expect_tier small "1 generated file not counted" -- --paths app/generated/x.ts src/b.ts --lines 2
expect_tier large "risky path: src/gen/auth.ts (token auth)" "1 generated file not counted" -- \
  --paths src/gen/auth.ts --lines 1
# "*" stays inside one segment; a pattern with no "/" matches the file name anywhere.
expect_tier large "risky path: app/x.ts (pattern app/*.ts)" -- --paths app/x.ts
expect_tier small -- --paths app/sub/x.ts --lines 1
expect_only_tier_line
expect_tier large "risky path: deploy/prod/keys.yml (pattern keys.yml)" -- --paths deploy/prod/keys.yml
# As in .gitignore, a folder pattern with no /** covers the files inside it.
expect_tier large "risky path: app/ledger/post.py (pattern app/ledger)" -- --paths app/ledger/post.py
expect_tier small -- --paths app/ledgers/post.py --lines 1
# A bad pattern warns, names itself and is skipped.
expect_tier small -- --paths src/z/x --lines 1
grep -qF 'src/[z-a]/x' "$TMP_ROOT/tier.err" || fail "bad pattern not named: $(cat "$TMP_ROOT/tier.err")"

# Thresholds come from tier_rules.
tier_policy="$tier_target/docs/agent-configs/context-policy.json"
cp "$tier_policy" "$TMP_ROOT/tier-policy.json"
python3 - "$tier_policy" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["tier_rules"]["small"]["max_files"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
expect_tier medium "2 counted files (small allows 1)" -- --paths a.ts b.ts
cp "$TMP_ROOT/tier-policy.json" "$tier_policy"

# classify, the JSON operation pre-final will use: renames, per-file lines,
# binary files and submodules. Called straight from the guard's function.
# Called straight in the target; --root, --policy and --tech-stack default
# to the project around scripts/agent-tier.py.
classify_json() {
  (cd "$tier_target" && python3 scripts/agent-tier.py classify --request "$1" 2>"$TMP_ROOT/classify.err") \
    || fail "classify failed: $(cat "$TMP_ROOT/classify.err")"
}
result="$(classify_json '{"files":[{"path":"src/new.ts","old_path":"auth/old.ts","lines":10},{"path":"src/a.test.ts","lines":30},{"path":"yarn.lock","lines":900},{"path":"assets/logo.png","binary":true},{"path":"libs/sdk.jar","binary":true},{"path":"vendor/lib","submodule":true}]}')"
python3 - "$result" <<'PY' || fail "classify result is wrong: $result"
import json, sys
r = json.loads(sys.argv[1])
assert r["tier"] == "large", r
assert r["counted_files"] == 4, r
assert r["counted_lines"] == 10, r
assert r["excluded"] == {"tests": 1, "locks": 1, "generated": 0, "lines": 930}, r
assert r["risky"] == [{"path": "auth/old.ts", "kind": "token", "match": "auth"}], r
for reason in ("binary file changed: libs/sdk.jar", "submodule changed: vendor/lib", "dependency lock changed: yarn.lock"):
    assert reason in r["reasons"], (reason, r)
# Tidy-up rule 2: an image is an asset, so it adds no binary reason.
assert not any("assets/logo.png" in reason for reason in r["reasons"]), r
PY

# classify_tier <want> <request JSON> [<reason text>...]: the tier and, for
# each text, a reason that contains it.
classify_tier() {
  local want="$1" request="$2" got
  shift 2
  got="$(classify_json "$request")"
  python3 - "$got" "$want" "$@" <<'PY' || fail "classify $request: want $want with the reasons ${*:-none}: $got"
import json, sys
r, want, texts = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3:]
assert r["tier"] == want, r
for text in texts:
    assert any(text in reason for reason in r["reasons"]), (text, r)
PY
}
# Tidy-up rule 2: images, fonts, media and PDF count like any file (any
# case); other binaries stay medium.
classify_tier small '{"files":[{"path":"img/Hero.PNG","binary":true}]}'
classify_tier small '{"files":[{"path":"fonts/a.woff2","binary":true},{"path":"docs/guide.pdf","binary":true}]}'
classify_tier medium '{"files":[{"path":"a/b.weird","binary":true}]}' "binary file changed: a/b.weird"
classify_tier medium '{"files":[{"path":"bin/tool","binary":true}]}' "binary file changed: bin/tool"
# A prebuilt library renamed to an image name is still a binary change.
classify_tier medium '{"files":[{"path":"a/x.png","old_path":"a/x.jar","binary":true}]}' "binary file changed: a/x.png"
# A project adds its own asset extensions (any case, with or without the
# dot); a bad value warns and is ignored.
asset_contract="$tier_target/docs/superpowers/specs/project-tech-stack.json"
cp "$asset_contract" "$TMP_ROOT/asset-contract.json"
python3 - "$asset_contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = [".Weird"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
classify_tier small '{"files":[{"path":"a/b.weird","binary":true}]}'
python3 - "$asset_contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = "weird"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
classify_tier medium '{"files":[{"path":"a/b.weird","binary":true}]}' "binary file changed: a/b.weird"
grep -qF 'project-tech-stack.json binary_asset_extensions is not a list' "$TMP_ROOT/classify.err" \
  || fail "a bad asset list does not warn: $(cat "$TMP_ROOT/classify.err")"
# "." would make every binary with no extension an asset: warned, left out.
python3 - "$asset_contract" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["binary_asset_extensions"] = [".", "psd"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
classify_tier medium '{"files":[{"path":"bin/tool","binary":true}]}' "binary file changed: bin/tool"
classify_tier small '{"files":[{"path":"art/cover.psd","binary":true}]}'
grep -qF "project-tech-stack.json binary_asset_extensions: . is not an extension like png; it is ignored" "$TMP_ROOT/classify.err" \
  || fail "a '.' asset entry does not warn: $(cat "$TMP_ROOT/classify.err")"
cp "$TMP_ROOT/asset-contract.json" "$asset_contract"

# Tidy-up rule 3: a pure move (an old path, 0 lines, not binary) counts for
# medium but never makes a change large.
moves_json() {
  python3 - "$@" <<'PY'
import json, sys
moves, edits, binary = (int(arg) for arg in sys.argv[1:4])
files = [{"path": f"app/cards/C{n}.tsx", "old_path": f"app/C{n}.tsx", "lines": 0} for n in range(moves)]
files += [{"path": f"src/e{n}.ts", "lines": 1} for n in range(edits)]
files += [{"path": f"img/i{n}.bin", "old_path": f"old/i{n}.bin", "lines": 0, "binary": True} for n in range(binary)]
renamed = int(sys.argv[4]) if len(sys.argv) > 4 else 0
files += [{"path": f"lib/R{n}.ts", "old_path": f"old/R{n}.ts", "lines": 2} for n in range(renamed)]
tests = int(sys.argv[5]) if len(sys.argv) > 5 else 0
files += [{"path": f"tests/t{n}.ts", "old_path": f"spec/t{n}.ts", "lines": 0} for n in range(tests)]
print(json.dumps({"files": files}))
PY
}
# no_move_reason <request JSON>: no reason says "only moved".
no_move_reason() {
  python3 - "$(classify_json "$1")" <<'PY' || fail "classify $1: a file with lines counted as only moved"
import json, sys
r = json.loads(sys.argv[1])
assert not any("only moved" in reason for reason in r["reasons"]), r
PY
}
classify_tier small "$(moves_json 3 0 0)"
classify_tier medium "$(moves_json 20 0 0)" "20 counted files, 20 only moved (small allows 3)"
classify_tier medium "$(moves_json 20 15 0)" "35 counted files, 20 only moved (small allows 3)"
classify_tier large "$(moves_json 20 16 0)" "16 changed files, plus 20 only moved (medium allows 15)"
classify_tier large "$(moves_json 0 16 0)" "16 counted files (medium allows 15)"
classify_tier large '{"files":[{"path":"app/payment/x.ts","old_path":"app/x.ts","lines":0}]}' "risky path: app/payment/x.ts"
classify_tier large "$(moves_json 0 0 16)" "16 counted files (medium allows 15)"
# A rename with edited lines is not a pure move.
classify_tier large "$(moves_json 0 0 0 16)" "16 counted files (medium allows 15)"
classify_tier medium "$(moves_json 0 0 0 4)" "4 counted files (small allows 3)"
no_move_reason "$(moves_json 0 0 0 4)"
# Moved tests are not counted at all, so they are not moves either.
classify_tier large "$(moves_json 0 16 0 0 5)" "16 counted files (medium allows 15)" "5 test files not counted"
result="$(classify_json '{"files":[{"path":"a.ts","lines":5}],"lines":70}')"
python3 - "$result" <<'PY' || fail "top-level lines did not win: $result"
import json, sys
r = json.loads(sys.argv[1])
assert r["tier"] == "medium" and r["counted_lines"] == 70, r
PY

# A very deeply nested tech-stack contract is bad user JSON: warn and ignore.
contract="$tier_target/docs/superpowers/specs/project-tech-stack.json"
cp "$contract" "$TMP_ROOT/tier-contract.json"
python3 - "$contract" <<'PY'
import sys
open(sys.argv[1], "w").write("[" * 200000 + "]" * 200000)
PY
expect_tier small -- --paths a.ts --lines 1
grep -q 'project-tech-stack.json is not valid JSON' "$TMP_ROOT/tier.err" \
  || fail "deep nesting did not warn: $(cat "$TMP_ROOT/tier.err")"
cp "$TMP_ROOT/tier-contract.json" "$contract"

# An unexpected evaluator error exits 70 (input errors exit 1). The crash
# hook works only with HARNESS_KIT_TEST_HOOKS=1.
TIER_RC=0
(cd "$tier_target" && AGENT_GUARD_TEST_TIER_CRASH=1 scripts/agent-guard.sh tier suggest --paths a.ts \
  >/dev/null 2>"$TMP_ROOT/tier.err") || TIER_RC=$?
[[ "$TIER_RC" -eq 0 ]] || fail "crash hook fired without HARNESS_KIT_TEST_HOOKS=1: exit $TIER_RC"
(cd "$tier_target" && HARNESS_KIT_TEST_HOOKS=1 AGENT_GUARD_TEST_TIER_CRASH=1 \
  scripts/agent-guard.sh tier suggest --paths a.ts >/dev/null 2>"$TMP_ROOT/tier.err") || TIER_RC=$?
[[ "$TIER_RC" -eq 70 ]] || fail "internal error: want exit 70, got $TIER_RC: $(cat "$TMP_ROOT/tier.err")"
grep -q 'agent-guard: ERROR: tier evaluator failed: ' "$TMP_ROOT/tier.err" \
  || fail "internal error message: $(cat "$TMP_ROOT/tier.err")"

# ---- tier set, show and close ----------------------------------------------
# A new target: its kit files are git-excluded, so the tree starts clean.
tier_target="$(fresh_target)"
[[ -z "$(git -C "$tier_target" status --porcelain)" ]] || fail "fresh target tree is not clean"
packets="$tier_target/.agents/tasks"
TIER_SCHEMA="$ROOT_DIR/agent-bootstrap/schemas/harness-tier-v1.schema.json"
HANDOFF_SCHEMA="$tier_target/docs/agent-configs/agent-handoff-schema.md"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
export ACTION_SMALL='implement, then run pre-final (small: no @gate, task.md optional)'
export ACTION_MEDIUM='write task.md, answer the tier check, then implement; @verify reviews'
export ACTION_LARGE='prepare spec for @gate'

# expect_rc <code> <args...>: runs `tier <args...>` and checks the exit code.
expect_rc() {
  local want="$1"
  shift
  run_tier "$@"
  [[ "$TIER_RC" -eq "$want" ]] \
    || fail "tier $*: want exit $want, got $TIER_RC: $TIER_OUT $(cat "$TMP_ROOT/tier.err")"
}

# json_check <schema> <file> <python expr>...: the JSON file matches the
# schema (the repo has no jsonschema library; a .jsonl file: its last line)
# and each expr is true. In an expr, d is the document, env is os.environ.
json_check="$TMP_ROOT/json-check.py"
cat >"$json_check" <<'PY'
import json, os, re, sys
schema = json.load(open(sys.argv[1]))
text = open(sys.argv[2], encoding="utf-8").read()
d = json.loads(text.splitlines()[-1] if sys.argv[2].endswith(".jsonl") else text)
TYPES = {"string": str, "object": dict, "array": list, "null": type(None), "boolean": bool, "integer": int}
def check(value, node, where):
    if "$ref" in node:
        node = schema["$defs"][node["$ref"].rsplit("/", 1)[-1]]
    if "oneOf" in node:
        matched = 0
        for sub in node["oneOf"]:
            try:
                check(value, sub, where)
                matched += 1
            except AssertionError:
                pass
        assert matched == 1, (where, "oneOf matched", matched)
    if "const" in node:
        assert value == node["const"], (where, value)
    if "enum" in node:
        assert value in node["enum"], (where, value)
    if "type" in node:
        kinds = node["type"] if isinstance(node["type"], list) else [node["type"]]
        assert any(isinstance(value, TYPES[k]) and (k == "boolean" or not isinstance(value, bool))
                   for k in kinds), (where, value)
    if "pattern" in node and isinstance(value, str):
        assert re.search(node["pattern"], value), (where, value)
    if isinstance(value, dict):
        for key in node.get("required", []):
            assert key in value, (where, "missing", key)
        props = node.get("properties", {})
        if node.get("additionalProperties") is False:
            assert not set(value) - set(props), (where, "extra", set(value) - set(props))
        for key, sub in props.items():
            if key in value:
                check(value[key], sub, where + "." + key)
    if isinstance(value, list) and "items" in node:
        for i, item in enumerate(value):
            check(item, node["items"], f"{where}[{i}]")
check(d, schema, os.path.basename(sys.argv[2]))
for expr in sys.argv[3:]:
    assert eval(expr, {"d": d, "env": os.environ, "re": re}), (expr, d)
PY
# tier_assert <task> <python expr>...: tier.json of <task> matches the schema,
# every history entry has a UTC time with Z, and each expr is true.
tier_assert() {
  local task="$1"
  shift
  python3 "$json_check" "$TIER_SCHEMA" "$packets/$task/tier.json" \
    "all(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', e['at']) for e in d['history'])" "$@" \
    || fail "tier.json of $task is wrong: $(cat "$packets/$task/tier.json" 2>&1)"
}

# state_assert <task> <python expr>...: state.json of <task> has exactly the
# keys of the handoff schema's initial state, values the reference allows,
# and each expr is true (s is the state, t the tier record).
state_check="$TMP_ROOT/state-check.py"
cat >"$state_check" <<'PY'
import json, os, re, sys
doc = open(sys.argv[1], encoding="utf-8").read()
initial = json.loads(re.search(r"Initial state:\s*```json\n(.*?)\n```", doc, re.S).group(1))
s = json.load(open(sys.argv[2], encoding="utf-8"))
t = json.load(open(sys.argv[3], encoding="utf-8"))
assert set(initial) <= set(s), ("missing", set(initial) - set(s))
assert set(s) - set(initial) <= {"closed_by", "occupant"}, ("extra", set(s) - set(initial))
assert s["status"] in ("open", "awaiting_user", "closed"), s
assert s["phase"] in ("analysis", "technical_review", "implementation", "verification",
                      "cross_review", "resolution", "closed"), s
assert s["owner"] in ("claude", "codex", "user", "agent"), s
assert s["verification"]["runner"] in ("none", "claude", "codex", "agent"), s
assert s["verification"]["status"] in ("not_run", "pass", "fail", "blocked"), s
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", s["updated_at"]), s
for expr in sys.argv[4:]:
    assert eval(expr, {"s": s, "t": t, "env": os.environ}), (expr, s)
PY
state_assert() {
  local task="$1"
  shift
  python3 "$state_check" "$HANDOFF_SCHEMA" "$packets/$task/state.json" "$packets/$task/tier.json" "$@" \
    || fail "state.json of $task is wrong: $(cat "$packets/$task/state.json" 2>&1)"
}
active_is() {
  [[ -f "$packets/ACTIVE" && "$(cat "$packets/ACTIVE")" == "$1" ]] \
    || fail "ACTIVE: want $1, got: $(cat "$packets/ACTIVE" 2>&1)"
}

# 1. The first set on a clean tree writes tier.json, a minimal state.json and ACTIVE.
first_head="$(git -C "$tier_target" rev-parse HEAD)"
expect_rc 0 set small --task fix-logout
[[ "$TIER_OUT" == "Tier set: small (task fix-logout)" ]] || fail "tier set output: $TIER_OUT"
HEAD_COMMIT="$first_head" tier_assert fix-logout \
  "d['schema'] == 'harness-tier/v1' and d['task_id'] == 'fix-logout'" \
  "d['branch'] == 'main' and d['base_ref'] is None" \
  "d['start_commit'] == env['HEAD_COMMIT']" \
  "d['declared'] == 'small' and d['suggested'] is None and d['suggestion_inputs'] == {}" \
  "d['reason'] is None and d['coding_started_tier'] is None and d['coding_started_at'] is None" \
  "d['status'] == 'open' and d['closed_at'] is None and d['closed_by'] is None" \
  "[e['event'] for e in d['history']] == ['set'] and d['history'][0]['tier'] == 'small'" \
  "d['history'][0]['printed_by'] == 'user' and d['history'][0]['recorded_by'] == 'user'" \
  "d['history'][0]['host_session'] is None" \
  "d['history'][0]['answer'] is None and d['history'][0]['reason'] is None"
state_assert fix-logout \
  "s['task_id'] == 'fix-logout' and s['phase'] == 'analysis' and s['status'] == 'open'" \
  "s['owner'] == 'claude' and s['base_commit'] == t['start_commit']" \
  "s['seat'] == '@spec' and s['requested_action'] == env['ACTION_SMALL']"
active_is fix-logout
cp "$packets/fix-logout/state.json" "$TMP_ROOT/state-before.json"

# 2. A later set keeps start_commit (HEAD has moved) and adds a history entry.
# In state.json it refreshes only requested_action (phase analysis, kit text).
printf 'export const b = 2;\n' >"$tier_target/src/b.ts"
git -C "$tier_target" add src/b.ts || fail "git add failed in the target"
git -C "$tier_target" commit -q -m b || fail "git commit failed in the target"
AGENT_HOST_SESSION_ID=host-123 expect_rc 0 set medium --task fix-logout
HEAD_COMMIT="$first_head" tier_assert fix-logout \
  "d['start_commit'] == env['HEAD_COMMIT'] and d['declared'] == 'medium'" \
  "[e['event'] for e in d['history']] == ['set', 'set'] and d['history'][1]['tier'] == 'medium'" \
  "d['history'][1]['host_session'] == 'host-123'"
python3 - "$TMP_ROOT/state-before.json" "$packets/fix-logout/state.json" <<'PY' \
  || fail "a later set changed state.json wrongly: $(cat "$packets/fix-logout/state.json")"
import json, os, sys
before, after = (json.load(open(path)) for path in sys.argv[1:3])
assert after["requested_action"] == os.environ["ACTION_MEDIUM"], after
for key in ("requested_action", "updated_at"):
    before.pop(key)
    after.pop(key)
assert before == after, (before, after)
PY

# 5. Close sets tier.json and state.json closed and clears ACTIVE; other state
# fields stay. A custom requested_action survives a later set. A set after
# close is refused.
python3 - "$packets/fix-logout/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["requested_action"] = "custom next step"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
expect_rc 0 set large --task fix-logout
state_assert fix-logout "s['requested_action'] == 'custom next step'"
expect_rc 0 close --task fix-logout
tier_assert fix-logout \
  "d['status'] == 'closed' and d['closed_by'] == 'user' and d['closed_at'] is not None" \
  "d['history'][-1]['event'] == 'close' and len(d['history']) == 4"
state_assert fix-logout \
  "s['phase'] == 'closed' and s['status'] == 'closed' and s['closed_by'] == 'user'" \
  "s['seat'] == '@owner' and s['owner'] == 'claude'" \
  "s['requested_action'] == 'custom next step' and s['base_commit'] == t['start_commit']"
[[ ! -s "$packets/ACTIVE" ]] || fail "close did not clear ACTIVE: $(cat "$packets/ACTIVE")"
expect_rc 1 set small --task fix-logout
grep -q 'closed' "$TMP_ROOT/tier.err" || fail "set on a closed task: $(cat "$TMP_ROOT/tier.err")"

# 9. --by, --recorded-by and --answer: a checkpoint; without --answer, a set.
expect_rc 0 set medium --task t3 --by @gate --recorded-by @build --answer keep
tier_assert t3 \
  "d['history'][-1]['event'] == 'checkpoint' and d['history'][-1]['answer'] == 'keep'" \
  "d['history'][-1]['printed_by'] == '@gate' and d['history'][-1]['recorded_by'] == '@build'"
expect_rc 0 set medium --task t3 --by @gate
tier_assert t3 \
  "d['history'][-1]['event'] == 'set' and d['history'][-1]['answer'] is None" \
  "d['history'][-1]['printed_by'] == '@gate' and d['history'][-1]['recorded_by'] == '@gate'"
expect_rc 1 set medium --task t3 --answer maybe
active_is t3

# 4. A tier below the last suggestion needs --reason; the reason is verbatim.
expect_rc 0 suggest --task t2 --by @spec --paths a.ts b.ts c.ts d.ts
[[ "$(printf '%s\n' "$TIER_OUT" | head -n1)" == "Suggested: medium" ]] || fail "suggest output changed: $TIER_OUT"
tier_assert t2 \
  "d['suggested'] == 'medium' and d['declared'] is None" \
  "d['suggestion_inputs'] == {'paths': ['a.ts', 'b.ts', 'c.ts', 'd.ts'], 'lines': None, 'flags': []}" \
  "[(e['event'], e['tier'], e['printed_by']) for e in d['history']] == [('suggest', 'medium', '@spec')]"
[[ ! -e "$packets/t2/state.json" ]] || fail "tier suggest wrote state.json"
active_is t3
expect_rc 1 set small --task t2
grep -q 'needs --reason' "$TMP_ROOT/tier.err" || fail "lowering message: $(cat "$TMP_ROOT/tier.err")"
expect_rc 0 set small --task t2 --reason "hotfix, prod down"
tier_assert t2 \
  "d['declared'] == 'small' and d['suggested'] == 'medium' and d['reason'] == 'hotfix, prod down'" \
  "d['history'][-1]['reason'] == 'hotfix, prod down' and d['history'][-1]['event'] == 'set'"
state_assert t2 "s['task_id'] == 't2' and s['base_commit'] == t['start_commit']" \
  "s['requested_action'] == env['ACTION_SMALL']"
active_is t2
# Re-confirming the same lowered tier needs no new reason; the stored one stays.
expect_rc 0 set small --task t2 --answer keep
tier_assert t2 "d['declared'] == 'small' and d['reason'] == 'hotfix, prod down'" \
  "d['history'][-1]['event'] == 'checkpoint' and d['history'][-1]['reason'] is None"
# After a newer suggestion it needs one again.
expect_rc 0 suggest --task t2 --paths a.ts b.ts c.ts d.ts
expect_rc 1 set small --task t2 --answer keep
grep -q 'needs --reason' "$TMP_ROOT/tier.err" || fail "re-confirm after a new suggestion: $(cat "$TMP_ROOT/tier.err")"
# A blank reason is refused.
expect_rc 1 set small --task t2 --reason "   "
grep -q 'blank' "$TMP_ROOT/tier.err" || fail "blank reason message: $(cat "$TMP_ROOT/tier.err")"
expect_rc 1 set small --task t2 --reason ""
expect_rc 0 set large --task t2
tier_assert t2 "d['declared'] == 'large' and d['reason'] is None"
state_assert t2 "s['requested_action'] == env['ACTION_LARGE']"
expect_rc 0 set small --task t2 --reason "hotfix, prod down"
state_assert t2 "s['requested_action'] == env['ACTION_SMALL']"

# 6. show and --pr-line; show defaults to the task in ACTIVE.
expect_rc 0 show --task t2 --pr-line
[[ "$TIER_OUT" == "Tier: small (suggested medium: hotfix, prod down) · 0 files, 0 lines" ]] || fail "pr-line: $TIER_OUT"
expect_rc 0 show --task t3 --pr-line
[[ "$TIER_OUT" == "Tier: medium · 0 files, 0 lines" ]] || fail "pr-line without a lower suggestion: $TIER_OUT"
expect_rc 0 show
for want in 'task: t2' 'declared: small' 'suggested: medium' 'reason: hotfix, prod down' \
  'status: open' 'history: 6 entries' 'measured: small (0 files, 0 lines)'; do
  grep -qxF "$want" <<<"$TIER_OUT" || fail "tier show lacks '$want': $TIER_OUT"
done

# Closing task A while ACTIVE names task B leaves ACTIVE at B.
expect_rc 0 close --task t3
active_is t2
expect_rc 0 close --task t2
[[ ! -s "$packets/ACTIVE" ]] || fail "close t2 did not clear ACTIVE"
cp "$packets/t2/tier.json" "$TMP_ROOT/t2-closed.json"
expect_rc 0 suggest --task t2 --paths a.ts
grep -q 'not recorded (task t2 is closed)' "$TMP_ROOT/tier.err" || fail "suggest on a closed task: $(cat "$TMP_ROOT/tier.err")"
cmp -s "$TMP_ROOT/t2-closed.json" "$packets/t2/tier.json" || fail "suggest changed a closed record"
expect_rc 0 close --task t2
[[ "$TIER_OUT" == "Tier already closed (task t2)" ]] || fail "second close: $TIER_OUT"
expect_rc 1 show
grep -q -- '--task' "$TMP_ROOT/tier.err" || fail "show without a task: $(cat "$TMP_ROOT/tier.err")"
expect_rc 1 close --task no-record

# 10. suggest --task on a new task: declared null, ACTIVE and state.json untouched.
printf 'other-task\n' >"$packets/ACTIVE"
expect_rc 0 suggest --task t4 --paths src/app.ts --lines 2
tier_assert t4 "d['declared'] is None and d['suggested'] == 'small' and d['status'] == 'open'" \
  "d['suggestion_inputs'] == {'paths': ['src/app.ts'], 'lines': 2, 'flags': []}"
[[ ! -e "$packets/t4/state.json" ]] || fail "tier suggest wrote state.json for t4"
active_is other-task
expect_rc 0 suggest --task t4 --paths a.ts --data --unclear
tier_assert t4 "d['suggested'] == 'large' and d['suggestion_inputs']['flags'] == ['data', 'unclear']" \
  "len(d['history']) == 2"
# A path that is not valid UTF-8 is still recorded as valid JSON.
expect_rc 0 suggest --task t4 --paths "$(printf 'src/bad\377.ts')" --lines 1
tier_assert t4 "len(d['history']) == 3 and d['suggestion_inputs']['paths'] == ['src/bad\udcff.ts']"

# 11. A read-only packet: the suggestion prints, is not recorded, exit 0.
if [[ "$(id -u)" != 0 ]]; then
  cp "$packets/t4/tier.json" "$TMP_ROOT/t4-before.json"
  chmod a-w "$packets/t4"
  expect_rc 0 suggest --task t4 --paths a.ts b.ts c.ts d.ts
  chmod u+w "$packets/t4"
  [[ "$(printf '%s\n' "$TIER_OUT" | head -n1)" == "Suggested: medium" ]] || fail "read-only suggest output: $TIER_OUT"
  grep -q 'not recorded (packet is read-only)' "$TMP_ROOT/tier.err" \
    || fail "read-only packet message: $(cat "$TMP_ROOT/tier.err")"
  cmp -s "$TMP_ROOT/t4-before.json" "$packets/t4/tier.json" || fail "read-only packet: tier.json changed"
fi

# 12. Quotes, a newline and unicode in --reason round-trip intact.
weird="$(printf 'x" y\nz \303\261')"
expect_rc 0 suggest --task t5 --paths a.ts b.ts c.ts d.ts
expect_rc 0 set small --task t5 --reason "$weird"
WANT_REASON="$weird" tier_assert t5 "d['reason'] == env['WANT_REASON'] == 'x\" y\nz \u00f1'" \
  "d['history'][-1]['reason'] == env['WANT_REASON']"
expect_rc 0 show --task t5 --pr-line
[[ "$TIER_OUT" == "Tier: small (suggested medium: x\" y z $(printf '\303\261')) · 0 files, 0 lines" ]] \
  || fail "pr-line with a newline in the reason is not one line: $TIER_OUT"

# The first set records the HEAD and branch of now, also when an earlier
# suggestion made the record.
expect_rc 0 suggest --task early --paths a.ts
printf 'export const c = 1;\n' >"$tier_target/src/c.ts"
git -C "$tier_target" add src/c.ts || fail "git add failed in the target"
git -C "$tier_target" commit -q -m c || fail "git commit failed in the target"
git -C "$tier_target" checkout -q -b feature/early || fail "git checkout -b failed in the target"
expect_rc 0 set small --task early
NEW_HEAD="$(git -C "$tier_target" rev-parse HEAD)" tier_assert early \
  "d['start_commit'] == env['NEW_HEAD'] and d['branch'] == 'feature/early'" \
  "[e['event'] for e in d['history']] == ['suggest', 'set']"
git -C "$tier_target" checkout -q main || fail "git checkout main failed in the target"

# A state.json that is already there with other text is not rewritten.
mkdir -p "$packets/pre-made"
printf '{"task_id": "pre-made", "phase": "analysis", "requested_action": "the user wrote this"}\n' \
  >"$packets/pre-made/state.json"
cp "$packets/pre-made/state.json" "$TMP_ROOT/pre-made.json"
expect_rc 0 set medium --task pre-made
cmp -s "$TMP_ROOT/pre-made.json" "$packets/pre-made/state.json" || fail "set rewrote a pre-made state.json"

# The id "active" is reserved in any case: it clashes with ACTIVE.
for id in active Active ACTIVE; do
  expect_rc 1 set small --task "$id"
  grep -q 'reserved' "$TMP_ROOT/tier.err" || fail "--task $id message: $(cat "$TMP_ROOT/tier.err")"
done
expect_rc 1 suggest --task active --paths a.ts

# 8 parallel sets on one task: the packet lock keeps every history entry.
pids=()
for n in 1 2 3 4 5 6 7 8; do
  (cd "$tier_target" && scripts/agent-guard.sh tier set medium --task par >/dev/null 2>"$TMP_ROOT/par.$n.err") &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "a parallel tier set failed: $(cat "$TMP_ROOT"/par.*.err)"
done
tier_assert par "len(d['history']) == 8 and all(e['event'] == 'set' for e in d['history'])"

# A held lock: the set waits, then fails clearly (the test hook shortens the wait).
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(10)
' "$packets/par" "$TMP_ROOT/par.locked" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -e "$TMP_ROOT/par.locked" ]] && break
  sleep 0.2
done
[[ -e "$TMP_ROOT/par.locked" ]] || fail "the lock holder did not start"
TIER_RC=0
(cd "$tier_target" && HARNESS_KIT_TEST_HOOKS=1 AGENT_GUARD_TEST_TIER_LOCK_SECONDS=0.5 \
  scripts/agent-guard.sh tier set medium --task par >/dev/null 2>"$TMP_ROOT/tier.err") || TIER_RC=$?
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$TIER_RC" -eq 1 ]] || fail "a held lock: want exit 1, got $TIER_RC"
grep -q 'still holds .agents/tasks/par' "$TMP_ROOT/tier.err" || fail "held lock message: $(cat "$TMP_ROOT/tier.err")"
tier_assert par "len(d['history']) == 8"

# Our own temp files older than an hour are removed on the next write.
touch -t 202001010000 "$packets/par/.tier.json.old1.tmp"
touch "$packets/par/.tier.json.new1.tmp"
expect_rc 0 set medium --task par
[[ ! -e "$packets/par/.tier.json.old1.tmp" ]] || fail "a stale temp file was not removed"
[[ -e "$packets/par/.tier.json.new1.tmp" ]] || fail "a fresh temp file was removed"
rm -f "$packets/par/.tier.json.new1.tmp"

# 3. Uncommitted changes count toward the task: a note, still exit 0.
printf 'export const a = 3;\n' >"$tier_target/src/app.ts"
printf 'export const b = 3;\n' >"$tier_target/src/b.ts"
expect_rc 0 set small --task dirty-one
grep -qF '2 files are already changed; they count toward this task. Commit or stash them on another branch first if they belong to other work.' \
  <<<"$TIER_OUT" || fail "dirty tree note: $TIER_OUT"
git -C "$tier_target" checkout -q -- src || fail "git checkout failed in the target"

# 7. --base: never the current branch, and it must resolve.
expect_rc 1 set small --task t6 --base main
grep -q 'current branch' "$TMP_ROOT/tier.err" || fail "--base main message: $(cat "$TMP_ROOT/tier.err")"
expect_rc 1 set small --task t6 --base nosuchref
[[ ! -e "$packets/t6/tier.json" ]] || fail "a refused set wrote tier.json"
git -C "$tier_target" checkout -q -b feature/stacked || fail "git checkout -b failed in the target"
expect_rc 0 set small --task t6 --base main
tier_assert t6 "d['branch'] == 'feature/stacked' and d['base_ref'] == 'refs/heads/main'"
t6_start="$(git -C "$tier_target" rev-parse HEAD)"
# A later set on another branch keeps branch and start commit; a later --base
# changes the base and says so.
git -C "$tier_target" checkout -q -b feature/other || fail "git checkout -b failed in the target"
printf 'export const d = 1;\n' >"$tier_target/src/d.ts"
git -C "$tier_target" add src/d.ts || fail "git add failed in the target"
git -C "$tier_target" commit -q -m d || fail "git commit failed in the target"
expect_rc 0 set medium --task t6 --base feature/stacked
grep -qxF 'The base is now feature/stacked.' <<<"$TIER_OUT" || fail "a later --base did not change the base: $TIER_OUT"
T6_START="$t6_start" tier_assert t6 \
  "d['branch'] == 'feature/stacked' and d['base_ref'] == 'refs/heads/feature/stacked' and d['start_commit'] == env['T6_START']"
git -C "$tier_target" checkout -q --detach || fail "git checkout --detach failed in the target"
expect_rc 0 set small --task t7
tier_assert t7 "d['branch'] is None"

# 8. A bad task id, a bad tier and a missing --task are refused.
expect_rc 1 set small --task Fix_Logout
grep -q 'task id' "$TMP_ROOT/tier.err" || fail "bad id message: $(cat "$TMP_ROOT/tier.err")"
[[ ! -e "$packets/Fix_Logout" ]] || fail "a bad id made a packet"
expect_rc 1 suggest --task Fix_Logout --paths a.ts
expect_rc 1 set huge --task t8
expect_rc 1 set small

# No commit yet: start_commit is the empty tree.
unborn="$(mktemp -d "$TMP_ROOT/unborn.XXXXXX")"
git -C "$unborn" init -q -b main || fail "git init failed"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" \
  --target "$unborn" --workflow full --project-name budget-fixture >/dev/null || fail "bootstrap failed"
(cd "$unborn" && scripts/agent-guard.sh tier set small --task first >/dev/null 2>"$TMP_ROOT/tier.err") \
  || fail "tier set with no commit: $(cat "$TMP_ROOT/tier.err")"
packets="$unborn/.agents/tasks" EMPTY="$EMPTY_TREE" tier_assert first \
  "d['start_commit'] == env['EMPTY'] and d['branch'] == 'main'"

# The guard runs agent-tier.py isolated: a project file named like a standard
# module must not be imported in its place.
printf 'raise SystemExit("shadowed")\n' >"$unborn/scripts/fnmatch.py"
out="$(cd "$unborn" && scripts/agent-guard.sh tier suggest --paths src/a.ts 2>&1)" \
  || fail "a project scripts/fnmatch.py must not break tier: $out"
[[ "$(sed -n '1p' <<<"$out")" == "Suggested: small" ]] || fail "shadowed suggest output: $out"
rm -f "$unborn/scripts/fnmatch.py"

# "tier help" prints the help; the project paths cannot be overridden.
(cd "$unborn" && scripts/agent-guard.sh tier help >"$TMP_ROOT/help.out" 2>&1) || fail "tier help must exit 0"
grep -q 'suggest' "$TMP_ROOT/help.out" || fail "tier help must list the commands"
if (cd "$unborn" && scripts/agent-guard.sh tier --root src show >/dev/null 2>"$TMP_ROOT/root.err"); then
  fail "tier --root must be refused"
fi
grep -q 'project paths are fixed' "$TMP_ROOT/root.err" || fail "tier --root message: $(cat "$TMP_ROOT/root.err")"

# Review fix: a suggest with no facts (a checkpoint that forgot them) keeps
# the facts on record instead of judging "files unknown"; new facts replace them.
expect_tier large -- --task keep-facts --paths app/payment/Momo.kt --access
expect_tier large "facts from the last suggestion (none were given)" -- --task keep-facts --by @build
tier_assert keep-facts "d['suggested'] == 'large'" \
  "d['suggestion_inputs'] == {'paths': ['app/payment/Momo.kt'], 'lines': None, 'flags': ['access']}"
expect_tier small -- --task keep-facts --paths README.txt --lines 1
tier_assert keep-facts "d['suggested'] == 'small' and d['suggestion_inputs']['paths'] == ['README.txt']"
expect_tier medium "files unknown" -- --task no-facts-yet
# --handoff is a fact like the others: recorded, and kept by a suggest with
# no facts.
expect_tier large "--handoff" -- --task handoff-facts --paths src/a.ts --handoff
tier_assert handoff-facts "d['suggestion_inputs']['flags'] == ['handoff']"
expect_tier large "facts from the last suggestion (none were given)" "--handoff" -- --task handoff-facts --by @spec
# tier set fills a null base_commit in an existing state.json.
mkdir -p "$packets/fill-base"
printf '{"task_id": "fill-base", "phase": "analysis", "status": "open", "base_commit": null}\n' \
  >"$packets/fill-base/state.json"
expect_rc 0 set small --task fill-base
python3 - "$packets/fill-base" <<'PY' || fail "base_commit not filled: $(cat "$packets/fill-base/state.json")"
import json, os, sys
state = json.load(open(os.path.join(sys.argv[1], "state.json")))
tier = json.load(open(os.path.join(sys.argv[1], "tier.json")))
assert state["base_commit"] == tier["start_commit"], (state, tier)
PY

# ---- measured change ---------------------------------------------------------
# No commit yet: the measure works against the empty tree.
printf 'export const n = 1;\n' >"$unborn/new.ts"
out="$(cd "$unborn" && scripts/agent-guard.sh tier show --task first 2>"$TMP_ROOT/tier.err")" \
  || fail "tier show with no commit: $(cat "$TMP_ROOT/tier.err")"
grep -qxF 'measured: small (1 file, 1 line)' <<<"$out" || fail "measure with no commit: $out"
grep -qxF 'base: empty tree (0 commits since)' <<<"$out" || fail "base with no commit: $out"
out="$(cd "$unborn" && scripts/agent-guard.sh tier measure --task first --committed 2>"$TMP_ROOT/tier.err")" \
  || fail "measure --committed with no commit: $(cat "$TMP_ROOT/tier.err")"
python3 -c 'import json,sys; m = json.loads(sys.argv[1]); assert m["files"] == [] and m["tier"] == "small", m' "$out" \
  || fail "measure --committed with no commit: $out"

# One target for the rest. Each case starts at main = m_base with a clean tree.
tier_target="$(fresh_target)"
packets="$tier_target/.agents/tasks"
tg() { git -C "$tier_target" "$@" || fail "git $* failed in the target"; }
# lines_file <path> <count>: writes <count> numbered lines.
lines_file() {
  mkdir -p "$(dirname "$tier_target/$1")"
  seq 1 "$2" | sed 's/^/line /' >"$tier_target/$1"
}
# commit_paths <message> <path>...
commit_paths() {
  local message="$1"
  shift
  tg add -- "$@"
  tg commit -q -m "$message"
}
# start_case <branch>: main back at m_base, a clean tree, then a new branch.
start_case() {
  tg checkout -q -f main
  tg reset -q --hard "$m_base"
  tg clean -q -fd
  [[ "$1" == main ]] || tg checkout -q -b "$1"
}
MEASURED_RE='^measured( \(partial: [^)]*\))?: (small|medium|large) \(([0-9]+) files?, ([0-9]+) lines?\)$'
# expect_measured <task> <tier> <files> <lines|-> [<reason text>...]: the
# measured line of `tier show` and its reason lines.
expect_measured() {
  local task="$1" want_tier="$2" want_files="$3" want_lines="$4" line reason
  shift 4
  expect_rc 0 show --task "$task"
  line="$(grep '^measured' <<<"$TIER_OUT")" || fail "tier show has no measured line: $TIER_OUT"
  [[ "$line" =~ $MEASURED_RE ]] || fail "measured line: $line"
  [[ "${BASH_REMATCH[2]} files=${BASH_REMATCH[3]}" == "$want_tier files=$want_files" ]] \
    || fail "$task: want $want_tier with files=$want_files: $TIER_OUT"
  [[ "$want_lines" == - || "${BASH_REMATCH[4]}" == "$want_lines" ]] || fail "$task: want $want_lines lines: $TIER_OUT"
  for reason in "$@"; do
    sed -n 's/^- //p' <<<"$TIER_OUT" | grep -qF -- "$reason" || fail "$task: no reason with '$reason': $TIER_OUT"
  done
}
# measure_assert <task> <python expr>...: the hidden measure op's JSON (m)
# makes each expr true; env is os.environ.
measure_check="$TMP_ROOT/measure-check.py"
cat >"$measure_check" <<'PY'
import json, os, sys
m = json.loads(sys.stdin.read())
for expr in sys.argv[1:]:
    assert eval(expr, {"m": m, "env": os.environ}), (expr, m)
PY
measure_assert() {
  local task="$1"
  shift
  expect_rc 0 measure --task "$task"
  python3 "$measure_check" "$@" <<<"$TIER_OUT" || fail "measure --task $task: $TIER_OUT"
}

lines_file app/auth/token.ts 10
lines_file lib/big.ts 600
lines_file src/edit.ts 100
mkdir -p "$tier_target/assets"
printf 'PNG\0\1\2' >"$tier_target/assets/logo.bin"
{ printf 'x\0'; seq 1 500; } >"$tier_target/assets/was-binary.dat"
commit_paths base app lib src assets
m_base="$(tg rev-parse HEAD)"
[[ -z "$(tg status --porcelain)" ]] || fail "measure target tree is not clean"

# 1. Feature branch: 2 files committed before set, 3 over 2 commits after, and
# 3 untracked files: all 8 count.
start_case feature/x
lines_file src/one.ts 2
lines_file src/two.ts 2
commit_paths "two before set" src/one.ts src/two.ts
expect_rc 0 set small --task feat
grep -qF '2 files are already changed; they count toward this task.' <<<"$TIER_OUT" || fail "set note: $TIER_OUT"
tier_assert feat "d['coding_started_tier'] == 'small' and d['coding_started_at'] is not None"
lines_file src/three.ts 2
commit_paths three src/three.ts
lines_file src/four.ts 2
lines_file src/five.ts 2
commit_paths "four and five" src/four.ts src/five.ts
for n in 1 2 3; do lines_file "src/u$n.ts" 1; done
expect_measured feat medium 8 13 "8 counted files (small allows 3)"
grep -qxF "base: ${m_base:0:7} \"base\" (3 commits since)" <<<"$TIER_OUT" || fail "base line: $TIER_OUT"
grep -qxF 'status: open' <<<"$TIER_OUT" || fail "status line: $TIER_OUT"
expect_rc 0 show --task feat --pr-line
[[ "$TIER_OUT" == "Tier: small · 8 files, 13 lines · measured medium, above the tier" ]] \
  || fail "pr-line with the measure: $TIER_OUT"
# Tidy-up rule 1: the task started with a commit main does not hold.
measure_assert feat "m['base_hint'] is True"

# 2. A merge of a main commit that touches 5 other files: still 8.
tg checkout -q main
for n in 1 2 3 4 5; do lines_file "other/m$n.ts" 1; done
commit_paths "main moves" other
tg checkout -q feature/x
tg merge -q --no-ff -m "merge main" main
expect_measured feat medium 8 13

# 3. A rebase onto a newer main: no upstream files.
tg checkout -q main
lines_file other/m6.ts 1
commit_paths "main moves again" other
main_tip="$(tg rev-parse HEAD)"
tg checkout -q feature/x
tg rebase -q main
expect_measured feat medium 8 13
MAIN="$main_tip" measure_assert feat "m['status'] == 'open' and m['partial'] is False" \
  "m['base']['kind'] == 'merge-base' and m['base']['sha'] == env['MAIN']" \
  "len(m['files']) == 8 and not [f for f in m['files'] if f['path'].startswith('other/')]" \
  "m['default_ref'] == 'main' and m['default_name'] == 'main'"

# 10. Another branch after the set: stale, and the measured tier still prints.
tg checkout -q -b feature/y
expect_measured feat medium 8 13
grep -q '^status: stale' <<<"$TIER_OUT" || fail "another branch is not stale: $TIER_OUT"
measure_assert feat "m['status'] == 'stale'"
# 11. A closed task: stale.
tg checkout -q feature/x
expect_rc 0 close --task feat
expect_measured feat medium 8 13
grep -q '^status: stale' <<<"$TIER_OUT" || fail "a closed task is not stale: $TIER_OUT"
expect_rc 0 show --task feat --pr-line
[[ "$TIER_OUT" == "Tier: small · 8 files, 13 lines (stale)" ]] || fail "pr-line of a stale task: $TIER_OUT"

# 4-6. A risky rename with no content change, a 600-line git mv and 40 lines
# edited in place.
start_case feature/moves
expect_rc 0 set small --task moves
mkdir -p "$tier_target/app/lib"
tg mv app/auth/token.ts app/lib/token.ts
tg commit -q -m "move token"
expect_measured moves large 1 0 "risky path: app/auth/token.ts (token auth)"
tg mv lib/big.ts lib/huge.ts
expect_measured moves large 2 0
awk 'NR <= 40 { print "changed " NR; next } { print }' "$tier_target/src/edit.ts" >"$TMP_ROOT/edit.ts"
mv "$TMP_ROOT/edit.ts" "$tier_target/src/edit.ts"
expect_measured moves large 3 40

# 7 and 19. Binary files: a committed new one, a tracked one modified and an
# untracked one.
start_case feature/bin
expect_rc 0 set small --task bin
printf 'PK\0\3\4' >"$tier_target/lib/sdk.aar"
commit_paths "add sdk" lib/sdk.aar
expect_measured bin medium 1 0 "binary file changed: lib/sdk.aar"
printf 'PNG\0\2\1' >"$tier_target/assets/logo.bin"
expect_measured bin medium 2 0 "binary file changed: assets/logo.bin"
printf 'x\0y' >"$tier_target/lib/extra.aar"
expect_measured bin medium 3 0 "binary file changed: lib/extra.aar"
# Binary on either side is binary, as in git: committed with a NUL, now text.
seq 1 500 >"$tier_target/assets/was-binary.dat"
expect_measured bin medium 4 0 "binary file changed: assets/was-binary.dat"

# 8. Submodules: a bump, a new gitlink and a deleted one.
start_case main
tg update-index --add --cacheinfo "160000,$m_base,vendor/old"
tg commit -q -m "add vendor/old"
mkdir -p "$tier_target/vendor/old"
tg checkout -q -b feature/subs
expect_rc 0 set small --task subs
expect_measured subs small 0 0
# Config that hides submodule changes must not hide a bump.
tg config diff.ignoreSubmodules all
tg update-index --cacheinfo "160000,$(tg rev-parse HEAD),vendor/old"
tg commit -q -m "bump vendor/old"
expect_measured subs medium 1 0 "submodule changed: vendor/old"
tg update-index --add --cacheinfo "160000,$m_base,vendor/sub"
tg commit -q -m "add vendor/sub"
expect_measured subs medium 2 0 "submodule changed: vendor/sub"
tg update-index --force-remove vendor/old
tg commit -q -m "drop vendor/old"
rmdir "$tier_target/vendor/old"
expect_measured subs medium 2 0 "submodule changed: vendor/old" "submodule changed: vendor/sub"
measure_assert subs "{f['path']: f['submodule'] for f in m['files']} == {'vendor/old': True, 'vendor/sub': True}"
tg config --unset diff.ignoreSubmodules

# 9. A manifest and its lock: the lock lines are not counted.
start_case feature/deps
expect_rc 0 set small --task deps
lines_file package.json 1
lines_file package-lock.json 3000
commit_paths deps package.json package-lock.json
expect_measured deps medium 1 1 "dependency manifest changed: package.json" "1 lock file not counted"
measure_assert deps "m['excluded']['locks'] == 1 and m['excluded']['lines'] == 3000"

# 14. On the default branch the base is start_commit.
start_case main
expect_rc 0 set small --task on-main
lines_file src/m1.ts 1
commit_paths m1 src/m1.ts
lines_file src/m2.ts 1
commit_paths m2 src/m2.ts
lines_file src/m3.ts 1
expect_measured on-main small 3 3
grep -qxF "base: ${m_base:0:7} \"base\" (2 commits since)" <<<"$TIER_OUT" || fail "base on main: $TIER_OUT"
START="$m_base" measure_assert on-main "m['base']['kind'] == 'start' and m['base']['sha'] == env['START']"

# 18 and 20. An unstaged mv is a rename with 0 lines. Coding start is recorded
# on the first show that sees a change, and later sets and shows keep it.
start_case feature/mv
expect_rc 0 set small --task mv
tier_assert mv "d['coding_started_tier'] is None and d['coding_started_at'] is None"
mv "$tier_target/src/app.ts" "$tier_target/src/moved.ts"
expect_measured mv small 1 0
tier_assert mv "d['coding_started_tier'] == 'small' and d['coding_started_at'] is not None"
measure_assert mv \
  "m['files'] == [{'path': 'src/moved.ts', 'old_path': 'src/app.ts', 'lines': 0, 'binary': False, 'submodule': False}]"
# Pin the time so a later rewrite would show.
python3 - "$packets/mv/tier.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["coding_started_at"] = "2000-01-01T00:00:00Z"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
expect_rc 0 set medium --task mv
expect_rc 0 show --task mv
tier_assert mv "d['declared'] == 'medium' and d['coding_started_tier'] == 'small'" \
  "d['coding_started_at'] == '2000-01-01T00:00:00Z'"

# Review fix: every side of the change counts. A file staged and then undone
# in the working tree still counts, and so does a commit undone there: the
# index and the commits are what a push sends.
start_case feature/sides
expect_rc 0 set small --task sides
cp "$tier_target/app/auth/token.ts" "$TMP_ROOT/token.ts"
printf 'export const leak = 1;\n' >>"$tier_target/app/auth/token.ts"
tg add app/auth/token.ts
cp "$TMP_ROOT/token.ts" "$tier_target/app/auth/token.ts"
expect_measured sides large 1 1 "risky path: app/auth/token.ts"
tg commit -q -m "staged auth change"
expect_measured sides large 1 1 "risky path: app/auth/token.ts"
# --committed (the pre-push hook) counts the commits alone, not drafts.
tg checkout -q -- app/auth/token.ts
lines_file notes/a.ts 40
lines_file notes/b.ts 40
measure_assert sides "sorted(f['path'] for f in m['files']) == ['app/auth/token.ts', 'notes/a.ts', 'notes/b.ts']"
expect_rc 0 measure --task sides --committed
python3 "$measure_check" "[f['path'] for f in m['files']] == ['app/auth/token.ts']" <<<"$TIER_OUT" \
  || fail "measure --committed: $TIER_OUT"

# Review fix: an unstaged mv of a binary file stays binary.
start_case feature/bin-mv
expect_rc 0 set small --task bin-mv
mkdir -p "$tier_target/vendor"
mv "$tier_target/assets/logo.bin" "$tier_target/vendor/logo.bin"
expect_measured bin-mv medium 1 0 "binary file changed: vendor/logo.bin"
measure_assert bin-mv \
  "[(f['path'], f['old_path'], f['binary']) for f in m['files']] == [('vendor/logo.bin', 'assets/logo.bin', True)]"

# Review fix: a plain mv of a file added or renamed on the branch counts once,
# under its new name, with the change it had.
start_case feature/mv-new
expect_rc 0 set small --task mv-new
lines_file src/p.ts 2
lines_file src/q.ts 2
tg add src/p.ts src/q.ts
mv "$tier_target/src/p.ts" "$tier_target/src/p2.ts"
mv "$tier_target/src/q.ts" "$tier_target/src/q2.ts"
expect_measured mv-new small 2 4
lines_file src/n.ts 30
commit_paths n src/n.ts
mv "$tier_target/src/n.ts" "$tier_target/src/m.ts"
measure_assert mv-new "sorted((f['path'], f['old_path'], f['lines']) for f in m['files']) == \
[('src/m.ts', None, 30), ('src/p2.ts', None, 2), ('src/q2.ts', None, 2)]"
start_case feature/mv-renamed
expect_rc 0 set small --task mv-renamed
tg mv src/edit.ts src/r.ts
printf 'one more\n' >>"$tier_target/src/r.ts"
commit_paths "rename and edit" src/r.ts
mv "$tier_target/src/r.ts" "$tier_target/src/r2.ts"
expect_measured mv-renamed small 1 1
measure_assert mv-renamed "[(f['path'], f['old_path'], f['lines']) for f in m['files']] == [('src/r2.ts', 'src/edit.ts', 1)]"
# A pure rename, then a plain mv: one file, also for a binary one.
start_case feature/mv-pure
expect_rc 0 set small --task mv-pure
tg mv src/app.ts src/r.ts
tg commit -q -m "pure rename"
mv "$tier_target/src/r.ts" "$tier_target/src/r2.ts"
tg mv assets/logo.bin assets/b.bin
tg commit -q -m "pure binary rename"
mv "$tier_target/assets/b.bin" "$tier_target/assets/c.bin"
measure_assert mv-pure "sorted((f['path'], f['old_path'], f['lines'], f['binary']) for f in m['files']) == \
[('assets/c.bin', 'assets/logo.bin', 0, True), ('src/r2.ts', 'src/app.ts', 0, False)]"

# Rule 2 (a move keeps every path): a moved file counts once, and the risk
# check still reads every path the measured snapshots had.
# mv_row <task> <tier> <files> <risky path or ->: the measured tier and count,
# and a risky-path reason naming that path.
mv_row() {
  expect_measured "$1" "$2" "$3" -
  if [[ "$4" != - ]] && ! sed -n 's/^- //p' <<<"$TIER_OUT" | grep -qF "risky path: $4 "; then
    fail "$1: no risky path $4: $TIER_OUT"
  fi
}
# a. A new risky file, staged, then moved to a safe path.
start_case feature/mv-risk-a
expect_rc 0 set small --task mv-risk-a
lines_file app/payment/new.ts 3
tg add app/payment/new.ts
mv "$tier_target/app/payment/new.ts" "$tier_target/src/new.ts"
mv_row mv-risk-a large 1 app/payment/new.ts
# b. The same, committed: the workspace measure and --committed both see it.
start_case feature/mv-risk-b
expect_rc 0 set small --task mv-risk-b
lines_file app/payment/new.ts 3
commit_paths "new payment file" app/payment/new.ts
mv "$tier_target/app/payment/new.ts" "$tier_target/src/new.ts"
mv_row mv-risk-b large 1 app/payment/new.ts
expect_rc 0 measure --task mv-risk-b --committed
python3 "$measure_check" "m['tier'] == 'large'" <<<"$TIER_OUT" || fail "mv-risk-b --committed: $TIER_OUT"
# c. A committed rename into a risky folder, then a plain mv out of it.
start_case feature/mv-risk-c
expect_rc 0 set small --task mv-risk-c
mkdir -p "$tier_target/app/payment"
tg mv src/edit.ts app/payment/edit.ts
tg commit -q -m "into payment"
mv "$tier_target/app/payment/edit.ts" "$tier_target/src/edit2.ts"
mv_row mv-risk-c large 1 app/payment/edit.ts
# d. A safe file moved (unstaged) into a risky folder: its new path is risky.
start_case feature/mv-risk-d
expect_rc 0 set small --task mv-risk-d
mkdir -p "$tier_target/app/payment"
mv "$tier_target/src/edit.ts" "$tier_target/app/payment/edit.ts"
mv_row mv-risk-d large 1 app/payment/edit.ts
# e. A safe file, staged, then moved to another safe path: small, one file.
start_case feature/mv-risk-e
expect_rc 0 set small --task mv-risk-e
lines_file src/fresh.ts 3
tg add src/fresh.ts
mv "$tier_target/src/fresh.ts" "$tier_target/src/fresh2.ts"
mv_row mv-risk-e small 1 -
# Files of 40 lines: counted twice, they would be 80 lines, above small.
# f. A committed new file, then a staged git mv: one file, 40 lines.
start_case feature/mv-git-f
expect_rc 0 set small --task mv-git-f
lines_file src/forty.ts 40
commit_paths forty src/forty.ts
tg mv src/forty.ts src/forty2.ts
expect_measured mv-git-f small 1 40
# g. A committed 35-line edit of a base file, then a staged git mv: one file.
start_case feature/mv-git-g
expect_rc 0 set small --task mv-git-g
awk 'NR <= 35 { print "changed " NR; next } { print }' "$tier_target/src/edit.ts" >"$TMP_ROOT/edit.ts"
mv "$TMP_ROOT/edit.ts" "$tier_target/src/edit.ts"
commit_paths "edit 35" src/edit.ts
tg mv src/edit.ts src/edit3.ts
expect_measured mv-git-g small 1 35
# h. A committed new file, a plain mv, then git add: one file, 40 lines.
start_case feature/mv-git-h
expect_rc 0 set small --task mv-git-h
lines_file src/forty.ts 40
commit_paths forty src/forty.ts
mv "$tier_target/src/forty.ts" "$tier_target/src/forty2.ts"
tg add -A src
expect_measured mv-git-h small 1 40
# i. The same with a plain mv not yet added: one file, 40 lines.
start_case feature/mv-git-i
expect_rc 0 set small --task mv-git-i
lines_file src/forty.ts 40
commit_paths forty src/forty.ts
mv "$tier_target/src/forty.ts" "$tier_target/src/forty2.ts"
expect_measured mv-git-i small 1 40
# j. A committed risky file, then a staged git mv to a safe path: large, one file.
start_case feature/mv-git-j
expect_rc 0 set small --task mv-git-j
lines_file app/payment/pay.ts 3
commit_paths pay app/payment/pay.ts
tg mv app/payment/pay.ts src/pay.ts
mv_row mv-git-j large 1 app/payment/pay.ts

# A committed code file moved (unstaged) to a .md name still started coding:
# a raise after it needs the new tier's reviews.
start_case feature/md-move
expect_rc 0 set small --task md-move
lines_file app/payment/new.ts 40
commit_paths "new payment file" app/payment/new.ts
mkdir -p "$tier_target/docs/scratch"
mv "$tier_target/app/payment/new.ts" "$tier_target/docs/scratch/new.md"
expect_rc 0 set large --task md-move
tier_assert md-move "d['coding_started_tier'] == 'small'"
measure_assert md-move "m['raised_after_coding'] is True and m['missing_reviews'] == ['@gate', '@verify', '@audit']"

# Review fix: on the default branch, commits pulled from the remote branch are
# not the task's. After a rebase or a merge pull only the task's own commit
# counts; after a push the pushed commits are left out, new work counts.
start_case main
expect_rc 0 set small --task pulled
lines_file src/own.ts 1
commit_paths own src/own.ts
own_sha="$(tg rev-parse HEAD)"
tg checkout -q -b mates "$m_base"
for n in 1 2 3 4 5; do lines_file "other/t$n.ts" 1; done
commit_paths teammates other
mates_tip="$(tg rev-parse HEAD)"
tg update-ref refs/remotes/origin/main "$mates_tip"
tg checkout -q main
tg rebase -q refs/remotes/origin/main
expect_measured pulled small 1 1
MATES="$mates_tip" measure_assert pulled "m['base']['kind'] == 'merge-base' and m['base']['sha'] == env['MATES']" \
  "[f['path'] for f in m['files']] == ['src/own.ts']" "m['partial'] is False and m['partial_reason'] is None"
tg reset -q --hard "$own_sha"
tg merge -q --no-ff -m "pull" refs/remotes/origin/main
expect_measured pulled small 1 1
tg update-ref refs/remotes/origin/main HEAD
expect_measured pulled small 0 0
lines_file src/after.ts 1
expect_measured pulled small 1 1
# A local commit made before tier set is not the task's: the base stays the start.
start_case main
lines_file src/early.ts 1
commit_paths early src/early.ts
tg update-ref refs/remotes/origin/main "$m_base"
expect_rc 0 set small --task early
lines_file src/late.ts 1
expect_measured early small 1 1
START="$(tg rev-parse HEAD)" measure_assert early "m['base']['kind'] == 'start' and m['base']['sha'] == env['START']" \
  "m['partial'] is False"
# Rule 4 (partial needs a cause). A local commit from before the task, the
# task's commit, then a pull of the five teammate files:
# a. a rebase pull rewrites the start commit: partial with that cause, from
#    the merge-base with origin/main, so no teammate file counts;
start_case main
lines_file src/early.ts 1
commit_paths early src/early.ts
tg update-ref refs/remotes/origin/main "$m_base"
expect_rc 0 set small --task rebased
lines_file src/task.ts 1
commit_paths task src/task.ts
tg update-ref refs/remotes/origin/main "$mates_tip"
tg rebase -q refs/remotes/origin/main
expect_rc 0 show --task rebased
grep -qxF "measured (partial: the start commit is no longer in this branch's history, after a rebase or reset): small (2 files, 2 lines)" \
  <<<"$TIER_OUT" || fail "a rebased start is not partial with its cause: $TIER_OUT"
MATES="$mates_tip" measure_assert rebased "m['partial'] is True and m['base']['sha'] == env['MATES']" \
  "sorted(f['path'] for f in m['files']) == ['src/early.ts', 'src/task.ts']"
# b. a merge pull: partial with its own cause, still no teammate file;
start_case main
lines_file src/early.ts 1
commit_paths early src/early.ts
tg update-ref refs/remotes/origin/main "$m_base"
expect_rc 0 set small --task merged
lines_file src/task.ts 1
commit_paths task src/task.ts
tg update-ref refs/remotes/origin/main "$mates_tip"
tg merge -q --no-ff -m pull refs/remotes/origin/main
MATES="$mates_tip" measure_assert merged "m['partial'] is True and m['base']['sha'] == env['MATES']" \
  "m['partial_reason'] == 'commits from before the task were merged with pulled commits'" \
  "sorted(f['path'] for f in m['files']) == ['src/early.ts', 'src/task.ts']"
# c. no remote branch, reset past the start: partial, from the common commit.
tg update-ref -d refs/remotes/origin/main
start_case main
lines_file src/x1.ts 1
commit_paths x1 src/x1.ts
expect_rc 0 set small --task reset
tg reset -q --hard "$m_base"
lines_file src/x2.ts 1
M_BASE="$m_base" measure_assert reset "m['partial'] is True and m['base']['sha'] == env['M_BASE']" \
  "m['partial_reason'].startswith('the start commit is no longer')" "[f['path'] for f in m['files']] == ['src/x2.ts']"
# d. A --base ref that is gone (a merged parent after fetch --prune): partial
#    with that cause, measured since tier set.
start_case main
tg checkout -q -b feature/parent
lines_file src/p1.ts 1
commit_paths p1 src/p1.ts
tg update-ref refs/remotes/origin/parent HEAD
tg checkout -q -b feature/child
expect_rc 0 set small --task child --base origin/parent
for n in 1 2 3 4; do lines_file "src/c$n.ts" 1; done
commit_paths four-c src/c1.ts src/c2.ts src/c3.ts src/c4.ts
expect_measured child medium 4 4
measure_assert child "m['partial'] is False"
tg update-ref -d refs/remotes/origin/parent
expect_rc 0 show --task child
grep -qxF 'measured (partial: the --base origin/parent is gone, so measured since tier set): medium (4 files, 4 lines)' \
  <<<"$TIER_OUT" || fail "a gone --base is not partial with its cause: $TIER_OUT"

# Rule 5 (a task follows its branch when the user says so): tier set on
# main, then a branch made from its work: stale, with a hint to move the
# task; tier set there moves it. A branch without the start commit stays
# stale with no hint.
start_case main
lines_file src/f0.ts 1
commit_paths f0 src/f0.ts
expect_rc 0 set small --task follow
tg checkout -q -b feature/follow
for n in 1 2 3 4; do lines_file "src/f$n.ts" 1; done
commit_paths four src/f1.ts src/f2.ts src/f3.ts src/f4.ts
expect_rc 0 show --task follow
grep -qxF 'status: stale (on feature/follow, not the task branch main; run tier set on this branch to move the task)' \
  <<<"$TIER_OUT" || fail "a task on a branch from its work lacks the hint: $TIER_OUT"
tg checkout -q -b feature/other "$m_base"
expect_rc 0 show --task follow
grep -qxF 'status: stale (on feature/other, not the task branch main)' <<<"$TIER_OUT" \
  || fail "a branch without the start commit: $TIER_OUT"
tg checkout -q feature/follow
expect_rc 0 set small --task follow
grep -qxF 'The task moved to branch feature/follow (it was started on main).' <<<"$TIER_OUT" || fail "follow note: $TIER_OUT"
tier_assert follow "d['branch'] == 'feature/follow'"
expect_measured follow medium 4 4
grep -qxF 'status: open' <<<"$TIER_OUT" || fail "a moved task is stale: $TIER_OUT"

# Rule 4, stacked branches: the base is the newer of the merge-base with the
# --base ref and with the default branch, when one holds the other.
# s1. The parent is squash-merged into main (with a teammate file), and the
#     child is rebased onto main: only the child's line counts.
start_case main
tg checkout -q -b feature/sp
lines_file src/sp.ts 45
commit_paths sp src/sp.ts
tg update-ref refs/remotes/origin/sp HEAD
tg checkout -q -b feature/sc
expect_rc 0 set small --task sc --base origin/sp
lines_file src/sc.ts 1
commit_paths sc src/sc.ts
tg checkout -q main
lines_file src/sp.ts 45
lines_file other/t1.ts 45
commit_paths "squash of sp, and a teammate file" src/sp.ts other/t1.ts
tg checkout -q feature/sc
tg rebase -q --onto main refs/remotes/origin/sp feature/sc
expect_measured sc small 1 1
# s2. The parent is merged into main, and the child merges main: only the
#     child's line counts.
start_case main
tg checkout -q -b feature/mp
lines_file src/mp.ts 45
commit_paths mp src/mp.ts
tg update-ref refs/remotes/origin/mp HEAD
tg checkout -q -b feature/mc
expect_rc 0 set small --task mc --base origin/mp
lines_file src/mc.ts 1
commit_paths mc src/mc.ts
tg checkout -q main
tg merge -q --no-ff -m "merge mp" feature/mp
lines_file other/t2.ts 45
commit_paths mate other/t2.ts
tg checkout -q feature/mc
tg merge -q --no-ff -m "pull main" main
expect_measured mc small 1 1
# s3. The child merges main while the parent is not merged: partial, with
#     that cause.
start_case main
tg checkout -q -b feature/np
lines_file src/np.ts 45
commit_paths np src/np.ts
tg update-ref refs/remotes/origin/np HEAD
tg checkout -q -b feature/nc
expect_rc 0 set small --task nc --base origin/np
lines_file src/nc.ts 1
commit_paths nc src/nc.ts
tg checkout -q main
lines_file other/t3.ts 45
commit_paths mate other/t3.ts
tg checkout -q feature/nc
tg merge -q --no-ff -m "pull main" main
measure_assert nc "m['partial'] is True" \
  "m['partial_reason'] == 'the branch took in default-branch commits that its --base does not have'"
for ref in sp mp np; do tg update-ref -d "refs/remotes/origin/$ref"; done
start_case main
tg branch -q -D mates

# A branch cut from develop with no --base at the first set: the push check
# counts develop's commits. The first set's note names --base; a later set
# with --base fixes it in place, and the history records it. While a review
# is negative, the base cannot change.
start_case main
tg checkout -q -b develop
for n in 1 2 3 4 5; do lines_file "dev/d$n.ts" 1; done
commit_paths develop dev
tg update-ref refs/remotes/origin/develop HEAD
tg checkout -q -b feature/gf
expect_rc 0 set small --task gf
grep -qF 'If this branch starts from another branch, run tier set again with --base <that branch>.' <<<"$TIER_OUT" \
  || fail "the first set does not name --base: $TIER_OUT"
lines_file src/gf.ts 1
commit_paths gf src/gf.ts
expect_rc 0 measure --task gf --committed
python3 "$measure_check" "m['tier'] == 'medium' and m['counted_files'] == 6" <<<"$TIER_OUT" || fail "gf before --base: $TIER_OUT"
expect_rc 0 set small --task gf --base origin/develop
grep -qxF 'The base is now origin/develop.' <<<"$TIER_OUT" || fail "base note: $TIER_OUT"
tier_assert gf "d['base_ref'] == 'refs/remotes/origin/develop'" "d['history'][-1]['base'] == 'refs/remotes/origin/develop'"
expect_measured gf small 1 1
printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: no\n' >"$packets/gf/gate-review.md"
expect_rc 0 set small --task gf --base main
grep -qxF 'agent-guard: warn: changing the --base although the latest @gate review is negative' "$TMP_ROOT/tier.err" \
  || fail "a base change with a negative review: $(cat "$TMP_ROOT/tier.err")"
rm -f "$packets/gf/gate-review.md"
tg update-ref -d refs/remotes/origin/develop

# Rule 5 after git branch -m: the old ref is gone and the branch holds the
# start commit, so tier set moves the task.
start_case feature/old-name
expect_rc 0 set small --task renamed
lines_file src/rn.ts 1
commit_paths rn src/rn.ts
tg branch -m feature/new-name
expect_rc 0 show --task renamed
grep -qxF 'status: stale (on feature/new-name, not the task branch feature/old-name; run tier set on this branch to move the task)' \
  <<<"$TIER_OUT" || fail "a renamed branch lacks the hint: $TIER_OUT"
expect_rc 0 set small --task renamed
grep -qxF 'The task moved to branch feature/new-name (it was started on feature/old-name).' <<<"$TIER_OUT" \
  || fail "rename note: $TIER_OUT"
expect_measured renamed small 1 1
grep -qxF 'status: open' <<<"$TIER_OUT" || fail "a moved task is stale: $TIER_OUT"

# Tidy-up rule 1: the --base hint needs evidence. A branch fresh from main
# (also its first-set note), main itself and a branch with --base: no hint.
# A branch whose task started on a commit main does not hold: the hint.
start_case feature/hint-new
lines_file src/hn.ts 1
expect_rc 0 set small --task hint-new
grep -qF '1 file is already changed' <<<"$TIER_OUT" || fail "hint-new set note: $TIER_OUT"
if grep -qF -- '--base' <<<"$TIER_OUT"; then fail "a branch fresh from main names --base: $TIER_OUT"; fi
measure_assert hint-new "m['base_hint'] is False"
start_case main
expect_rc 0 set small --task hint-main
measure_assert hint-main "m['base_hint'] is False"
start_case feature/hint-own
lines_file src/ho.ts 1
commit_paths own src/ho.ts
expect_rc 0 set small --task hint-own
grep -qF 'If this branch starts from another branch, run tier set again with --base <that branch>.' <<<"$TIER_OUT" \
  || fail "a branch with its own commit lacks the first-set hint: $TIER_OUT"
measure_assert hint-own "m['base_hint'] is True"
expect_rc 0 set small --task hint-own --base main
measure_assert hint-own "m['base_hint'] is False"

# A detached HEAD gives no hint (as before).
start_case feature/hint-det
lines_file src/hd.ts 1
commit_paths det src/hd.ts
expect_rc 0 set small --task hint-det
measure_assert hint-det "m['base_hint'] is True"
tg checkout -q --detach
measure_assert hint-det "m['base_hint'] is False"
tg checkout -q feature/hint-det

# Tidy-up rule 3 on a real move: 20 files moved without edits are medium.
start_case main
for n in $(seq 1 20); do lines_file "cards/c$n.ts" 1; done
commit_paths cards cards
tg checkout -q -b feature/move-only
tg mv cards app-cards
tg commit -q -m "move the cards"
expect_rc 0 set medium --task move-only
expect_measured move-only medium 20 0 "20 counted files, 20 only moved (small allows 3)"

# Rule 4: the default branch is unknown (a dev default, no origin/HEAD):
# partial with that cause, so pulled commits never make the push exit 5.
# With origin/HEAD set, the measure is full again.
dev_target="$(mktemp -d "$TMP_ROOT/dev.XXXXXX")"
dg() { git -C "$dev_target" "$@" || fail "git $* failed in the dev target"; }
dg init -q -b dev
dg config user.name Test
dg config user.email test@example.invalid
mkdir -p "$dev_target/src"
printf 'export const a = 1;\n' >"$dev_target/src/app.ts"
dg add src/app.ts
dg commit -q -m init
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$dev_target" --workflow full \
  --project-name budget-fixture >/dev/null || fail "bootstrap failed in the dev target"
dev_base="$(dg rev-parse HEAD)"
dg update-ref refs/remotes/origin/dev "$dev_base"
(cd "$dev_target" && scripts/agent-guard.sh tier set small --task devt >/dev/null 2>&1) || fail "tier set in the dev target"
dg checkout -q -b mates-dev
for n in 1 2 3 4 5; do printf 'export const t%s = 1;\n' "$n" >"$dev_target/src/t$n.ts"; done
dg add src
dg commit -q -m teammates
dg update-ref refs/remotes/origin/dev HEAD
dg checkout -q dev
printf 'export const own = 1;\n' >"$dev_target/src/own.ts"
dg add src/own.ts
dg commit -q -m own
dg rebase -q refs/remotes/origin/dev
out="$(cd "$dev_target" && scripts/agent-guard.sh tier measure --task devt --committed 2>&1)" || fail "dev measure: $out"
python3 "$measure_check" "m['partial'] is True" "m['partial_reason'].startswith('the default branch is unknown')" \
  "m['base_hint'] is True" <<<"$out" || fail "an unknown default branch is not partial: $out"
# Partial still recommends, with its cause next to each step.
(cd "$dev_target" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight in the dev target"
out="$(cd "$dev_target" && scripts/agent-guard.sh pre-final --task devt --committed 2>&1)" || fail "dev pre-final: $out"
grep -qF '(partial: the default branch is unknown' <<<"$out" || fail "a partial exceeded lacks its cause: $out"
grep -qF 'Next: if this branch starts from another branch, give its base: scripts/agent-guard.sh tier set small --task devt --base <branch>. (partial: the default branch is unknown' \
  <<<"$out" || fail "an unknown default lacks the --base hint: $out"
grep -qF 'TIER: declared small, measured medium, partial (recommended: raise the tier or split the change)' <<<"$out" \
  || fail "a partial exceeded is not recommended: $out"
dg symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
out="$(cd "$dev_target" && scripts/agent-guard.sh tier measure --task devt --committed 2>&1)" || fail "dev measure: $out"
python3 "$measure_check" "m['partial'] is False" "[f['path'] for f in m['files']] == ['src/own.ts']" "m['base_hint'] is False" <<<"$out" \
  || fail "a dev default with origin/HEAD: $out"

# 17. No tier (a packet with state.json only): the no-tier base rule, partial.
start_case feature/no-tier
lines_file src/nt.ts 1
commit_paths nt src/nt.ts
mkdir -p "$packets/no-tier"
printf '{}\n' >"$packets/no-tier/state.json"
MAIN="$m_base" measure_assert no-tier "m['status'] == 'none' and m['partial'] is True and m['task'] is None" \
  "m['base']['kind'] == 'merge-base' and m['base']['sha'] == env['MAIN']" \
  "[f['path'] for f in m['files']] == ['src/nt.ts']"
tg checkout -q main
HEAD_SHA="$m_base" measure_assert no-tier "m['status'] == 'none' and m['partial'] is True" \
  "m['base']['kind'] == 'head' and m['base']['sha'] == env['HEAD_SHA'] and m['files'] == []"

# One case, step by step: a -diff text file counts its lines; a partly staged
# file counts once, with the larger total; delete and re-create counts the
# larger of the two.
start_case feature/edits
expect_rc 0 set small --task edits
m_git_dir="$(tg rev-parse --absolute-git-dir)"
printf '*.csv -diff\n' >>"$m_git_dir/info/attributes"
lines_file data/table.csv 20
commit_paths table data/table.csv
expect_measured edits small 1 20
if grep -q 'binary file changed' <<<"$TIER_OUT"; then fail "a -diff text file is binary: $TIER_OUT"; fi
awk 'NR <= 30 { print "changed " NR; next } { print }' "$tier_target/src/edit.ts" >"$TMP_ROOT/edit.ts"
cp "$TMP_ROOT/edit.ts" "$tier_target/src/edit.ts"
tg add src/edit.ts
tg show "$m_base:src/edit.ts" | awk 'NR > 20 && NR <= 30 { print "changed " NR; next } { print }' >"$TMP_ROOT/edit.ts"
mv "$TMP_ROOT/edit.ts" "$tier_target/src/edit.ts"
expect_measured edits small 2 50
tg rm -q lib/big.ts
lines_file lib/big.ts 10
expect_measured edits large 3 650
# .agents/ is not counted, also when the exclude block lacks it.
cp "$m_git_dir/info/exclude" "$TMP_ROOT/exclude.bak"
grep -vxF '.agents/' "$TMP_ROOT/exclude.bak" >"$m_git_dir/info/exclude"
[[ "$(tg status --porcelain)" == *'?? .agents/'* ]] || fail ".agents/ is still ignored: $(tg status --porcelain)"
expect_measured edits large 3 650
cp "$TMP_ROOT/exclude.bak" "$m_git_dir/info/exclude"
# GIT_DIR and GIT_INDEX_FILE from the caller are not used.
out="$(cd "$tier_target" && GIT_DIR="$TMP_ROOT/nowhere" GIT_INDEX_FILE="$TMP_ROOT/nowhere/index" \
  python3 -I scripts/agent-tier.py show --task edits 2>&1)" || fail "show with GIT_DIR set: $out"
grep -qxF 'measured: large (3 files, 650 lines)' <<<"$out" || fail "GIT_DIR changed the measure: $out"
# A git failure (a corrupt index): show and --pr-line say n/a and exit 0.
cp "$m_git_dir/index" "$TMP_ROOT/index.bak"
printf 'not an index' >"$m_git_dir/index"
expect_rc 0 show --task edits
grep -qxF 'measured: n/a (cannot read the change from git)' <<<"$TIER_OUT" || fail "show with a corrupt index: $TIER_OUT"
expect_rc 0 show --task edits --pr-line
[[ "$TIER_OUT" == "Tier: small · measured: n/a (cannot read the change from git)" ]] \
  || fail "pr-line with a corrupt index: $TIER_OUT"
cp "$TMP_ROOT/index.bak" "$m_git_dir/index"

# Speed: 300 -diff text files (*.csv here) measure quickly. The limit is 3 s:
# one git diff per file took about 4 s here, so 5 s would not catch it.
start_case feature/many
expect_rc 0 set small --task many
mkdir -p "$tier_target/data/many"
for n in $(seq 1 300); do printf 'a,%s\nb,%s\n' "$n" "$n" >"$tier_target/data/many/f$n.csv"; done
commit_paths many data/many
started=$SECONDS
expect_measured many large 300 600
(( SECONDS - started < 3 )) || fail "300 -diff files took $((SECONDS - started)) s to measure"

# A stacked branch: --base names a full ref, and only feature/b's own commits
# count. A position that moves with HEAD is refused.
start_case feature/a
lines_file src/a1.ts 1
commit_paths a1 src/a1.ts
a_tip="$(tg rev-parse HEAD)"
tg checkout -q -b feature/b
lines_file src/b1.ts 1
commit_paths b1 src/b1.ts
lines_file src/b2.ts 1
commit_paths b2 src/b2.ts
for bad in 'HEAD~1' 'HEAD^0' '@{0}'; do
  expect_rc 1 set small --task stacked --base "$bad"
  grep -q 'full commit id' "$TMP_ROOT/tier.err" || fail "--base $bad message: $(cat "$TMP_ROOT/tier.err")"
done
[[ ! -e "$packets/stacked/tier.json" ]] || fail "a refused --base wrote tier.json"
expect_rc 0 set small --task stacked --base refs/heads/feature/a
tier_assert stacked "d['base_ref'] == 'refs/heads/feature/a'"
expect_measured stacked small 2 2
grep -qxF "base: ${a_tip:0:7} \"a1\" (2 commits since)" <<<"$TIER_OUT" || fail "stacked base line: $TIER_OUT"
expect_rc 0 set small --task stacked-short --base feature/a
tier_assert stacked-short "d['base_ref'] == 'refs/heads/feature/a'"
expect_rc 0 set small --task stacked-sha --base "$a_tip"
A_TIP="$a_tip" tier_assert stacked-sha "d['base_ref'] == env['A_TIP']"
# The upstream of the current branch moves with each push: refused.
tg remote add up "$TMP_ROOT/up.git"
tg update-ref refs/remotes/up/feature-b-copy HEAD~1
tg branch -q --set-upstream-to=up/feature-b-copy
for bad in '@{u}' up/feature-b-copy; do
  expect_rc 1 set small --task stacked-up --base "$bad"
  grep -q 'upstream' "$TMP_ROOT/tier.err" || fail "--base $bad message: $(cat "$TMP_ROOT/tier.err")"
done
tg remote remove up
# A stacked branch with no commit yet: the base is at HEAD, and is accepted.
tg checkout -q -b feature/c
expect_rc 0 set small --task stacked-new --base feature/b
lines_file src/c1.ts 1
commit_paths c1 src/c1.ts
expect_measured stacked-new small 1 1

# Odd file names: a space, unicode, a tab, a newline, a CR and a leading
# quote. An unstaged move to a quoted name still pairs.
start_case feature/odd
expect_rc 0 set small --task odd
lines_file "src/with space.ts" 2
lines_file $'src/\303\274n.ts' 3
lines_file $'src/tab\tname.ts' 1
commit_paths odd "src/with space.ts" $'src/\303\274n.ts' $'src/tab\tname.ts'
lines_file $'src/new\nline.ts' 1
lines_file $'src/cr\r.ts' 1
lines_file '"quote.ts' 1
mv "$tier_target/src/edit.ts" "$tier_target/\"moved edit.ts"
expect_rc 0 measure --task odd
python3 - "$TIER_OUT" <<'PY' || fail "odd file names: $TIER_OUT"
import json, sys
m = json.loads(sys.argv[1])
want = ["src/with space.ts", "src/ün.ts", "src/tab\tname.ts", "src/new\nline.ts", "src/cr\r.ts",
        '"quote.ts', '"moved edit.ts']
assert sorted(f["path"] for f in m["files"]) == sorted(want), m["files"]
moved = [f for f in m["files"] if f["old_path"]]
assert moved == [{"path": '"moved edit.ts', "old_path": "src/edit.ts", "lines": 0,
                  "binary": False, "submodule": False}], moved
assert (m["counted_files"], m["counted_lines"]) == (7, 9), m
PY

# 15. Remote default: origin/HEAD names origin/main; local main is the default.
start_case main
git init -q --bare "$TMP_ROOT/remote.git" || fail "git init --bare failed"
tg remote add origin "$TMP_ROOT/remote.git"
tg push -q origin main
tg remote set-head origin main
measure_assert on-main "m['default_ref'] == 'origin/main' and m['default_name'] == 'main'" \
  "m['base']['kind'] == 'start' and m['status'] == 'open'"
# A start_commit that is not an object id: stale, measured from HEAD.
python3 - "$packets/on-main/tier.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["start_commit"] = "not-a-sha"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
expect_measured on-main small 0 0
grep -q '^status: stale (the base commit not-a-sha' <<<"$TIER_OUT" || fail "a bad start_commit is not stale: $TIER_OUT"
grep -q '^measured (partial: the base commit is not here, so uncommitted changes only): ' <<<"$TIER_OUT" \
  || fail "a bad start_commit is not partial: $TIER_OUT"
expect_rc 0 show --task on-main --pr-line
[[ "$TIER_OUT" == "Tier: small · 0 files, 0 lines (stale, partial)" ]] || fail "stale and partial pr-line: $TIER_OUT"

# 16. A shallow clone whose merge-base is outside the history: partial, no error.
shallow="$TMP_ROOT/shallow"
git clone -q --depth 1 --no-single-branch "file://$tier_target" "$shallow" 2>/dev/null || fail "shallow clone failed"
git -C "$shallow" switch -q feature/x || fail "git switch failed in the shallow clone"
printf 'export const s = 1;\n' >"$shallow/new.ts"
# direct_tier <root> <args...>: runs the target's program on another root.
direct_tier() {
  local root="$1"
  shift
  TIER_RC=0
  TIER_OUT="$(python3 -I "$tier_target/scripts/agent-tier.py" --root "$root" \
    --policy "$tier_target/docs/agent-configs/context-policy.json" \
    --tech-stack "$tier_target/docs/superpowers/specs/project-tech-stack.json" "$@" 2>"$TMP_ROOT/tier.err")" \
    || TIER_RC=$?
  [[ "$TIER_RC" -eq 0 ]] || fail "tier $* on $root exited $TIER_RC: $(cat "$TMP_ROOT/tier.err")"
}
direct_tier "$shallow" set small --task shallow
direct_tier "$shallow" show --task shallow
grep -qxF 'measured (partial: no shared history with origin/main, so uncommitted changes only): small (1 file, 1 line)' \
  <<<"$TIER_OUT" || fail "shallow clone measure: $TIER_OUT"
direct_tier "$shallow" show --task shallow --pr-line
[[ "$TIER_OUT" == "Tier: small · 1 file, 1 line (partial)" ]] || fail "partial pr-line: $TIER_OUT"
direct_tier "$shallow" measure --task shallow
python3 "$measure_check" "m['partial'] is True and m['status'] == 'open'" "m['base']['kind'] == 'head'" \
  "m['default_ref'] == 'origin/main'" <<<"$TIER_OUT" || fail "shallow measure JSON: $TIER_OUT"

# 13. Subdirectory install: changes outside app/ are not counted, paths are
# relative to app/.
sub_repo="$(mktemp -d "$TMP_ROOT/subrepo.XXXXXX")"
git -C "$sub_repo" init -q -b main || fail "git init failed"
git -C "$sub_repo" config user.name "Test" || fail "git config failed"
git -C "$sub_repo" config user.email "test@example.invalid" || fail "git config failed"
mkdir -p "$sub_repo/app/src" "$sub_repo/other"
printf 'export const a = 1;\n' >"$sub_repo/app/src/app.ts"
printf 'export const o = 1;\n' >"$sub_repo/other/o.ts"
git -C "$sub_repo" add -A || fail "git add failed"
git -C "$sub_repo" commit -q -m init || fail "git commit failed"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" \
  --target "$sub_repo/app" --workflow full --project-name budget-fixture >/dev/null || fail "bootstrap in app/ failed"
git -C "$sub_repo" switch -q -c feature/sub || fail "git switch failed"
tier_target="$sub_repo/app"
packets="$tier_target/.agents/tasks"
expect_rc 0 set small --task sub
printf 'export const x = 1;\n' >"$sub_repo/app/src/x.ts"
printf 'export const y = 1;\n' >"$sub_repo/other/y.ts"
git -C "$sub_repo" add app/src/x.ts other/y.ts || fail "git add failed"
git -C "$sub_repo" commit -q -m "x and y" || fail "git commit failed"
printf 'export const u = 1;\n' >"$sub_repo/app/src/u.ts"
printf 'export const z = 1;\n' >"$sub_repo/other/z.ts"
expect_measured sub small 2 2
measure_assert sub "sorted(f['path'] for f in m['files']) == ['src/u.ts', 'src/x.ts']"

# ---- pre-final checks the tier -----------------------------------------------
# One target; each case is a branch. verification[] in the contract says what
# the runner runs: true passes, false fails.
pf="$(fresh_target)"
packets="$pf/.agents/tasks"
pf_report="$pf/.agents/state/last-verify-report.json"
pf_events="$pf/.agents/state/session-events.jsonl"
REPORT_SCHEMA="$ROOT_DIR/agent-bootstrap/schemas/agent-guard-verification-v2.schema.json"
EVENT_SCHEMA="$ROOT_DIR/agent-bootstrap/schemas/agent-guard-event-v2.schema.json"
(cd "$pf" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight failed in the pre-final target"
pg() { git -C "$pf" "$@" || fail "git $* failed in the pre-final target"; }
pf_tier() {
  (cd "$pf" && scripts/agent-guard.sh tier "$@") >/dev/null 2>"$TMP_ROOT/pf-tier.err" \
    || fail "tier $*: $(cat "$TMP_ROOT/pf-tier.err")"
}
# pf_verify <command>...: verification[] holds these commands.
pf_verify() {
  python3 - "$pf/docs/superpowers/specs/project-tech-stack.json" "$@" <<'PY' || fail "cannot write verification[]"
import json, sys
doc = json.load(open(sys.argv[1]))
doc["verification"] = [{"command": c, "purpose": "test", "source": "test"} for c in sys.argv[2:]]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
}
# pf_expect <code> [--split] <pre-final args...>: checks the exit code. PF_OUT
# is stdout and stderr in order; with --split, PF_OUT is stdout, PF_ERR stderr.
pf_expect() {
  local want="$1" split=false
  shift
  if [[ "${1:-}" == --split ]]; then
    split=true
    shift
  fi
  PF_RC=0 PF_ERR=""
  if [[ "$split" == true ]]; then
    PF_OUT="$(cd "$pf" && scripts/agent-guard.sh pre-final "$@" 2>"$TMP_ROOT/pf.err")" || PF_RC=$?
    PF_ERR="$(cat "$TMP_ROOT/pf.err")"
  else
    PF_OUT="$(cd "$pf" && scripts/agent-guard.sh pre-final "$@" 2>&1)" || PF_RC=$?
  fi
  [[ "$PF_RC" -eq "$want" ]] || fail "pre-final $*: want exit $want, got $PF_RC: $PF_OUT $PF_ERR"
}
# last_is <line> / last_starts <text>: the last line of PF_OUT.
last_is() {
  [[ "$(tail -n 1 <<<"$PF_OUT")" == "$1" ]] || fail "last line: want $1, got: $PF_OUT"
}
last_starts() {
  [[ "$(tail -n 1 <<<"$PF_OUT")" == "$1"* ]] || fail "last line: want $1..., got: $PF_OUT"
}
report_assert() {
  python3 "$json_check" "$REPORT_SCHEMA" "$pf_report" "$@" || fail "verify report: $(cat "$pf_report")"
}
event_assert() {
  python3 "$json_check" "$EVENT_SCHEMA" "$pf_events" "d['event'] == 'pre_final'" "$@" \
    || fail "pre_final event: $(tail -n 1 "$pf_events")"
}
# review <task> <file> <body>...: writes a review file of the pre-final target
# by hand, one attempt per body, with the attempt headers of the handoff
# schema. A body is printed with printf %b, so \n starts a new line.
review() {
  local task="$1" file="$2" n=0 body
  shift 2
  mkdir -p "$packets/$task"
  {
    case "$file" in
      gate-review.md) printf '## Pre-coding technical review\n' ;;
      verify-review.md) printf '## Final technical review\n' ;;
      *) printf '# Cross-review\n' ;;
    esac
    for body in "$@"; do
      n=$((n + 1))
      if [[ "$file" == audit-review.md ]]; then
        printf '\n## Cross-review attempt %s\n\n' "$n"
      else
        printf '\n### Attempt %s\n\n' "$n"
      fi
      printf '%b\n' "$body"
    done
  } >"$packets/$task/$file"
}

out="$(cd "$pf" && scripts/agent-guard.sh --help)"
grep -qF 'pre-final [--advisory|--strict] [--run-verify] [--verify-scope fast|full] [--task <id>] [--committed]' <<<"$out" \
  || fail "usage lacks pre-final --task and --committed: $out"
for bad in '' --run-verify ../etc Bad-Id; do
  pf_expect 1 --task "$bad"
  grep -qF 'pre-final --task needs a task id' <<<"$PF_OUT" || fail "--task '$bad': $PF_OUT"
done
pf_expect 1 --task

# 6 and 10. Within the tier: ok and the summary last. The first pre-final
# records the coding start; a later set and pre-final keep it.
pg checkout -q -b feature/pf-ok
pf_tier set small --task pf-ok
tier_assert pf-ok "d['coding_started_tier'] is None"
pf_verify true
printf 'export const a = 2;\n' >"$pf/src/app.ts"
pf_expect 0 --run-verify
grep -q '^agent-guard: pre-final ok' <<<"$PF_OUT" || fail "no pre-final ok within the tier: $PF_OUT"
last_is 'TIER: small ok (measured small, 1 file)'
tier_assert pf-ok "d['coding_started_tier'] == 'small'"
report_assert "d['status'] == 'pass'" \
  "d['tier']['status'] == 'ok' and d['tier']['task'] == 'pf-ok' and d['tier']['allowed'] == 'small'" \
  "d['tier']['measured'] == 'small' and d['tier']['partial'] is False and d['tier']['base']['kind'] == 'merge-base'" \
  "d['tier']['coding_started_tier'] == 'small' and d['tier']['reason'] is None"
event_assert "d['gate_status'] == 'pass' and d['tier']['status'] == 'ok'" \
  "d['tier']['raised_after_coding'] is False and d['tier']['missing_reviews'] == []"
# Review rule 5. A raise after coding stays exceeded (a recommendation, never
# a failure) until the latest verify-review.md attempt passes; an earlier pass
# does not count.
pf_tier set medium --task pf-ok
tier_assert pf-ok "d['declared'] == 'medium' and d['coding_started_tier'] == 'small'"
raised_medium='TIER: declared medium, measured small; raised after coding: @verify review still needed'
raised_next='(recommended: hand off to @verify (or ask the user); do not write review files yourself)'
pf_expect 0 --run-verify
grep -q '^agent-guard: pre-final ok' <<<"$PF_OUT" || fail "a raise after coding must not fail: $PF_OUT"
[[ "$(tail -n 2 <<<"$PF_OUT")" == "Next: the tier was raised after coding started (small -> medium); the latest attempt in verify-review.md must pass, then run pre-final again.
$raised_medium $raised_next" ]] || fail "raised after coding output: $PF_OUT"
report_assert "d['status'] == 'pass' and d['tier']['status'] == 'exceeded' and d['tier']['allowed'] == 'medium'" \
  "d['tier']['raised_after_coding'] is True and d['tier']['missing_reviews'] == ['@verify']"
event_assert "d['gate_status'] == 'warn' and d['tier']['missing_reviews'] == ['@verify']"
pf_expect 0 --advisory
last_is "$raised_medium $raised_next"
review pf-ok verify-review.md 'reviewer_model: m1\nverdict: pass' 'reviewer_model: m1\nverdict: changes_required'
pf_expect 0
last_is "$raised_medium $raised_next"
review pf-ok verify-review.md 'reviewer_model: m1\nverdict: changes_required' 'reviewer_model: m1\nverdict: pass'
pf_expect 0
last_is 'TIER: medium ok (measured small, 1 file)'
event_assert "d['tier']['status'] == 'ok' and d['tier']['raised_after_coding'] is True and d['tier']['missing_reviews'] == []"
# A failure that is not the tier's: the summary, still last, carries it.
pf_verify false
pf_expect 1 --run-verify
last_is 'TIER: medium ok (measured small, 1 file); verification fail (exit 1)'
pf_verify true

# 1 and 15. Exceeded (6 counted files on small): a recommendation, never a
# failure. Exit 0, and the reasons and the next steps come right before the
# summary, which is last.
pg checkout -q -f main
pg checkout -q -b feature/pf-big
pf_tier set small --task pf-big
for n in 1 2 3 4 5 6; do printf 'export const f%s = 1;\n' "$n" >"$pf/src/f$n.ts"; done
pf_expect 0 --run-verify
grep -q '^agent-guard: pre-final ok' <<<"$PF_OUT" || fail "a size excess must not fail: $PF_OUT"
# A branch fresh from main: no --base line (tidy-up rule 1).
pf_big_tail="- 6 counted files (small allows 3)
Next: ask the user to raise the tier (scripts/agent-guard.sh tier set medium --task pf-big; the raise then needs @verify to pass) or split the change.
TIER: declared small, measured medium (recommended: raise the tier or split the change)"
[[ "$(tail -n 3 <<<"$PF_OUT")" == "$pf_big_tail" ]] || fail "exceeded output: $PF_OUT"
report_assert "d['status'] == 'pass' and d['tier']['status'] == 'exceeded'"
event_assert "d['gate_status'] == 'warn' and d['tier']['status'] == 'exceeded' and d['tier']['committed'] is False"
# The same files committed: --committed (the pre-push hook) gives the same
# recommendation.
pg add src/f1.ts src/f2.ts src/f3.ts src/f4.ts src/f5.ts src/f6.ts
pg commit -q -m six
pf_expect 0 --committed --run-verify
grep -q '^agent-guard: pre-final ok' <<<"$PF_OUT" || fail "a committed size excess must not fail: $PF_OUT"
[[ "$(tail -n 3 <<<"$PF_OUT")" == "$pf_big_tail" ]] || fail "committed exceeded output: $PF_OUT"
report_assert "d['status'] == 'pass'" "d['tier']['status'] == 'exceeded'" \
  "d['tier']['declared'] == 'small' and d['tier']['measured'] == 'medium' and d['tier']['counted_files'] == 6" \
  "d['tier']['committed'] is True"
event_assert "d['gate_status'] == 'warn' and d['tier']['status'] == 'exceeded' and d['tier']['committed'] is True"
# 2. A failing command wins over the tier: exit 1; the report has the tier.
pf_verify false
pf_expect 1 --committed --run-verify
last_is 'TIER: declared small, measured medium (recommended: raise the tier or split the change); verification fail (exit 1)'
report_assert "d['status'] == 'fail' and d['tier']['status'] == 'exceeded'"
# 12. A runner error wins too: exit 2.
pf_verify ./no-such-tool
pf_expect 2 --committed --run-verify
last_is 'TIER: declared small, measured medium (recommended: raise the tier or split the change); verification error (exit 2)'
report_assert "d['status'] == 'error' and d['tier']['status'] == 'exceeded'"
# 3. Nothing ran: strict exits 4, the tier does not change it.
pf_verify 'run <placeholder>'
pf_expect 4 --committed --run-verify
last_is 'TIER: declared small, measured medium (recommended: raise the tier or split the change); verification unverified (exit 4)'
report_assert "d['status'] == 'unverified' and d['tier']['status'] == 'exceeded'"
# 4 and 13. Advisory: the same recommendation; the report records exceeded.
pf_verify true
pf_expect 0 --advisory --committed --run-verify
grep -q '^agent-guard: pre-final ok' <<<"$PF_OUT" || fail "advisory exceeded lacks pre-final ok: $PF_OUT"
last_is 'TIER: declared small, measured medium (recommended: raise the tier or split the change)'
report_assert "d['status'] == 'pass' and d['tier']['status'] == 'exceeded'"
event_assert "d['gate_status'] == 'warn' and d['tier']['status'] == 'exceeded'"
pf_verify false
pf_expect 0 --advisory --committed --run-verify
report_assert "d['status'] == 'fail' and d['tier']['status'] == 'exceeded'"
# 11. --task measures that task instead of the one in ACTIVE.
pf_tier set large --task pf-wide
printf 'pf-big\n' >"$packets/ACTIVE"
pf_expect 0 --task pf-wide
last_is 'TIER: large ok (measured medium, 6 files)'
event_assert "d['tier']['task'] == 'pf-wide' and d['tier']['status'] == 'ok'"
# 5 and 14. Strict without --run-verify: exit 0, the event has the tier, and
# the older report is neither read nor changed.
sum_before="$(cksum <"$pf_report")"
pf_expect 0 --committed
last_is 'TIER: declared small, measured medium (recommended: raise the tier or split the change)'
[[ "$(cksum <"$pf_report")" == "$sum_before" ]] || fail "pre-final without --run-verify changed the report"
event_assert "d['verification']['ran'] is False and d['tier']['status'] == 'exceeded' and d['tier']['task'] == 'pf-big'"
# 8. Below the suggestion with a reason: allowed up to the suggestion.
pf_tier suggest --task pf-low --paths src/f1.ts src/f2.ts src/f3.ts src/f4.ts src/f5.ts src/f6.ts
pf_tier set small --task pf-low --reason 'hotfix, prod down'
pf_verify true
pf_expect 0 --split --run-verify
grep -qF 'warn: tier small is below the suggested medium (reason: hotfix, prod down)' <<<"$PF_ERR" \
  || fail "below-suggested warning: $PF_ERR"
last_is 'TIER: small below suggested medium (reason: hotfix, prod down)'
report_assert "d['tier']['status'] == 'below_suggested' and d['tier']['allowed'] == 'medium'" \
  "d['tier']['suggested'] == 'medium' and d['tier']['reason'] == 'hotfix, prod down'"
# 9. Stale (another branch after the set): warns, never exits 5.
printf 'pf-big\n' >"$packets/ACTIVE"
pg checkout -q -b feature/pf-elsewhere
pf_expect 0 --split --run-verify
grep -q 'warn: tier is stale (on feature/pf-elsewhere, .*); measured: medium (6 files)' <<<"$PF_ERR" \
  || fail "stale warning: $PF_ERR"
last_is 'TIER: stale (on feature/pf-elsewhere, not the task branch feature/pf-big; measured medium)'
report_assert "d['tier']['status'] == 'stale' and d['tier']['stale_reason'].startswith('on feature/pf-elsewhere')"
# 7. No tier declared: one warning line, no TIER line, the old last line last.
rm "$packets/ACTIVE"
pf_expect 0 --split
[[ "$PF_ERR" == *'agent-guard: warn: no tier declared; measured: medium (6 files, partial); run scripts/agent-guard.sh tier suggest'* ]] \
  || fail "no-tier warning: $PF_ERR"
[[ "$(grep -ci tier <<<"$PF_ERR")" -eq 1 ]] || fail "more than one tier line without a tier: $PF_ERR"
last_starts 'agent-guard: pre-final ok'
event_assert "d['tier']['status'] == 'none' and d['tier']['declared'] is None and d['tier']['partial'] is True"
pf_verify false
pf_expect 1 --run-verify
if grep -q 'TIER:' <<<"$PF_OUT"; then fail "a TIER line without a tier: $PF_OUT"; fi
[[ "$(grep -v '^agent-guard: verify_report=' <<<"$PF_OUT" | tail -n 1)" == 'agent-guard: ERROR: verification failed'* ]] \
  || fail "the old last line is not last without a tier: $PF_OUT"
report_assert "'tier' not in d and d['status'] == 'fail'"
# 16. The tier check cannot run: one warning, the exit code as before.
printf 'pf-big\n' >"$packets/ACTIVE"
pg checkout -q feature/pf-big
pf_verify true
mv "$pf/scripts/agent-tier.py" "$TMP_ROOT/agent-tier.py.saved"
pf_expect 0 --split --run-verify
mv "$TMP_ROOT/agent-tier.py.saved" "$pf/scripts/agent-tier.py"
[[ "$(grep -c 'tier check skipped' <<<"$PF_ERR")" -eq 1 && "$PF_ERR" == *'tier check skipped: scripts/agent-tier.py is missing'* ]] \
  || fail "missing agent-tier.py: $PF_ERR"
if grep -q 'TIER:' <<<"$PF_OUT$PF_ERR"; then fail "a TIER line when the check was skipped: $PF_OUT"; fi
last_starts 'agent-guard: pre-final ok'
report_assert "'tier' not in d and d['status'] == 'pass'"
HARNESS_KIT_TEST_HOOKS=1 AGENT_GUARD_TEST_TIER_CRASH=1 pf_expect 0 --split
[[ "$PF_ERR" == *'tier check skipped: tier evaluator failed: RuntimeError'*'(exit 70)'* ]] || fail "crashed agent-tier.py: $PF_ERR"
# A failure inside verification still stops pre-final (set -e): a file where
# the log directory belongs exits 1 in both modes, as before the tier check.
rm "$packets/ACTIVE"
logs="$pf/.agents/state/verify-logs"
mv "$logs" "$TMP_ROOT/verify-logs.saved"
touch "$logs"
pf_expect 1 --run-verify
pf_expect 1 --advisory --run-verify
if grep -q 'pre-final ok' <<<"$PF_OUT"; then fail "pre-final ok after a broken verification: $PF_OUT"; fi
rm "$logs"
mv "$TMP_ROOT/verify-logs.saved" "$logs"

# Tidy-up rule 1: a branch cut from another branch that holds a commit of
# its own, with no --base: the warning names --base.
pf_prev="$(pg rev-parse --abbrev-ref HEAD)"
pg checkout -q -b feature/pf-parent main
printf 'export const parent = 1;\n' >"$pf/src/parent.ts"
pg add src/parent.ts
pg commit -q -m parent
pg checkout -q -b feature/pf-stack
pf_tier set small --task pf-stack
for n in 1 2 3 4 5 6; do printf 'export const s%s = 1;\n' "$n" >"$pf/src/s$n.ts"; done
pg add src/s1.ts src/s2.ts src/s3.ts src/s4.ts src/s5.ts src/s6.ts
pg commit -q -m stack
pf_expect 0 --committed --task pf-stack
grep -qxF 'Next: if this branch starts from another branch, give its base: scripts/agent-guard.sh tier set small --task pf-stack --base <branch>.' \
  <<<"$PF_OUT" || fail "a stacked branch lacks the --base hint: $PF_OUT"
pg checkout -q "$pf_prev"

# Parallel runs on one target: each writes its report once, with its own
# tier. The command logs its loop, so a report's results name the run whose
# tier it must carry. A report can be missing for a moment (the next run
# removes it first), never partial or mixed.
for loop in a b c; do pf_tier set large --task "pf-par-$loop"; done
pf_verify "sh -c 'echo loop=\$PF_LOOP'"
par_check="$TMP_ROOT/par-check.py"
cat >"$par_check" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
try:
    text = (root / ".agents/state/last-verify-report.json").read_text(encoding="utf-8")
except FileNotFoundError:
    sys.exit(0)
d = json.loads(text)
log = (root / d["results"][0]["log_path"]).read_text(encoding="utf-8")
loop = log.split("loop=", 1)[1].split()[0]
assert d["tier"]["task"] == "pf-par-" + loop, (d["tier"], loop)
PY
par_loop() {
  local loop="$1" n
  for n in 1 2 3 4 5 6 7 8; do
    (cd "$pf" && PF_LOOP="$loop" scripts/agent-guard.sh pre-final --advisory --run-verify --task "pf-par-$loop") \
      >"$TMP_ROOT/par-$loop.out" 2>&1 || { echo "run $n exited $?"; return 1; }
    if grep -q Traceback "$TMP_ROOT/par-$loop.out"; then
      echo "run $n: a traceback"
      return 1
    fi
    python3 "$par_check" "$pf" 2>&1 || { echo "run $n: a bad report"; return 1; }
  done
}
par_pids=()
for loop in a b c; do
  par_loop "$loop" >"$TMP_ROOT/par-$loop.fail" 2>&1 &
  par_pids+=("$!")
done
for n in 0 1 2; do
  wait "${par_pids[$n]}" || fail "parallel loop $n: $(cat "$TMP_ROOT"/par-*.fail) $(cat "$TMP_ROOT"/par-*.out)"
done
python3 "$par_check" "$pf" || fail "the report after the parallel runs is bad"
[[ -f "$pf_report" ]] || fail "no report after the parallel runs"
stray="$(find "$pf/.agents/state" -name '*.tmp')"
[[ -z "$stray" ]] || fail "stray temp files after the parallel runs: $stray"

# ---- review files: lowering and raising ---------------------------------------
# The latest attempt of each review file decides. Lowering needs a reason while
# one is negative, even with --reason; raising is always allowed. A raise
# after coding stays exceeded until the reviews the new tier needs pass.
pg checkout -q -f main
rm -f "$pf"/src/f*.ts
pf_verify true
[[ -z "$(git -C "$pf" status --porcelain)" ]] || fail "the pre-final target tree is not clean"
# rv_tier <code> <tier args...>: RV_OUT is stdout, RV_ERR stderr.
rv_tier() {
  local want="$1"
  shift
  RV_RC=0
  RV_OUT="$(cd "$pf" && scripts/agent-guard.sh tier "$@" 2>"$TMP_ROOT/rv.err")" || RV_RC=$?
  RV_ERR="$(cat "$TMP_ROOT/rv.err")"
  [[ "$RV_RC" -eq "$want" ]] || fail "tier $*: want exit $want, got $RV_RC: $RV_OUT $RV_ERR"
}
# rv_measure <task> <python expr>...: the measure JSON (m) makes each expr true.
rv_measure() {
  local task="$1"
  shift
  rv_tier 0 measure --task "$task"
  python3 "$measure_check" "$@" <<<"$RV_OUT" || fail "measure --task $task: $RV_OUT"
}
# rv_case <branch>: main with a clean tree, then a new branch.
rv_case() {
  pg checkout -q -f main
  pg checkout -q -b "$1"
}

# 1. The latest @gate attempt is negative: lowering needs --reason.
rv_case feature/rv-gate
pf_tier set large --task rv-gate
review rv-gate gate-review.md 'reviewer_model: m1\nsufficient_for_coding_model: no'
gate_refused='latest @gate review is negative; fix the spec, or give --reason TEXT for lowering the tier anyway'
rv_tier 1 set medium --task rv-gate
[[ "$RV_ERR" == "agent-guard: ERROR: $gate_refused" ]] || fail "gate refusal: $RV_ERR"
tier_assert rv-gate "d['declared'] == 'large' and [e['event'] for e in d['history']] == ['set']"
# The same tier, or a higher one, is always allowed.
rv_tier 0 set large --task rv-gate
# Review fix: the first set is a lowering too when the packet was reviewed
# before it: below the suggestion with a negative @gate, it is refused.
rv_case feature/rv-first
pf_tier suggest --task rv-first --access
review rv-first gate-review.md 'reviewer_model: m1\nsufficient_for_coding_model: no'
rv_tier 1 set small --task rv-first
[[ "$RV_ERR" == "agent-guard: ERROR: latest @gate review is negative; fix the spec, or give --reason TEXT for setting the tier below the suggested large anyway" ]] \
  || fail "first-set refusal: $RV_ERR"
rv_tier 0 set large --task rv-first
pg checkout -q feature/rv-gate
# 10. Lines in a code fence are not read: neither an attempt header nor a key.
# shellcheck disable=SC2016  # literal backticks
review rv-gate gate-review.md 'sufficient_for_coding_model: no\n```\n### Attempt 2\nsufficient_for_coding_model: yes\n```'
rv_tier 1 set medium --task rv-gate
# 4 and 10. An earlier negative attempt does not count once the latest is
# yes; keys are read in any case, with extra spaces.
review rv-gate gate-review.md 'sufficient_for_coding_model: no' 'SUFFICIENT_FOR_CODING_MODEL :  Yes '
rv_tier 0 set medium --task rv-gate
tier_assert rv-gate "d['declared'] == 'medium'"

# Rule 1 (lowering): a set below the higher of the declared tier and the
# current suggestion needs a reason while a review is negative, also as a
# keep; with one it warns, and the PR line shows it.
# lw_case <task>: declared small for a small suggestion, then the scope grows
# and the suggestion is large.
lw_case() {
  rv_case "feature/$1"
  pf_tier suggest --task "$1" --paths src/app.ts --lines 1
  pf_tier set small --task "$1"
  pf_tier suggest --task "$1" --access
}
keep_refused='agent-guard: ERROR: latest @gate review is negative; fix the spec, or give --reason TEXT for setting the tier below the suggested large anyway'
# a. Keep small below the new suggestion, with a negative @gate: it needs a
#    reason; with one it warns, and the PR line and tier show say so.
lw_case lw-a
review lw-a gate-review.md 'sufficient_for_coding_model: no'
rv_tier 1 set small --task lw-a --answer keep --by @gate
[[ "$RV_ERR" == "$keep_refused" ]] || fail "lw-a keep: $RV_ERR"
# b. A raise that stays below the suggestion needs one too.
rv_tier 1 set medium --task lw-a
[[ "$RV_ERR" == "$keep_refused" ]] || fail "lw-a medium: $RV_ERR"
rv_tier 0 set small --task lw-a --reason hotfix --answer keep --by @gate
grep -qxF 'agent-guard: warn: setting the tier below the suggested large although the latest @gate review is negative (reason: hotfix)' \
  <<<"$RV_ERR" || fail "lw-a override warning: $RV_ERR"
tier_assert lw-a "d['history'][-1]['overrode'] == ['@gate'] and d['declared'] == 'small'"
rv_tier 0 show --task lw-a --pr-line
[[ "$RV_OUT" == *" · lowered despite a negative @gate review" ]] || fail "lw-a pr-line: $RV_OUT"
rv_tier 0 show --task lw-a
grep -qxF 'note: lowered despite a negative @gate review' <<<"$RV_OUT" || fail "lw-a show: $RV_OUT"
# c. Up to the suggestion: allowed, and the PR line no longer has the note.
rv_tier 0 set large --task lw-a
rv_tier 0 show --task lw-a --pr-line
[[ "$RV_OUT" != *"lowered despite"* ]] || fail "lw-a note after a later set: $RV_OUT"
# A read-only packet: the set fails, and no override warning is printed.
lw_case lw-ro
review lw-ro gate-review.md 'sufficient_for_coding_model: no'
chmod a-w "$packets/lw-ro"
rv_tier 1 set small --task lw-ro --reason hotfix --answer keep
chmod u+w "$packets/lw-ro"
if grep -qF 'although' <<<"$RV_ERR"; then fail "an override warning for a set that was not written: $RV_ERR"; fi
# d. No review: the keep below the suggestion needs a reason, then passes.
lw_case lw-d
rv_tier 1 set small --task lw-d --answer keep
grep -qF 'small is below the suggested large; this needs --reason TEXT' <<<"$RV_ERR" || fail "lw-d: $RV_ERR"
rv_tier 0 set small --task lw-d --reason hotfix --answer keep
# e. The latest @gate attempt passes: the same keep passes with a reason.
lw_case lw-e
review lw-e gate-review.md 'sufficient_for_coding_model: no' 'sufficient_for_coding_model: yes'
rv_tier 0 set small --task lw-e --reason hotfix --answer keep
# f. No suggestion above the declared tier: a keep is not a lowering.
rv_case feature/lw-f
pf_tier set small --task lw-f
review lw-f gate-review.md 'sufficient_for_coding_model: no'
rv_tier 0 set small --task lw-f --answer keep
# g. Combined: the scope grew, @gate said no, the keep without a reason was
# refused; then a payment change is committed, and the pre-push hook passes
# with the recommendation.
lw_case lw-g
review lw-g gate-review.md 'sufficient_for_coding_model: no'
rv_tier 1 set small --task lw-g --answer keep
mkdir -p "$pf/app/payment"
printf 'export const pay = 1;\n' >"$pf/app/payment/pay.ts"
pg add app/payment/pay.ts
pg commit -q -m pay
push_rc=0
(cd "$pf" && bash scripts/githooks/pre-push </dev/null >"$TMP_ROOT/lw-push.out" 2>&1) || push_rc=$?
[[ "$push_rc" -eq 0 ]] || fail "lw-g pre-push: want 0, got $push_rc: $(cat "$TMP_ROOT/lw-push.out")"
grep -qF 'TIER: declared small, measured large (recommended: raise the tier or split the change)' "$TMP_ROOT/lw-push.out" \
  || fail "lw-g pre-push recommendation: $(cat "$TMP_ROOT/lw-push.out")"
# The reason covers only the suggestion in force at the last set; a later,
# higher one is not allowed until the user confirms again.
# h. Suggested medium, small with a reason, then large: a risky change gets
#    the exceeded recommendation against medium.
rv_case feature/lw-h
pf_tier suggest --task lw-h --paths src/a.ts src/b.ts src/c.ts src/d.ts
pf_tier set small --task lw-h --reason hotfix
pf_tier suggest --task lw-h --paths app/auth/login.ts --access
mkdir -p "$pf/app/auth"
printf 'export const login = 1;\n' >"$pf/app/auth/login.ts"
pg add app/auth/login.ts
pg commit -q -m login
pf_expect 0 --split --committed --task lw-h
grep -qF 'TIER: declared small (allowed medium), measured large' <<<"$PF_ERR" || fail "lw-h summary: $PF_ERR"
grep -qF 'agent-guard: warn: a newer suggestion (large) came after the user chose small; ask the user to confirm the tier again' \
  <<<"$PF_ERR" || fail "lw-h warning: $PF_ERR"
rv_tier 0 show --task lw-h --pr-line
[[ "$RV_OUT" == "Tier: small (suggested large; the reason covers medium: hotfix) · 1 file, 1 line · measured large, above the tier" ]] \
  || fail "lw-h pr-line: $RV_OUT"
# i. The user confirms again, with a reason: now large is allowed, and the PR
#    line has no "above the tier".
rv_tier 0 set small --task lw-h --reason 'still a hotfix'
pf_expect 0 --committed --task lw-h
last_starts 'TIER: small below suggested large'
rv_tier 0 show --task lw-h --pr-line
[[ "$RV_OUT" == "Tier: small (suggested large: still a hotfix) · 1 file, 1 line" ]] || fail "lw-h pr-line after the confirm: $RV_OUT"
rm -rf "$pf/app"
# j. A raise with a reason does not cover a later suggestion either.
rv_case feature/lw-j
pf_tier suggest --task lw-j --paths src/app.ts --lines 1
pf_tier set medium --task lw-j --reason 'user wants a review'
pf_tier suggest --task lw-j --access
mkdir -p "$pf/app/auth"
printf 'export const login = 1;\n' >"$pf/app/auth/login.ts"
pg add app/auth/login.ts
pg commit -q -m login
pf_expect 0 --split --committed --task lw-j
grep -qF 'TIER: declared medium, measured large (recommended: raise the tier or split the change)' <<<"$PF_ERR" || fail "lw-j: $PF_ERR"
# k. A later, lower suggestion keeps the allowance the reason gave.
rv_case feature/lw-k
pf_tier suggest --task lw-k --paths src/a.ts src/b.ts src/c.ts src/d.ts
pf_tier set small --task lw-k --reason hotfix
pf_tier suggest --task lw-k --paths src/e.ts
rv_tier 0 set small --task lw-k --answer keep
for n in 1 2 3 4; do printf 'export const k%s = 1;\n' "$n" >"$pf/src/k$n.ts"; done
pg add src/k1.ts src/k2.ts src/k3.ts src/k4.ts
pg commit -q -m four
pf_expect 0 --committed --task lw-k
last_is 'TIER: small below suggested medium (reason: hotfix)'
rv_tier 0 show --task lw-k --pr-line
[[ "$RV_OUT" == "Tier: small (suggested small; the reason covers medium: hotfix) · 4 files, 4 lines" ]] || fail "lw-k pr-line: $RV_OUT"

# Rule 3 (review states): absent, pending, negative or passed; the own file
# decides once it has an attempt, the older one only while it is absent. A
# pending own file keeps an older negative and never borrows an older pass.
# rs_row <n> <own: absent|template|newer|negative|passed> <older: absent|changes_required|pass>
#   <negative: yes|no> <passed: yes|no>, for @verify after a raise to medium.
rs_row() {
  local task="rs-$1" own="$2" older="$3" negative="$4" passed="$5" missing="['@verify']" want_set=0
  rv_case "feature/$task"
  pf_tier set small --task "$task"
  printf 'export const a = %s;\n' "$((100 + $1))" >"$pf/src/app.ts"  # not the committed a = 1
  rv_tier 0 show --task "$task"
  pf_tier set medium --task "$task"
  case "$own" in
    absent) ;;
    template) review "$task" verify-review.md 'reviewer_model: m1\nverdict: pass | changes_required | blocked' ;;
    newer) review "$task" verify-review.md 'reviewer_model: m1\nverdict: pass' 'reviewer_model: m2' ;;
    negative) review "$task" verify-review.md 'reviewer_model: m1\nverdict: changes_required' ;;
    passed) review "$task" verify-review.md 'reviewer_model: m1\nverdict: pass' ;;
  esac
  if [[ "$older" != absent ]]; then
    printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: yes\n\n## Final technical review\n\n### Attempt 1\n\nverdict: %s\n' \
      "$older" >"$packets/$task/codex-review.md"
  fi
  [[ "$passed" == no ]] || missing="[]"
  rv_measure "$task" "m['raised_after_coding'] is True and m['missing_reviews'] == $missing"
  pf_expect 0 --task "$task"
  if [[ "$passed" == yes ]]; then
    last_is 'TIER: medium ok (measured small, 1 file)'
  else
    last_starts 'TIER: declared medium, measured small; raised after coding: @verify review still needed'
  fi
  [[ "$negative" == no ]] || want_set=1
  rv_tier "$want_set" set small --task "$task"
}
rs_row 1 absent absent no no
rs_row 2 absent changes_required yes no
rs_row 3 absent pass no yes
rs_row 4 template absent no no
rs_row 5 template changes_required yes no
rs_row 6 template pass no no
rs_row 7 newer absent no no
rs_row 8 newer changes_required yes no
rs_row 9 newer pass no no
rs_row 10 negative absent yes no
rs_row 11 negative pass yes no
rs_row 12 passed absent no yes
rs_row 13 passed changes_required no yes

# Review fix: older packets keep the @gate and @verify attempts in two
# sections of codex-review.md and the @audit ones in claude-review.md.
rv_case feature/rv-legacy
pf_tier set large --task rv-legacy
legacy="$packets/rv-legacy/codex-review.md"
printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: no\n\n## Final technical review\n\n### Attempt 1\n\nverdict: pass\n' >"$legacy"
rv_tier 1 set medium --task rv-legacy
[[ "$RV_ERR" == "agent-guard: ERROR: $gate_refused" ]] || fail "legacy gate refusal: $RV_ERR"
printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: yes\n\n## Final technical review\n\n### Attempt 1\n\nverdict: changes_required\n' >"$legacy"
rv_tier 1 set medium --task rv-legacy
grep -qxF 'agent-guard: ERROR: latest @verify review is negative; fix the change, or give --reason TEXT for lowering the tier anyway' \
  <<<"$RV_ERR" || fail "legacy verify refusal: $RV_ERR"
printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: yes\n\n## Final technical review\n\n### Attempt 1\n\nverdict: pass\n' >"$legacy"
printf '# Cross-review\n\n## Cross-review attempt 1\n\nverdict: changes_required\n' >"$packets/rv-legacy/claude-review.md"
rv_tier 1 set medium --task rv-legacy
grep -qF 'latest @audit review is negative' <<<"$RV_ERR" || fail "legacy audit refusal: $RV_ERR"
printf '# Cross-review\n\n## Cross-review attempt 1\n\nverdict: pass\n' >"$packets/rv-legacy/claude-review.md"
rv_tier 0 set small --task rv-legacy
# A raise after coding counts the older files' passes.
printf 'export const a = 10;\n' >"$pf/src/app.ts"
rv_tier 0 show --task rv-legacy
pf_tier set large --task rv-legacy
rv_measure rv-legacy "m['raised_after_coding'] is True and m['missing_reviews'] == []"
# A verdict in gate-review.md replaces the older file's; a template line does not.
printf '## Pre-coding technical review\n\n### Attempt 1\n\nsufficient_for_coding_model: no\n\n## Final technical review\n\n### Attempt 1\n\nverdict: pass\n' >"$legacy"
review rv-legacy gate-review.md 'sufficient_for_coding_model: yes | no'
rv_tier 1 set medium --task rv-legacy
[[ "$RV_ERR" == "agent-guard: ERROR: $gate_refused" ]] || fail "a template hid the older negative: $RV_ERR"
review rv-legacy gate-review.md 'sufficient_for_coding_model: yes'
rv_tier 0 set medium --task rv-legacy

# 2. The latest @verify attempt is changes_required or blocked.
rv_case feature/rv-verify
pf_tier set medium --task rv-verify
for verdict in changes_required blocked; do
  review rv-verify verify-review.md 'reviewer_model: m1\nverdict: pass' "reviewer_model: m1\nverdict: $verdict"
  rv_tier 1 set small --task rv-verify
  grep -qxF 'agent-guard: ERROR: latest @verify review is negative; fix the change, or give --reason TEXT for lowering the tier anyway' <<<"$RV_ERR" \
    || fail "verify refusal ($verdict): $RV_ERR"
done
review rv-verify verify-review.md 'verdict: changes_required' 'Verdict: PASS'
rv_tier 0 set small --task rv-verify

# Values with a note count by their first word; a BOM, a bullet, bold keys,
# HTML comments and an empty newer attempt do not hide a verdict.
rv_case feature/rv-parse
pf_tier set large --task rv-parse
# refused <seat>: lowering to medium fails and names <seat>.
refused() {
  rv_tier 1 set medium --task rv-parse
  grep -qF "latest $1 review is negative" <<<"$RV_ERR" || fail "want a $1 refusal: $RV_ERR"
}
review rv-parse gate-review.md 'sufficient_for_coding_model: no (2 blockers)'
refused @gate
review rv-parse gate-review.md 'sufficient_for_coding_model: yes'
review rv-parse verify-review.md 'verdict: changes_required (3 blockers)'
refused @verify
review rv-parse verify-review.md '- **verdict:** changes_required'
refused @verify
review rv-parse verify-review.md 'verdict: changes_required' 'reviewer_model: m2'
refused @verify
review rv-parse verify-review.md 'verdict: pass'
printf '\xef\xbb\xbf## Cross-review attempt 1\n\nverdict: changes_required\n' >"$packets/rv-parse/audit-review.md"
refused @audit
review rv-parse audit-review.md 'verdict: changes_required' \
  'verdict: pass\n<!--\n## Cross-review attempt 3\n\nverdict: changes_required\n-->'
rv_tier 0 set medium --task rv-parse

# 3 and 10. The latest @audit attempt is changes_required; a sub-heading does
# not end the attempt, a fenced verdict is not read, an upper-case key is.
rv_case feature/rv-audit
pf_tier set large --task rv-audit
# shellcheck disable=SC2016  # literal backticks
review rv-audit audit-review.md 'verdict: pass' \
  '### Findings\n\n- none blocking\n\n```text\nverdict: pass\n```\n\nVERDICT :  changes_required'
rv_tier 1 set medium --task rv-audit
grep -qxF 'agent-guard: ERROR: latest @audit review is negative; fix what it found, or give --reason TEXT for lowering the tier anyway' <<<"$RV_ERR" \
  || fail "audit refusal: $RV_ERR"
# Two negative reviews: the message names both.
review rv-audit gate-review.md 'sufficient_for_coding_model: no'
rv_tier 1 set small --task rv-audit
grep -qxF 'agent-guard: ERROR: latest @gate and @audit reviews are negative; fix what they found, or give --reason TEXT for lowering the tier anyway' <<<"$RV_ERR" \
  || fail "two refusals: $RV_ERR"
# 4. The latest attempts pass: lowering below the suggestion still needs --reason.
pf_tier suggest --task rv-audit --access
review rv-audit gate-review.md 'sufficient_for_coding_model: no' 'sufficient_for_coding_model: yes'
review rv-audit audit-review.md 'verdict: changes_required' 'verdict: pass'
rv_tier 1 set medium --task rv-audit
grep -qF 'medium is below the suggested large; this needs --reason TEXT' <<<"$RV_ERR" || fail "below suggestion: $RV_ERR"
rv_tier 0 set medium --task rv-audit --reason 'auth part split out'
tier_assert rv-audit "d['declared'] == 'medium' and d['reason'] == 'auth part split out'"

# 6 and 8. small -> large after a file changed, before the first pre-final,
# is a raise after coding. It needs @gate yes, @verify pass and @audit pass.
rv_case feature/rv-large
pf_tier set small --task rv-large
printf 'export const a = 6;\n' >"$pf/src/app.ts"
pf_tier set large --task rv-large
tier_assert rv-large "d['coding_started_tier'] == 'small' and d['declared'] == 'large'"
pf_expect 0 --task rv-large
last_is 'TIER: declared large, measured small; raised after coding: @gate, @verify and @audit reviews still needed (recommended: hand off to @gate, @verify and @audit (or ask the user); do not write review files yourself)'
grep -qxF 'Next: the tier was raised after coding started (small -> large); the latest attempts in gate-review.md, verify-review.md and audit-review.md must pass, then run pre-final again.' <<<"$PF_OUT" \
  || fail "large raise next step: $PF_OUT"
rv_measure rv-large "m['raised_after_coding'] is True and m['missing_reviews'] == ['@gate', '@verify', '@audit']"
rv_tier 0 show --task rv-large --pr-line
[[ "$RV_OUT" == *" · @gate, @verify and @audit reviews still needed" ]] || fail "rv-large pr-line: $RV_OUT"
review rv-large gate-review.md 'sufficient_for_coding_model: no'
review rv-large verify-review.md 'verdict: pass'
review rv-large audit-review.md 'verdict: pass'
rv_measure rv-large "m['missing_reviews'] == ['@gate']"
review rv-large gate-review.md 'sufficient_for_coding_model: yes'
review rv-large audit-review.md 'verdict: pass' 'verdict: changes_required'
rv_measure rv-large "m['missing_reviews'] == ['@audit']"
pf_expect 0 --task rv-large
last_is 'TIER: declared large, measured small; raised after coding: @audit review still needed (recommended: hand off to @audit (or ask the user); do not write review files yourself)'
# Stale is never exceeded, also after a raise.
pg checkout -q -b feature/rv-large-elsewhere
pf_expect 0 --task rv-large
last_starts 'TIER: stale (on feature/rv-large-elsewhere'
pg checkout -q feature/rv-large
review rv-large audit-review.md 'verdict: changes_required' 'verdict: pass'
pf_expect 0 --task rv-large
last_is 'TIER: large ok (measured small, 1 file)'

# 7 and 10. Medium: a human review counts with reviewer_model: human, a pr:
# line and verdict: pass. A PR link alone, a negative verdict, a missing pr:
# line or a fenced verdict does not.
rv_case feature/rv-human
pf_tier set small --task rv-human
printf 'export const a = 7;\n' >"$pf/src/app.ts"
pf_tier set medium --task rv-human
# shellcheck disable=SC2016  # literal backticks
for body in 'reviewer_model: human\npr: https://example/1' \
  'reviewer_model: human\npr: https://example/1\nverdict: changes_required' \
  'reviewer_model: human\nverdict: pass' \
  'reviewer_model: human\npr: TBD\nverdict: pass' \
  'reviewer_model: human\npr: TBD after 2 fixes\nverdict: pass' \
  'reviewer_model: m1\n```\nverdict: pass\n```' \
  'reviewer_model: m1\n<!--\nverdict: pass\n-->' \
  'reviewer_model: m1\nverdict: pass | changes_required | blocked'; do
  review rv-human verify-review.md "$body"
  rv_measure rv-human "m['raised_after_coding'] is True and m['missing_reviews'] == ['@verify']"
done
pf_expect 0 --task rv-human
last_starts 'TIER: declared medium, measured small; raised after coding: @verify review still needed'
# A note after the verdict is fine. An old pass under a newer attempt with no
# verdict yet (a re-review under way) does not count: @verify is still needed.
review rv-human verify-review.md 'reviewer_model: human\npr: https://example/1\n**Verdict**: pass (two nits)' \
  'reviewer_model: human'
rv_measure rv-human "m['raised_after_coding'] is True and m['missing_reviews'] == ['@verify']"
pf_expect 0 --task rv-human
last_starts 'TIER: declared medium, measured small; raised after coding: @verify review still needed'
review rv-human verify-review.md 'reviewer_model: human\npr: <https://example/1>\n**Verdict**: pass (two nits)\n- verdict: none of the nits block'
rv_measure rv-human "m['raised_after_coding'] is True and m['missing_reviews'] == []"
pf_expect 0 --task rv-human
last_is 'TIER: medium ok (measured small, 1 file)'
# A human review with pr: pending counts at push only, because the PR needs
# the push; in a session the link must be filled in.
rv_case feature/rv-pending
pf_tier set small --task rv-pending
printf 'export const a = 77;\n' >"$pf/src/app.ts"
rv_tier 0 show --task rv-pending
pf_tier set medium --task rv-pending
review rv-pending verify-review.md 'reviewer_model: human\npr: pending\nverdict: pass'
pg add src/app.ts
pg commit -q -m change
pf_expect 0 --committed --task rv-pending
last_is 'TIER: medium ok (measured small, 1 file)'
pf_expect 0 --task rv-pending
last_starts 'TIER: declared medium, measured small; raised after coding: @verify review still needed'

# Review fix 3. Only *.md and *.mdx changes do not start coding: a raise after
# them is a normal raise. A .ts change then starts coding.
rv_case feature/rv-docs
pf_tier set medium --task rv-docs
mkdir -p "$pf/plans"
printf '# Design\n' >"$pf/plans/design.md"
printf '# Notes\n' >"$pf/plans/notes.MDX"
rv_tier 0 show --task rv-docs
pf_tier set large --task rv-docs
tier_assert rv-docs "d['coding_started_tier'] is None and d['declared'] == 'large'"
rv_measure rv-docs "m['raised_after_coding'] is False and m['missing_reviews'] == []"
rm -rf "$pf/plans"
rv_case feature/rv-docs-code
pf_tier set small --task rv-docs-code
mkdir -p "$pf/plans"
printf '# Design\n' >"$pf/plans/design.md"
rv_tier 0 show --task rv-docs-code
tier_assert rv-docs-code "d['coding_started_tier'] is None"
printf 'export const a = 8;\n' >"$pf/src/app.ts"
rv_tier 0 show --task rv-docs-code
tier_assert rv-docs-code "d['coding_started_tier'] == 'small'"
pf_tier set medium --task rv-docs-code
rv_measure rv-docs-code "m['raised_after_coding'] is True and m['missing_reviews'] == ['@verify']"
rm -rf "$pf/plans"

# 9. A raise before any change is a normal raise: no review is needed.
rv_case feature/rv-early
pf_tier set small --task rv-early
pf_tier set large --task rv-early
tier_assert rv-early "d['coding_started_tier'] is None"
printf 'export const a = 9;\n' >"$pf/src/app.ts"
pf_expect 0 --task rv-early
last_is 'TIER: large ok (measured small, 1 file)'
tier_assert rv-early "d['coding_started_tier'] == 'large'"
rv_measure rv-early "m['raised_after_coding'] is False and m['missing_reviews'] == []"
pg checkout -q -f main

# Combined (rule 4): a local commit on main, then the task and its commit,
# then a rebase pull of five teammate files. The start commit is rewritten:
# pre-final warns with the cause and exits 0, it does not count the teammates.
main_before="$(pg rev-parse HEAD)"
pg checkout -q -b mates-pf
for n in 1 2 3 4 5; do printf 'export const t%s = 1;\n' "$n" >"$pf/src/t$n.ts"; done
pg add src/t1.ts src/t2.ts src/t3.ts src/t4.ts src/t5.ts
pg commit -q -m teammates
mates_pf="$(pg rev-parse HEAD)"
pg checkout -q main
pg update-ref refs/remotes/origin/main "$main_before"
printf 'export const early = 1;\n' >"$pf/src/early.ts"
pg add src/early.ts
pg commit -q -m early
pf_tier set small --task rb-combo
printf 'export const task = 1;\n' >"$pf/src/task.ts"
pg add src/task.ts
pg commit -q -m task
pg update-ref refs/remotes/origin/main "$mates_pf"
pg rebase -q refs/remotes/origin/main
pf_expect 0 --split --task rb-combo
grep -qF "agent-guard: warn: the tier measure is partial (the start commit is no longer in this branch's history, after a rebase or reset)" \
  <<<"$PF_ERR" || fail "rebased combo warning: $PF_ERR"
last_is 'TIER: small ok (measured small, 2 files, partial)'
pg update-ref -d refs/remotes/origin/main
pg reset -q --hard "$main_before"
pg branch -q -D mates-pf

# A plain mv with an edit, not staged: the next steps say git add pairs it.
rv_case feature/mv-hint
seq 1 45 >"$pf/src/big.ts"
pg add src/big.ts
pg commit -q -m big
pf_tier set small --task mv-hint
mv "$pf/src/big.ts" "$pf/src/big2.ts"
printf 'edit\n' >>"$pf/src/big2.ts"
pf_expect 0 --split --task mv-hint
grep -qxF 'Next: if you moved files, git add them, so each move counts once.' <<<"$PF_ERR" || fail "move hint: $PF_ERR"
pg add -A src
pf_expect 0 --split --task mv-hint
if grep -qF 'if you moved files' <<<"$PF_ERR"; then fail "a paired move still hints: $PF_ERR"; fi
[[ "$(tail -n 1 <<<"$PF_OUT")" == 'TIER: small ok (measured small, 1 file)' ]] || fail "paired move: $PF_OUT"
# The new file added to the index, the deletion left unstaged: the hint too.
rv_case feature/mv-hint-staged
seq 1 45 >"$pf/src/big.ts"
pg add src/big.ts
pg commit -q -m big
pf_tier set small --task mv-hint-staged
mv "$pf/src/big.ts" "$pf/src/big2.ts"
printf 'edit\n' >>"$pf/src/big2.ts"
pg add src/big2.ts
pf_expect 0 --split --task mv-hint-staged
grep -qxF 'Next: if you moved files, git add them, so each move counts once.' <<<"$PF_ERR" || fail "staged move hint: $PF_ERR"
# A clean tree (a committed delete and a committed new file): nothing to add, no hint.
rv_case feature/no-hint
pg rm -q src/app.ts
mkdir -p "$pf/src"
seq 1 70 >"$pf/src/other.ts"
pg add src/other.ts
pg commit -q -m "delete and add"
pf_tier set small --task no-hint
pf_expect 0 --split --task no-hint
grep -qF 'measured medium' <<<"$PF_ERR" || fail "no-hint case is not exceeded: $PF_ERR"
if grep -qF 'if you moved files' <<<"$PF_ERR"; then fail "a clean tree hints git add: $PF_ERR"; fi
pg checkout -q -f main

# The review formats: @audit has a verdict; medium may take a human review.
reference="$pf/docs/agent-configs/agent-handoff-reference.md"
# section_of <heading>: the lines under it, up to the next heading outside a code fence.
section_of() { awk -v head="$1" '$0 == head { on = 1; next } /^```/ { fence = !fence } on && !fence && /^###? / { exit } on' "$reference"; }
# shellcheck disable=SC2016  # literal backticks
{
  audit_format="$(section_of '### `audit-review.md`')"
  verify_format="$(section_of '### `verify-review.md`')"
  grep -qF '`verdict: pass | changes_required`' <<<"$audit_format" \
    || fail "the audit-review.md format lacks its verdict: $audit_format"
  if ! grep -qF '`reviewer_model: human`' <<<"$verify_format" || ! grep -qF '`pr: <url>`' <<<"$verify_format"; then
    fail "the verify-review.md format lacks the human review: $verify_format"
  fi
}

# ---- tier stats ---------------------------------------------------------------
# Numbers from the records already kept: tasks per tier, suggestions kept,
# lowered or raised, warnings at pre-final and at push, and time to close.
st="$(fresh_target)"
st_run() {
  ST_RC=0
  ST_OUT="$(cd "$st" && scripts/agent-guard.sh tier stats "$@" 2>"$TMP_ROOT/st.err")" || ST_RC=$?
}
st_run
[[ "$ST_RC" -eq 0 && "$ST_OUT" == "No tier records yet." ]] || fail "stats with no records: $ST_RC $ST_OUT"
python3 - "$st" <<'PY' || fail "cannot write the stats fixture"
import json, os, sys
root = sys.argv[1]

def record(task, declared, suggested, status, times, flags=(), reason=None, started=None):
    history = [{"at": times[0], "event": "suggest", "tier": suggested}, {"at": times[0], "event": "set", "tier": declared}]
    if status == "closed":
        history.append({"at": times[1], "event": "close", "tier": declared})
    doc = {"schema": "harness-tier/v1", "task_id": task, "branch": "main", "base_ref": None,
           "start_commit": "0" * 40, "declared": declared, "suggested": suggested,
           "suggestion_inputs": {"paths": [], "lines": None, "flags": list(flags)}, "reason": reason,
           "coding_started_tier": started, "coding_started_at": None, "status": status,
           "closed_at": times[1] if status == "closed" else None, "closed_by": None, "history": history}
    os.makedirs(os.path.join(root, ".agents/tasks", task), exist_ok=True)
    with open(os.path.join(root, ".agents/tasks", task, "tier.json"), "w") as handle:
        json.dump(doc, handle)

record("s1", "small", "small", "closed", ["2026-10-20T08:00:00Z", "2026-10-20T08:30:00Z"])
record("s2", "small", "medium", "closed", ["2026-10-21T09:00:00Z", "2026-10-21T10:00:00Z"], reason="one line")
record("m1", "medium", "small", "open", ["2026-10-22T10:00:00Z"], started="small")
record("l1", "large", "large", "closed", ["2026-10-22T08:00:00Z", "2026-10-24T08:00:00Z"], flags=["handoff"])
record("old", "small", "small", "open", ["2026-09-01T08:00:00Z"])
os.makedirs(os.path.join(root, ".agents/tasks/bad"), exist_ok=True)
with open(os.path.join(root, ".agents/tasks/bad/tier.json"), "w") as handle:
    handle.write("{}\n")
os.makedirs(os.path.join(root, ".agents/state"), exist_ok=True)
events = [
    {"schema": "agent-guard-event/v2", "event": "pre_final", "tier": {"task": "m1", "status": "exceeded"}},
    {"schema": "agent-guard-event/v2", "event": "pre_final", "tier": {"task": "m1", "status": "exceeded", "committed": True}},
    {"schema": "agent-guard-event/v2", "event": "pre_final", "tier": {"task": "s1", "status": "ok", "committed": False}},
    {"schema": "agent-guard-event/v2", "event": "pre_final", "tier": {"task": "old", "status": "exceeded", "committed": False}},
    {"schema": "agent-guard-event/v2", "event": "skill_note", "skill": "x"},
]
with open(os.path.join(root, ".agents/state/session-events.jsonl"), "w") as handle:
    handle.write("\n".join(json.dumps(event) for event in events[:2]) + "\nnot json\n"
                 + "\n".join(json.dumps(event) for event in events[2:]) + "\n")
PY
st_run --since 2026-10-01
st_want="Tasks: 4 (3 closed, 1 open) since 2026-10-01
Tier: small 2 · medium 1 · large 1 · handoff 1 · raised after coding 1
Suggestion: kept 2 · lowered with a reason 1 · raised 1
Warnings: pre-final 1 on 1 task · push 1 on 1 task
Time to close (median): small 45 min · large 2.0 d"
[[ "$ST_RC" -eq 0 && "$ST_OUT" == "$st_want" ]] || fail "stats --since: $ST_RC
$ST_OUT"
grep -qxF 'agent-guard: warn: tier stats: 1 record skipped (not readable)' "$TMP_ROOT/st.err" \
  || fail "stats skipped record: $(cat "$TMP_ROOT/st.err")"
st_run
[[ "$(head -n 2 <<<"$ST_OUT")" == "Tasks: 5 (3 closed, 2 open)
Tier: small 3 · medium 1 · large 1 · handoff 1 · raised after coding 1" ]] || fail "stats without --since: $ST_OUT"
grep -qxF 'Warnings: pre-final 2 on 2 tasks · push 1 on 1 task' <<<"$ST_OUT" || fail "stats warnings: $ST_OUT"
st_run --json --since 2026-10-01
python3 - "$ST_OUT" <<'PY' || fail "stats --json: $ST_OUT"
import json, sys
d = json.loads(sys.argv[1])
assert d["schema"] == "harness-tier-stats/v1", d
assert d["since"] == "2026-10-01" and d["tasks"] == {"total": 4, "closed": 3, "open": 1}, d
assert d["tiers"] == {"small": 2, "medium": 1, "large": 1, "none": 0} and d["handoff"] == 1, d
assert d["raised_after_coding"] == 1, d
assert d["suggestion"] == {"kept": 2, "lowered": 1, "raised": 1, "not_compared": 0}, d
assert d["warnings"] == {"pre_final": {"events": 1, "tasks": 1}, "push": {"events": 1, "tasks": 1}}, d
assert d["close_minutes_median"] == {"small": 45.0, "large": 2880.0}, d
assert d["skipped"] == 1, d
PY
st_run --since 2026-13-01
[[ "$ST_RC" -eq 1 ]] || fail "a bad --since: want exit 1, got $ST_RC"
grep -qF -- '--since must be a date like 2026-10-23' "$TMP_ROOT/st.err" \
  || fail "a bad --since: $(cat "$TMP_ROOT/st.err")"
st_run --since 2027-01-01
[[ "$ST_RC" -eq 0 && "$ST_OUT" == "No tier records since 2027-01-01." ]] || fail "stats after the last task: $ST_OUT"
# Odd data never fails stats: a record with no declared or suggested key,
# flags that are not a list, a history time that is not one (left out with
# --since), an event naming a list as its task, and a very deep event line.
python3 - "$st" <<'PY' || fail "cannot write the odd stats fixture"
import json, os, sys
root = sys.argv[1]
def write(task, doc):
    os.makedirs(os.path.join(root, ".agents/tasks", task), exist_ok=True)
    with open(os.path.join(root, ".agents/tasks", task, "tier.json"), "w") as handle:
        json.dump(dict({"schema": "harness-tier/v1", "task_id": task, "status": "open", "start_commit": "0" * 40}, **doc), handle)
write("nod", {"history": [{"at": "2026-10-22T00:00:00Z"}]})
write("flg", {"declared": "small", "suggested": "small", "suggestion_inputs": {"flags": 5},
              "history": [{"at": "2026-10-22T00:00:00Z"}]})
write("zzz", {"declared": "small", "suggested": "small", "history": [{"at": "zzz"}]})
with open(os.path.join(root, ".agents/state/session-events.jsonl"), "a") as handle:
    handle.write(json.dumps({"event": "pre_final", "tier": {"task": ["m1"], "status": "exceeded"}}) + "\n")
    handle.write("[" * 100000 + "]" * 100000 + "\n")
PY
st_run --since 2026-10-01
st_want="Tasks: 6 (3 closed, 3 open) since 2026-10-01
Tier: small 3 · medium 1 · large 1 · no tier 1 · handoff 1 · raised after coding 1
Suggestion: kept 3 · lowered with a reason 1 · raised 1 · not compared 1
Warnings: pre-final 1 on 1 task · push 1 on 1 task
Time to close (median): small 45 min · large 2.0 d"
[[ "$ST_RC" -eq 0 && "$ST_OUT" == "$st_want" ]] || fail "stats on odd data: $ST_RC
$ST_OUT
$(cat "$TMP_ROOT/st.err")"

# ---- the Stop hook: verification blocks, the tier warns -----------------------
# close-out: a verification problem blocks (exit 2, no snapshot advance); an
# exceeded tier only warns; a closed task never makes pre-push exit 5.
hk="$(fresh_target)"
hg() { git -C "$hk" "$@" || fail "git $* failed in the hook target"; }
hk_tier() {
  (cd "$hk" && scripts/agent-guard.sh tier "$@") >/dev/null 2>"$TMP_ROOT/hk-tier.err" \
    || fail "hook tier $*: $(cat "$TMP_ROOT/hk-tier.err")"
}
hk_verify() {
  python3 - "$hk/docs/superpowers/specs/project-tech-stack.json" "$1" <<'PY' || fail "cannot write hook verification[]"
import json, sys
doc = json.load(open(sys.argv[1]))
doc["verification"] = [{"command": sys.argv[2], "purpose": "test", "source": "test"}]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
}
hk_sid=0
hk_start() {
  hk_sid=$((hk_sid + 1))
  printf '{"session_id":"hk%s"}' "$hk_sid" | (cd "$hk" && scripts/agent-hook.sh claude-session-start >/dev/null 2>&1) \
    || fail "hook session start"
}
HK_RC=0
HK_ERR=""
hk_close() {
  HK_RC=0
  printf '{"session_id":"hk%s","stop_hook_active":false}' "$hk_sid" \
    | (cd "$hk" && scripts/agent-hook.sh close-out >"$TMP_ROOT/hk.out" 2>"$TMP_ROOT/hk.err") || HK_RC=$?
  HK_ERR="$(cat "$TMP_ROOT/hk.err")"
  HK_OUT="$(cat "$TMP_ROOT/hk.out")"
}
# hk_message <text>...: the systemMessage JSON on stdout holds each text.
hk_message() {
  python3 -c 'import json, sys
message = json.loads(sys.argv[1])["systemMessage"]
assert all(text in message for text in sys.argv[2:]), message' "$HK_OUT" "$@" || fail "systemMessage: $HK_OUT"
}
hk_files() {
  local n
  for n in 1 2 3 4 5 6; do printf 'export const h%s = 1;\n' "$n" >"$hk/src/h$n.ts"; done
}
hk_prepush() {
  HK_RC=0
  (cd "$hk" && bash scripts/githooks/pre-push </dev/null >"$TMP_ROOT/hk-push.out" 2>&1) || HK_RC=$?
  HK_ERR="$(cat "$TMP_ROOT/hk-push.out")"
}
hk_verify true
(cd "$hk" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight failed in the hook target"
hg checkout -q -b feature/hk-big
hk_tier set small --task hk-big
# 5. A failing verification blocks Stop, and wins over the tier.
hk_start
hk_files
hk_verify false
hk_close
[[ "$HK_RC" -eq 2 ]] || fail "failing verification above tier must block (got $HK_RC): $HK_ERR"
grep -qF 'close-out fast verification' <<<"$HK_ERR" || fail "verification message expected: $HK_ERR"
if grep -qF 'above its tier' <<<"$HK_ERR"; then fail "verification must win over the tier: $HK_ERR"; fi
hk_verify true
# 1. Above its tier, Stop only warns (tier checks recommend). The message
# reaches the user as systemMessage, gives the reasons, asks the user and
# never suggests tier set.
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "a size excess must not block Stop (got $HK_RC): $HK_ERR"
grep -qF 'agent-hook: warn: this change is above its tier (small -> medium). Decide before pushing: raise the tier or split the change.' \
  <<<"$HK_ERR" || fail "tier warning: $HK_ERR"
hk_message 'agent-hook: warn: this change is above its tier (small -> medium)' 'Reasons: 6 counted files (small allows 3).'
if grep -q 'tier set' <<<"$HK_ERR$HK_OUT"; then fail "the tier warning must not suggest tier set: $HK_ERR"; fi
# The snapshot advanced: a repeated Stop with no new change is quiet.
hk_close
[[ "$HK_RC" -eq 0 && -z "$HK_ERR" && -z "$HK_OUT" ]] || fail "a repeated Stop must be quiet (got $HK_RC): $HK_ERR $HK_OUT"
# 2. No file changed after the session start: the hook does nothing.
hk_start
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "unchanged session above tier must not block (got $HK_RC): $HK_ERR"
# 1b. Above its tier with nothing verified: one systemMessage carries both.
hk_verify 'run <placeholder>'
hk_start
printf 'export const h7 = 1;\n' >"$hk/src/h7.ts"
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "unverified above the tier must not block (got $HK_RC): $HK_ERR"
hk_message 'close-out verification unverified' 'above its tier (small -> medium)'
hk_verify true
# 6. Pre-push runs strict pre-final on the commits of the checked-out branch:
# drafts that are not committed do not count; once committed, an open
# exceeded task gets the recommendation.
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push must not count uncommitted drafts (got $HK_RC): $HK_ERR"
hg add src
hg commit -q -m "six files"
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push with an open exceeded task must pass (got $HK_RC): $HK_ERR"
grep -qF 'TIER: declared small, measured medium (recommended: raise the tier or split the change)' <<<"$HK_ERR" || fail "pre-push recommendation: $HK_ERR"
# A closed task is no longer measured: pre-push does not exit 5.
hk_tier close --task hk-big
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push with a closed task must pass (got $HK_RC): $HK_ERR"
# 3. A small task within its tier: the hook does not block.
rm -f "$hk"/src/h*.ts
hg checkout -q -f main
hg checkout -q -b feature/hk-ok
hk_tier set small --task hk-ok
hk_start
printf 'export const a = 3;\n' >"$hk/src/app.ts"
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "a change within its tier must not block (got $HK_RC): $HK_ERR"
# 4. No tier declared: as today.
hk_tier close --task hk-ok
hg checkout -q -f main
hg checkout -q -b feature/hk-none
hk_start
hk_files
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "no tier declared must not block (got $HK_RC): $HK_ERR"
# 7. A raise after coding with its review missing does not block Stop, so the
# coding session can end and @verify can run; it warns, and pre-push keeps
# the recommendation until the review passes. Case 1 (size) only warns too.
rm -f "$hk"/src/h*.ts
hg checkout -q -f main
hg checkout -q -b feature/hk-raise
hk_tier set small --task hk-raise
printf 'export const a = 4;\n' >"$hk/src/app.ts"
hk_tier set medium --task hk-raise
hk_start
printf 'export const a = 5;\n' >"$hk/src/app.ts"
hk_close
[[ "$HK_RC" -eq 0 ]] || fail "a raise after coding must not block Stop (got $HK_RC): $HK_ERR"
grep -qxF 'agent-hook: the tier was raised after coding, so @verify should review it (run that seat, or review it yourself) before this counts as done.' \
  <<<"$HK_ERR" || fail "raise warning: $HK_ERR"
hk_message 'the tier was raised after coding, so @verify should review it'
if grep -qF 'above its tier' <<<"$HK_ERR"; then fail "a raise is not a size problem: $HK_ERR"; fi
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push with a raise and no review must pass (got $HK_RC): $HK_ERR"
grep -qF '@verify review still needed' <<<"$HK_ERR" || fail "pre-push raise recommendation: $HK_ERR"
printf '## Final technical review\n\n### Attempt 1\n\nverdict: pass\n' >"$hk/.agents/tasks/hk-raise/verify-review.md"
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push after a passing @verify review must pass (got $HK_RC): $HK_ERR"
if grep -qF 'still needed' <<<"$HK_ERR"; then fail "a passing @verify review still recommended: $HK_ERR"; fi
# An old pass followed by a newer attempt with no verdict yet (a re-review is
# under way) must not count: the raise still needs @verify.
printf '\n### Attempt 2\n\nreviewer_model: other\n' >>"$hk/.agents/tasks/hk-raise/verify-review.md"
hk_prepush
[[ "$HK_RC" -eq 0 ]] || fail "pre-push must pass (got $HK_RC): $HK_ERR"
grep -qF '@verify review still needed' <<<"$HK_ERR" || fail "an old pass under a newer attempt must still recommend @verify: $HK_ERR"

# ---- the pre-push hook through a real git push --------------------------------
# A bare remote, a kit installed in app/, the armed hook: git runs the hook,
# which recommends while the commits are above the tier.
push_repo="$(mktemp -d "$TMP_ROOT/push.XXXXXX")"
push_remote="$(mktemp -d "$TMP_ROOT/remote.XXXXXX")"
git init -q --bare "$push_remote" || fail "git init --bare failed"
ph() { git -C "$push_repo" "$@" || fail "git $* failed in the push repo"; }
ph init -q -b main
ph config user.name Test
ph config user.email test@example.invalid
mkdir -p "$push_repo/app/src"
printf 'export const a = 1;\n' >"$push_repo/app/src/app.ts"
ph add app/src/app.ts
ph commit -q -m init
ph remote add origin "$push_remote"
ph push -q origin main
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$push_repo/app" --workflow full \
  --project-name budget-fixture >/dev/null || fail "bootstrap in app/ failed"
python3 - "$push_repo/app/docs/superpowers/specs/project-tech-stack.json" <<'PY' || fail "cannot write verification[]"
import json, sys
doc = json.load(open(sys.argv[1]))
doc["verification"] = [{"command": "true", "purpose": "test", "source": "test"}]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
(cd "$push_repo/app" && scripts/agent-guard.sh preflight >/dev/null 2>&1 && bash scripts/install-git-hooks.sh >/dev/null) \
  || fail "the hook install failed in app/"
[[ "$(ph config core.hooksPath)" == "app/scripts/githooks" ]] || fail "hooksPath in a subdirectory install: $(ph config core.hooksPath)"
ph switch -q -c feature/push
(cd "$push_repo/app" && scripts/agent-guard.sh tier set small --task push >/dev/null 2>&1) || fail "tier set in app/"
for n in 1 2 3 4 5 6; do printf 'export const p%s = 1;\n' "$n" >"$push_repo/app/src/p$n.ts"; done
ph add app/src
ph commit -q -m six
push_rc=0
git -C "$push_repo" push -q origin feature/push >"$TMP_ROOT/real-push.out" 2>&1 || push_rc=$?
[[ "$push_rc" -eq 0 ]] || fail "a real push above the tier must pass with a warning (got $push_rc): $(cat "$TMP_ROOT/real-push.out")"
grep -qF 'TIER: declared small, measured medium (recommended: raise the tier or split the change)' "$TMP_ROOT/real-push.out" \
  || fail "the real push did not run the tier check: $(cat "$TMP_ROOT/real-push.out")"
# A push that only deletes a branch sends no commit: the hook checks nothing.
push_rc=0
git -C "$push_repo" push -q origin --delete feature/push >"$TMP_ROOT/real-push.out" 2>&1 || push_rc=$?
[[ "$push_rc" -eq 0 ]] || fail "a delete-only push must pass (got $push_rc): $(cat "$TMP_ROOT/real-push.out")"
if grep -qF 'TIER:' "$TMP_ROOT/real-push.out"; then fail "a delete-only push ran the tier check: $(cat "$TMP_ROOT/real-push.out")"; fi

# ---- onboarding: risk_paths guide and hint -----------------------------------
ob="$(fresh_target)"
ob_guide="$(cat "$ob/docs/agent-configs/project-onboarding.md")"
for phrase in 'risk_paths' 'app/billing/**' 'always count'; do
  [[ "$ob_guide" == *"$phrase"* ]] || fail "onboarding guide must contain: $phrase"
done
ob_hint='hint: add your risky folders as risk_paths in docs/superpowers/specs/project-tech-stack.json (see project-onboarding.md)'
ob_contract="$ob/docs/superpowers/specs/project-tech-stack.json"
ob_next() { (cd "$ob" && scripts/agent-onboarding.sh next 2>&1) || true; }
ob_status_json() { (cd "$ob" && scripts/agent-onboarding.sh next --json 2>&1) || true; }
python3 - "$ob_contract" <<'PY' || fail "cannot drop risk_paths"
import json, sys
d = json.load(open(sys.argv[1])); d.pop("risk_paths", None)
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
ob_json_before="$(ob_status_json)"
ob_rc=0
(cd "$ob" && scripts/agent-onboarding.sh check >/dev/null 2>&1) || ob_rc=$?
[[ "$(ob_next)" == *"$ob_hint"* ]] || fail "no risk_paths hint without the key: $(ob_next)"
python3 - "$ob_contract" <<'PY' || fail "cannot set empty risk_paths"
import json, sys
d = json.load(open(sys.argv[1])); d["risk_paths"] = []
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
[[ "$(ob_next)" != *"$ob_hint"* ]] || fail "hint must go away with an empty risk_paths list"
ob_rc2=0
(cd "$ob" && scripts/agent-onboarding.sh check >/dev/null 2>&1) || ob_rc2=$?
[[ "$ob_rc" -eq "$ob_rc2" ]] || fail "the hint must not change the check exit code ($ob_rc vs $ob_rc2)"
[[ "$ob_json_before" != *"hint:"* ]] || fail "next --json must stay unchanged"

# ---- upgrade of an older project ---------------------------------------------
up="$(fresh_target)"
up_policy="$up/docs/agent-configs/context-policy.json"
up_contract="$up/docs/superpowers/specs/project-tech-stack.json"
python3 - "$up_policy" "$up_contract" <<'PY' || fail "cannot simulate an older project"
import json, sys
p = json.load(open(sys.argv[1]))
for k in ("tier_rules", "risk_paths", "risk_tokens", "dependency_manifests", "dependency_locks", "test_patterns"):
    p.pop(k, None)
json.dump(p, open(sys.argv[1], "w"), indent=2)
c = json.load(open(sys.argv[2])); c.pop("risk_paths", None)
open(sys.argv[2], "w").write(json.dumps(c, indent=2) + "\n")
PY
mkdir -p "$up/.agents/tasks/old-task"
printf '{}\n' >"$up/.agents/tasks/old-task/state.json"
python3 - "$up/AGENTS.md" <<'PY' || fail "cannot add a USER block"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = "<!-- BEGIN USER: agents:extra -->\n"
assert a in s
open(p, "w", encoding="utf-8").write(s.replace(a, a + "UPGRADE-KEEP\n", 1))
PY
cp "$up_contract" "$TMP_ROOT/up-contract.before"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" \
  --target "$up" --workflow full --project-name budget-fixture --force >/dev/null \
  || fail "update of the older project failed"
grep -qF 'UPGRADE-KEEP' "$up/AGENTS.md" || fail "the USER overlay was lost in the update"
python3 - "$up_policy" <<'PY' || fail "the update did not restore the tier keys"
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("tier_rules", "risk_paths", "risk_tokens", "dependency_manifests", "dependency_locks", "test_patterns"):
    assert k in d, k
PY
cmp -s "$TMP_ROOT/up-contract.before" "$up_contract" || fail "project-tech-stack.json was rewritten by the update"
[[ -f "$up/.agents/tasks/old-task/state.json" && ! -e "$up/.agents/tasks/old-task/tier.json" ]] \
  || fail "the old packet was changed"
fails="$(failing_checks "$up")"
[[ -z "$fails" ]] || fail "verifier fails after the update: $fails"
(cd "$up" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || fail "preflight failed after the update"
up_rc=0
up_err="$(cd "$up" && scripts/agent-guard.sh pre-final 2>&1 >/dev/null)" || up_rc=$?
[[ "$up_err" == *'no tier declared'* ]] || fail "update: no 'no tier declared' warning: $up_err"
[[ "$up_rc" -eq 0 ]] || fail "update: pre-final exit code changed (got $up_rc): $up_err"
up_next="$(cd "$up" && scripts/agent-onboarding.sh next 2>&1)" || true
[[ "$up_next" == *"$ob_hint"* ]] || fail "update: no risk_paths hint: $up_next"

printf 'change-tiers-test: ok\n'
