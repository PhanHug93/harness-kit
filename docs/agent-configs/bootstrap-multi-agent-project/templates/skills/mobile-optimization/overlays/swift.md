# Swift Overlay — how to fix what the catalog flags

Apply only when the detector reports an iOS/Swift stack. Patterns to *find* live in `catalog.md`; this file shows the *fix*.

## One-pass loop with conditional sort

```swift
var result: [Item] = []
result.reserveCapacity(source.count)
var isSorted = true
var last = Int64.min

for item in source {
    guard !item.key.allSatisfy(\.isWhitespace) else { continue }   // blank check, no allocation; true for "" too
    guard item.isEligible else { continue }
    var updated = item
    updated.status = .pending
    if updated.timestamp < last { isSorted = false }
    last = updated.timestamp
    result.append(updated)
}
if !isSorted && result.count > 1 {
    result.sort { $0.timestamp < $1.timestamp }
}
```

Replaces `filter/filter/map/sorted` chains. `reserveCapacity` with a conservative estimate when output size is uncertain.

## Membership and slicing

```swift
let idSet = Set(selectedIds)                       // O(1) membership
if let i = value.firstIndex(of: ":") {             // instead of components(separatedBy:)
    return String(value[..<i])
}
```

## Cached regex

```swift
private enum AmountValidator {
    static let regex = try! NSRegularExpression(pattern: #"^\d+(\.\d{1,2})?$"#)
}
```

`NSRegularExpression` is immutable and thread-safe after creation — a `static let` cache is correct.

## Cached formatter — pin everything, mutate nothing

```swift
private enum Formatters {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
```

Rules: never mutate a shared formatter after creation; pin calendar/locale/timezone explicitly for stable machine-format output (user-facing text may instead need current locale — decide per call site and state it); never create formatters in `body`, cell binding, or loops.

## SwiftUI

Keep `body` computation-free: no sorting, no formatting, no model mapping. Precompute row models (`Identifiable`, `Equatable`) in the ViewModel. `@StateObject` when the view owns the object, `@ObservedObject` when the parent owns it. Use stable model IDs — `ForEach(items.indices, id: \.self)` causes view recreation and state loss on reorder.

## UIKit cells

Forbidden in `cellForRowAt`/`cellForItemAt`: formatter creation, network/disk, image decoding, sorting/filtering, unowned async tasks. Cancel work on reuse:

```swift
override func prepareForReuse() {
    super.prepareForReuse()
    imageTask?.cancel(); imageTask = nil
    imageView?.image = nil
}
```

## Concurrency

CPU-heavy work never runs on MainActor — compute off-main, publish results back on main. Respect cancellation (`try Task.checkCancellation()` around await points). Bound parallelism for large lists instead of one task per element. Value types are copy-on-write — measure before replacing clean value semantics with reference types.
