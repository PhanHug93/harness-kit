#!/usr/bin/env bash
set -euo pipefail

# Edit paths through the Claude hook on a fresh full target:
#   - a path outside the project goes to Claude Code (exit 0), except agent
#     instructions or config (Claude and Codex homes, ~/.agents, another
#     repository's agent files), which ask the user; this project's own
#     auto-memory Markdown is written directly;
#   - a symlink or ".." out of the project blocks (exit 2), also through an
#     alias of the root;
#   - a path outside that resolves inside is checked as inside;
#   - a broken policy blocks even an outside path;
#   - NotebookEdit is guarded.
# Then the Codex hook applies the same rules to every apply_patch path, also
# reads an ack written from the Codex sandbox, and the Codex doctor warns until
# Codex trusts the hook.
# scripts/test-workspace-repository-guard.py covers the cross-repo question.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
key=""
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; [[ -z "$key" ]] || rm -rf "/tmp/agent-bootstrap-state/$key"' EXIT
work="$(cd "$work" && pwd -P)"
fail() { echo "edit-guard-hosts: FAIL: $*" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
hasnt() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

target="$work/target"
mkdir -p "$target" "$work/outside" "$work/tmp"
bash "$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null
mkdir -p "$target/src"
printf 'x\n' >"$target/src/main.txt"
git -C "$target" init -q
git -C "$target" add -A
git -C "$target" -c user.name=t -c user.email=t@example.invalid commit -qm init
ln -s "$work/outside" "$target/out-link"
ln -s "$target" "$work/alias"
slug="$(printf '%s' "$target" | tr -c 'A-Za-z0-9' '-')"
# Fake Claude and Codex homes, so the user's own are never named.
claude_home="$work/home/.claude"
codex_home="$work/home/.codex"
mkdir -p "$claude_home/projects/$slug/memory" "$codex_home" "$work/other-repo"

# Usage: claude NAME TOOL KEY PATH [ENV=VALUE...]; sets RC, OUT and ERR.
claude() {
  local name="$1" tool="$2" key="$3" path="$4" input
  shift 4
  input="$(python3 -I -S -c 'import json, sys; print(json.dumps({"session_id": "e1", "tool_name": sys.argv[1], "tool_input": {sys.argv[2]: sys.argv[3]}}))' "$tool" "$key" "$path")"
  RC=0
  (cd "$target" && printf '%s' "$input" | env -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID \
    CLAUDE_PROJECT_DIR="$target" CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" "$@" \
    scripts/agent-hook.sh claude-pretool >"$work/$name.out" 2>"$work/$name.err") || RC=$?
  OUT="$(cat "$work/$name.out")"
  ERR="$(cat "$work/$name.err")"
  printf 'edit-guard-hosts: claude %-18s rc=%s\n' "$name" "$RC"
}
allowed_outside() { # NAME
  [[ "$RC" -eq 0 ]] || fail "$1: an outside path must reach the host: rc=$RC err=$ERR"
  has "$OUT" "outside_project=true" "$1 classification"
  hasnt "$ERR" "edit blocked" "$1"
}
asked() { # NAME
  [[ "$RC" -eq 0 ]] || fail "$1: agent instructions must ask, not block: rc=$RC err=$ERR"
  has "$OUT" '"permissionDecision": "ask"' "$1 asks the user"
  has "$OUT" "agent instructions or config outside this project" "$1 ask reason"
}
blocked() { # NAME TEXT
  [[ "$RC" -eq 2 ]] || fail "$1: must block: rc=$RC err=$ERR"
  has "$ERR" "$2" "$1 reason"
}

# 1. Outside paths go to Claude Code; this project's auto memory is one.
claude memory-own Write file_path "$claude_home/projects/$slug/memory/MEMORY.md"
allowed_outside memory-own
claude scratchpad Write file_path "$work/tmp/claude-501/$slug/e1/scratchpad/x.md"
allowed_outside scratchpad
claude elsewhere Edit file_path "$work/outside/settings.json"
allowed_outside elsewhere
claude multi MultiEdit file_path "$work/outside/m.txt"
allowed_outside multi

# 2. Agent instructions or config outside the project ask the user.
claude memory-other Write file_path "$claude_home/projects/-x-android/memory/note.md"
asked memory-other
claude memory-not-md Write file_path "$claude_home/projects/$slug/memory/hook.json"
asked memory-not-md
claude claude-settings Edit file_path "$claude_home/settings.json"
asked claude-settings
claude claude-global Write file_path "$claude_home/CLAUDE.md"
asked claude-global
claude codex-config Edit file_path "$codex_home/config.toml"
asked codex-config
claude codex-agents Write file_path "$codex_home/AGENTS.md"
asked codex-agents
claude repo-agents Write file_path "$work/other-repo/AGENTS.md"
asked repo-agents
claude repo-codex Write file_path "$work/other-repo/.codex/hooks.json"
asked repo-codex
claude repo-githook Write file_path "$work/other-repo/.git/hooks/pre-commit"
asked repo-githook
# A case-insensitive volume opens agents.md as AGENTS.md, so names fold.
claude repo-agents-case Write file_path "$work/other-repo/agents.md"
asked repo-agents-case
claude codex-home-case Write file_path "$work/home/.CODEX/config.toml"
asked codex-home-case
ln -s "$codex_home/AGENTS.md" "$claude_home/projects/$slug/memory/link.md"
claude memory-link Write file_path "$claude_home/projects/$slug/memory/link.md"
asked memory-link
claude nb-instructions NotebookEdit notebook_path "$codex_home/n.ipynb"
asked nb-instructions
# Claude's user config, another repository's MCP servers and git config (hooks
# and fsmonitor run code) are agent config too.
user_env=(HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config")
claude claude-json Write file_path "$work/home/.claude.json" "${user_env[@]}"
asked claude-json
claude repo-mcp Write file_path "$work/other-repo/.mcp.json"
asked repo-mcp
claude repo-gitconfig Edit file_path "$work/other-repo/.git/config"
asked repo-gitconfig
claude user-gitconfig Edit file_path "$work/home/.gitconfig" "${user_env[@]}"
asked user-gitconfig
claude xdg-gitconfig Edit file_path "$work/home/.config/git/config" "${user_env[@]}"
asked xdg-gitconfig
# A failure on the ask path must not let the write through (Claude Code only
# blocks on exit 2): a path that is not valid UTF-8 still asks.
claude bad-utf8 Write file_path "$codex_home/x$(printf '\377').toml" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
asked bad-utf8
printf '%s' '{"session_id": "e1", "tool_name": "Write", "tool_input": {"file_path": "'"$codex_home"'/x\ud800.toml"}}' >"$work/surrogate.json"
RC=0
(cd "$target" && env -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID CLAUDE_PROJECT_DIR="$target" \
  CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" \
  scripts/agent-hook.sh claude-pretool <"$work/surrogate.json" >"$work/surrogate.out" 2>"$work/surrogate.err") || RC=$?
OUT="$(cat "$work/surrogate.out")"
ERR="$(cat "$work/surrogate.err")"
printf 'edit-guard-hosts: claude %-18s rc=%s\n' lone-surrogate "$RC"
asked lone-surrogate

# 3. Escapes from the project block.
claude symlink-out Write file_path "$target/out-link/x.txt"
blocked symlink-out "escapes the project root"
claude dotdot-out Write file_path "$target/../x.txt"
blocked dotdot-out "escapes the project root"
claude alias-out Write file_path "$work/alias/out-link/x.txt"
blocked alias-out "escapes the project root"
# A ".." after a link names one file for the guard (real path) and another for
# a host that drops ".." as text (macOS /var and /tmp are links): block it.
mkdir -p "$work/deep/dir"
ln -s "$work/deep/dir" "$work/hop"
claude hop-protected Write file_path "$work/hop/../target/scripts/agent-hook.sh"
blocked hop-protected "escapes the project root"
claude hop-plain Write file_path "$work/hop/../target/src/x.txt"
blocked hop-plain "escapes the project root"
# On a case-insensitive volume the root under another case is the project
# (found by inode), and a file is matched by its name on disk.
if [[ "$work/TARGET" -ef "$target" ]]; then
  claude case-root Write file_path "$work/TARGET/CLAUDE.md"
  blocked case-root "protected path"
  claude case-file Write file_path "$target/claude.md"
  blocked case-file "protected path"
  claude case-out Write file_path "$work/TARGET/out-link/x.txt"
  blocked case-out "escapes the project root"
else
  echo "edit-guard-hosts: case-sensitive volume; case-variant cases skipped"
fi

# 4. A path outside that resolves inside is checked as inside. Acks last an
#    hour per path, so the un-acked cases run first.
claude alias-protected Write file_path "$work/alias/AGENTS.md"
blocked alias-protected "DENIED: protected path"
claude dotdot-protected Write file_path "$work/outside/../target/AGENTS.md"
blocked dotdot-protected "DENIED: protected path"
claude alias-acked Write file_path "$work/alias/AGENTS.md" AGENT_GUARD_EDIT_ACK="edit guard test"
[[ "$RC" -eq 0 ]] || fail "acked protected path through an alias: rc=$RC err=$ERR"
claude inside Edit file_path "$target/src/main.txt"
[[ "$RC" -eq 0 ]] || fail "inside path: rc=$RC err=$ERR"
has "$OUT" "protected_path=false" "inside classification"

# 5. A broken policy blocks even an outside path.
policy="$target/docs/agent-configs/context-policy.json"
cp "$policy" "$work/policy.saved"
printf '%s\n' '{ malformed policy' >"$policy"
claude broken-policy Write file_path "$work/outside/x.txt"
blocked broken-policy "edit blocked"
cp "$work/policy.saved" "$policy"

# 6. NotebookEdit is guarded.
has "$(cat "$target/.claude/settings.json")" '"matcher": "Edit|Write|MultiEdit|NotebookEdit"' "settings matcher"
mkdir -p "$target/src/deep"
# Claude Code runs a hook command in the session's current directory, which a
# `cd` moves: every command in settings.json must start the hook from a
# subdirectory too (CLAUDE_PROJECT_DIR is the project root), and the edit
# guard must still block there.
settings_commands="$(python3 -I -S -c 'import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
for event in hooks:
    for group in hooks[event]:
        for hook in group["hooks"]:
            print(event + "\t" + hook["command"])' "$target/.claude/settings.json")"
[[ "$(grep -c . <<<"$settings_commands")" -eq 4 ]] || fail "settings.json: four hook commands expected: $settings_commands"
while IFS=$'\t' read -r event command; do
  case "$event" in
    PreToolUse) input="$(python3 -I -S -c 'import json, sys; print(json.dumps({"session_id": "sub1", "tool_name": "Edit", "tool_input": {"file_path": sys.argv[1]}}))' "$target/AGENTS.md")" ;;
    *) input='{"session_id":"sub1","stop_hook_active":true}' ;;
  esac
  RC=0
  (cd "$target/src/deep" && printf '%s' "$input" | env -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID \
    CLAUDE_PROJECT_DIR="$target" CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" \
    sh -c "$command" >"$work/sub.out" 2>"$work/sub.err") || RC=$?
  [[ "$RC" -ne 126 && "$RC" -ne 127 ]] || fail "$event hook does not start from a subdirectory (rc=$RC): $command: $(cat "$work/sub.err")"
  if [[ "$event" == PreToolUse ]]; then
    # The guard judged the path: it blocks (2), or passes an edit that an
    # earlier case of this suite acknowledged (0).
    [[ "$RC" -eq 2 || "$RC" -eq 0 ]] || fail "the edit guard from a subdirectory: rc=$RC: $(cat "$work/sub.out" "$work/sub.err")"
    grep -qF 'protected_path=true' "$work/sub.out" "$work/sub.err" \
      || fail "the edit guard must judge a protected file from a subdirectory (rc=$RC): $(cat "$work/sub.out" "$work/sub.err")"
  else
    [[ "$RC" -eq 0 ]] || fail "$event hook from a subdirectory: rc=$RC: $(cat "$work/sub.err")"
  fi
done <<<"$settings_commands"
# A settings.json kept from an older kit still has the relative path: the
# verifier warns, because those hooks stop after the agent changes directory.
cp "$target/.claude/settings.json" "$work/settings.keep"
# shellcheck disable=SC2016  # a literal $CLAUDE_PROJECT_DIR
python3 -I -S -c 'import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace("\\\"$CLAUDE_PROJECT_DIR\\\"/scripts/", "./scripts/"))' "$target/.claude/settings.json"
grep -qF '"command": "./scripts/agent-hook.sh claude-pretool"' "$target/.claude/settings.json" || fail "fixture: the relative path was not written"
relative_warns="$({ cd "$target" && scripts/verify-ai-deps.sh --json 2>/dev/null; } | python3 -I -S -c 'import json, sys
print(sum(1 for c in json.load(sys.stdin)["checks"] if c.get("status") == "warn" and "relative path" in c.get("label", "")))' || true)"
[[ "$relative_warns" == 1 ]] || fail "the verifier must warn about relative hook paths (got: $relative_warns)"
cp "$work/settings.keep" "$target/.claude/settings.json"
relative_warns="$({ cd "$target" && scripts/verify-ai-deps.sh --json 2>/dev/null; } | python3 -I -S -c 'import json, sys
print(sum(1 for c in json.load(sys.stdin)["checks"] if c.get("status") == "warn" and "relative path" in c.get("label", "")))' || true)"
[[ "$relative_warns" == 0 ]] || fail "the generated settings.json must not get the relative-path warning"
claude nb-protected NotebookEdit notebook_path "$target/.claude/commands/x.ipynb"
blocked nb-protected "DENIED: protected path"
claude nb-inside NotebookEdit notebook_path "$target/src/n.ipynb"
[[ "$RC" -eq 0 ]] || fail "unprotected notebook: rc=$RC err=$ERR"
has "$OUT" "protected_path=false" "notebook classification"
claude nb-outside NotebookEdit notebook_path "$work/outside/n.ipynb"
allowed_outside nb-outside
claude nb-symlink NotebookEdit notebook_path "$target/out-link/n.ipynb"
blocked nb-symlink "escapes the project root"
# A Write larger than one environment variable may hold is still checked.
python3 -I -S -c 'import json, sys; print(json.dumps({"session_id": "e1", "tool_name": "Write", "tool_input": {"file_path": sys.argv[1], "content": "x" * 1300000}}))' "$target/CLAUDE.md" >"$work/big-write.json"
RC=0
(cd "$target" && env -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID CLAUDE_PROJECT_DIR="$target" \
  CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" \
  scripts/agent-hook.sh claude-pretool <"$work/big-write.json" >/dev/null 2>"$work/big-write.err") || RC=$?
ERR="$(cat "$work/big-write.err")"
printf 'edit-guard-hosts: claude %-18s rc=%s\n' large-protected "$RC"
blocked large-protected "DENIED: protected path"

# 7. Codex: every apply_patch path goes through the same rules.
python3 -m json.tool "$target/.codex/hooks.json" >/dev/null || fail ".codex/hooks.json is not JSON"
has "$(cat "$target/.codex/hooks.json")" 'codex-pretool' "Codex hooks file runs the guard"
# Usage: codex NAME PATCH [ENV=VALUE...]; sets RC and ERR.
codex() {
  local name="$1" patch="$2" input
  shift 2
  input="$(python3 -I -S -c 'import json, sys; print(json.dumps({"session_id": "c1", "hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "$patch" "$target")"
  RC=0
  (cd "$target" && printf '%s' "$input" | env CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" "$@" \
    scripts/agent-hook.sh codex-pretool >"$work/c-$name.out" 2>"$work/c-$name.err") || RC=$?
  ERR="$(cat "$work/c-$name.err")"
  printf 'edit-guard-hosts: codex  %-18s rc=%s\n' "$name" "$RC"
}
p() { printf '*** Begin Patch\n%s\n*** End Patch\n' "$1"; }
codex add "$(p '*** Add File: src/new.txt
+x')"
[[ "$RC" -eq 0 ]] || fail "codex add: rc=$RC err=$ERR"
codex update "$(p '*** Update File: src/main.txt
@@
-x
+y')"
[[ "$RC" -eq 0 ]] || fail "codex update: rc=$RC err=$ERR"
# The Claude part acked AGENTS.md, so the un-acked cases use other files.
codex protected "$(p '*** Add File: .github/workflows/x.yml
+x')"
[[ "$RC" -eq 2 ]] || fail "codex protected: rc=$RC err=$ERR"
has "$ERR" "DENIED: protected path" "codex protected reason"
codex many "$(p '*** Add File: src/a.txt
+a
*** Delete File: CLAUDE.md')"
[[ "$RC" -eq 2 ]] || fail "codex many: one protected path must block: rc=$RC err=$ERR"
codex move "$(p '*** Update File: src/main.txt
*** Move to: .claude/commands/m.md')"
[[ "$RC" -eq 2 ]] || fail "codex move into a protected path: rc=$RC err=$ERR"
codex outside "$(p "*** Add File: $work/outside/o.txt
+o")"
[[ "$RC" -eq 0 ]] || fail "codex outside: rc=$RC err=$ERR"
codex symlink "$(p '*** Add File: out-link/s.txt
+s')"
[[ "$RC" -eq 2 ]] || fail "codex symlink out: rc=$RC err=$ERR"
has "$ERR" "escapes the project root" "codex symlink reason"
(cd "$target" && scripts/agent-guard.sh pre-edit --ack "codex test" -- "$target/.github/workflows/x.yml" >/dev/null)
codex acked "$(p '*** Add File: .github/workflows/x.yml
+x')"
[[ "$RC" -eq 0 ]] || fail "codex acked: rc=$RC err=$ERR"
RC=0
printf '%s' '{"tool_name":"exec_command","tool_input":{"command":"ls"}}' |
  (cd "$target" && scripts/agent-hook.sh codex-pretool) || RC=$?
[[ "$RC" -eq 0 ]] || fail "codex tool other than apply_patch: rc=$RC"
RC=0
printf '%s' 'not json' | (cd "$target" && scripts/agent-hook.sh codex-pretool) 2>"$work/c-bad.err" || RC=$?
[[ "$RC" -eq 0 ]] || fail "codex malformed input: rc=$RC"
has "$(cat "$work/c-bad.err")" "not JSON" "codex malformed warning"

codex instructions "$(p "*** Add File: $codex_home/AGENTS.md
+x")"
[[ "$RC" -eq 2 ]] || fail "codex agent instructions outside: rc=$RC err=$ERR"
has "$ERR" "Codex hooks cannot ask" "codex instructions reason"
codex memory "$(p "*** Add File: $claude_home/projects/$slug/memory/codex.md
+x")"
[[ "$RC" -eq 0 ]] || fail "codex this project's auto memory: rc=$RC err=$ERR"
# A CRLF patch: CLAUDE.md must not become an unprotected "CLAUDE.md\r".
codex crlf-protected "$(p '*** Delete File: CLAUDE.md' | sed 's/$/\r/')"
[[ "$RC" -eq 2 ]] || fail "codex CRLF patch must still see CLAUDE.md: rc=$RC err=$ERR"
# Codex trims Unicode whitespace around a header: a trailing no-break space
# or an indent still names CLAUDE.md.
codex nbsp-protected "$(p "$(printf '*** Delete File: CLAUDE.md\302\240')")"
[[ "$RC" -eq 2 ]] || fail "codex header with a no-break space: rc=$RC err=$ERR"
codex indent-protected "$(p '   *** Delete File: CLAUDE.md')"
[[ "$RC" -eq 2 ]] || fail "codex indented header: rc=$RC err=$ERR"
codex instructions-case "$(p "*** Add File: $work/other-repo/agents.md
+x")"
[[ "$RC" -eq 2 ]] || fail "codex agents.md in another repository: rc=$RC err=$ERR"
codex hop-protected "$(p "*** Add File: $work/hop/../target/scripts/agent-x.sh
+x")"
[[ "$RC" -eq 2 ]] || fail "codex '..' after a link into a protected path: rc=$RC err=$ERR"
has "$ERR" "escapes the project root" "codex hop reason"
# Codex may expand "~"; check that path too.
codex tilde "$(p '*** Add File: ~/.codex/AGENTS.md
+x')" HOME="$work/home"
[[ "$RC" -eq 2 ]] || fail "codex ~/.codex/AGENTS.md: rc=$RC err=$ERR"
codex repo-gitconfig "$(p "*** Update File: $work/other-repo/.git/config
@@
+x")"
[[ "$RC" -eq 2 ]] || fail "codex another repository's .git/config: rc=$RC err=$ERR"
# Codex Edit and Write calls name the file in file_path.
codex_raw() { # NAME JSON [ENV=VALUE...]; sets RC and ERR
  local name="$1" input="$2"
  shift 2
  RC=0
  (cd "$target" && printf '%s' "$input" | env CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" "$@" \
    scripts/agent-hook.sh codex-pretool >"$work/c-$name.out" 2>"$work/c-$name.err") || RC=$?
  ERR="$(cat "$work/c-$name.err")"
  printf 'edit-guard-hosts: codex  %-18s rc=%s\n' "$name" "$RC"
}
codex_raw write-protected '{"tool_name": "Write", "cwd": "'"$target"'", "tool_input": {"file_path": "CLAUDE.md", "content": "x"}}'
[[ "$RC" -eq 2 ]] || fail "codex Write of a protected path: rc=$RC err=$ERR"
codex_raw edit-plain '{"tool_name": "Edit", "cwd": "'"$target"'", "tool_input": {"file_path": "'"$target"'/src/main.txt"}}'
[[ "$RC" -eq 0 ]] || fail "codex Edit of a plain path: rc=$RC err=$ERR"
# A NUL in a header must not end the path list before a protected header.
codex_raw nul-header "$(python3 -I -S -c 'import json, sys; print(json.dumps({"tool_name": "apply_patch", "cwd": sys.argv[1], "tool_input": {"command": "*** Begin Patch\n*** Update File: src/main.txt\n@@\n *** Update File: x\u0000\n*** Delete File: CLAUDE.md\n*** End Patch\n"}}))' "$target")"
[[ "$RC" -eq 2 ]] || fail "codex patch with a NUL before a protected header: rc=$RC err=$ERR"
# The 30 s hook timeout caps the paths one patch may name; repeats count once.
codex_raw too-many "$(python3 -I -S -c 'import json, sys; print(json.dumps({"tool_name": "apply_patch", "cwd": sys.argv[1], "tool_input": {"command": "*** Begin Patch\n" + "".join("*** Add File: src/p%d.txt\n+x\n" % i for i in range(101)) + "*** End Patch\n"}}))' "$target")"
[[ "$RC" -eq 2 ]] || fail "codex patch naming 101 paths: rc=$RC err=$ERR"
has "$ERR" "split the patch" "codex too-many reason"
codex_raw repeats "$(python3 -I -S -c 'import json, sys; print(json.dumps({"tool_name": "apply_patch", "cwd": sys.argv[1], "tool_input": {"command": "*** Begin Patch\n" + "*** Update File: src/main.txt\n@@\n-x\n+y\n" * 150 + "*** End Patch\n"}}))' "$target")"
[[ "$RC" -eq 0 ]] || fail "codex patch repeating one path: rc=$RC err=$ERR"
# A patch larger than one environment variable may hold is still checked.
python3 -I -S -c 'import json, sys; print(json.dumps({"session_id": "c1", "hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": sys.argv[1], "tool_input": {"command": "*** Begin Patch\n*** Add File: src/big.txt\n+" + "x" * 1300000 + "\n*** Delete File: CLAUDE.md\n*** End Patch\n"}}))' "$target" >"$work/big.json"
RC=0
(cd "$target" && env CLAUDE_CONFIG_DIR="$claude_home" CODEX_HOME="$codex_home" \
  scripts/agent-hook.sh codex-pretool <"$work/big.json" >/dev/null 2>"$work/c-big.err") || RC=$?
printf 'edit-guard-hosts: codex  %-18s rc=%s\n' large-protected "$RC"
[[ "$RC" -eq 2 ]] || fail "codex large patch: rc=$RC err=$(cat "$work/c-big.err")"

# Codex keeps .agents/ read-only in its sandbox, so an ack from a Codex shell
# lands in the state dir under TMPDIR, or /tmp when TMPDIR is unset. The hook
# runs outside the sandbox and must still find it, but only in a log that is
# yours and that nobody else can write.
config="$(cat "$target/.codex/config.toml")"
has "$config" 'inherit = "core"' "Codex shells keep PATH"
has "$config" '"TMPDIR"' "Codex shells keep TMPDIR"
key="$(printf '%s' "$target" | cksum | tr -d ' \t')"
sandbox_ack() { # TMPDIR-or-empty PATH
  local rc=0
  chmod a-w "$target/.agents/state"
  (cd "$target" && env -u AGENT_STATE_DIR -u TMPDIR ${1:+"TMPDIR=$1"} \
    scripts/agent-guard.sh pre-edit --ack "sandbox test" -- "$2" >/dev/null) || rc=$?
  chmod u+w "$target/.agents/state"
  [[ "$rc" -eq 0 ]] || fail "sandbox ack for $2: rc=$rc"
}
sandbox_ack "$work/tmp" "$target/.github/workflows/sandbox.yml"
tmp_log="$work/tmp/agent-bootstrap-state/$key/guard-ack.log"
[[ -f "$tmp_log" ]] || fail "the sandbox ack must land under TMPDIR: $tmp_log"
hasnt "$(cat "$target/.agents/state/guard-ack.log" 2>/dev/null || true)" "sandbox.yml" "sandbox ack in .agents/state"
codex sandbox-ack "$(p '*** Add File: .github/workflows/sandbox.yml
+x')" TMPDIR="$work/tmp"
[[ "$RC" -eq 0 ]] || fail "codex ack from the sandbox TMPDIR: rc=$RC err=$ERR"
sandbox_ack "" "$target/.github/workflows/shared.yml"
codex shared-tmp-ack "$(p '*** Add File: .github/workflows/shared.yml
+x')" TMPDIR="$work/tmp"
[[ "$RC" -eq 0 ]] || fail "codex ack from /tmp: rc=$RC err=$ERR"
sandbox_ack "$work/tmp" "$target/.github/workflows/loose.yml"
chmod g+w "$tmp_log"
codex loose-ack "$(p '*** Add File: .github/workflows/loose.yml
+x')" TMPDIR="$work/tmp"
chmod g-w "$tmp_log"
[[ "$RC" -eq 2 ]] || fail "codex ack in a log others can write: rc=$RC err=$ERR"
has "$ERR" "ignoring ack log" "codex loose ack warning"
# The same rules hold when the hook itself cannot write .agents/state and the
# temp log is its own state.
sandbox_ack "$work/tmp" "$target/.github/workflows/primary.yml"
chmod a-w "$target/.agents/state"
codex primary-temp "$(p '*** Add File: .github/workflows/primary.yml
+x')" TMPDIR="$work/tmp"
[[ "$RC" -eq 0 ]] || { chmod u+w "$target/.agents/state"; fail "codex private temp log as the hook's own state: rc=$RC err=$ERR"; }
chmod g+w "$tmp_log"
codex primary-loose "$(p '*** Add File: .github/workflows/primary.yml
+x')" TMPDIR="$work/tmp"
chmod g-w "$tmp_log"
chmod u+w "$target/.agents/state"
[[ "$RC" -eq 2 ]] || fail "codex loose temp log as the hook's own state: rc=$RC err=$ERR"
has "$ERR" "ignoring ack log" "codex primary loose warning"
# A link to a log elsewhere, or a state dir others can write, is not trusted.
mv "$tmp_log" "$work/moved-ack.log"
ln -s "$work/moved-ack.log" "$tmp_log"
codex link-ack "$(p '*** Add File: .github/workflows/sandbox.yml
+x')" TMPDIR="$work/tmp"
rm "$tmp_log"
mv "$work/moved-ack.log" "$tmp_log"
[[ "$RC" -eq 2 ]] || fail "codex ack log behind a link: rc=$RC err=$ERR"
chmod g+w "$(dirname "$tmp_log")"
codex loose-dir-ack "$(p '*** Add File: .github/workflows/sandbox.yml
+x')" TMPDIR="$work/tmp"
chmod g-w "$(dirname "$tmp_log")"
[[ "$RC" -eq 2 ]] || fail "codex ack in a state dir others can write: rc=$RC err=$ERR"
# Under umask 002 (Ubuntu, Fedora) the sandbox ack still makes private dirs,
# and an ack tightens a temp state dir of yours that an older release left
# open to the group.
mkdir -p "$work/tmp2" "$work/tmp3/agent-bootstrap-state/$key"
chmod 775 "$work/tmp3/agent-bootstrap-state" "$work/tmp3/agent-bootstrap-state/$key"
for dir in tmp2 tmp3; do
  rc=0
  chmod a-w "$target/.agents/state"
  (umask 002 && cd "$target" && env -u AGENT_STATE_DIR TMPDIR="$work/$dir" \
    scripts/agent-guard.sh pre-edit --ack "umask test" -- "$target/.github/workflows/$dir.yml" >/dev/null) || rc=$?
  chmod u+w "$target/.agents/state"
  [[ "$rc" -eq 0 ]] || fail "sandbox ack under umask 002 ($dir): rc=$rc"
  codex "umask-$dir" "$(p "*** Add File: .github/workflows/$dir.yml
+x")" TMPDIR="$work/$dir"
  [[ "$RC" -eq 0 ]] || fail "codex ack written under umask 002 ($dir): rc=$RC err=$ERR"
done

# 8. The verifier wants a PreToolUse group that takes apply_patch.
hooks="$target/.codex/hooks.json"
cp "$hooks" "$work/hooks.saved"
verify_line() { (cd "$target" && { scripts/verify-ai-deps.sh 2>&1 || true; }) | { grep -F "Codex PreToolUse" || true; }; }
has "$(verify_line)" "ok    Codex PreToolUse guards apply_patch" "verifier accepts the kit hook"
sed 's/"PreToolUse"/"PostToolUse"/' "$work/hooks.saved" >"$hooks"
has "$(verify_line)" "does not guard apply_patch" "verifier rejects a PostToolUse hook"
sed 's/\^(apply_patch|Edit|Write)\$/^Bash$/' "$work/hooks.saved" >"$hooks"
has "$(verify_line)" "does not guard apply_patch" "verifier rejects a matcher without apply_patch"
sed 's/"command": "sh -c/"command": "echo sh -c/' "$work/hooks.saved" >"$hooks"
has "$(verify_line)" "does not guard apply_patch" "verifier rejects a command that only names the guard"
sed 's/"type": "command"/"type": "prompt"/' "$work/hooks.saved" >"$hooks"
has "$(verify_line)" "does not guard apply_patch" "verifier rejects a hook that is not a command"
# Codex does not wait for an async hook, so it cannot block.
sed 's/"type": "command",/"type": "command", "async": true,/' "$work/hooks.saved" >"$hooks"
has "$(verify_line)" "does not guard apply_patch" "verifier rejects an async hook"
cp "$work/hooks.saved" "$hooks"
# An update keeps an edited settings.json; the verifier names what is missing.
settings="$target/.claude/settings.json"
cp "$settings" "$work/settings.saved"
sed 's/"Edit|Write|MultiEdit|NotebookEdit"/"Edit|Write|MultiEdit"/' "$work/settings.saved" >"$settings"
claude_line="$( (cd "$target" && { scripts/verify-ai-deps.sh 2>&1 || true; }) | { grep -F "Claude PreToolUse does not guard" || true; })"
has "$claude_line" "does not guard NotebookEdit" "verifier names the missing NotebookEdit"
cp "$work/settings.saved" "$settings"

# 9. The Codex doctor warns until Codex keeps a trust record (fake CODEX_HOME).
mkdir -p "$work/codex-home"
doctor() { (cd "$target" && { CODEX_HOME="$work/codex-home" .codex/codex-mode.sh doctor 2>&1 || true; }); }
head_line="[hooks.state.\"$target/.codex/hooks.json:pre_tool_use:0:0\"]"
has "$(doctor)" "has no trust record" "doctor warns without a Codex config"
printf '%s\n' "$head_line" '[other]' 'trusted_hash = "sha256:0"' >"$work/codex-home/config.toml"
has "$(doctor)" "has no trust record" "doctor wants trusted_hash inside the table"
printf '%s\n' "$head_line" 'trusted_hash = "sha256:0"' 'enabled = false' >"$work/codex-home/config.toml"
has "$(doctor)" "has no trust record" "doctor treats a disabled hook as untrusted"
printf '%s\n' "$head_line" 'trusted_hash = "sha256:0"' >"$work/codex-home/config.toml"
has "$(doctor)" "info  Codex edit guard hook has a trust record; trust for the current hook entry is not verified" "doctor sees the trust record"
hasnt "$(doctor)" "ok    Codex edit guard hook" "doctor does not call a trust record ok"

# 10. Without python3 the guard has no symlink resolution: an absolute path
#     that starts in the root ("<root>/../x") is still no outside path, and
#     agent-instruction names ask with no auto-memory exception.
eval "$(sed -n '/^collapse_relative_path() {/,/^}/p; /^outside_lexical() {/,/^}/p; /^instructions_lexical() {/,/^}/p' "$target/scripts/agent-guard.sh")"
PROJECT_ROOT="$target"
outside_lexical "$work/outside/x" || fail "lexical: a path outside the root"
! outside_lexical "$target/../x" || fail "lexical: <root>/../x is an escape"
! outside_lexical "$work/outside/../target/AGENTS.md" || fail "lexical: a path that normalises into the root"
! outside_lexical "src/x" || fail "lexical: a relative path"
instructions_lexical "$codex_home/config.toml" || fail "lexical: a Codex home file"
instructions_lexical "$work/other-repo/CLAUDE.md" || fail "lexical: another repository's CLAUDE.md"
instructions_lexical "$claude_home/projects/$slug/memory/MEMORY.md" || fail "lexical: no memory exception"
CODEX_HOME="$work/agent-config" instructions_lexical "$work/agent-config/config.toml" ||
  fail "lexical: a configured Codex home"
instructions_lexical "$work/other-repo/agents.md" || fail "lexical: agents.md in any case"
instructions_lexical "$work/other-repo/.mcp.json" || fail "lexical: another repository's .mcp.json"
instructions_lexical "$work/other-repo/.git/config" || fail "lexical: another repository's .git/config"
HOME="$work/home" instructions_lexical "$work/home/.claude.json" || fail "lexical: ~/.claude.json"
HOME="$work/home" instructions_lexical "$work/home/.gitconfig" || fail "lexical: ~/.gitconfig"
HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" instructions_lexical "$work/home/.config/git/config" ||
  fail "lexical: the XDG git config"

# 11. An update keeps a user's own hooks in .codex/hooks.json; the kit's file
#     becomes a candidate beside it. No baseline: the user's file came before
#     the kit managed it (an install older than 2026.11.05.2).
rm -f "$target/.tools/agent-state/harness-baseline/files/.codex/hooks.json"
python3 -I -S - "$hooks" <<'PY'
import json
import sys

path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["hooks"]["PreToolUse"].append({"matcher": "^Bash$", "hooks": [{"type": "command", "command": "echo user-hook"}]})
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
bash "$ROOT_DIR/scripts/bootstrap-multi-agent-project.sh" --target "$target" --workflow full >/dev/null 2>&1 || true
has "$(cat "$hooks")" "echo user-hook" "an update keeps the user's own Codex hooks"
ls "$hooks".generated.* >/dev/null 2>&1 || fail "an update writes the kit's .codex/hooks.json as a candidate"
! shopt -q nocasematch || fail "lexical: nocasematch must be restored"
! instructions_lexical "$work/outside/notes.md" || fail "lexical: a plain outside file"

echo "edit-guard-hosts: ok"
