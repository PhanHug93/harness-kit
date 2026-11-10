#!/usr/bin/env bash
set -euo pipefail

# Before a release: one real Claude Code session and one real Codex session
# in a scratch project made from this checkout.
#
# The suites never start a host, and two defects shipped that way: Claude
# hooks stopped after the agent ran `cd`, and Codex seats could not write
# their packet. This script tries both on the real hosts:
#   Claude Code  after `cd src`, an edit to AGENTS.md must still be refused
#                by the edit guard (a control edit to src/app.ts goes through).
#   Codex        with the launcher's own sandbox options, a session writes a
#                packet file under .agents/tasks/ and cannot write
#                .agents/skills/ (a control file under src/ goes through).
#
# It uses your own Claude and Codex accounts (one short session each, a few
# cents), so it is run by hand: it is not part of scripts/test.sh or CI.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLAUDE_MODEL="${RELEASE_SMOKE_CLAUDE_MODEL:-haiku}"
CLAUDE_BUDGET_USD="${RELEASE_SMOKE_CLAUDE_BUDGET_USD:-0.25}"

usage() {
  printf '%s\n' \
    "Usage: scripts/release-smoke.sh [--only claude|codex] [--source-dir DIR] [--keep]" \
    "" \
    "  --only HOST        run one host (claude or codex)" \
    "  --source-dir DIR   the kit checkout to install (default: this one)" \
    "  --keep             keep the scratch project and print where it is" \
    "" \
    "Exit: 0 every check passed; 1 a check failed; 2 usage; 3 a host could not" \
    "be tried (not installed, not signed in, or the session did not do the" \
    "control step), so nothing is proven for it."
}

only=""
keep=false
source_dir="$ROOT_DIR"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      only="${2:-}"
      [[ "$only" == "claude" || "$only" == "codex" ]] || { echo "release-smoke: --only takes claude or codex" >&2; exit 2; }
      shift 2
      ;;
    --source-dir)
      source_dir="${2:-}"
      [[ -d "$source_dir/agent-bootstrap" ]] || { echo "release-smoke: --source-dir has no agent-bootstrap/: $source_dir" >&2; exit 2; }
      shift 2
      ;;
    --keep) keep=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-smoke: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf 'release-smoke: %s\n' "$*"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
finish() {
  if [[ "$keep" == "true" ]]; then
    say "scratch project kept: $WORK/demo (logs in $WORK)"
  else
    rm -rf "$WORK"
  fi
}
trap finish EXIT

failed=0
not_tried=0
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; failed=$((failed + 1)); keep=true; }
untried() { say "NOT TRIED  $*"; not_tried=$((not_tried + 1)); keep=true; }
# The last lines of a log, on one line, for a message.
tail_of() { tail -n 4 "$1" 2>/dev/null | tr '\n' ' ' | cut -c1-400; }

# ---- the scratch project ----
proj="$WORK/demo"
mkdir -p "$proj/src" "$WORK/home"
git -C "$proj" init -q -b main
git -C "$proj" config user.name "Release Smoke"
git -C "$proj" config user.email "release-smoke@example.invalid"
printf 'export const a = 1;\n' >"$proj/src/app.ts"
git -C "$proj" add src/app.ts
git -C "$proj" commit -q -m init
say "installing the kit from $source_dir into a scratch project"
# A scratch HOME for the install only: it must not touch yours.
if ! HOME="$WORK/home" bash "$source_dir/agent-bootstrap/harness-kit-one-shot.sh" \
  --source-dir "$source_dir" --target "$proj" </dev/null >"$WORK/install.log" 2>&1; then
  say "the kit did not install: $(tail_of "$WORK/install.log")"
  keep=true
  exit 1
fi

# ---- Claude Code: the hooks still run after `cd` ----
smoke_claude() {
  local rc=0 before after cost prompt
  if ! command -v claude >/dev/null 2>&1; then
    untried "Claude Code: claude is not on PATH"
    return 0
  fi
  say "Claude Code $(claude --version 2>/dev/null | sed -n '1p'): one session, model $CLAUDE_MODEL"
  before="$(cksum <"$proj/AGENTS.md")"
  prompt="Do exactly these three steps, in this order, and nothing else. Do not ask questions.
1. Run this Bash command: cd src
2. With the Edit tool, add this new last line to the file $proj/src/app.ts: // release-smoke control
3. With the Edit tool, add this new last line to the file $proj/AGENTS.md: release-smoke
If a tool call is refused, do not retry it and do not use another tool for it: go on to the next step. Then answer with the word done."
  (cd "$proj" && claude -p "$prompt" --setting-sources project --no-session-persistence --strict-mcp-config \
    --permission-mode acceptEdits --allowedTools "Edit" "Read" "Bash(cd:*)" --model "$CLAUDE_MODEL" \
    --max-budget-usd "$CLAUDE_BUDGET_USD" --output-format json </dev/null >"$WORK/claude.json" 2>"$WORK/claude.err") || rc=$?
  cost="$(python3 -c 'import json, sys
try:
    print("about %.4f USD" % json.load(open(sys.argv[1]))["total_cost_usd"])
except Exception:
    print("cost unknown")' "$WORK/claude.json")"
  if ! grep -qF 'release-smoke control' "$proj/src/app.ts"; then
    untried "Claude Code: the session did not make the control edit in src/app.ts (exit $rc, $cost): $(tail_of "$WORK/claude.err") $(cut -c1-300 "$WORK/claude.json" 2>/dev/null)"
    return 0
  fi
  after="$(cksum <"$proj/AGENTS.md")"
  if [[ "$before" == "$after" ]]; then
    pass "Claude Code: after cd, the edit guard still refused AGENTS.md ($cost)"
  else
    fail "Claude Code: after cd, the hooks did not run: the session edited AGENTS.md ($cost)"
  fi
}

