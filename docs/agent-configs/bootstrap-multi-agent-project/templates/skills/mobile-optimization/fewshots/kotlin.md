# Kotlin Few-Shot — one-pass partition with special-cased "today"

The expected response shape for this skill. Names are generic; the transformation pattern is what matters.

## Input

```kotlin
fun partitionSyncableRecords(
    records: List<DailyRecord>,
    typeCode: Int?,
    todayKey: String,
    includeToday: Boolean,
    nowSeconds: Long,
    legacyPredicate: (DailyRecord) -> Boolean,
): SyncPartition {
    val syncable = mutableListOf<DailyRecord>()
    val withheld = mutableListOf<DailyRecord>()

    records.asSequence()
        .filter { it.dateKey.trim().isNotEmpty() }
        .filterNot { it.dateKey == todayKey }
        .filter(legacyPredicate)
        .forEach { record ->
            if (record.hasRequiredMetrics(typeCode)) syncable += record.copy()
            else withheld += record.copy()
        }

    if (includeToday) {
        records.firstOrNull { it.dateKey.trim().isNotEmpty() && it.dateKey == todayKey }?.let { today ->
            if (today.hasRequiredMetrics(typeCode)) {
                syncable += today.copy(timestamp = nowSeconds, status = RecordStatus.PENDING.code)
            } else {
                withheld += today.copy()
            }
        }
    }

    return SyncPartition(
        syncable = syncable.sortedBy { it.timestamp },
        withheld = withheld.sortedBy { it.timestamp },
    )
}
```

## Output

### Mode Detected
Kotlin code-level optimization for domain logic.

### Behavior Invariants
- Blank date keys are ignored.
- Historical records exclude `todayKey`.
- Historical records must pass `legacyPredicate`; today does **not** go through `legacyPredicate` (matches original).
- Today is included only when `includeToday == true`; when multiple records match today, the first wins.
- Complete records go to `syncable`; incomplete to `withheld`.
- Today's complete record gets `timestamp = nowSeconds` and `status = PENDING`.
- Both outputs are ordered by `timestamp`.

### Bottlenecks
- `asSequence()` adds overhead for this side-effecting, branching pipeline.
- `trim().isNotEmpty()` may allocate just to check blank.
- `records` is scanned a second time to find today.
- `sortedBy` always allocates new lists; `copy()` allocates per item (kept — ownership unproven).

### Optimized Code

```kotlin
fun partitionSyncableRecords(
    records: List<DailyRecord>,
    typeCode: Int?,
    todayKey: String,
    includeToday: Boolean,
    nowSeconds: Long,
    legacyPredicate: (DailyRecord) -> Boolean,
): SyncPartition {
    val estimated = (records.size / 2).coerceAtLeast(1)
    val syncable = ArrayList<DailyRecord>(estimated)
    val withheld = ArrayList<DailyRecord>(estimated)

    var today: DailyRecord? = null
    var syncSorted = true
    var holdSorted = true
    var lastSync = Long.MIN_VALUE
    var lastHold = Long.MIN_VALUE

    for (record in records) {
        val key = record.dateKey
        if (key.isBlank()) continue

        if (key == todayKey) {
            if (includeToday && today == null) today = record
            continue
        }
        if (!legacyPredicate(record)) continue

        if (record.hasRequiredMetrics(typeCode)) {
            val copied = record.copy()
            if (copied.timestamp < lastSync) syncSorted = false
            lastSync = copied.timestamp
            syncable.add(copied)
        } else {
            val copied = record.copy()
            if (copied.timestamp < lastHold) holdSorted = false
            lastHold = copied.timestamp
            withheld.add(copied)
        }
    }

    if (includeToday) {
        today?.let { t ->
            if (t.hasRequiredMetrics(typeCode)) {
                val copied = t.copy(timestamp = nowSeconds, status = RecordStatus.PENDING.code)
                if (copied.timestamp < lastSync) syncSorted = false
                syncable.add(copied)
            } else {
                val copied = t.copy()
                if (copied.timestamp < lastHold) holdSorted = false
                withheld.add(copied)
            }
        }
    }

    if (!syncSorted && syncable.size > 1) syncable.sortBy { it.timestamp }
    if (!holdSorted && withheld.size > 1) withheld.sortBy { it.timestamp }

    return SyncPartition(syncable = syncable, withheld = withheld)
}
```

### Why This Is Faster
- Single scan of `records`; no second lookup pass for today.
- No sequence/lambda pipeline overhead; `isBlank()` avoids trim allocation.
- Pre-sized result lists; in-place sort only when input was actually unordered.

### Trade-offs / Risks
- Conditional-sort tracking adds state; keep only if input is usually sorted.
- Removing `copy()` would save more, but requires proof that `DailyRecord` is immutable and never shared across mutation boundaries — not proven here, so copies stay.

### Tests To Protect Behavior
- Empty list; blank date key.
- Historical complete/incomplete; historical rejected by `legacyPredicate`.
- `includeToday` true/false; today complete/incomplete.
- Multiple records matching today — first one used.
- Already-sorted and unsorted timestamps.
