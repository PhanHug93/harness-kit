# Writer Integration — mobile-optimization skill

Not emitted to target projects. This documents how the kit's writers consume this template directory.

## Emission table (parity: one source, four surfaces)

| Tool | Surface | Mechanism | Always-on cost |
|---|---|---|---|
| Windsurf | `.windsurf/rules/mobile-optimization.md` | native `trigger: glob` | ~0 (loads on matching file) |
| Cursor | `.cursor/rules/mobile-optimization.mdc` | `globs` + `alwaysApply: false` | ~0 |
| Claude Code | `.claude/commands/optimize-code.md` | native slash command | 0 |
| Codex | one line in `AGENTS.md` Skills section | pointer text | ~60 tok |
| all | `.agents/skills/mobile-optimization/**` | canonical content, read on demand | 0 |

`{{GLOBS}}` in pointer templates is substituted by the writer from the detected stack: `**/*.kt,**/*.kts` (android_kotlin), `**/*.swift` (ios_swift), comma-joined when both.

## Writer sketch

```bash
write_skill_mobile_optimization() {
  local want_kotlin=false want_swift=false globs=""
  stack_has android_kotlin && want_kotlin=true
  stack_has ios_swift && want_swift=true
  [[ $want_kotlin == false && $want_swift == false ]] && return 0

  local src="$TEMPLATES_DIR/skills/mobile-optimization"
  local dst="$TARGET_DIR/.agents/skills/mobile-optimization"

  copy_template "$src/SKILL.md"   "$dst/SKILL.md"
  copy_template "$src/catalog.md" "$dst/catalog.md"
  $want_kotlin && { copy_template "$src/overlays/kotlin.md" "$dst/overlays/kotlin.md"
                    copy_template "$src/fewshots/kotlin.md" "$dst/fewshots/kotlin.md"
                    globs="**/*.kt,**/*.kts"; }
  $want_swift  && { copy_template "$src/overlays/swift.md" "$dst/overlays/swift.md"
                    copy_template "$src/fewshots/swift.md" "$dst/fewshots/swift.md"
                    globs="${globs:+$globs,}**/*.swift"; }

  render_pointer "$src/pointers/windsurf.rules.md" "$TARGET_DIR/.windsurf/rules/mobile-optimization.md" "$globs"
  render_pointer "$src/pointers/cursor.rules.mdc"  "$TARGET_DIR/.cursor/rules/mobile-optimization.mdc"  "$globs"
  copy_template  "$src/pointers/claude.command.md" "$TARGET_DIR/.claude/commands/optimize-code.md"
  append_agents_skill_line "mobile-optimization" \
    "Kotlin/Swift optimization tasks: read .agents/skills/mobile-optimization/SKILL.md before patching."
}

render_pointer() {  # $1 src  $2 dst  $3 globs — sed on {{GLOBS}} only
  sed "s|{{GLOBS}}|$3|" "$1" | write_file_from_stdin "$2"
}
```

All emissions go through the existing non-destructive path (`*.generated.*` candidates on conflict), same as other surfaces.

## Tests to add (drift + behavior)

1. **Parity**: all four surfaces reference the same `.agents/skills/mobile-optimization/SKILL.md` path.
2. **Stack selection**: android-only fixture emits no `swift.md`/no `**/*.swift` glob; ios-only the inverse; dual emits both.
3. **Budget**: rendered pointer files each ≤ 120 estimated tokens; assert skill content is absent from the default context-pack.
4. **Glob substitution**: no literal `{{GLOBS}}` remains in emitted files.
5. **Byte-identical drift**: add this directory to MANIFEST / sync-template-catalog coverage like other templates.

## Sanitization record

Fewshot 1 was genericized from a real project function: names, domain types, and status enums replaced (`partitionSyncableRecords`, `DailyRecord`, `hasRequiredMetrics`, `RecordStatus.PENDING`, `SyncPartition`); control flow and the verified behavior-equivalence of the transformation preserved exactly. Do not reintroduce project-identifying names, package IDs, or app config into these templates.

## Deliberate omissions

- No `Updated:` dates in emitted files — keeps drift tests byte-stable.
- No separate workflow file — the process lives in SKILL.md §Process; pointers/commands reference it (single source).
- Runtime performance content (startup/jank/memory) intentionally out of scope; belongs to a separate skill if ever needed.
