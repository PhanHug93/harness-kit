#!/usr/bin/env bash
set -euo pipefail

# Packet seats (spec 2026-11-04 §H): a packet keeps its own seat arrangement,
# copied from the project roster at its first tier set; every change is logged
# with the user's words; the Codex launcher and the Claude seat check follow it.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/packet-seats.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'packet-seats-test: FAIL: %s\n' "$*" >&2
  exit 1
}

target="$TMP_ROOT/project"
mkdir -p "$target"
git -C "$target" init -q
printf '# project\n' >"$target/README.md"
git -C "$target" add README.md
git -C "$target" -c user.name=test -c user.email=test@example.invalid commit -qm init
if ! bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow full \
  >"$TMP_ROOT/generate.out" 2>&1 </dev/null; then
  cat "$TMP_ROOT/generate.out" >&2
  fail "generation failed"
fi

run() {  # run <command...>: sets rc, out and err for one call from the project root
  rc=0
  (cd "$target" && env -u CODEX_HARNESS_SESSION -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID "$@") \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" </dev/null || rc=$?
  out="$(cat "$TMP_ROOT/out")"
  err="$(cat "$TMP_ROOT/err")"
}
seats() { run scripts/agent-seats.sh "$@"; }
has() {  # has <text> <phrase> <label>
  [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"
}
field() {  # field <json file> <python expression over d>
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
packet="$target/.agents/tasks"
project_sum="$(shasum -a 256 <"$target/docs/agent-configs/seats.json")"

# 1 The first tier set copies the roster and prints the tier's seats; later sets add nothing.
run scripts/agent-guard.sh tier set medium --task p1 --by @spec
[[ "$rc" -eq 0 ]] || fail "tier set (rc=$rc): $err"
has "$out" "Seats for medium: @spec claude → @build codex (gpt-5.6-luna) → @verify codex (gpt-6-astra)" "tier set seat line"
has "$out" "@build codes on codex; the user can move it: scripts/agent-seats.sh set build --host claude --task p1 --reason" "tier set names how to move @build"
[[ "$(field "$packet/p1/seats.json" 'd["schema"], len(d["history"]), d["history"][0]["change"], d["history"][0]["by"]')" == \
  "('agent-packet-seats/v1', 1, 'snapshot', '@spec')" ]] || fail "first tier set snapshot: $(cat "$packet/p1/seats.json")"
run scripts/agent-guard.sh tier set large --task p1 --by @spec
has "$out" "Seats for large: @spec claude → @gate codex (gpt-6-astra)" "second tier set seat line"
[[ "$(field "$packet/p1/seats.json" 'len(d["history"])')" == 1 ]] || fail "a second tier set added a snapshot"

# 2 show groups the seats by host.
seats show --task p1
has "$out" "- Claude: @spec @audit" "show Claude seats"
has "$out" "- Codex: @gate (gpt-6-astra ultra) @build (gpt-5.6-luna xhigh) @verify (gpt-6-astra ultra)" "show Codex seats"
has "$out" "Seats for large:" "show tier line"
has "$out" "Changes: 0" "show change count"

# 3 A preset changes the packet only, and only once.
seats use claude --task p1 --reason "all on Claude"
[[ "$rc" -eq 0 ]] || fail "use claude (rc=$rc): $err"
[[ "$(field "$packet/p1/seats.json" 'sorted({o["host"] for s, o in d["seats"].items() if s != "owner"}), d["history"][-1]["reason"], d["history"][-1]["change"]')" == \
  "(['claude'], 'all on Claude', 'preset claude')" ]] || fail "use claude result: $(cat "$packet/p1/seats.json")"
[[ "$(shasum -a 256 <"$target/docs/agent-configs/seats.json")" == "$project_sum" ]] || fail "a packet change wrote the project seats.json"
seats use claude --task p1 --reason "again"
has "$out" "already has that arrangement" "no-op preset"
[[ "$(field "$packet/p1/seats.json" 'len(d["history"])')" == 2 ]] || fail "a no-op preset was logged"
cp "$packet/p1/seats.json" "$TMP_ROOT/before-set.json"

# 4 One seat: from and to name only that seat.
seats set build --host codex --model gpt-5.6-luna --effort xhigh --task p1 --reason "Codex builds"
[[ "$rc" -eq 0 ]] || fail "set build (rc=$rc): $err"
[[ "$(field "$packet/p1/seats.json" 'sorted(d["history"][-1]["to"]), d["history"][-1]["change"]')" == "(['build'], 'seat build')" ]] ||
  fail "set build entry: $(cat "$packet/p1/seats.json")"

# 5 codex: a seat keeps its Codex occupant, else takes its project one on Codex, else @verify's.
seats use codex --task p1 --reason "all on Codex"
[[ "$(field "$packet/p1/seats.json" 'd["seats"]["spec"]["model"], d["seats"]["build"]["model"], d["seats"]["gate"]["model"], d["seats"]["audit"]["model"]')" == \
  "('gpt-6-astra', 'gpt-5.6-luna', 'gpt-6-astra', 'gpt-6-astra')" ]] || fail "use codex result: $(cat "$packet/p1/seats.json")"

# 6 check: ok, or STOP with the way out.
seats check spec --host claude --task p1
[[ "$rc" -eq 1 && "$out" == STOP:* ]] || fail "check on the wrong host must STOP (rc=$rc): $out"
has "$out" ".codex/codex-mode.sh @spec --task p1" "STOP names the launcher"
seats check spec --host codex --task p1
[[ "$rc" -eq 0 && "$out" == ok:* ]] || fail "check on the right host (rc=$rc): $out"

# 7 Usage errors write nothing.
cp "$packet/p1/seats.json" "$TMP_ROOT/p1.json"
for argv in "use claude --task p1" "use claude --reason r" "use all --task p1 --reason r" \
  "set build --host claude --reason r" "use claude --task P1 --reason r" "check spec --task p1"; do
  # shellcheck disable=SC2086 # split on purpose
  seats $argv
  [[ "$rc" -ne 0 ]] || fail "'$argv' must fail"
  cmp -s "$packet/p1/seats.json" "$TMP_ROOT/p1.json" || fail "'$argv' changed the packet"
done
[[ "$(shasum -a 256 <"$target/docs/agent-configs/seats.json")" == "$project_sum" ]] || fail "a usage error wrote the project seats.json"

# 8 The log is append-only and prints oldest first.
python3 -I - "$TMP_ROOT/before-set.json" "$packet/p1/seats.json" <<'PY' || fail "history is not append-only"
import json, sys
old, new = (json.load(open(p))["history"] for p in sys.argv[1:])
assert new[:len(old)] == old and len(new) == len(old) + 2, (old, new)
PY
seats history --task p1
[[ "$(wc -l <<<"$out")" -eq 4 ]] || fail "history must print 4 lines: $out"
[[ "$(sed -n '1p' <<<"$out")" == *"snapshot: first tier set"* && "$(sed -n '4p' <<<"$out")" == *"preset codex: all on Codex"* ]] ||
  fail "history order: $out"

# 9 codex refuses when the project has no Codex reviewer to lend.
mkdir -p "$packet/p2"
seats use claude --task p2 --reason r
cp "$target/docs/agent-configs/seats.json" "$TMP_ROOT/project-seats.json"
cp "$target/AGENTS.md" "$TMP_ROOT/agents.md"
seats set gate --host claude
seats set verify --host claude
seats use codex --task p2 --reason r
[[ "$rc" -eq 1 ]] || fail "the codex preset without a Codex reviewer to lend must refuse (rc=$rc)"
has "$err" "set spec --host codex --model <id> --task p2" "codex refusal names set"
cp "$TMP_ROOT/project-seats.json" "$target/docs/agent-configs/seats.json"
cp "$TMP_ROOT/agents.md" "$target/AGENTS.md"

# 10 An old packet without a seats file follows the project roster.
mkdir -p "$packet/old"
printf '{"status": "open", "phase": "analysis"}\n' >"$packet/old/state.json"
seats show --task old
has "$out" "follows the project roster" "old packet show"
seats resolve gate --task old
[[ "$(sed -n '4p;5p' <<<"$out" | tr '\n' ' ')" == "codex gpt-6-astra " ]] || fail "old packet resolve: $out"
rm -rf "$packet/old"
# 10b A task with no packet yet (what /spec <id> starts) follows the project roster; reads create nothing.
seats check spec --host claude --task brand-new
[[ "$rc" -eq 0 && "$out" == "ok: @spec sits on claude for the project roster"* ]] ||
  fail "check on a task with no packet yet (rc=$rc): $out $err"
seats resolve gate --task brand-new
[[ "$rc" -eq 0 && "$(sed -n '4p;5p' <<<"$out" | tr '\n' ' ')" == "codex gpt-6-astra " ]] ||
  fail "resolve on a task with no packet yet (rc=$rc): $out $err"
[[ ! -e "$packet/brand-new" ]] || fail "a read on a new task must not create its packet"

# 11 The Codex launcher follows the packet: seed, lock, run, refusal, default packet.
stubbin="$TMP_ROOT/bin"
codex_args="$TMP_ROOT/codex.args"
mkdir -p "$stubbin"
cat >"$stubbin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$codex_args"
STUB
chmod +x "$stubbin/codex"
launch() {
  rm -f "$codex_args"
  run env CODEX_SKIP_CLOSEOUT=1 PATH="$stubbin:$PATH" .codex/codex-mode.sh "$@"
}
launch @spec --task p1 x
[[ "$rc" -eq 0 && -s "$codex_args" ]] || fail "@spec on the packet's Codex seat must launch (rc=$rc): $err"
grep -qF "SEAT LOCK: @spec · phase analysis · packet p1 ·" "$codex_args" || fail "the seed must name packet p1"
grep -qx 'task=p1' "$target/.codex-mode-lock" || fail "the lock must keep task=p1"
launch run x
grep -qF "· packet p1 ·" "$codex_args" || fail "run must keep the locked packet"
seats use claude --task p1 --reason "back to Claude"
launch @build --task p1 x
[[ "$rc" -eq 2 && ! -e "$codex_args" ]] || fail "a seat the packet gives Claude must exit 2 without launching (rc=$rc)"
has "$err" "seat @build sits on claude for packet p1" "launcher refusal names the packet"
seats use project --task p1 --reason "the project roster"
rm -f "$target/.codex-mode-lock"
launch @gate x
grep -qF "· packet p1 ·" "$codex_args" || fail "the only open packet must be used without --task: $(cat "$codex_args")"
if grep -q '^task=' "$target/.codex-mode-lock"; then
  fail "a packet picked without --task must not go into the lock"
fi
launch @gate --task p1 x
run .codex/codex-mode.sh status
has "$out" "Locked packet: p1" "status names the locked packet"
seats set verify --host codex --model gpt-5.6-luna --effort xhigh --task p1 --reason "same model"
launch @build --task p1 x
grep -qF "model_overlap=verify" "$codex_args" || fail "the overlap fact must come from the packet: $(cat "$codex_args")"
seats use project --task p1 --reason "the project roster"
mkdir -p "$packet/p3"
printf '{"status": "open"}\n' >"$packet/p3/state.json"
launch @gate x
has "$err" "several open packets (p1, p3)" "several open packets note"
if grep -qF "· packet p" "$codex_args"; then
  fail "with two open packets the project roster must decide"
fi
# The Claude check applies the same rule as the launcher: the project roster, with the note.
seats check gate --host codex
[[ "$rc" -eq 0 && "$out" == *"ok: @gate sits on codex for the project roster"* ]] ||
  fail "check without a task on several packets must use the project roster (rc=$rc): $out"
has "$out" "several open packets (p1, p3); pass --task <id>" "check note on several packets"
seats check gate --host claude
[[ "$rc" -eq 1 && "$out" == *"STOP: @gate sits on codex"*"for the project roster"* ]] ||
  fail "check on the wrong host for the project roster must STOP (rc=$rc): $out"
rm -rf "$packet/p3"
launch @gate --task brand-new x
if [[ "$rc" -ne 0 ]] || ! grep -qF "· packet brand-new ·" "$codex_args"; then
  fail "a task with no packet yet must launch on the project roster (rc=$rc): $err"
fi
rm -f "$target/.codex-mode-lock"

# 12a A catalog change never locks a packet: show warns, use project repairs it.
mkdir -p "$packet/p5"
seats use codex --task p5 --reason r
python3 -I - "$packet/p5/seats.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["seats"]["spec"]["model"] = "gpt-retired"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
seats show --task p5
[[ "$rc" -eq 0 ]] || fail "show must read a packet whose model left the catalog (rc=$rc): $err"
has "$err" "use project --task p5 repairs it" "show warns about the stale model"
seats use project --task p5 --reason repair
[[ "$rc" -eq 0 && "$(field "$packet/p5/seats.json" 'd["seats"]["spec"]["host"]')" == claude ]] || fail "use project must repair the packet (rc=$rc): $err"
# 12b A packet seats file is never a link.
mkdir -p "$packet/p6"
ln -s ../../../docs/agent-configs/planted.json "$packet/p6/seats.json"
seats use claude --task p6 --reason r
[[ "$rc" -ne 0 && ! -e "$target/docs/agent-configs/planted.json" ]] || fail "a linked seats file must be refused (rc=$rc)"
seats use project --task p6 --reason r
[[ "$rc" -ne 0 && -L "$packet/p6/seats.json" ]] || fail "use project must not replace a linked seats file (rc=$rc)"
rm -rf "$packet/p6" "$packet/p5"
# 12c A broken packet seats file: show names the repair, the launcher points at the
# packet (not at the project file), and use project rewrites it, keeping the bad copy.
mkdir -p "$packet/p7"
printf '{"status": "open"}\n' >"$packet/p7/state.json"
printf '{broken\n' >"$packet/p7/seats.json"
seats show --task p7
[[ "$rc" -ne 0 ]] || fail "show must refuse a broken packet seats file"
has "$err" "use project --task p7" "show names the repair"
launch @gate --task p7 x
[[ "$rc" -ne 0 && ! -e "$codex_args" ]] || fail "the launcher must refuse a broken packet (rc=$rc)"
has "$err" "use project --task p7" "launcher names the packet repair"
[[ "$err" != *"validate or reset"* ]] || fail "a broken packet must not point at the project reset: $err"
seats use project --task p7 --reason "the file broke"
[[ "$rc" -eq 0 ]] || fail "use project must repair a broken packet seats file (rc=$rc): $err"
[[ "$(field "$packet/p7/seats.json" '[(e["change"], e["reason"]) for e in d["history"]]')" == "[('repair', 'the file broke')]" ]] ||
  fail "the repair must start a new trail: $(cat "$packet/p7/seats.json")"
compgen -G "$packet/p7/seats.json.broken-*" >/dev/null || fail "the broken file must be kept beside the packet"
seats use claude --task p7 --reason r
[[ "$rc" -eq 0 ]] || fail "after the repair the packet takes changes (rc=$rc): $err"
# 12d A history entry with the right keys but wrong values is refused, never a traceback.
python3 -I - "$packet/p7/seats.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["history"][-1]["to"] = None
doc["history"][-1]["from"] = {}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
seats history --task p7
[[ "$rc" -ne 0 && "$err" != *Traceback* ]] || fail "a malformed history entry must be refused cleanly (rc=$rc): $err"
has "$err" "history" "the refusal names the history"
rm -rf "$packet/p7"

# 12 The first state's owner follows the packet's @spec.
mkdir -p "$packet/p4"
seats use codex --task p4 --reason "Codex leads"
run scripts/agent-guard.sh tier set small --task p4
has "$out" "Seats for small: @spec codex (gpt-6-astra) → @build codex (gpt-5.6-luna), which plans, builds and verifies" "small seat line"
[[ "$(field "$packet/p4/state.json" 'd["owner"]')" == codex ]] || fail "the state owner must follow the packet's @spec"

# 13 tier close prints the final arrangement; a closed packet's seats no longer change.
run scripts/agent-guard.sh tier close --task p1
has "$out" "Seats at close: Claude: @spec @audit · Codex:" "close line"
has "$out" "(7 changes)" "close line count"
seats use claude --task p1 --reason late
[[ "$rc" -ne 0 ]] || fail "a closed packet must refuse a change"
has "$err" "is closed" "closed packet refusal"

# 14 The @build close-out checks the packet it was launched for.
mkdir -p "$packet/p10"
printf '{"status": "open"}\n' >"$packet/p10/state.json"
rm -f "$codex_args"
run env PATH="$stubbin:$PATH" .codex/codex-mode.sh @build --task p10 x
has "$err" "@build close-out: scripts/agent-guard.sh pre-final --run-verify --task p10" "close-out names the packet"

echo "packet-seats-test: ok"
