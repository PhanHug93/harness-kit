#!/usr/bin/env bash
set -euo pipefail

# The Claude hook runs before every Bash, Edit, Write, MultiEdit and
# NotebookEdit call, so its process count is a budget: python3 and git starts
# per call are counted through PATH shims on a fresh full target. Also checked:
#   - json_escape matches json.dumps;
#   - a planted json.py is never imported;
#   - the context pack is rewritten only when its content changes;
#   - edit paths canonicalise as before (scripts/test-edit-guard-hosts.sh
#     covers the inside, escape and outside cases).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
work="$(cd "$work" && pwd -P)"
fail() { echo "hook-hot-path: FAIL: $*" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

target="$work/target"
mkdir -p "$target" "$work/shim" "$work/outside"
bash "$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null
mkdir -p "$target/src"
printf 'x\n' >"$target/src/main.txt"
git -C "$target" init -q
git -C "$target" add -A
git -C "$target" -c user.name=hot -c user.email=hot@example.invalid commit -qm init
for tool in python3 git; do
  real="$(command -v "$tool")"
  # shellcheck disable=SC2016 # the shim expands these when it runs
  printf '#!/bin/bash\nprintf "x\\n" >>"$HOT_PATH_LOG.%s"\nexec "%s" "$@"\n' "$tool" "$real" >"$work/shim/$tool"
  chmod +x "$work/shim/$tool"
done

count() { if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
# Usage: run_hook NAME JSON [ENV=VALUE...]; sets RC, PY, GIT, OUT and ERR.
run_hook() {
  local name="$1" input="$2" log="$work/count.$1"
  shift 2
  RC=0
  (cd "$target" && printf '%s' "$input" | env HOT_PATH_LOG="$log" CLAUDE_PROJECT_DIR="$target" PATH="$work/shim:$PATH" "$@" \
    scripts/agent-hook.sh claude-pretool >"$work/$name.out" 2>"$work/$name.err") || RC=$?
  PY="$(count "$log.python3")"
  GIT="$(count "$log.git")"
  OUT="$(cat "$work/$name.out")"
  ERR="$(cat "$work/$name.err")"
  printf 'hook-hot-path: %-15s rc=%s python3=%s git=%s\n' "$name" "$RC" "$PY" "$GIT"
}
budget() { # NAME PY_MAX GIT_MAX
  [[ "$PY" -le "$2" ]] || fail "$1: $PY python3 starts (budget $2)"
  [[ "$GIT" -le "$3" ]] || fail "$1: $GIT git starts (budget $3)"
}

# 1. Process budgets per hook call: the measured count plus one, under the
#    design caps (Bash 2 python3 / 3 git, Edit 6 / 6). Before: Bash 75 / 16, Edit 89 / 24.
run_hook bash '{"session_id":"hot1","tool_name":"Bash","tool_input":{"command":"ls"}}'
[[ "$RC" -eq 0 && -z "$OUT" ]] || fail "Bash call: rc=$RC out=$OUT err=$ERR"
budget bash 2 3
run_hook edit '{"session_id":"hot1","tool_name":"Edit","tool_input":{"file_path":"'"$target"'/src/main.txt"}}'
[[ "$RC" -eq 0 ]] || fail "unprotected Edit: rc=$RC err=$ERR"
has "$OUT" "protected_path=false" "unprotected Edit classification"
budget edit 4 3
protected='{"session_id":"hot1","tool_name":"Edit","tool_input":{"file_path":"'"$target"'/docs/agent-configs/project-brief.md"}}'
run_hook protected-ack "$protected" AGENT_GUARD_EDIT_ACK="hot path test"
[[ "$RC" -eq 0 ]] || fail "protected Edit with ack: rc=$RC err=$ERR"
run_hook protected-log "$protected"
[[ "$RC" -eq 0 ]] || fail "protected Edit from the ack log: rc=$RC err=$ERR"
has "$OUT" "ack_source=log" "protected Edit uses the ack log"
budget protected-log 5 3
run_hook protected-deny '{"session_id":"hot1","tool_name":"Write","tool_input":{"file_path":"'"$target"'/AGENTS.md"}}'
[[ "$RC" -eq 2 ]] || fail "protected Write without ack must exit 2: rc=$RC err=$ERR"
run_hook notebook '{"session_id":"hot1","tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$target"'/src/n.ipynb"}}'
[[ "$RC" -eq 0 ]] || fail "unprotected NotebookEdit: rc=$RC err=$ERR"
budget notebook 4 3
run_hook outside '{"session_id":"hot1","tool_name":"Write","tool_input":{"file_path":"'"$work"'/outside/x.txt"}}'
[[ "$RC" -eq 0 ]] || fail "outside Write: rc=$RC err=$ERR"
budget outside 4 3
# The Codex hook runs one parser and one pre-edit per patch path (measured
# 4 python3 / 0 git for three files).
patch=$'*** Begin Patch\n*** Add File: src/a.txt\n+a\n*** Update File: src/main.txt\n@@\n-x\n+y\n*** Add File: src/b.txt\n+b\n*** End Patch\n'
codex_input="$(PATCH="$patch" CWD="$target" python3 -I -S -c 'import json, os; print(json.dumps({"tool_name": "apply_patch", "cwd": os.environ["CWD"], "tool_input": {"command": os.environ["PATCH"]}}))')"
log="$work/count.codex"
RC=0
(cd "$target" && printf '%s' "$codex_input" | env HOT_PATH_LOG="$log" PATH="$work/shim:$PATH" \
  scripts/agent-hook.sh codex-pretool >"$work/codex.out" 2>"$work/codex.err") || RC=$?
PY="$(count "$log.python3")"
GIT="$(count "$log.git")"
printf 'hook-hot-path: %-15s rc=%s python3=%s git=%s\n' "codex-3-files" "$RC" "$PY" "$GIT"
[[ "$RC" -eq 0 ]] || fail "Codex three-file patch: rc=$RC err=$(cat "$work/codex.err")"
budget codex-3-files 5 1

# 2. json_escape matches json.dumps(value, ensure_ascii=False)[1:-1].
eval "$(sed -n '/^json_escape() {/,/^}/p' "$target/scripts/agent-guard.sh")"
corpus=("" "plain" "quote \" and backslash \\" $'tab\tnew\nline\rcr' $'bell\a form\f back\b' $'del\177' 'đồng ý ✓ 日本')
for code in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
  # shellcheck disable=SC2059 # the format is the octal escape for this code
  printf -v char "\\$(printf '%03o' "$code")"
  corpus+=("a${char}b")
done
for value in "${corpus[@]}"; do
  want="$(VALUE="$value" python3 -I -S -c 'import json, os, sys; sys.stdout.write(json.dumps(os.environ["VALUE"], ensure_ascii=False)[1:-1])')"
  got="$(json_escape "$value")"
  [[ "$got" == "$want" ]] || fail "json_escape $(printf '%q' "$value"): got $(printf '%q' "$got"), want $(printf '%q' "$want")"
done

# 3. A json.py in the project root is never imported by the guard or the hook.
printf 'import pathlib\npathlib.Path(__file__).with_name("json-imported").touch()\n' >"$target/json.py"
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null 2>&1) || true
run_hook planted-bash '{"session_id":"hot1","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_hook planted-edit '{"session_id":"hot1","tool_name":"Edit","tool_input":{"file_path":"'"$target"'/src/main.txt"}}'
[[ ! -e "$target/json-imported" ]] || fail "a project json.py was imported by kit python"
rm -f "$target/json.py" "$target/json-imported"

# 4. The context pack is rewritten only when its content changes.
pack="$target/.agents/state/context-pack.json"
# The pack's inode and generated_at: both stay when the pack is not rewritten.
# shellcheck disable=SC2012 # one known file name; ls -i is portable, stat is not
pack_state() { printf '%s %s' "$(ls -i "$pack" | awk '{print $1}')" "$(grep -o '"generated_at":"[^"]*"' "$pack")"; }
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null)
before="$(pack_state)"
sleep 1
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null)
after="$(pack_state)"
[[ "$before" == "$after" ]] || fail "unchanged context rewrote the pack: $before -> $after"
printf '\n<!-- hot path -->\n' >>"$target/AGENTS.md"
(cd "$target" && scripts/agent-guard.sh preflight >/dev/null)
changed="$(pack_state)"
[[ "$changed" != "$after" ]] || fail "changed required context did not rewrite the pack"
(cd "$target" && scripts/agent-guard.sh check >/dev/null) || fail "check failed after the pack refresh"

# 5. Edit paths canonicalise as before.
ln -s src "$target/linkdir"
ln -s "$work/outside" "$target/out-link"
canon() { (cd "$target" && scripts/agent-guard.sh pre-edit --advisory "$1" 2>&1) || true; }
has "$(canon src/main.txt)" "path=src/main.txt" "relative path"
has "$(canon "$target/src/../src/main.txt")" "path=src/main.txt" "absolute path with .."
has "$(canon linkdir/main.txt)" "path=src/main.txt" "symlink inside the root"
has "$(canon src/missing.txt)" "path=src/missing.txt" "missing file"
has "$(canon out-link/x.txt)" "path escapes the project root" "symlink out of the root"
has "$(canon ../x.txt)" "path escapes the project root" "dot-dot out of the root"
has "$(canon "$work/outside/x.txt")" "outside_project=true" "absolute path outside the root"
# 6. guard-local-state asks git once for every local-only pattern (it runs at
#    every Codex launch), and still names the pattern of a tracked file.
log="$work/count.local-state"
(cd "$target" && HOT_PATH_LOG="$log" PATH="$work/shim:$PATH" scripts/agent-hook.sh guard-local-state) ||
  fail "guard-local-state failed on a clean target"
GIT="$(count "$log.git")"
printf 'hook-hot-path: %-15s git=%s\n' "local-state" "$GIT"
[[ "$GIT" -le 2 ]] || fail "guard-local-state: $GIT git starts (budget 2)"
printf 'local\n' >"$target/CLAUDE.local.md"
git -C "$target" add -f CLAUDE.local.md
RC=0
(cd "$target" && scripts/agent-hook.sh guard-local-state >"$work/local.out" 2>&1) || RC=$?
[[ "$RC" -ne 0 ]] || fail "guard-local-state accepted a tracked CLAUDE.local.md"
has "$(cat "$work/local.out")" "local-only agent state is tracked: CLAUDE.local.md" "guard-local-state names the pattern"
git -C "$target" rm -q --cached CLAUDE.local.md
echo "hook-hot-path: ok"
