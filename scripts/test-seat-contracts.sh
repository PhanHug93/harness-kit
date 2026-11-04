#!/usr/bin/env bash
set -euo pipefail

# Seat contracts (spec 2026-11-04 §G): one section per seat with the same
# seven labels, one Claude command per seat that points to its section, Codex
# seeds that point to the same section, the removed mode words and the
# gate-review plan lines.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/seat-contracts.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'seat-contracts-test: FAIL: %s\n' "$*" >&2
  exit 1
}

generate() {  # generate <preset>
  local target="$TMP_ROOT/$1"
  mkdir -p "$target"
  git -C "$target" init -q
  if ! bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow "$1" \
    >"$TMP_ROOT/$1.out" 2>&1 </dev/null; then
    cat "$TMP_ROOT/$1.out" >&2
    fail "$1 generation failed"
  fi
}
generate full
generate infra
full="$TMP_ROOT/full"

python3 -I -B - "$full" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
problems = []
contracts = (root / "docs/agent-configs/agent-mode-contracts.md").read_text(encoding="utf-8")
seats = ["@spec", "@gate", "@build", "@verify", "@audit", "@owner"]
labels = ["Duty", "Starts when", "Writes", "Never", "Exits", "By tier", "End of turn"]
if not contracts.startswith("# Seat Contracts\n"):
    problems.append("the contracts title is not 'Seat Contracts'")
heads = re.findall(r"^## `(@[a-z]+)`$", contracts, re.M)
if heads != seats:
    problems.append(f"seat sections {heads} != {seats}")
parts = re.split(r"^## ", contracts, flags=re.M)
for seat in seats:
    body = next((p for p in parts if p.startswith(f"`{seat}`\n")), "")
    found = re.findall(r"^- (Duty|Starts when|Writes|Never|Exits|By tier|End of turn):", body, re.M)
    if found != labels:
        problems.append(f"{seat} labels {found} != {labels}")
for old in ("## Planning Mode", "## Coding Mode", "## Reviewing Mode"):
    if old in contracts:
        problems.append(f"the contracts still have {old}")
if "## Project-Specific Seat Overrides\n\n<!-- BEGIN USER: mode-contracts:overrides -->" not in contracts:
    problems.append("the overrides heading or its USER marker changed")
for seat in ("spec", "gate", "build", "verify", "audit"):
    path = root / ".claude" / "commands" / f"{seat}.md"
    if not path.is_file():
        problems.append(f"missing .claude/commands/{seat}.md")
        continue
    text = path.read_text(encoding="utf-8")
    if not re.match(r"---\ndescription: .+\nargument-hint: <task-id>\n"
                    r"allowed-tools: Bash\(scripts/agent-seats.sh check:\*\)\n---\n", text):
        problems.append(f"{seat}.md: front matter needs description, argument-hint: <task-id> and allowed-tools")
    if f'!`scripts/agent-seats.sh check {seat} --host claude --task "$ARGUMENTS"`' not in text:
        problems.append(f"{seat}.md does not check the packet's host for @{seat}")
    if f"section `@{seat}` of `docs/agent-configs/agent-mode-contracts.md`" not in " ".join(text.split()):
        problems.append(f"{seat}.md does not point to section @{seat}")
for old in ("planning", "coding", "reviewing"):
    for name in (f"{old}.md", f"{old}-full-flow.md"):
        if (root / ".claude" / "commands" / name).exists():
            problems.append(f".claude/commands/{name} is still generated")
reference = (root / "docs/agent-configs/agent-handoff-reference.md").read_text(encoding="utf-8")
for line in ("plan: <path> | none", "blocking_gaps: none | <spec findings only>",
             "resolved_in_plan: none | <technical findings and where the plan answers them>"):
    if line not in reference:
        problems.append(f"the gate-review.md template lacks: {line}")
for problem in problems:
    print(f"seat-contracts-test: FAIL: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

for name in spec gate build verify audit planning coding reviewing; do
  for suffix in .md -full-flow.md; do
    [[ ! -e "$TMP_ROOT/infra/.claude/commands/$name$suffix" ]] ||
      fail "infra generates .claude/commands/$name$suffix"
  done
done

# Codex: each Codex seat's seed points to its contract section; the old mode
# words exit 2 with the new name and never launch.
stubbin="$TMP_ROOT/bin"
codex_args="$TMP_ROOT/codex.args"
mkdir -p "$stubbin"
cat >"$stubbin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$codex_args"
STUB
chmod +x "$stubbin/codex"
launch() {  # launch <codex-mode args...>; sets rc
  rc=0
  rm -f "$codex_args"
  (cd "$full" && env -u CODEX_HARNESS_SESSION -u AGENT_WORKSPACE_CONTEXT -u AGENT_HOST_SESSION_ID \
    -u CODEX_MODEL_OVERRIDE -u CODEX_USE_FALLBACK -u CODEX_REASONING_EFFORT CODEX_SKIP_CLOSEOUT=1 \
    PATH="$stubbin:$PATH" .codex/codex-mode.sh "$@") \
    >"$TMP_ROOT/launch.out" 2>"$TMP_ROOT/launch.err" </dev/null || rc=$?
}
for seat in gate build verify; do
  launch "@$seat" x
  [[ "$rc" -eq 0 && -s "$codex_args" ]] || fail "@$seat launch (rc=$rc): $(cat "$TMP_ROOT/launch.err")"
  grep -qF "SEAT LOCK: @$seat" "$codex_args" || fail "@$seat seed lacks its seat lock"
  grep -qF "follow section @$seat of docs/agent-configs/agent-mode-contracts.md" "$codex_args" ||
    fail "@$seat seed does not point to its contract section"
  if grep -qF 'MODE LOCK' "$codex_args"; then
    fail "@$seat seed still carries a mode lock"
  fi
done
for pair in planning:@spec coding:@build reviewing:@verify; do
  launch "${pair%%:*}" x
  [[ "$rc" -eq 2 && ! -e "$codex_args" ]] || fail "${pair%%:*} must exit 2 without launching (rc=$rc)"
  grep -qF "removed: use ${pair#*:}" "$TMP_ROOT/launch.err" || fail "${pair%%:*} must name ${pair#*:}"
done
# The rescue handoff offers only what the launcher accepts.
if grep -qE 'planning|coding|reviewing' "$full/.claude/commands/codex/rescue.md"; then
  fail "the rescue command still offers a removed mode word"
fi
# Small and medium: the packet's @build implements, on the host the user picked;
# no surface says Claude implements on its own.
for doc in CLAUDE.md docs/agent-configs/agent-mode-contracts.md; do
  if grep -qF 'Claude implements the change' "$full/$doc" || grep -qF 'Claude implements only after' "$full/$doc"; then
    fail "$doc still says Claude implements a small or medium change by itself"
  fi
  grep -qF "packet's \`@build\`" "$full/$doc" || fail "$doc must say the packet's @build implements"
done
# A mode command the update kept (tracked by git or edited) gets a doctor warning.
printf '# planning\n' >"$full/.claude/commands/planning.md"
(cd "$full" && scripts/verify-ai-deps.sh </dev/null >"$TMP_ROOT/verify.out" 2>&1) || true
grep -qF "old mode command still here: .claude/commands/planning.md" "$TMP_ROOT/verify.out" ||
  fail "the verifier must name a kept mode command: $(grep -E 'WARN|FAIL' "$TMP_ROOT/verify.out" | head -5)"
rm -f "$full/.claude/commands/planning.md"
echo "seat-contracts-test: ok"
