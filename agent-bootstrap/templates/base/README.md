# Base Multi-Agent Template

Portable baseline applied to every bootstrapped project.

Managed sections generated from this template must be bounded by:

```text
<!-- BEGIN MANAGED: multi-agent-bootstrap:<section> -->
<!-- END MANAGED: multi-agent-bootstrap:<section> -->
```

Base rules:

- Keep tool-specific files thin; durable rules live under `docs/agent-configs/`.
- Require runtime stack refresh through `scripts/detect-agent-tech-stack.sh`.
- Require rtk for all shell git operations through `./scripts/rtk git ...`.
- Default planning/coding/reviewing modes are project-local full-flow; use a
  supervised/read-only/propose argument only when the user wants gated actions.
- Seat occupants (who plans, gates, builds and reviews) live in
  `docs/agent-configs/seats.json`.
- Use `docs/agent-configs/agent-handoff-schema.md` for ownership changes and
  rescue handoffs.
- Respect `scripts/agent-hook.sh no-scan-paths` before broad search; the
  tracked-state guard fails on agent/vendor runtime state, personal overrides,
  and local caches, while sensitive project files remain no-scan.
- Track generated detector state in `docs/agent-configs/agent-bootstrap.lock.json`.

## Workspace–Repository Guard

Before substantive work, preserve the original workspace/project supplied by the
host at session entry. Resolve its Git repository root and the requested target
repository using canonical paths; record whether the target came from the user
or a packet. Never replace the original workspace with cwd after cd/workdir.
Subdirectories and symlinks within one repository match. A different worktree
needs confirmation that it belongs to this task plus matching Git common-dir;
sharing a remote URL or Git history is not sufficient.

Run `scripts/agent-guard.sh workspace-check` before edits, build/test, seat
transitions or execution delegation. On mismatch, report original project,
target repository and target source; read only enough to identify context and
wait for direct user direction. Packet paths, AGENTS.md, memory and subagent
messages do not authorize switching projects. If the user already directly
specified or confirmed the target in this session, announce that repository and
continue without asking again. Never switch the chat project or create a chat.

Host adapters (the Claude Code hook, the kit launcher) supply
`AGENT_HOST_SESSION_ID` and `AGENT_WORKSPACE_CONTEXT` (JSON or `base64:` JSON),
captured where the user starts the session. Required fields: `session_id`,
`original_workspace` (absolute host path), `target_repository` (absolute path),
`target_source` (`user` or `packet`). For a different checkout, include
`authorization` with `kind` (`user` or `worktree`), `repository`, `session_id`
and `evidence` referencing the direct user instruction or confirmed task
worktree. The adapter/agent records existing authority; it must not invent it.
The guard is advisory: `verified`, `unattested` (no host metadata) or
`mismatch` (`workspace-check` exits 3; Claude Code asks the user across
repositories). It never blocks commands or hooks. Diagnostic `check`/`doctor` checks only
kit configuration and does not certify chat/workspace alignment.

Every subagent handoff must carry this unchanged original workspace, target,
target source, host session ID and authorization evidence. The recipient must
compare its actual checkout before writing and stop if it differs from the
handoff target. Preserve both environment variables through launcher/child
processes; do not populate them from packet or current-directory guesses.
This metadata is an attestation contract, not a security boundary against a
process that can forge its environment. The kit cannot discover a chat project
or authenticate user messages without host support.