# ---- Codex: a seat writes its packet, and nothing else under .agents/ ----
smoke_codex() {
  local rc=0 real_codex prompt item
  local -a exec_args=()
  if ! command -v codex >/dev/null 2>&1; then
    untried "Codex: codex is not on PATH"
    return 0
  fi
  real_codex="$(command -v codex)"
  # The launcher's own options, recorded by a stand-in codex.
  mkdir -p "$WORK/stand-in"
  cat >"$WORK/stand-in/codex" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import json, os, sys; json.dump(sys.argv[1:], open(os.environ["CODEX_CAPTURE_FILE"], "w"))' "$@"
EOF
  chmod +x "$WORK/stand-in/codex"
  if ! (cd "$proj" && HOME="$WORK/home" PATH="$WORK/stand-in:$PATH" CODEX_CAPTURE_FILE="$WORK/argv.json" CODEX_SKIP_CLOSEOUT=1 \
    bash .codex/codex-mode.sh @gate --full-flow </dev/null >"$WORK/launch.out" 2>&1) || [[ ! -s "$WORK/argv.json" ]]; then
    fail "Codex: the launcher did not start (.codex/codex-mode.sh @gate --full-flow): $(tail_of "$WORK/launch.out")"
    return 0
  fi
  # codex exec takes the launcher's sandbox mode and added folders as they
  # are; the approval policy (-a) is a config value there. The seat's model
  # and effort are left out: this session uses your Codex defaults.
  python3 - "$WORK/argv.json" >"$WORK/exec-args.nul" <<'PY'
import json
import sys

args = json.load(open(sys.argv[1]))[:-1]
out = []
index = 0
while index < len(args):
    name = args[index]
    value = args[index + 1] if index + 1 < len(args) else ""
    if name == "-s":
        out += ["-s", value]
    elif name == "-a":
        out += ["-c", 'approval_policy="%s"' % value]
    elif name == "--add-dir":
        out += ["--add-dir", value]
    elif name == "-c" and value.startswith("sandbox_"):
        out += ["-c", value]
    index += 2 if name in ("-s", "-a", "--add-dir", "-c", "-C", "--model") else 1
sys.stdout.write("".join(item + "\0" for item in out))
PY
  while IFS= read -r -d '' item; do exec_args+=("$item"); done <"$WORK/exec-args.nul"
  if [[ "${#exec_args[@]}" -eq 0 ]]; then
    fail "Codex: the launcher gave Codex no sandbox option: $(tail_of "$WORK/launch.out")"
    return 0
  fi
  say "Codex $("$real_codex" --version 2>/dev/null | sed -n '1p'): one session with the launcher's options: ${exec_args[*]}"
  prompt="Do exactly these three steps, in this order, and nothing else. Do not ask questions.
1. Create the file src/release-smoke-control.txt with the single line: control
2. Create the file .agents/tasks/release-smoke/gate-review.md with the single line: packet
3. Create the file .agents/skills/release-smoke.md with the single line: skills
Use apply_patch for each file. If a step is refused, do not retry it and do not try another way: go on to the next step. Then answer with the word done."
  (cd "$proj" && "$real_codex" exec --ephemeral --disable hooks --skip-git-repo-check "${exec_args[@]}" \
    -o "$WORK/codex.last" "$prompt" </dev/null >"$WORK/codex.log" 2>&1) || rc=$?
  if [[ ! -f "$proj/src/release-smoke-control.txt" ]]; then
    untried "Codex: the session did not write the control file under src/ (exit $rc): $(tail_of "$WORK/codex.log")"
    return 0
  fi
  if [[ ! -f "$proj/.agents/tasks/release-smoke/gate-review.md" ]]; then
    fail "Codex: a seat cannot write its packet: .agents/tasks/release-smoke/gate-review.md was not written: $(tail_of "$WORK/codex.last")"
    return 0
  fi
  if [[ -e "$proj/.agents/skills/release-smoke.md" ]]; then
    fail "Codex: the session wrote .agents/skills/, which must stay read-only"
    return 0
  fi
  pass "Codex: the session wrote its packet under .agents/tasks/ and could not write .agents/skills/"
}

[[ "$only" == "codex" ]] || smoke_claude
[[ "$only" == "claude" ]] || smoke_codex

if [[ "$failed" -gt 0 ]]; then
  say "result: $failed failed"
  exit 1
fi
if [[ "$not_tried" -gt 0 ]]; then
  say "result: $not_tried not tried; nothing is proven for it"
  exit 3
fi
say "result: ok"
