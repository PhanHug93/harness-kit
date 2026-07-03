---
name: mobile-optimization
description: Code-level efficiency review and refactoring for Kotlin (Android) and Swift (iOS). Behavior-preserving optimization of collections, strings, allocation, UI hot paths, and concurrency. Load when a task involves optimizing, performance-refactoring, or efficiency-reviewing .kt/.kts/.swift code.
---

# Skill — Mobile Code Optimization (Kotlin / Swift)

Scope: code-level efficiency only. Runtime performance work (startup, jank, memory profiling) is a separate concern.

## Load order (on demand — never preload)

1. This file.
2. `catalog.md` — the anti-pattern scan list (single source of truth).
3. `overlays/kotlin.md` OR `overlays/swift.md` — only the language in scope.
4. `fewshots/<language>.md` — one worked example of the expected output.

## Contract (non-negotiable)

1. **Preserve behavior first.** Filtering semantics, ordering, null/blank handling, date/timezone logic, nullability, security validation, and public API are invariants unless the user explicitly asks to change them.
2. **Characterization test before patch.** If the target code has no behavior test, write one first (golden input → output), then optimize against it.
3. **Optimize only the stated scope.** No drive-by renames, cleanup, or architecture changes in the same patch. Keep the diff reviewable.
4. **State assumptions in writing.** Removing a copy requires an immutability/ownership claim. Caching requires a thread-safety claim. Every claim appears under Trade-offs / Risks.
5. **Security-sensitive code is correctness-first.** Auth, token, wallet/key, PIN/biometric, crypto, lockout logic: conservative changes only; never remove validation; never alter timing/lockout behavior for speed.

## Decision tree

| Code path | Optimization stance |
|---|---|
| UI frame path: bind cell/view, SwiftUI `body`, scroll, draw | Aggressive allocation avoidance |
| Text input: TextWatcher, InputFilter, text bindings | Aggressive allocation avoidance |
| Startup / init | No blocking I/O, no repeated parsing, no heavy object churn |
| Background sync / batch | Reduce passes, pre-size collections, stream carefully |
| Security / payment / wallet | Conservative only |
| One-time / admin / debug | Readability; do not optimize |

Blanket rule: outside a known hot path, with no measurement, prefer answering "measure first" over speculative optimization. Pattern-level fixes are justified inside recognized hot paths (bind/body/input) even without a profile.

## Process

0. **Detect scope** — language, platform, code path class (table above), risk level.
1. **Lock behavior** — list invariants per the contract; write or extend the characterization test.
2. **Scan** — walk `catalog.md`; note only the patterns that actually apply.
3. **Patch** — apply the minimal fix per the language overlay.
4. **Validate** — run the targeted test command, then the project gate:
   `scripts/agent-guard.sh pre-final --run-verify --verify-scope fast`
   A red gate means the task is not complete. Do not report success on red.

## Response format (exact section order)

### Mode Detected
### Behavior Invariants
### Bottlenecks
### Optimized Code
### Why This Is Faster
### Trade-offs / Risks
### Tests To Protect Behavior
### Optional Further Optimization
