#!/usr/bin/env bash
set -euo pipefail

# Migration runner (agent-bootstrap/lib/migrations.sh) and the three shipped
# migrations, exercised on generated throwaway projects and on stub migrations
# in a temporary kit copy. The repository is never modified.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-migrations-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

KIT="$ROOT_DIR/agent-bootstrap"
KNOW="$KIT/lib/knowledge.py"
MARKER='# >>> multi-agent bootstrap local state >>>'

fail() {
  printf 'harness-migrations-test: FAIL: %s\n' "$*" >&2
  exit 1
}

eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

[[ -f "$KIT/lib/migrations.sh" ]] || fail "agent-bootstrap/lib/migrations.sh is missing"
# shellcheck disable=SC1091
. "$KIT/lib/migrations.sh"

n_target=0
new_target() {
  n_target=$((n_target + 1))
  TARGET_DIR="$TMP_ROOT/p$n_target"
  mkdir -p "$TARGET_DIR"
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config user.email t@example.invalid
  git -C "$TARGET_DIR" config user.name t
  KIT_DIR="$KIT"
  STAMP="20261015-00000$n_target"
  JOURNAL_DIR="$TMP_ROOT/journal$n_target"
  mkdir -p "$JOURNAL_DIR"
  export TARGET_DIR KIT_DIR STAMP JOURNAL_DIR
}

gen() { bash "$KIT/bootstrap-multi-agent-project.sh" --target "$TARGET_DIR" --workflow full "$@" >/dev/null 2>&1 || fail "generation failed"; }
state_hash() { { git -C "$TARGET_DIR" ls-files -s; git -C "$TARGET_DIR" status --porcelain=v1 -uall; cat "$TARGET_DIR/.gitignore" 2>/dev/null || true; cat "$(git -C "$TARGET_DIR" rev-parse --git-path info/exclude)"; } | cksum; }
pending_ids() { python3 -I "$KNOW" --target "$TARGET_DIR" decisions --pending | tr '\n' ' '; }
result_line() { grep -F "$1"$'\t' "$MIGRATIONS_RESULT_FILE" | tail -1; }

UNTRACK=next-untrack-local-records
TOEXCL=next-ignore-block-to-exclude
RETIRE=next-retire-files

# ---------------------------------------------------------------- untrack
new_target
gen
eq "$(migrations_select 2026.10.13.2 next update)" "" "a clean project selects nothing"
git -C "$TARGET_DIR" add -f AGENTS.md
mkdir -p "$TARGET_DIR/.agents/tasks/a b" "$TARGET_DIR/docs/superpowers/plans/x"
printf 'x\n' >"$TARGET_DIR/.agents/tasks/a b/task.md"
printf 'x\n' >"$TARGET_DIR/docs/superpowers/plans/x/plan.md"
git -C "$TARGET_DIR" add -f ".agents/tasks/a b/task.md" docs/superpowers/plans/x/plan.md
(cd "$TARGET_DIR" && AGENT_BOOTSTRAP_ROOT="$TARGET_DIR" bash "$KIT/agent-local-only-check.sh" --list >"$TMP_ROOT/list.out")
eq "$(wc -l <"$TMP_ROOT/list.out" | tr -d ' ')" "3" "--list prints one tracked local-only path per line"
grep -qxF ".agents/tasks/a b/task.md" "$TMP_ROOT/list.out" || fail "--list must print paths with spaces verbatim"
eq "$(migrations_select 2026.10.13.2 next update)" "$UNTRACK" "untrack is selected"
eq "$(migrations_select 2026.10.13.2 2026.10.13.3 update)" "" "next migrations are not in a released range"
eq "$(migrations_select 2026.10.13.2 next install)" "" "install selects only pending decisions"
facts="$(migrations_facts "$UNTRACK")"
has "$facts" "3 tracked local-only files: " "facts count"
has "$facts" ".agents/tasks/a b/task.md" "facts list"

