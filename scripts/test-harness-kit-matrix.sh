#!/usr/bin/env bash
set -euo pipefail

# One-shot fixture matrix: install (design case 1) and an update from the
# v2026.09.07.1 bundle with a conflicting patch (case 4: exit 3, --resolved
# gives exit 0, the next run reapplies from knowledge) on three plain fixtures:
# no stack, a web project (package.json with a test script) and a mobile
# project (Gradle Android). Detection must pick the stack, and every run
# report must match the run-report schema. Offline: the kit comes from
# --source-dir.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/oneshot-matrix.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export TMPDIR="$TMP_ROOT/private-tmp"
mkdir -p "$TMPDIR"

fail() {
  printf 'oneshot-matrix: FAIL: %s\n' "$*" >&2
  exit 1
}

ENTRY="$ROOT_DIR/agent-bootstrap/harness-kit-one-shot.sh"
VERSION="$(sed -n '1p' "$ROOT_DIR/agent-bootstrap/VERSION" | tr -d '[:space:]')"
MARKER='# >>> multi-agent bootstrap local state >>>'
OLD_KIT="$TMP_ROOT/old-kit"
mkdir -p "$OLD_KIT"
tar -xf "$ROOT_DIR/scripts/fixtures/historical-bundles/v2026.09.07.1.tar" -C "$OLD_KIT"

