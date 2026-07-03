# Swift Few-Shot — normalize without intermediate arrays

## Input

```swift
func normalizeNames(_ names: [String]) -> [String] {
    names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { $0.lowercased() }
        .removingDuplicates()
        .sorted()
}
```

## Output

### Mode Detected
Swift collection/string optimization.

### Behavior Invariants
- Names are trimmed; empty names removed; names lowercased; duplicates removed; output sorted.

### Bottlenecks
- Four intermediate arrays plus a dedup pass. Trimming and lowercasing are required by the output contract, so they stay — the passes collapse.

### Optimized Code

```swift
func normalizeNames(_ names: [String]) -> [String] {
    guard !names.isEmpty else { return [] }

    var unique = Set<String>()
    unique.reserveCapacity(names.count)

    for name in names {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        unique.insert(trimmed.lowercased())
    }
    return unique.sorted()
}
```

### Why This Is Faster
- One pass normalizes and deduplicates via `Set`; only the final sort allocates.

### Trade-offs / Risks
- `lowercased()` performs locale-independent Unicode case mapping. If business rules require locale-specific casing (e.g., Turkish dotless i), switch to `lowercased(with:)` explicitly — that changes behavior and must be called out.
- `trimmingCharacters` stays because the output requires trimmed values (contrast with blank-only checks, where `allSatisfy(\.isWhitespace)` avoids the allocation).

### Tests To Protect Behavior
- Empty list; whitespace-only names; duplicates differing only by case; Unicode names.
