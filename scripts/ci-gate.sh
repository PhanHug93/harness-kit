#!/usr/bin/env bash
set -uo pipefail

# Prints tree=<sha> and full=true|false for $GITHUB_OUTPUT.
# - A pull request or a manual run always tests in full.
# - A push to main or a v* tag skips the heavy jobs when a successful run of
#   this workflow in this repository recorded the same tree: the record job
#   uploads artifact tested-tree-<tree> only after every job passed. A pull
#   request run tests its merge commit, so trees are compared, not SHAs; the
#   tree includes this workflow file, so a match ran the same definition.
# Any doubt (API error, unreadable reply) means full=true.
read -r -a api <<<"${CI_GATE_API:-gh api}"
full() {
  echo "full=true"
  echo "ci-gate: full run: $1" >&2
  exit 0
}
tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" || full "cannot read the tree"
echo "tree=$tree"
[[ "${GITHUB_EVENT_NAME:-}" == "push" ]] || full "${GITHUB_EVENT_NAME:-local} event"
repo="${GITHUB_REPOSITORY:-}"
[[ -n "$repo" ]] || full "GITHUB_REPOSITORY is not set"
artifacts="$("${api[@]}" "repos/$repo/actions/artifacts?name=tested-tree-$tree&per_page=20" 2>/dev/null)" ||
  full "artifact lookup failed"
run_ids="$(python3 -I -S -c '
import json, sys
try:
    doc = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
for item in (doc.get("artifacts") or []) if isinstance(doc, dict) else []:
    if isinstance(item, dict) and not item.get("expired"):
        run = item.get("workflow_run") or {}
        if isinstance(run.get("id"), int):
            print(run["id"])
' <<<"$artifacts")" || full "unreadable artifact list"
for id in $run_ids; do
  run="$("${api[@]}" "repos/$repo/actions/runs/$id" 2>/dev/null)" || continue
  if REPO="$repo" python3 -I -S -c '
import json, os, sys
try:
    run = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
ok = (isinstance(run, dict)
      and str(run.get("path", "")).startswith(".github/workflows/test.yml")
      and run.get("conclusion") == "success"
      and (run.get("repository") or {}).get("full_name") == os.environ["REPO"])
sys.exit(0 if ok else 1)
' <<<"$run"; then
    echo "full=false"
    echo "ci-gate: tree $tree passed in run $id; skipping the heavy jobs" >&2
    exit 0
  fi
done
full "no successful run recorded tree $tree"