git_c() { git -C "$1" -c user.name=oneshot -c user.email=oneshot@example.invalid "${@:2}"; }
new_repo() { # dir kind: a repository on main with the fixture's files committed
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
  printf '# fixture\n' >"$1/README.md"
  case "$2" in
    web)
      printf '{"name":"web","main":"index.js","scripts":{"test":"node -e 0"}}\n' >"$1/package.json"
      printf 'module.exports = {};\n' >"$1/index.js"
      ;;
    mobile)
      mkdir -p "$1/app"
      printf 'rootProject.name = "mobile"\ninclude(":app")\n' >"$1/settings.gradle.kts"
      printf 'plugins { id("com.android.application") }\n' >"$1/app/build.gradle.kts"
      ;;
  esac
  git -C "$1" add -A
  git_c "$1" commit -qm init
}
old_install() {
  bash "$OLD_KIT/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$1" --workflow full >/dev/null 2>&1 ||
    fail "fixture: the v2026.09.07.1 install failed in $1"
}
# hk DIR ARGS...: one run from DIR; console in OUT, exit code in RC, report in REPORT.
hk() {
  local dir="$1"
  shift
  RC=0
  OUT="$(cd "$dir" && bash "$ENTRY" --source-dir "$ROOT_DIR" "$@" 2>"$TMP_ROOT/hk.err")" || RC=$?
  REPORT="$dir/$(printf '%s\n' "$OUT" | sed -n 's/^report: //p' | tail -n 1)"
}
expect() { # code label: exit code, mode on the first line, at most 12 lines, schema
  [[ "$RC" -eq "$1" ]] || fail "$2: exit $RC, expected $1
$OUT
$(tail -n 5 "$TMP_ROOT/hk.err")"
  [[ "$(sed -n '1p' <<<"$OUT")" == mode:* ]] || fail "$2: the first line must name the mode: $OUT"
  [[ "$(wc -l <<<"$OUT")" -le 12 ]] || fail "$2: console summary over 12 lines: $OUT"
  [[ -f "$REPORT" ]] || fail "$2: no report: $OUT"
  schema_check "$REPORT"
}
jget() { python3 -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
exclude_of() {
  local path
  path="$(git -C "$1" rev-parse --git-path info/exclude)"
  case "$path" in /*) ;; *) path="$1/$path" ;; esac
  printf '%s\n' "$path"
}
stacks_of() { # the detected stacks recorded in the lock
  jget "$1/docs/agent-configs/agent-bootstrap.lock.json" \
    '[l.split("=", 1)[1] for l in d["detector_summary"].splitlines() if l.startswith("tech_stacks=")][0]'
}

# Run reports must match agent-bootstrap/schemas/harness-kit-run-report-v1.schema.json
# (a stdlib JSON-Schema subset: type, required, properties, items, enum, const,
# additionalProperties, $ref, pattern, minLength, minimum).
RUN_REPORT_SCHEMA="$ROOT_DIR/agent-bootstrap/schemas/harness-kit-run-report-v1.schema.json"
IFS= read -r -d '' SCHEMA_CHECK <<'PY' || true
import json, re, sys
schema = json.load(open(sys.argv[1]))
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool, "number": (int, float)}
def resolve(node):
    while "$ref" in node:
        target = schema
        for part in node["$ref"].lstrip("#/").split("/"):
            target = target[part]
        node = target
    return node
def check(node, value, where, errs):
    node = resolve(node)
    kind = node.get("type")
    if kind and (not isinstance(value, TYPES[kind]) or (kind in ("integer", "number") and isinstance(value, bool))):
        errs.append("%s: expected %s" % (where, kind))
        return
    if "const" in node and value != node["const"]:
        errs.append("%s: expected %r" % (where, node["const"]))
    if "enum" in node and value not in node["enum"]:
        errs.append("%s: %r not in %r" % (where, value, node["enum"]))
    if isinstance(value, str):
        if "pattern" in node and not re.search(node["pattern"], value):
            errs.append("%s: does not match %s" % (where, node["pattern"]))
        if len(value) < node.get("minLength", 0):
            errs.append("%s: too short" % where)
    if isinstance(value, int) and not isinstance(value, bool) and value < node.get("minimum", value):
        errs.append("%s: below the minimum" % where)
    if isinstance(value, dict):
        errs.extend("%s: missing %s" % (where, key) for key in node.get("required", []) if key not in value)
        props, extra = node.get("properties", {}), node.get("additionalProperties", True)
        for key, item in value.items():
            if key in props:
                check(props[key], item, where + "." + key, errs)
            elif extra is False:
                errs.append("%s: unexpected key %s" % (where, key))
            elif isinstance(extra, dict):
                check(extra, item, where + "." + key, errs)
    if isinstance(value, list) and "items" in node:
        for index, item in enumerate(value):
            check(node["items"], item, "%s[%d]" % (where, index), errs)
source = sys.argv[2]
doc = json.loads(source) if source.lstrip().startswith("{") else json.load(open(source))
errors = []
check(schema, doc, "report", errors)
if errors:
    sys.exit("\n".join(errors[:10]))
PY
schema_check() { # report.json path or JSON text
  python3 -I -B -c "$SCHEMA_CHECK" "$RUN_REPORT_SCHEMA" "$1" 2>&1 ||
    fail "report does not match the run-report schema: ${1:0:200}"
}
# The validator itself rejects an unknown key, a wrong enum and a missing field.
for bad in '{"schema":"harness-kit-run-report/v1","extra":1}' '{"schema":"other"}'; do
  if python3 -I -B -c "$SCHEMA_CHECK" "$RUN_REPORT_SCHEMA" "$bad" >/dev/null 2>&1; then
    fail "schema validator accepted an invalid report: $bad"
  fi
done

for kind in none web mobile; do
  case "$kind" in
    none) stack=generic verify=(--skip-verify) ;;
    web) stack=node_js verify=() ;;
    mobile) stack=android_java verify=() ;;
  esac

  # 1 install on a new repository on main (the no-stack fixture is verified in
  # test-harness-kit-oneshot.sh).
  dir="$TMP_ROOT/install-$kind"
  new_repo "$dir" "$kind"
  hk "$dir" ${verify[@]+"${verify[@]}"}
  expect 0 "$kind: install"
  [[ "$(sed -n '1p' <<<"$OUT")" == "mode: install $VERSION" ]] || fail "$kind: install mode line: $OUT"
  [[ -z "$(git -C "$dir" status --porcelain)" ]] || fail "$kind: install must leave git status clean: $(git -C "$dir" status --porcelain)"
  grep -Fxq "$MARKER" "$(exclude_of "$dir")" || fail "$kind: the ignore block must be in the exclude file"
  [[ "$(jget "$dir/.tools/agent-state/project-knowledge.json" 'd["kit"]["version"]')" == "$VERSION" ]] ||
    fail "$kind: project knowledge was not written"
  [[ "$(stacks_of "$dir")" == "$stack" ]] || fail "$kind: detection must pick $stack, got $(stacks_of "$dir")"
  if [[ "${#verify[@]}" -eq 0 ]]; then
    [[ "$(jget "$REPORT" '[v["status"] for v in d["verify"]]')" == "['pass', 'pass']" ]] ||
      fail "$kind: harness checks must pass: $(jget "$REPORT" 'd["verify"]')"
  fi

  # 4 update from v2026.09.07.1 with a conflicting patch.
  dir="$TMP_ROOT/update-$kind"
  new_repo "$dir" "$kind"
  old_install "$dir"
  printf 'legacy patch\n' >>"$dir/.claude/commands/coding.md"
  hk "$dir" --skip-verify
  expect 3 "$kind: update with a conflicting patch"
  [[ "$(sed -n '1p' <<<"$OUT")" == "mode: update 2026.09.07.1 -> $VERSION" ]] || fail "$kind: update mode line: $OUT"
  grep -qx 'legacy patch' "$dir/.claude/commands/coding.md" || fail "$kind: a conflict overwrote the local file"
  [[ "$(jget "$REPORT" '".claude/commands/coding.md" in [c["path"] for c in d["files"]["conflicts"]]')" == True ]] ||
    fail "$kind: the patched file must be a conflict: $(jget "$REPORT" 'd["files"]["counts"]')"
  [[ "$(stacks_of "$dir")" == "$stack" ]] || fail "$kind: the update must keep detecting $stack, got $(stacks_of "$dir")"
  takes=()
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && takes+=(--take-kit "$rel")
  done < <(jget "$REPORT" '"\n".join(c["path"] for c in d["files"]["conflicts"] if c["path"].startswith(("docs/agent-configs/project-", "docs/superpowers/specs/project-tech-stack")))')
  hk "$dir" --skip-verify --resolved .claude/commands/coding.md --accept next-ignore-block-to-exclude \
    --take-kit all ${takes[@]+"${takes[@]}"}
  expect 0 "$kind: --resolved"
  grep -qx 'legacy patch' "$dir/.claude/commands/coding.md" || fail "$kind: --resolved must keep the local file"
  leftover="$(find "$dir" \( -path "$dir/.git" -o -path "$dir/.tools" -o -path "$dir/.harness-kit" \) -prune -o -name '*.generated.*' -print)"
  [[ -z "$leftover" ]] || fail "$kind: candidates left after --resolved and --take-kit: $leftover"
  hk "$dir" --skip-verify
  expect 0 "$kind: next run"
  [[ "$(sed -n '1p' <<<"$OUT")" == "mode: reinstall $VERSION" ]] || fail "$kind: the next run must be a reinstall: $OUT"
  [[ "$(jget "$REPORT" '".claude/commands/coding.md" in d["files"]["kept"]')" == True ]] ||
    fail "$kind: the next run must keep the resolved file: $(jget "$REPORT" 'd["files"]')"
  [[ "$(stacks_of "$dir")" == "$stack" ]] || fail "$kind: detection changed after the update: $(stacks_of "$dir")"
  printf 'oneshot-matrix: %s ok\n' "$kind"
done

leftover="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)"
[[ -z "$leftover" ]] || fail "runs left scratch files behind: $leftover"
printf 'oneshot-matrix: ok\n'
