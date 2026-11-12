#!/usr/bin/env bash
set -euo pipefail

# Mandatory rules in the generated agent docs. Each row of
# scripts/rule-inventory.tsv names a rule, its preset, the generated file that
# owns it and a short exact phrase: the phrase must be in the owner file and,
# when single is yes, in no other generated agent doc. A fresh full target's
# agent docs stay at or under WORD_CEILING words, and CLAUDE.md is the only
# tool wrapper.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INVENTORY="$ROOT_DIR/scripts/rule-inventory.tsv"
# 10,353 words before the 2026-11 rewrite; the RECOVERY restore recipe (about 300
# words, run by scripts/test-agent-retirement.py) stays verbatim. 7,900 until
# the 2026-11 skill text fixes (evidence principle, doubt-driven findings,
# agentmemory search layer, plan header rule: +43 words, owner decision).
WORD_CEILING=7942
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rule-inventory.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

for preset in full infra; do
  target="$TMP_ROOT/plain-$preset"
  mkdir -p "$target"
  git -C "$target" init -q
  if ! bash "$ROOT_DIR/agent-bootstrap/bootstrap-multi-agent-project.sh" --target "$target" --workflow "$preset" \
    >"$TMP_ROOT/$preset.out" 2>&1; then
    cat "$TMP_ROOT/$preset.out" >&2
    printf 'rule-inventory: FAIL: %s generation failed\n' "$preset" >&2
    exit 1
  fi
done

python3 -I -B - "$INVENTORY" "$TMP_ROOT" "$WORD_CEILING" <<'PY'
import os
import sys

inventory, root, ceiling = sys.argv[1], sys.argv[2], int(sys.argv[3])
WRAPPERS = ("GEMINI.md", ".windsurfrules", ".cursor/rules/agent-conventions.mdc")


def agent_docs(target):
    found = {}
    for base, dirs, files in os.walk(target):
        if base == target:
            dirs[:] = [d for d in dirs if d not in (".git", ".tools")]
        for name in files:
            if name.endswith((".md", ".mdc")) or name == ".windsurfrules":
                path = os.path.join(base, name)
                with open(path, encoding="utf-8") as handle:
                    found[os.path.relpath(path, target)] = handle.read()
    return found


def norm(text):
    return " ".join(text.split())


docs = {p: agent_docs(os.path.join(root, "plain-" + p)) for p in ("full", "infra")}
flat = {p: {rel: norm(text) for rel, text in files.items()} for p, files in docs.items()}
problems, ids, rows = [], set(), 0
with open(inventory, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
for number, line in enumerate(lines, 1):
    if not line.strip() or line.startswith("#"):
        continue
    fields = line.split("\t")
    if len(fields) != 5:
        problems.append(f"line {number}: expected 5 tab-separated fields, got {len(fields)}")
        continue
    rule, preset, owner, single, phrase = fields
    rows += 1
    if rule in ids:
        problems.append(f"line {number}: duplicate id {rule}")
    ids.add(rule)
    if preset not in ("full", "infra", "both") or single not in ("yes", "no") or not phrase.strip():
        problems.append(f"line {number}: bad preset, single or empty phrase")
        continue
    needle = norm(phrase)
    for p in ("full", "infra") if preset == "both" else (preset,):
        files = flat[p]
        if owner not in files:
            problems.append(f"{rule}: {owner} is not generated in {p}")
            continue
        if needle not in files[owner]:
            problems.append(f"{rule}: {owner} ({p}) lacks: {phrase}")
        if single == "yes":
            others = sorted(rel for rel, text in files.items() if rel != owner and needle in text)
            if others:
                problems.append(f"{rule}: ({p}) also in {', '.join(others)}: {phrase}")

for p, files in docs.items():
    for rel in WRAPPERS:
        if rel in files:
            problems.append(f"{p}: {rel} is still generated")
    claude = files.get("CLAUDE.md", "")
    content = [l.strip() for l in claude.splitlines() if l.strip() and not l.startswith("#")]
    if not content or content[0] != "@AGENTS.md":
        problems.append(f"{p}: CLAUDE.md must start with @AGENTS.md after its title")
    for repeated in ("scripts/agent-guard.sh preflight", "workspace-check"):
        if repeated in claude:
            problems.append(f"{p}: CLAUDE.md repeats AGENTS.md: {repeated}")

words = {p: sum(len(text.split()) for text in files.values()) for p, files in docs.items()}
if words["full"] > ceiling:
    problems.append(f"full agent docs hold {words['full']} words (ceiling {ceiling})")
print(f"rule-inventory: {rows} rules; full {len(docs['full'])} docs {words['full']} words "
      f"(ceiling {ceiling}); infra {len(docs['infra'])} docs {words['infra']} words")
for problem in problems:
    print(f"rule-inventory: FAIL: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
printf 'rule-inventory-test: ok\n'
