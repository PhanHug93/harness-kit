#!/usr/bin/env bash
set -euo pipefail

# Local-only mode in a generated project: of the development records only specs
# of started work and plan journals reach the index with `git add -A`. Draft
# specs, analyses and plans stay local, and the pre-push check reports any other
# development record that was force-added.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-only-mode-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'local-only-mode-test: FAIL: %s\n' "$*" >&2
  exit 1
}

target="$TMP_ROOT/project"
mkdir -p "$target"
git -C "$target" init -q
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null 2>&1

# The startup prompt tells agents where packets and Markdown records go.
agents="$(cat "$target/AGENTS.md")"
for phrase in "## Development Records" ".agents/tasks/<task-id>/" "docs/superpowers/plans/<topic>/" \
  "in the first commit that" "docs/superpowers/plans/<topic>/journal.md" \
  "superpowers brainstorming and writing-plans" "do not commit them"; do
  [[ "$agents" == *"$phrase"* ]] || fail "AGENTS.md must state the development-record rule: $phrase"
done

pushed=(
  src/app.txt
  docs/superpowers/specs/checkout/design.md
  docs/superpowers/plans/checkout/journal.md
)
local_only=(
  docs/superpowers/plans/checkout/plan.md
  docs/superpowers/plans/checkout/summary.md
  docs/superpowers/plans/refunds/design.md
  docs/superpowers/plans/refunds/analysis.md
  docs/superpowers/plans/2026-10-14-refunds.md
  .superpowers/brainstorm/1-2/content/screen.html
  docs/superpowers/plans/README.md
  docs/superpowers/reviews/checkout.md
  docs/superpowers/archive/old.md
  .agents/tasks/checkout/task.md
  .agents/tasks/checkout/evidence/run.log
  docs/superpowers/specs/project-tech-stack.json
)
for rel in "${pushed[@]}" "${local_only[@]}"; do
  mkdir -p "$target/$(dirname "$rel")"
  [[ -e "$target/$rel" ]] || printf 'sample\n' > "$target/$rel"
done

git -C "$target" add -A
# The kit's .gitignore block is itself local-only (reported by the check).
git -C "$target" rm -q --cached .gitignore
tracked="$(git -C "$target" ls-files)"
for rel in "${pushed[@]}"; do
  grep -qxF "$rel" <<<"$tracked" || fail "$rel must be pushable"
done
for rel in "${local_only[@]}"; do
  if grep -qxF "$rel" <<<"$tracked"; then
    fail "$rel must stay local-only"
  fi
done
unexpected="$(grep -E '^(docs/superpowers/|\.agents/)' <<<"$tracked" |
  grep -vE '^docs/superpowers/specs/|^docs/superpowers/plans/[^/]+/journal\.md$' || true)"
[[ -z "$unexpected" ]] || fail "unexpected development records reached the index: $unexpected"

(cd "$target" && bash scripts/agent-local-only-check.sh status >/dev/null 2>&1) ||
  fail "specs and journals must pass the local-only check"

git -C "$target" add -f docs/superpowers/plans/checkout/plan.md docs/superpowers/plans/checkout/summary.md \
  .agents/tasks/checkout/task.md
set +e
out="$(cd "$target" && bash scripts/agent-local-only-check.sh status 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "a force-added plan must fail the local-only check"
[[ "$out" == *"docs/superpowers/plans/checkout/plan.md"*"local-only development record"* ]] ||
  fail "the check must name the plan as a development record: $out"
[[ "$out" == *"docs/superpowers/plans/checkout/summary.md"* ]] || fail "the check must name the summary: $out"
[[ "$out" == *".agents/tasks/checkout/task.md"* ]] || fail "the check must name the task packet: $out"
[[ "$out" != *"journal.md"* && "$out" != *"specs/checkout/design.md"* ]] ||
  fail "pushable records must not be reported: $out"

printf 'local-only-mode-test: ok\n'
