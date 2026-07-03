# Kotlin Overlay — how to fix what the catalog flags

Apply only when the detector reports an Android/Kotlin stack. Patterns to *find* live in `catalog.md`; this file shows the *fix*.

## One-pass loop with conditional sort

```kotlin
val result = ArrayList<Item>(source.size)
var sorted = true
var last = Long.MIN_VALUE

for (item in source) {
    if (item.key.isBlank()) continue
    if (!item.isEligible) continue
    val updated = item.copy(status = Status.PENDING.code)
    if (updated.timestamp < last) sorted = false
    last = updated.timestamp
    result.add(updated)
}
if (!sorted && result.size > 1) result.sortBy { it.timestamp }
```

Replaces `filter/filter/map/sortedBy` chains: one scan, no intermediate lists, in-place sort only when input was actually unordered. Keep the sorted-tracking only when input is usually sorted — it adds state.

## Membership and lookup

```kotlin
val ids = selectedIdsList.toHashSet()          // O(1) membership
val byId = users.associateBy { it.id }          // repeated key lookups
```

## Cached regex

```kotlin
private val amountRegex: Regex by lazy { Regex("^\\d+(\\.\\d{1,2})?$") }
```

`Regex(...)` compiles a Pattern per call — expensive per keystroke. For extremely hot validation, a manual parser beats regex. In input paths prefer `CharSequence` and avoid `toString()` until required.

## `copy()` rules

Keep `copy()` when: fields change, mutation isolation is required, nested objects are mutable, the value crosses cache/UI/network boundaries, or defensive copy is part of the API contract. Remove it only with a written immutability/ownership justification — and say so in Trade-offs.

## Logging

```kotlin
Timber.d("payload=%s", payload)   // args formatted only if loggable
```

Interpolated strings (`"payload=$payload"`) are built before the call regardless of log level. Never log secrets, tokens, keys, PIN, or biometric payloads.

## RecyclerView bind path

Forbidden in `onBindViewHolder`: sorting, filtering, formatter creation, network/database calls, bitmap decode, heavy parsing, launching untracked coroutines. Precompute a display model instead:

```kotlin
data class RowUiModel(val id: Long, val title: String, val dateText: String)
```

Build it in ViewModel/use case; bind only assigns. Use ListAdapter/DiffUtil and stable IDs for large updates.

## Coroutines and lifecycle

```kotlin
viewLifecycleOwner.lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        viewModel.uiState.collect(::render)
    }
}
```

No `runBlocking` in app code; no `GlobalScope`. `Dispatchers.Default` for CPU work, `Dispatchers.IO` for blocking I/O — do not shove everything onto IO. Clear Fragment ViewBinding in `onDestroyView`.
