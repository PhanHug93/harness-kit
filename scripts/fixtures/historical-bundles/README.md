# Historical migration fixtures

These repository-only archives are immutable exports of the two historical
`agent-bootstrap` trees used by the migration harness. Their pinned commits,
archive sizes/digests, and per-file bytes/modes are recorded in `manifest.json`.

The migration test verifies the archive before extracting it into a disposable
directory. It rejects traversal paths, links, special members, duplicates, and
files outside `agent-bootstrap/`. Fixture mode is selected with
`--historical-source fixtures`; tags mode requires the corresponding local tags,
and auto mode uses a verified local tag when available before falling back to
these archives.