migrations_run 2026.10.13.2 next update "" "" || fail "undecided run must succeed"
IFS=$'\t' read -r rid rstatus rsummary rfacts <<<"$(result_line "$UNTRACK")"
eq "$rstatus" "pending" "undecided needed decision is pending"
eq "$rfacts" "$facts" "result carries the facts"
[[ -n "$rsummary" ]] || fail "result carries the summary"
eq "$(pending_ids)" "$UNTRACK " "pending recorded in knowledge"
eq "$(git -C "$TARGET_DIR" ls-files | grep -c 'task.md')" "1" "pending leaves the index alone"
eq "$(migrations_select 2026.10.13.2 next install)" "$UNTRACK" "install re-asks a pending decision"
eq "$(migrations_select 2026.10.13.2 next reinstall)" "$UNTRACK" "reinstall re-asks a pending decision"

migrations_run 2026.10.13.2 next update "$UNTRACK" "" || fail "accepted run must succeed"
eq "$(cut -f2 <<<"$(result_line "$UNTRACK")")" "applied" "accepted decision applies"
(cd "$TARGET_DIR" && AGENT_BOOTSTRAP_ROOT="$TARGET_DIR" bash "$KIT/agent-local-only-check.sh" --list) >"$TMP_ROOT/list.out"
eq "$(wc -l <"$TMP_ROOT/list.out" | tr -d ' ')" "0" "nothing tracked afterwards"
[[ -f "$TARGET_DIR/.agents/tasks/a b/task.md" && -f "$TARGET_DIR/AGENTS.md" ]] || fail "files stay on disk"
eq "$(migrations_select 2026.10.13.2 next update)" "" "no longer needed"
eq "$(pending_ids)" "" "applied decision is not pending"
[[ -d "$JOURNAL_DIR/migrations/$UNTRACK" ]] || fail "backup directory missing under the journal"
[[ -n "$(find "$JOURNAL_DIR/migrations/$UNTRACK" -type f | head -1)" ]] || fail "index backup missing"
before="$(state_hash)"
migrations_run 2026.10.13.2 next update "$UNTRACK" "" || fail "second run must succeed"
eq "$(state_hash)" "$before" "a second run changes nothing"

# Decline is recorded and re-asked only when the facts change.
new_target
gen
git -C "$TARGET_DIR" add -f AGENTS.md
migrations_run 2026.10.13.2 next update "" "$UNTRACK" || fail "decline run"
eq "$(cut -f2 <<<"$(result_line "$UNTRACK")")" "declined" "declined result"
eq "$(pending_ids)" "" "declined is not pending"
eq "$(migrations_select 2026.10.13.2 next update)" "" "declined with unchanged facts is not re-asked"
eq "$(migrations_select 2026.10.13.2 next install)" "" "declined is not re-asked on install"
sha="$(python3 -I -B -c 'import json,sys;print(json.load(open(sys.argv[1]))["migrations"][sys.argv[2]]["facts_sha256"])' \
  "$TARGET_DIR/.tools/agent-state/project-knowledge.json" "$UNTRACK")"
eq "$sha" "$(printf '%s' "$(migrations_facts "$UNTRACK")" | python3 -I -B -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" "facts hash"
eq "$(git -C "$TARGET_DIR" ls-files | grep -c '^AGENTS.md$')" "1" "declined leaves the index alone"
git -C "$TARGET_DIR" add -f CLAUDE.md
eq "$(migrations_select 2026.10.13.2 next update)" "$UNTRACK" "changed facts re-ask a declined decision"
migrations_run 2026.10.13.2 next update "" "" || fail "re-ask run"
eq "$(cut -f2 <<<"$(result_line "$UNTRACK")")" "pending" "re-asked decision is pending"

