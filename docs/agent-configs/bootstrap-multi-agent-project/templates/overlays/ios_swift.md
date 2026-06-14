# iOS/Swift Overlay

Apply only when detector reports `ios_swift`.

- Inspect `.xcodeproj`, `.xcworkspace`, `Package.swift`, `Podfile`, and scheme layout before proposing verification.
- `xcodebuild -list` is discovery only, not a build proof.
- Do not apply Android/Gradle protected-path rules to iOS projects.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
