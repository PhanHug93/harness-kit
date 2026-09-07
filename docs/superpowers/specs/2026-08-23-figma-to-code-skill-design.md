# Figma → UI code: an opt-in kit skill

**Status:** Implemented 2026-08-25. Both suites green. Awaiting Sol technical review.
**Branch:** `feature/figma-to-code-skill`
**Date:** 2026-08-23
**Source material:** user-supplied `figma.zip` (skill draft, 2 scripts, 5 references)

## Objective

Ship `figma-to-code` as an opt-in skill of harness-kit, installed with
`--add-skill figma-to-code`, so that an agent working on UI in any generated
target can extract real design data from Figma and reproduce the design closely
on the platform the user names.

The supplied material is the content core and is high quality. This spec covers
what turns it into a kit skill: the platform gate, the credential handling, the
budget consequence, and the integration surface.

## 1. Platform gate — mandatory, four targets

The agent asks the user which UI target to produce **before any extraction
runs**, every time. Repository detection is a suggestion in the question, never
a substitute for the answer.

| id | Stack | Icon format |
|---|---|---|
| `android-compose` | Jetpack Compose | SVG → vector drawable |
| `android-xml` | Android View system, XML layouts | SVG → vector drawable |
| `flutter` | Flutter / Dart | SVG |
| `swiftui` | SwiftUI | PDF |

Asking is mandatory rather than inferred because the ambiguity is real: an
Android repository can target Compose or XML, and the presence of an
`androidx.compose` dependency does not establish which one this screen is for.
Icon export format is decided by the answer, so the answer must precede
extraction, not just generation.

`android-xml` is new content this spec adds: the source material covers only
three platforms.

## 2. Credentials and frame configuration

The agent receives a **path**, never a credential. Two files, split by
sensitivity, because the URL list and the token do not deserve the same
treatment.

### 2.1 Token file — `.agents/skills/figma-to-code/.env.figma`

```
FIGMA_TOKEN=figd_xxxxxxxx
```

This location was chosen because two existing kit mechanisms already cover it
and no new one is required:

- `.agents/` is in the generated target `.gitignore` (`render.sh:226`), so the
  file cannot reach a commit by accident.
- `SENSITIVE_LOCAL_PATHS` in `agent-hook.sh` already lists `.env`, `.env.*`,
  `*/.env` and `*/.env.*`, so the file is reported by
  `scripts/agent-hook.sh no-scan-paths` and falls under the standing rule that
  agents do not read no-scan paths.

**Verify before relying on it:** that the `*/.env.*` glob actually matches at
this depth. If it does not, add the explicit path to `SENSITIVE_LOCAL_PATHS`
rather than assuming coverage.

**The honest limit of that protection.** The Claude PreToolUse hook guards
`Edit`, `Write` and `MultiEdit` only (`agent-hook.sh:272`); it does not guard
`Read`. So the no-scan list is a documented convention for reads, not a control.
An agent that disregards it can read the file. A user who wants a real boundary
rather than a convention puts the token outside the project root
(`~/.config/harness-kit/figma.env`, supported via `--token-file=PATH`), where
the kit's existing rule that external paths require exact approval applies and
where agent tooling is normally scoped out. The skill documents both and does
not describe the in-project location as protection it is not.

### 2.2 Frame file — `.agents/skills/figma-to-code/frames.md`

```markdown
# Figma frames

- home    https://www.figma.com/design/KEY/App?node-id=241-1053
- player  https://www.figma.com/design/KEY/App?node-id=270-1380
```

Frame URLs are not secret, and they are useful context: they tell the agent
which screens exist and what each is called. Keeping them in a separate file the
agent may read freely preserves that value, which merging them into the token
file would throw away. `.agents/` already keeps this out of commits.

### 2.3 Rules the implementation must satisfy

- The token is read from the token file only. It never appears in `argv`, is
  never placed in a child process's environment, and is never echoed — including
  inside error messages.
- The script refuses to run when the token file is tracked by git or is not
  ignored, checked with `git ls-files` and `git check-ignore`. This is a real
  fail-closed check rather than advice, and it is testable.
