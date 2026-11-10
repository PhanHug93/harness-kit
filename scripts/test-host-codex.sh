#!/usr/bin/env bash
set -euo pipefail

# The Codex launcher against a real Codex, with no model call.
#
# Codex keeps .agents/ read-only in its workspace sandbox. In full flow the
# launcher adds the packet and state folders, so a seat can write its review
# file. Every other suite gives the launcher a stand-in codex; this one takes
# the launcher's own arguments and asks the installed Codex two things:
#   1. which folders it will let the session write (codex debug prompt-input);
#   2. whether a write really lands there (codex sandbox).
# The user's Codex config names a writable folder of its own: it must stay.
#
# No Codex on PATH (CI): skipped, and it says so. A Codex whose probe
# commands differ from the ones used here is skipped too. Only an answer that
# is wrong fails.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { printf 'host-codex-test: FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'host-codex: skipped (%s)\n' "$*"; exit 0; }

command -v codex >/dev/null 2>&1 || skip "Codex is not installed"
REAL_CODEX="$(command -v codex)"
PYTHON_BIN="$(command -v python3)" || fail "python3 is missing"
"$REAL_CODEX" debug prompt-input --help >/dev/null 2>&1 ||
  skip "this Codex has no 'debug prompt-input' ($("$REAL_CODEX" --version 2>/dev/null | sed -n '1p'))"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/host-codex-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# A project path with a space: the folders reach Codex as plain arguments.
proj="$WORK/demo project"
codex_home="$WORK/codex-home"
own_folder="$WORK/own-folder"
mkdir -p "$proj" "$codex_home" "$own_folder" "$WORK/stand-in" "$WORK/home"
git -C "$proj" init -q || fail "git init failed"
bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$proj" --workflow full >/dev/null ||
  fail "bootstrap failed"
mkdir -p "$proj/.agents/skills" "$proj/.codex" "$proj/src"

# The user's own Codex config: one writable folder. The temp folders are
# taken out of the sandbox: this scratch area lives under TMPDIR, and with
# Codex's default (TMPDIR writable) that folder would be writable whatever
# the launcher did.
cat >"$codex_home/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = ["$own_folder"]
exclude_tmpdir_env_var = true
exclude_slash_tmp = true
EOF

# 1. The launcher's own arguments, recorded by a stand-in codex.
cat >"$WORK/stand-in/codex" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import json, os, sys; json.dump(sys.argv[1:], open(os.environ["CODEX_CAPTURE_FILE"], "w"))' "$@"
EOF
chmod +x "$WORK/stand-in/codex"
launch_rc=0
(cd "$proj" && HOME="$WORK/home" PATH="$WORK/stand-in:$PATH" CODEX_CAPTURE_FILE="$WORK/argv.json" CODEX_SKIP_CLOSEOUT=1 \
  bash .codex/codex-mode.sh @gate --full-flow </dev/null >"$WORK/launch.out" 2>&1) || launch_rc=$?
[[ "$launch_rc" -eq 0 && -s "$WORK/argv.json" ]] ||
  fail "the launcher did not start Codex (exit $launch_rc): $(tail -n 5 "$WORK/launch.out")"
# Everything but the prompt (the last argument), one per line, NUL-separated.
python3 -c 'import json, sys
args = json.load(open(sys.argv[1]))[:-1]
sys.stdout.write("".join(arg + "\0" for arg in args))' "$WORK/argv.json" >"$WORK/argv.nul" ||
  fail "cannot read the launcher's arguments"
launcher_args=()
while IFS= read -r -d '' item; do launcher_args+=("$item"); done <"$WORK/argv.nul"
[[ "${#launcher_args[@]}" -gt 0 ]] || fail "the launcher gave Codex no option"

# 2. The folders the real Codex will let that session write.
roots_rc=0
CODEX_HOME="$codex_home" "$REAL_CODEX" "${launcher_args[@]}" debug prompt-input </dev/null >"$WORK/prompt.out" 2>&1 || roots_rc=$?
[[ "$roots_rc" -eq 0 ]] ||
  fail "the installed Codex refuses the launcher's options (exit $roots_rc): $(tail -n 5 "$WORK/prompt.out")"
