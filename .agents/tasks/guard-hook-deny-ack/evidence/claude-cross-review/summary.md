# Claude cross-review — fresh verification summary

Snapshot reviewed: `worktree-snapshot.tgz` (sha256 3afefea08c6a18b3333103a7690f4b88c40e41ec1896c1a91eccc8a61ff62e4f), tar of the worktree excluding `.git`/`.agents`, base 45585fa + 6 uncommitted files.

| Check | Environment | Result |
|---|---|---|
| Focused guard/hook regression (`BOOTSTRAP_GUARD_FOCUS_ONLY=true`) | device VM, non-root, bash 5.1 | rc=0 (22s) |
| Mutation: `3) exit 2` → `3) exit 1` in hook heredoc + snapshot, on a copy | device VM | focused test FAIL: `protected edit denial expected rc=2 actual rc=1` |
| Fresh fixture (Android, version catalog) generated from worktree bundle: deny / CLI ack / reuse / other path | device VM | rc=2 (2 stderr lines) / rc=0 `ack_source=ack` / rc=0 `ack_source=log` / rc=2 |
| Snapshot equality `agent-bootstrap/agent-hook.sh`, `agent-guard.sh` vs generated | device VM | identical |
| `test-onboarding-fixtures.sh` | cloud container, bash 5.2 | rc=0 |
| `test-one-shot-upgrade.sh` | cloud container | rc=0 |
| `test-bootstrap-multi-agent-project.sh` as root | cloud container | rc=1 at `TMPDIR fallback state did not receive verification report` — environment artifact: `chmod a-w` does not restrict root; pre-existing test, unrelated to this change |
| `test-bootstrap-multi-agent-project.sh` as non-root user | cloud container | rc=0 (382s) |
| Context budget on fresh fixture (`codex-mode.sh doctor`) | device VM | core 2365 / on-demand 6068 (amber) |
