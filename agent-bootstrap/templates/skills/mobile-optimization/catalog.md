# Anti-Pattern Catalog — single scan list

One line per pattern: what to look for → where the fix goes → what must stay true. The idiom is your choice: pick the one that fits the code and the platform, and check that it keeps the behavior named here.

## Collections
- Several passes over one collection in a hot path (filter, map and sort chains) → one pass. Keep the result order, including the order of equal elements. If a callback may change the data, keep each read at its original moment.
- The same list searched by key again and again → index it once. The same element must win when a key repeats, and a repeated key must not crash.
- Membership test against a list inside a loop → a set built once. Keep the equality the original used.
- A new collection built on every loop step → one collection that grows.
- Grouping when only counts or sums are needed → count in one pass.
- Lazy sequences added as a blanket fix → only for large chains that can stop early; otherwise a plain loop.

## Strings
- A trimmed copy made only to test for blank → a test that makes no copy and treats the same characters as blank. Keep the trim when its result is used.
- A split made to read one part → read that part in place.
- A regex or a formatter built per call, per loop step or per bind → build it once and reuse it. A shared instance must be safe across threads and is never changed after creation. Pin locale, calendar and time zone when a machine reads the output.
- A log message built even when the log is off → let the logger build it only when it writes.

## Allocation
- A copy with no changed field → remove it only with a stated ownership or immutability reason; otherwise keep it and say why.
- Model-to-display mapping inside a bind or a view body → prepare display models before the UI layer.

## UI hot paths
- Sorting, filtering, formatting, decoding or I/O inside a list bind, a cell setup or a view body → do it before the UI layer; the UI only assigns.
- List identity that changes between updates (positions used as ids) → stable ids from the model.

## Async
- Work with no owner or no cancellation (a global scope, a blocked caller, a detached task) → tie it to the screen or view-model lifetime and cancel it with that owner.
- CPU-heavy or blocking work on the main thread → move it off main; publish the result on main.
- One task per element of a large list → bounded parallelism.

## Security — never "optimize" into these
- Logging secrets to debug performance.
- Caching decrypted keys or tokens without expiry/invalidations.
- Removing validation branches; weakening PIN/biometric/lockout or constant-time comparisons.
- Replacing standard crypto with custom byte/string manipulation.
- Swallowing security exceptions to avoid crashes.
