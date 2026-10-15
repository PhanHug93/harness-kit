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
  "superpowers brainstorming and writing-plans" "plans never leave"; do
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
# The kit's ignore block lives in .git/info/exclude, never in a tracked file.
exclude_file="$(git -C "$target" rev-parse --git-path info/exclude)"
case "$exclude_file" in /*) ;; *) exclude_file="$target/$exclude_file" ;; esac
marker='# >>> multi-agent bootstrap local state >>>'
grep -Fq "$marker" "$exclude_file" || fail "the ignore block must be written to $exclude_file"
if [[ -f "$target/.gitignore" ]] && grep -Fq "$marker" "$target/.gitignore"; then
  fail "the ignore block must not be written to .gitignore by default"
fi
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

# Design case 10: a tracked plain .gitignore (without the block) passes the check.
git -C "$target" rm -q --cached -f docs/superpowers/plans/checkout/plan.md docs/superpowers/plans/checkout/summary.md \
  .agents/tasks/checkout/task.md
printf 'node_modules/\n' > "$target/.gitignore"
git -C "$target" add .gitignore
(cd "$target" && bash scripts/agent-local-only-check.sh status >/dev/null 2>&1) ||
  fail "a tracked plain .gitignore must pass the local-only check"

# --ignore-target gitignore keeps the block in .gitignore only.
gi_target="$TMP_ROOT/gitignore-project"
mkdir -p "$gi_target"
git -C "$gi_target" init -q
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$gi_target" --workflow full \
  --ignore-target gitignore >/dev/null 2>&1
grep -Fq "$marker" "$gi_target/.gitignore" || fail "--ignore-target gitignore must write .gitignore"
gi_exclude="$(git -C "$gi_target" rev-parse --git-path info/exclude)"
case "$gi_exclude" in /*) ;; *) gi_exclude="$gi_target/$gi_exclude" ;; esac
if [[ -f "$gi_exclude" ]] && grep -Fq "$marker" "$gi_exclude"; then
  fail "--ignore-target gitignore must not also write the exclude file"
fi
# A rerun keeps the block where it already is.
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$gi_target" --workflow full --force >/dev/null 2>&1
if [[ -f "$gi_exclude" ]] && grep -Fq "$marker" "$gi_exclude"; then
  fail "a rerun must keep the block in .gitignore"
fi

# A linked worktree writes to the common exclude file.
wt_repo="$TMP_ROOT/wt-repo"
mkdir -p "$wt_repo"
git -C "$wt_repo" init -q
git -C "$wt_repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m seed
git -C "$wt_repo" worktree add -q "$TMP_ROOT/wt-second"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$TMP_ROOT/wt-second" --workflow full >/dev/null 2>&1
wt_exclude="$(git -C "$TMP_ROOT/wt-second" rev-parse --git-path info/exclude)"
case "$wt_exclude" in /*) ;; *) wt_exclude="$TMP_ROOT/wt-second/$wt_exclude" ;; esac
grep -Fq "$marker" "$wt_exclude" || fail "worktree block must land in the common exclude file: $wt_exclude"
[[ "$wt_exclude" == "$wt_repo/.git/info/exclude" ]] || fail "worktree exclude must be the common one, got $wt_exclude"
[[ ! -f "$TMP_ROOT/wt-second/.gitignore" ]] || ! grep -Fq "$marker" "$TMP_ROOT/wt-second/.gitignore" ||
  fail "worktree must not write the block to .gitignore"

# Monorepo subprojects: the block is anchored under each subproject prefix.
mono="$TMP_ROOT/mono"
mkdir -p "$mono/apps/a" "$mono/apps/b"
git -C "$mono" init -q
kit() { bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$1" --workflow full >/dev/null 2>&1; }
ignored() { git -C "$mono" check-ignore -q "$1"; }
kit "$mono/apps/a"
printf 'x\n' > "$mono/AGENTS.md"; printf 'x\n' > "$mono/apps/b/AGENTS.md"; mkdir -p "$mono/apps/a/sub"; printf 'x\n' > "$mono/apps/a/sub/x.bak.1"
ignored apps/a/AGENTS.md || fail "apps/a/AGENTS.md must be ignored"
ignored apps/a/.agents/x || fail "apps/a/.agents/ must be ignored"
ignored apps/a/sub/x.bak.1 || fail "slash-less patterns must still match at depth inside apps/a"
ignored AGENTS.md && fail "root AGENTS.md must not be ignored"
ignored apps/b/AGENTS.md && fail "apps/b/AGENTS.md must not be ignored"
kit "$mono/apps/b"
ignored apps/b/AGENTS.md || fail "apps/b/AGENTS.md must be ignored after generating apps/b"
ignored AGENTS.md && fail "root AGENTS.md must stay unignored"
mono_ex="$mono/.git/info/exclude"
grep -Fxq "$marker apps/a/" "$mono_ex" || fail "apps/a block marker missing"
grep -Fxq "$marker apps/b/" "$mono_ex" || fail "apps/b block marker missing"
before="$(cat "$mono_ex")"
kit "$mono/apps/a"; kit "$mono/apps/b"
[[ "$(cat "$mono_ex")" == "$before" ]] || fail "rerun must be idempotent"
[[ "$(grep -Fc "$marker" "$mono_ex")" -eq 2 ]] || fail "expected exactly two blocks"

printf 'local-only-mode-test: ok\n'
