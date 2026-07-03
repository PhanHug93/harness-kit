# Anti-Pattern Catalog — single scan list

One line per pattern: smell → action. Code and rationale live in the language overlays; do not duplicate them here.

## Collections
- Multi-pass `filter/map/sorted` chain in a hot path → one-pass loop; sort conditionally.
- Repeated `firstOrNull` / `first(where:)` lookups by the same key → build an index map once (`associateBy` / `Dictionary(uniqueKeysWithValues:)`).
- Membership test against a List/Array inside a loop → convert to `Set` once, test against the set.
- `list + item` / `array + [item]` inside a loop → mutable accumulator, pre-sized, `add`/`append`.
- `groupBy` when only counts or sums are needed → count in one pass.
- `asSequence()` / `.lazy` applied as a blanket fix → only for large, linear, short-circuiting chains; otherwise a plain loop.

## Strings
- `trim()` / `trimmingCharacters` used only to check blank → `isBlank()` (Kotlin) / `allSatisfy(\.isWhitespace)` (Swift). Keep trimming when the normalized value is actually used.
- `split` / `components(separatedBy:)` to extract one token → index-based slice.
- Regex compiled per call → cache the compiled instance (immutable, thread-safe).
- Formatter created per call, per loop iteration, or per bind → cache one instance; pin calendar/locale/timezone; never mutate a shared formatter.
- String interpolation into logs that may be disabled → format-args logging.

## Allocation
- `copy()` / struct copy with no changed fields → keep only with an ownership/immutability reason; always warn before removing a copy.
- DTO → domain → UI mapping inside bind/`body` → precompute display models in the ViewModel layer.

## UI hot paths
- Sorting, filtering, formatting, or decoding inside `onBindViewHolder` / `cellForRowAt` / SwiftUI `body` → move to ViewModel; use DiffUtil/diffable updates and stable IDs.
- `ForEach(items.indices, id: \.self)` or other unstable identity → stable model IDs.

## Async
- `GlobalScope`, `runBlocking`, wrong dispatcher; Flow collected outside lifecycle → `viewModelScope` + `repeatOnLifecycle`; `Default` for CPU, `IO` for blocking I/O.
- Unowned `Task {}`, missing cancellation, CPU-heavy work on MainActor → structured concurrency; cancel on reuse; move CPU off main.
- Unbounded task group over a large list → bounded concurrency.

## Security — never "optimize" into these
- Logging secrets to debug performance.
- Caching decrypted keys or tokens without expiry/invalidations.
- Removing validation branches; weakening PIN/biometric/lockout or constant-time comparisons.
- Replacing standard crypto with custom byte/string manipulation.
- Swallowing security exceptions to avoid crashes.