- After writing outputs the script greps its own products for `figd_` and exits
  non-zero on a hit. A leak fails loudly rather than shipping quietly.
- `--forget` deletes the token file after a successful run. This is how the
  original "use once and forget" requirement survives the move to a config file:
  the credential's lifetime becomes a per-run decision rather than a property of
  where it is stored.
- One entry per run: `figma_spec.py` gains `--icons=svg|pdf|png` so icon export
  runs in the same process against the same credential read.
- `FIGMA_TOKEN` in the environment stays supported for non-interactive runs but
  is absent from user-facing instructions, and its use prints a warning that a
  persistent credential is present.

### 2.4 What this trades

The earlier draft kept the token ephemeral by keeping the agent out of the
credential path at the cost of one manual step per frame. The config file
removes the manual step and still keeps the agent out of the credential path,
but the token now rests on disk between runs. `--forget`, a short-expiry token,
and revocation after a session are the mitigations; the spec states the trade
rather than presenting the config file as strictly better.

**Assumption requiring verification:** if Figma's token dialog offers an expiry,
the skill should recommend the shortest available. This has not been verified
against the current Figma UI.

## 3. Workspace

Outputs go to `.agents/skills/figma-to-code/workspace/`.

`.agents/` is already ignored in generated targets, so `raw.json`, `spec.md`,
downloaded images and exported icons never reach a commit. The path sits
outside the no-scan list, so agents may read it. Icons the user chooses to keep
are copied by the agent into the project's real resource directory as an
explicit step, never automatically.

## 4. Budget — a defect this branch must fix first

Measured on the Android + Wear fixture at branch point:

| Configuration | Full-workflow tokens | Gate 6200 |
|---|---|---|
| no skill | 6182 | pass |
| `--add-skill mobile-optimization` | **6210** | **fail** |
| projected, with a second skill bullet | ~6238 | fail |

The 6182 figure reported when the previous branch closed was the no-skill
configuration, and no test measures the budget with a skill enabled. An
Android/Wear target that enables `mobile-optimization` today already exceeds the
gate. Adding a second per-skill bullet makes it worse, and the cost grows
linearly with every skill the kit ever adds.

**Proposed fix — remove per-skill bullets from `AGENTS.md`.** The file already
carries a general line: *"Skills under `.agents/skills/` only when their
descriptions match the current task."* Each skill's own `SKILL.md` frontmatter
carries a `description` written for exactly this purpose. Skill discovery
becomes a directory read rather than generated text, which costs the shared
budget nothing and makes the Nth skill free.

Consequences to accept: the mobile-optimization bullet is removed as well;
`assert_mobile_optimization_pointer_budget` changes from asserting the bullet's
presence to asserting the general line plus a readable skill description; and an
agent learns which skills exist by listing the directory rather than by reading
`AGENTS.md`.

Alternative considered and rejected: keep the bullets and reclaim ~60 tokens
elsewhere. It buys one skill and fails again at the next.

**A new assertion covers the untested combination**: the full-workflow budget is
measured on a target with every available skill enabled, not only on the bare
target.

## 5. Corrections to the source material

Carry these into the ported template; each was verified against the supplied
files.

| id | File | Defect | Fix |
|---|---|---|---|
| F1 | `platform-swiftui.md` | `.renderable(.template)` is not a SwiftUI API | `.renderingMode(.template)` |
| F2 | `figma_spec.py` | Non-solid paints print a type name only, so gradients lose colours and stops while the skill forbids reading `raw.json` | Emit `gradient=[stop:ARGB,…]` with the gradient's direction |
| F3 | `figma_spec.py` | `used = {…} or imgs` falls back to the whole file's image map when the frame has no image fill | Keep the empty set |
| F4 | `figma_spec.py` | `most_common(24)` truncates the colour list silently | Report the number omitted |
| F5 | `export_icons.py` | A small `TEXT` node matching the name regex exports as an icon | Exclude `TEXT` from candidates |
| F6 | `platform-swiftui.md`, SKILL.md | "SwiftUI cannot load SVG" overstates: Xcode accepts SVG in an asset catalog; the runtime cannot load one | Correct the reason, keep the PDF recommendation |

