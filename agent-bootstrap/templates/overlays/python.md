# Python Overlay

Apply only when detector reports `python`, `python_fastapi`, or `python_django`.

- Prefer existing package/test layout before introducing new structure.
- Verify with the detected test/lint commands only after confirming they exist.
- Do not apply Android/Gradle protected-path rules to Python projects.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
