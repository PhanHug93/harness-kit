# Kotlin Overlay — where the catalog shows up on Android

Load only for an Android/Kotlin stack. `catalog.md` says what to look for and what must stay true; this file says where that shows up on Android. It holds no recipes: choose the idiom, then state the behavior you kept.

## Hot paths
- List binding and item composition: assign prepared values only. No sorting, filtering, formatting, decoding, I/O or new background work there.
- Text input callbacks run on every keystroke: no regex compile and no needless string copies there. Keep a copy that later work reads: the input buffer changes after the callback.
- App start and screen start: no blocking I/O, no repeated parsing.

## Choices that change behavior, not only speed
- How an index is built decides which element wins when a key repeats. Check it against the original lookup.
- "Blank" depends on the trim: Kotlin's `trim()` and `isBlank()` test the same characters; Java's `String.trim()` tests a different set.
- A shared formatter must be safe across threads; not every JVM formatter is.
- A data-class `copy()` may be what isolates a caller from later mutation: keep it when fields change, when nested objects are mutable, or when the value crosses a cache, UI or network boundary.

## Lifetime and threads
- Background work belongs to a screen or view-model lifetime and stops with it. No global scope, no blocking the calling thread.
- Collect UI state only while the screen is started.
- A reference to a view must not outlive the view. A Fragment can live longer than its view.
- CPU work and blocking I/O use different thread pools; neither runs on main.

## Logs
- Never log secrets, tokens, keys, PIN or biometric data, not even to measure.