python3 - "$WORK/prompt.out" >"$WORK/roots.txt" <<'PY' || skip "this Codex does not print its writable folders"
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
match = re.search(r"The writable roots are ((?:`[^`]*`(?:, )?)+)", text)
if not match:
    sys.exit(1)
print("\n".join(re.findall(r"`([^`]*)`", match.group(1))))
PY
has_root() { grep -qxF -- "$1" "$WORK/roots.txt"; }
for folder in "$proj/.agents/tasks" "$proj/.agents/state"; do
  has_root "$folder" ||
    fail "Codex will not let a seat write ${folder#"$proj/"}: it is not among the writable folders: $(tr '\n' ' ' <"$WORK/roots.txt")"
  [[ -d "$folder" ]] || fail "the launcher must create ${folder#"$proj/"}"
done
has_root "$own_folder" ||
  fail "the launcher dropped the writable folder of the user's own Codex config: $(tr '\n' ' ' <"$WORK/roots.txt")"
if has_root "$proj/.agents" || has_root "$proj/.agents/skills"; then
  fail "the launcher must add the packet and state folders only: $(tr '\n' ' ' <"$WORK/roots.txt")"
fi

# 3. Real writes inside the Codex sandbox, with the folders step 2 reported
# (codex sandbox has no --add-dir, so the same list goes in through -c).
# Run once with the user's config alone and once with the launcher's folders.
probe='
import json, pathlib, sys
results = {}
for label, path in (("packet", ".agents/tasks/probe"), ("state", ".agents/state/probe"), ("skills", ".agents/skills/probe"),
                    ("codex", ".codex/probe"), ("src", "src/probe"), ("own", sys.argv[1] + "/probe")):
    try:
        pathlib.Path(path).write_text("probe")
        results[label] = "written"
    except OSError:
        results[label] = "refused"
print(json.dumps(results))
'
roots_override="$(python3 -c 'import json, sys
roots = [line for line in open(sys.argv[1]).read().splitlines() if line and line != sys.argv[2]]
print("sandbox_workspace_write.writable_roots=" + json.dumps(roots, ensure_ascii=False))' "$WORK/roots.txt" "$proj")" ||
  fail "cannot build the sandbox folder list"
SANDBOX_OUT=""
sandbox_probe() { # sandbox_probe [codex sandbox option]...: sets SANDBOX_OUT, false when the command cannot run
  local rc=0
  SANDBOX_OUT="$(cd "$proj" && CODEX_HOME="$codex_home" "$REAL_CODEX" sandbox -c 'sandbox_mode="workspace-write"' "$@" \
    -- "$PYTHON_BIN" -c "$probe" "$own_folder" </dev/null 2>"$WORK/sandbox.err")" || rc=$?
  [[ "$rc" -eq 0 && "$SANDBOX_OUT" == "{"* ]]
}
if ! sandbox_probe; then
  echo "host-codex: ok (writable folders checked; the sandbox write probe did not run on this Codex: $(tail -n 1 "$WORK/sandbox.err"))"
  exit 0
fi
without="$SANDBOX_OUT"
sandbox_probe -c "$roots_override" || fail "the sandbox probe failed with the launcher's folders: $(tail -n 3 "$WORK/sandbox.err")"
with="$SANDBOX_OUT"
python3 - "$without" "$with" <<'PY' || fail "sandbox writes: without the launcher's folders $without, with them $with"
import json
import sys

without, with_ = json.loads(sys.argv[1]), json.loads(sys.argv[2])
# The seat writes its packet and the guard's state; the user's folder stays.
assert with_["packet"] == with_["state"] == with_["own"] == with_["src"] == "written", with_
# The launcher opens nothing else: the rest of .agents/ and .codex are as
# writable as they were without it (refused, on a Codex that protects them).
assert with_["skills"] == without["skills"] and with_["codex"] == without["codex"], (without, with_)
PY
echo "host-codex: ok ($("$REAL_CODEX" --version 2>/dev/null | sed -n '1p'); without the launcher's folders $without, with them $with)"