# -------------------------------------------------------- ignore block move
new_target
printf 'node_modules/\n' >"$TARGET_DIR/.gitignore"
gen --ignore-target gitignore --force
grep -Fq "$MARKER" "$TARGET_DIR/.gitignore" || fail "setup: block must be in .gitignore"
git -C "$TARGET_DIR" add .gitignore
git -C "$TARGET_DIR" commit -q -m seed
exclude="$(git -C "$TARGET_DIR" rev-parse --git-path info/exclude)"; case "$exclude" in /*) ;; *) exclude="$TARGET_DIR/$exclude" ;; esac
if [[ -f "$exclude" ]] && grep -Fq "$MARKER" "$exclude"; then fail "setup: exclude must not hold the block yet"; fi
eq "$(migrations_select 2026.10.13.2 next update)" "$TOEXCL" "ignore-block selected"
eq "$(migrations_facts "$TOEXCL")" "the local-only ignore block is in .gitignore" "ignore-block facts"
migrations_run 2026.10.13.2 next update "" ""
eq "$(cut -f2 <<<"$(result_line "$TOEXCL")")" "pending" "ignore-block pending"
eq "$(grep -c 'multi-agent' "$TARGET_DIR/.gitignore")" "2" "pending leaves .gitignore alone"
migrations_run 2026.10.13.2 next update "$TOEXCL" ""
eq "$(cut -f2 <<<"$(result_line "$TOEXCL")")" "applied" "ignore-block applied"
eq "$(cat "$TARGET_DIR/.gitignore")" "node_modules/" ".gitignore keeps only the user's lines"
grep -Fq "$MARKER" "$exclude" || fail "block must land in the exclude file"
git -C "$TARGET_DIR" check-ignore -q AGENTS.md || fail "AGENTS.md must stay ignored"
eq "$(python3 -I "$KNOW" --target "$TARGET_DIR" ignore-target)" "exclude" "knowledge records the exclude target"
[[ -f "$JOURNAL_DIR/migrations/$TOEXCL/.gitignore" ]] || fail ".gitignore backup missing"
grep -Fq "$MARKER" "$JOURNAL_DIR/migrations/$TOEXCL/.gitignore" || fail "backup must hold the original block"
eq "$(migrations_select 2026.10.13.2 next update)" "" "ignore-block no longer needed"
before="$(state_hash)"
migrations_run 2026.10.13.2 next update "$TOEXCL" ""
eq "$(state_hash)" "$before" "second ignore-block run changes nothing"
eq "$(grep -Fc "$MARKER" "$exclude")" "1" "block not duplicated"

# A stale .gitignore block: generation leaves .gitignore alone and writes the
# current block to the exclude file; the migration then only removes the
# .gitignore block, leaving one current block in the exclude file.
new_target
printf 'node_modules/\n' >"$TARGET_DIR/.gitignore"
gen --ignore-target gitignore --force --no-backup
python3 -I -B - "$TARGET_DIR/.gitignore" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
open(path, "w", encoding="utf-8").write("".join(l for l in lines if l.strip() != "scripts/harness-kit.sh"))
PY
git -C "$TARGET_DIR" add .gitignore
git -C "$TARGET_DIR" commit -q -m seed
stale_gitignore="$(cat "$TARGET_DIR/.gitignore")"
gen
exclude="$(git -C "$TARGET_DIR" rev-parse --git-path info/exclude)"; case "$exclude" in /*) ;; *) exclude="$TARGET_DIR/$exclude" ;; esac
eq "$(cat "$TARGET_DIR/.gitignore")" "$stale_gitignore" "generation leaves a stale .gitignore block alone"
grep -Fxq 'scripts/harness-kit.sh' "$exclude" || fail "generation writes the current block to the exclude file"
eq "$(migrations_select 2026.10.13.2 next update)" "$TOEXCL" "ignore-block still selected with both blocks"
migrations_run 2026.10.13.2 next update "$TOEXCL" ""
eq "$(cut -f2 <<<"$(result_line "$TOEXCL")")" "applied" "ignore-block applied with both blocks"
eq "$(cat "$TARGET_DIR/.gitignore")" "node_modules/" "only the .gitignore block is removed"
eq "$(grep -Fc "$MARKER" "$exclude")" "1" "one block in the exclude file"
grep -Fxq 'scripts/harness-kit.sh' "$exclude" || fail "the exclude block stays current"
eq "$(migrations_select 2026.10.13.2 next update)" "" "ignore-block no longer needed after the move"

# Below the repository top level the block is anchored under the prefix.
new_target
git -C "$TARGET_DIR" commit -q --allow-empty -m seed
sub="$TARGET_DIR/apps/a"; mkdir -p "$sub"
TARGET_DIR="$sub"; export TARGET_DIR
gen --ignore-target gitignore
eq "$(migrations_select 2026.10.13.2 next update)" "$TOEXCL" "sub-project ignore-block selected"
migrations_run 2026.10.13.2 next update "$TOEXCL" ""
exclude="$(git -C "$sub" rev-parse --git-path info/exclude)"; case "$exclude" in /*) ;; *) exclude="$sub/$exclude" ;; esac
grep -Fxq "$MARKER apps/a/" "$exclude" || fail "marker must carry the prefix: $(cat "$exclude")"
git -C "$sub" check-ignore -q AGENTS.md || fail "sub-project AGENTS.md must be ignored"
[[ ! -f "$sub/.gitignore" ]] || ! grep -Fq "$MARKER" "$sub/.gitignore" || fail "block must leave .gitignore"

# ----------------------------------------------------- stubbed kit copies
make_stub_kit() {
  STUB_KIT="$TMP_ROOT/kit$1"
  rm -rf "$STUB_KIT"
  mkdir -p "$STUB_KIT/lib" "$STUB_KIT/migrations"
  cp "$KIT/lib/migrations.sh" "$KIT/lib/knowledge.py" "$STUB_KIT/lib/"
  cp "$KIT"/lib/render.sh "$STUB_KIT/lib/" 2>/dev/null || true
}
stub_migration() { # file id since kind needed-file
  cat >"$STUB_KIT/migrations/$1.sh" <<STUB
MIGRATION_ID=$2
MIGRATION_SINCE=$3
MIGRATION_KIND=$4
MIGRATION_SUMMARY="stub $2"
migration_needed() { [ -f "\$TARGET_DIR/$5" ]; }
migration_describe() { echo "facts of $2"; }
migration_apply() { migration_backup "$5"; rm -f "\$TARGET_DIR/$5"; echo "\$MIGRATION_ID" >>"\$TARGET_DIR/applied.log"; }
STUB
}

# Selection order: version, then name, `next` last; ranges FROM < SINCE <= TO.
new_target
make_stub_kit 1
KIT_DIR="$STUB_KIT"; export KIT_DIR
for f in a b c d e; do : >"$TARGET_DIR/n-$f"; done
stub_migration next-aaa next-aaa next auto n-a
stub_migration 2026.10.13.2-zzz 2026.10.13.2-zzz 2026.10.13.2 auto n-b
stub_migration 2026.10.13.2-bbb 2026.10.13.2-bbb 2026.10.13.2 auto n-c
stub_migration 2026.09.01.1-old 2026.09.01.1-old 2026.09.01.1 auto n-d
stub_migration 2026.10.14.1-late 2026.10.14.1-late 2026.10.14.1 auto n-e
eq "$(migrations_select 2026.09.01.1 next update | tr '\n' ' ')" "2026.10.13.2-bbb 2026.10.13.2-zzz 2026.10.14.1-late next-aaa " "order with FROM exclusive"
eq "$(migrations_select 2026.09.01.0 2026.10.13.2 update | tr '\n' ' ')" "2026.09.01.1-old 2026.10.13.2-bbb 2026.10.13.2-zzz " "TO inclusive, next excluded"
eq "$(migrations_select 2026.10.14.1 next update | tr '\n' ' ')" "next-aaa " "FROM equal to SINCE is excluded"
eq "$(migrations_select 2026.09.01.0 next install)" "" "install selects no auto migrations"
# Auto migrations run, in order; a failing one stops the rest.
stub_migration 2026.10.13.2-fail 2026.10.13.2-fail 2026.10.13.2 auto n-b
cat >>"$STUB_KIT/migrations/2026.10.13.2-fail.sh" <<'STUB'
migration_apply() { return 3; }
STUB
rm "$STUB_KIT/migrations/2026.10.13.2-zzz.sh"
rc=0; migrations_run 2026.09.01.1 next update "" "" || rc=$?
[[ "$rc" -ne 0 ]] || fail "a failing migration must return non-zero"
eq "$(cut -f1,2 "$MIGRATIONS_RESULT_FILE" | tr '\t\n' '::')" "2026.10.13.2-bbb:applied:2026.10.13.2-fail:failed:" "outcomes so far are reported, rest not run"
eq "$(cat "$TARGET_DIR/applied.log")" "2026.10.13.2-bbb" "only migrations before the failure ran"
[[ -f "$JOURNAL_DIR/migrations/2026.10.13.2-bbb/n-c" ]] || fail "migration_backup copies into the journal"
has "$(migrations_report)" "2026.10.13.2-bbb"$'\t'"applied"$'\t'"stub 2026.10.13.2-bbb"$'\t'"facts of 2026.10.13.2-bbb" "report line"

# Pending decisions from knowledge join an update outside the version range.
new_target
make_stub_kit 2
KIT_DIR="$STUB_KIT"; export KIT_DIR
: >"$TARGET_DIR/n-a"
stub_migration 2026.01.01.1-old 2026.01.01.1-old 2026.01.01.1 decision n-a
eq "$(migrations_select 2026.10.13.2 next update)" "" "out-of-range decision is not newly asked"
python3 -I "$KNOW" --target "$TARGET_DIR" decision 2026.01.01.1-old --status pending --facts-sha256 abc
eq "$(migrations_select 2026.10.13.2 next update)" "2026.01.01.1-old" "pending decision joins an update"
eq "$(migrations_select "" next install)" "2026.01.01.1-old" "pending decision joins an install"
rm "$TARGET_DIR/n-a"
eq "$(migrations_select 2026.10.13.2 next update)" "" "a pending decision that is no longer needed is dropped"

# --------------------------------------------------------- retire files
new_target
make_stub_kit 3
KIT_DIR="$STUB_KIT"; export KIT_DIR
cp "$KIT/migrations/next-retire-files.sh" "$STUB_KIT/migrations/" 2>/dev/null || fail "next-retire-files.sh missing"
cat >"$STUB_KIT/bootstrap-multi-agent-project.sh" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" --retirement-plan "*)
    if [ -f "$STUB_STATE" ]; then
      printf '{"entries":[{"id":"a","path":"x","action":"none"},{"id":"b","path":"y","action":"none"}]}\n'
    else
      printf '{"entries":[{"id":"a","path":"x","action":"retire"},{"id":"b","path":"y","action":"retire"},{"id":"c","path":"z","action":"none"}]}\n'
    fi ;;
  *" --apply-retirements "*) : >"$STUB_STATE"; echo "$*" >"$STUB_STATE.args" ;;
  *) exit 9 ;;
esac
STUB
export STUB_STATE="$TMP_ROOT/retired.flag"
eq "$(migrations_select 2026.10.13.2 next update)" "$RETIRE" "retire selected when the plan lists actions"
eq "$(migrations_facts "$RETIRE")" "2 retired kit files can be removed" "retire facts"
migrations_run 2026.10.13.2 next update "" ""
eq "$(cut -f2 <<<"$(result_line "$RETIRE")")" "pending" "retire pending"
[[ ! -e "$STUB_STATE" ]] || fail "pending must not apply"
migrations_run 2026.10.13.2 next update "$RETIRE" ""
eq "$(cut -f2 <<<"$(result_line "$RETIRE")")" "applied" "retire applied"
has "$(cat "$STUB_STATE.args")" "--apply-retirements" "retire runs --apply-retirements"
has "$(cat "$STUB_STATE.args")" "--target $TARGET_DIR" "retire targets the project"
eq "$(migrations_select 2026.10.13.2 next update)" "" "retire no longer needed"
rm -f "$STUB_STATE"
# A real generated project with no retired files does not select it.
new_target
gen
eq "$(KIT_DIR="$KIT" migrations_select 2026.10.13.2 next update)" "" "no retired files in a fresh project"

printf 'harness-migrations-test: ok\n'
