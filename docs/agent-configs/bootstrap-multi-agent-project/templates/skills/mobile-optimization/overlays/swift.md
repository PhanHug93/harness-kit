# Swift Overlay — where the catalog shows up on iOS

Load only for an iOS/Swift stack. `catalog.md` says what to look for and what must stay true; this file says where that shows up on iOS. It holds no recipes: choose the idiom, then state the behavior you kept.

## Hot paths
- SwiftUI `body` and list rows: no sorting, formatting or model mapping. Prepare row models with a stable identity before the view.
- UIKit cell setup: assign only. No formatter creation, decoding, I/O or untracked tasks. On reuse, cancel the cell's pending work and clear what the previous item showed.
- App start and text bindings: no blocking I/O, no repeated parsing, no needless string copies per keystroke.

## Choices that change behavior, not only speed
- How a dictionary is built decides which element wins when a key repeats, and one way of building it stops the app on a repeated key. Check it against the original lookup.
- "Blank" has more than one definition: a character-level test and a `CharacterSet` trim disagree on some input. Keep the original test unless the input is proven.
- A shared formatter is set up once (calendar, locale, time zone) and never changed. Text for the user may need the current locale instead: decide per call site and say so.
- Measure before trading value semantics for a reference type.

## Lifetime and threads
- CPU-heavy work never runs on the main actor; publish the result on main.
- A task has an owner and honors cancellation. Bound the parallelism over a large list.
- A model lives as long as its owner: one the view creates must survive the view being rebuilt; one it receives stays the parent's.