Also missing from extraction and worth adding while the walker is open:
`textCase` and `textDecoration`, without which a label styled as uppercase in
Figma is generated with the wrong casing.

## 6. Integration surface

Follow `mobile-optimization`, which is the only precedent in the kit:
`skill.manifest.json`, `WRITER-INTEGRATION.md`, pointer files for Claude command
/ Cursor / Windsurf, `--add-skill` wiring, lock hash and staleness reporting,
`skill-note` telemetry, the docs mirror, and surface-parity tests.

One difference from `mobile-optimization`: that skill gates on a Kotlin/Swift
stack. This one does not gate on stack at all, because the platform comes from
the user's answer rather than from detection.

Single source: the expanded template under
`agent-bootstrap/templates/skills/figma-to-code/` is canonical. `AGENTS.md`
inside the skill and any `.skill` archive are generated at packaging time. The
supplied zip contains two divergent copies of the same content; neither is
committed.

## 7. Non-goals

No Figma plugin, no design-token/variables import (Enterprise-only), no
automatic writing into the project's resource directories, no MCP server, no
network dependency beyond Python's standard library, and no attempt to generate
behaviour that a static design cannot express.

## 8. Work packages

One packet. Pre-coding adequacy review is this document. Checkpoint reviews are
pre-registered on WP2 and WP3 because both touch security or budget.

1. **WP1 — Port.** Canonical template, corrections F1–F6, `textCase`/
   `textDecoration`, English CLI messages, single-source packaging.
2. **WP2 — Credentials.** stdin-only entry, hidden prompt, `--icons=` chaining,
   scrub-and-fail guard, warning on environment token. *Checkpoint.*
3. **WP3 — Budget.** Remove per-skill bullets, update the affected assertions,
   add the all-skills-enabled budget assertion, measure. *Checkpoint.*
4. **WP4 — `android-xml` reference.** New platform document.
5. **WP5 — Integration and tests.** Manifest, pointers, wiring, parity suite.

**Definition of done.** Both suites pass; the full-workflow budget is at or
under 6200 with every skill enabled; a scrub test proves no product file can
carry `figd_`; the four platform references exist and are reachable; and no gate
was raised.

## 9. Questions for the user

1. Resolved: per-skill bullets removed. Measured after implementation - the
   full-workflow budget is 6183 with no skill, with one skill, and with both,
   so the number of installed skills no longer moves either budget.
2. Resolved: a config file replaces the per-run paste. The agent receives a
   path, never a credential.
3. Resolved: `android-xml` mirrors the Figma tree with LinearLayout and
   FrameLayout. The output is a suggestion a developer verifies against a
   build, so a tree that matches the design is worth more than a flat one.
   ConstraintLayout only where the design needs it.


## Implementation record (2026-08-25)

Measured full-workflow budget on the Android + Wear fixture: **6183 in every
configuration** - no skill, `figma-to-code` only, `mobile-optimization` only,
and both. Before this change the same fixture measured 6182 bare and 6210 with
one skill, over the 6200 gate. The regression test now asserts equality between
the bare and all-skills targets rather than a fixed number, so the property that
matters is what fails when it breaks.

Both suites pass. Credential guards were proven by hand before being encoded as
assertions: an unignored token file is refused, a tracked one is refused, an
unknown frame lists the known ones, the token never appears in any message, and
a token pattern in an output file aborts the run.

Deviations from the spec as written:

- The explicit path `.agents/skills/figma-to-code/.env.figma` was added to
  `SENSITIVE_LOCAL_PATHS` rather than relying on the `*/.env.*` glob, and to
  `writers-runtime.sh` as well, since the drift test compares the standalone
  hook against the generated one.
- The Claude command pointer was shortened to stay under its token cap instead
  of raising the cap.
- `agent-hook.sh`'s PreToolUse guard still covers `Edit`/`Write`/`MultiEdit`
  only. Read protection for the credential file remains a documented
  convention, and the skill says so.
