#!/usr/bin/env bash
set -euo pipefail

# ci-gate.sh against a stub API: full=false only for a push whose tree a
# successful run of this workflow in this repository recorded, unexpired.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "ci-gate-test: FAIL: $*" >&2; exit 1; }

repo="$work/repo"
mkdir -p "$repo" "$work/api"
git -C "$repo" init -q
printf 'x\n' >"$repo/file"
git -C "$repo" add file
git -C "$repo" -c user.name=g -c user.email=g@example.invalid commit -qm init
tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
# The stub prints $CI_GATE_STUB/<path with / ? & = replaced by _>, or fails.
cat >"$work/stub" <<'EOF'
#!/usr/bin/env bash
key="$(printf '%s' "$1" | tr '/?&=' '____')"
[[ -f "$CI_GATE_STUB/$key" ]] || exit 1
cat "$CI_GATE_STUB/$key"
EOF
chmod +x "$work/stub"
artifacts_key="$(printf '%s' "repos/o/r/actions/artifacts?name=tested-tree-$tree&per_page=20" | tr '/?&=' '____')"
run_key="$(printf '%s' "repos/o/r/actions/runs/77" | tr '/?&=' '____')"

# Usage: gate EVENT ARTIFACTS_JSON RUN_JSON; prints the gate's stdout.
gate() {
  local dir="$work/api/$RANDOM$RANDOM"
  mkdir -p "$dir"
  if [[ -n "$2" ]]; then printf '%s' "$2" >"$dir/$artifacts_key"; fi
  if [[ -n "$3" ]]; then printf '%s' "$3" >"$dir/$run_key"; fi
  (cd "$repo" && CI_GATE_API="$work/stub" CI_GATE_STUB="$dir" GITHUB_EVENT_NAME="$1" GITHUB_REPOSITORY=o/r \
    bash "$ROOT_DIR/scripts/ci-gate.sh" 2>/dev/null)
}
expect() { # LABEL WANT OUTPUT
  [[ "$3" == *"full=$2"* ]] || fail "$1: want full=$2, got: $3"
  [[ "$3" == *"tree=$tree"* ]] || fail "$1: missing tree=$tree in: $3"
}
art='{"artifacts":[{"name":"tested-tree-'"$tree"'","expired":false,"workflow_run":{"id":77}}]}'
expired='{"artifacts":[{"name":"tested-tree-'"$tree"'","expired":true,"workflow_run":{"id":77}}]}'
ok_run='{"id":77,"path":".github/workflows/test.yml","conclusion":"success","repository":{"full_name":"o/r"}}'
other_wf='{"id":77,"path":".github/workflows/other.yml","conclusion":"success","repository":{"full_name":"o/r"}}'
failed='{"id":77,"path":".github/workflows/test.yml","conclusion":"failure","repository":{"full_name":"o/r"}}'
other_repo='{"id":77,"path":".github/workflows/test.yml","conclusion":"success","repository":{"full_name":"x/y"}}'

expect "push, recorded green tree" false "$(gate push "$art" "$ok_run")"
expect "pull request" true "$(gate pull_request "$art" "$ok_run")"
expect "manual run" true "$(gate workflow_dispatch "$art" "$ok_run")"
expect "expired artifact" true "$(gate push "$expired" "$ok_run")"
expect "another workflow" true "$(gate push "$art" "$other_wf")"
expect "failed run" true "$(gate push "$art" "$failed")"
expect "another repository" true "$(gate push "$art" "$other_repo")"
expect "no artifact" true "$(gate push '{"artifacts":[]}' "")"
expect "API error" true "$(gate push "" "")"
expect "unreadable JSON" true "$(gate push 'not json' "")"
echo "ci-gate-test: ok"
