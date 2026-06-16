# Android/Kotlin Overlay

Apply only when detector reports `android_kotlin` or `android_java`.

- Prefer existing Android architecture and Gradle module boundaries.
- Verify with project-specific Gradle tasks from `project-agent-context.md`.
- Treat manifests, resources, navigation graphs, DI, R8/ProGuard, Firebase, and build variants as protected areas.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
