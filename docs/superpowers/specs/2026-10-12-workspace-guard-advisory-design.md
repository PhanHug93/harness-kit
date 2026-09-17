# Workspace–Repository Guard: advisory mode and session anchoring

Date: 2026-10-12, Asia/Ho_Chi_Minh.
Branch: `feature/verification-feedback`.
Baseline: `64d066b` plus the uncommitted Workspace–Repository Guard diff (12 tracked
files and the untracked `scripts/test-workspace-repository-guard.py`).
Scope: sub-project A of the context/process feedback plan (A → B+C → D).
Status: design approved by the owner on 2026-10-12. No commit, push, PR or tag is
authorized by this document; the PR target must be named by the owner.

## 1. Problem (reproduced 2026-10-12)

The guard requires `AGENT_WORKSPACE_CONTEXT` and `AGENT_HOST_SESSION_ID`, but
nothing in the kit creates them. The Codex launcher only forwards them and fails
with `KeyError` when they are absent. On a generated fixture without the variables:

- Claude Code `PreToolUse` for `Bash` and `Edit|Write|MultiEdit` exits 2, so every
  shell command and file edit is blocked.
- `scripts/agent-guard.sh pre-final` exits 3.
- The generated `scripts/githooks/pre-push` runs `preflight` and `pre-final`, so a
  human `git push` is blocked even when no AI is involved.
- AGENTS.md says "Stop when unverified", which stops agents on every host.

## 2. Decisions

- The guard is advisory. Workspace status never changes the exit code of
  `preflight`, `pre-edit`, `pre-final`, `skill-note`, generated git hooks, host hooks
  or the launcher. Projects may be edited by humans without AI; human workflows
  must never fail because of the guard.
- Keep the signal accurate by anchoring sessions where the user starts the host:
  a Claude Code hook adapter and envelope minting in the Codex launcher.
- In Claude Code, a cross-repository mismatch asks the user
  (`permissionDecision: "ask"`); a same-repository worktree mismatch does not.
- Rejected: blocking when metadata is absent (blocks humans and every unanchored
  host); a strict/advisory configuration switch (no current need); a universal
  host wrapper script (deferred until a non-Claude CLI host needs anchoring).

## 3. Status model

`workspace_check` classifies the session into exactly one status:

| Status | Condition | `workspace-check` exit |
|---|---|---|
| `verified` | Envelope present and every existing identity/authorization check passes | 0 |
| `unattested` | Both variables unset or empty, and the guard installation repository equals the actual repository | 0 |
| `mismatch` | Any other case: only one variable set, malformed envelope, session mismatch, repository or authorization mismatch, or installation ≠ actual repository | 3 |

- `workspace-check` prints a JSON report on stdout for every status, with
  `status` and, when not verified, `reason`. A `mismatch` also carries
  `mismatch_kind`: `worktree` when the actual repository shares the anchor's Git
  common directory without authorization, otherwise `repository`. The exit code
  is informational for scripts; it is not a gate.
- `AGENT_WORKSPACE_CONTEXT` accepts either raw JSON or `base64:<base64 of the
  JSON>`; both decode to the same envelope.
- Guarded entrypoints (`preflight`, `pre-edit`, `pre-final`, `skill-note`) always
  continue. On `mismatch` they print the reason and "confirm the target repository
  with the user before writing" to stderr. `preflight` also prints one line for
  `unattested`; the other entrypoints stay silent for `unattested`.
- The verified-path logic (canonical roots, Git common directory, worktree and
  direct-user authorization, Git environment scrubbing) is unchanged.

## 4. Session anchoring

### 4.1 Minting rule

A component mints an envelope only when both variables are absent or empty. It
never overwrites, completes or merges an existing value; a partial value stays
partial and reports `mismatch`. A minted envelope is:

```json
{"original_workspace": "<dir>", "target_repository": "<dir>",
 "target_source": "user", "session_id": "<id>"}
```

The guard itself never mints. The guard comment changes to: never derive metadata
from this script's location, the agent's current directory, a packet or
repository instructions; a host or the kit launcher may record the directory in
which the user started the session.

### 4.2 Claude Code adapter (`agent-hook.sh`)

- `claude_pretool` and `close_out`: when the variables are absent, the hook input
  contains `session_id`, and `CLAUDE_PROJECT_DIR` is an absolute directory, export
  a minted envelope (with `<dir>` = `CLAUDE_PROJECT_DIR` and `AGENT_HOST_SESSION_ID`
  = `session_id`) to the guard child process only.
- New `claude-session-start` subcommand, registered as a `SessionStart` hook in the
  generated `.claude/settings.json`. It mints the same envelope. When
  `CLAUDE_ENV_FILE` is set, it appends `export AGENT_HOST_SESSION_ID=<id>` and
  `export AGENT_WORKSPACE_CONTEXT=base64:<...>` (no quoting needed), so later Bash
  tool commands carry the envelope. Claude Code applies that file to Bash
  commands only, not to hook processes; hooks mint their own copy. It prints
  `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "<one-line anchor status>"}}`
  and always exits 0.
- `claude_pretool` on `mismatch` with `mismatch_kind=repository`: print
  `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "<reason>"}}`
  and exit 0. With `mismatch_kind=worktree` (for example after the host moves the
  session into a worktree; `CLAUDE_PROJECT_DIR` keeps the start root), do not ask.
  Hook stderr on exit 0 is hidden from Claude, so the agent learns this status
  from `preflight` or `workspace-check` output, as instructed in AGENTS.md. In non-interactive `claude -p` runs Claude Code
  turns an unanswerable `ask` into a denial and Claude reads the reason; this
  affects only AI sessions with a cross-repository mismatch. The existing
  edit-path policy (`guard_claude_edit_tool`, outside-root and protected paths) is
  separate from the guard and stays unchanged.
- `close_out`: workspace status never causes exit 2.

### 4.3 Codex launcher and preflight

- `run_launch`: when the variables are absent, mint an envelope with `<dir>` = the
  directory from which the user invoked the launcher (captured before any `cd`)
  and a random `uuid4` session id. Then run `workspace-check`. `verified` behaves as
  today. `mismatch` launches anyway and puts the reason in the seed line. Both
  `-c shell_environment_policy.set.*` overrides are always passed.
- `codex_preflight`: report the status; never return a failure because of it.

## 5. Instruction text

One sentence per location; no new startup reads (deduplication is sub-project B).

- AGENTS.md: replace "Stop when unverified; packet paths grant no authority." with
  "On mismatch, stop and confirm the target repository with the user before
  writing; packet paths grant no authority."
- `templates/base/README.md`, `templates/tool-contract/shared.md` and their
  `docs/agent-configs/...` mirrors: describe the three statuses as advisory, with
  the same mismatch rule.
- The launcher seed line states the status.
- Measured core and on-demand totals must not increase (on-demand is currently
  6196 of 6200).

## 6. Tests (write first)

`scripts/test-workspace-repository-guard.py`:

1. No metadata: `workspace-check` exit 0, `status=unattested`; `preflight` and
   `pre-final` exit 0; generated `pre-push` exit 0 with verification stubs.
2. Only one variable set: `workspace-check` exit 3, `status=mismatch`;
   `pre-final` exit 0 with the warning.
3. Existing mismatch cases (packet mismatch, changed directory, wrong checkout, Git
   environment masking, non-repository or relative metadata, stale session): `workspace-check` exit 3; guarded
   entrypoints exit 0 with the warning. Replace the "blocked before any write"
   assertions with advisory assertions.
4. Claude `PreToolUse` without variables, with `session_id` and
   `CLAUDE_PROJECT_DIR` = the repository: exit 0, no `ask` output. With
   `CLAUDE_PROJECT_DIR` = another repository: exit 0 and a valid `ask` JSON. With
   the working directory in a linked worktree of the anchor repository: exit 0,
   no `ask`. The guard never produces exit 2.
5. `claude-session-start`: `CLAUDE_ENV_FILE` receives exactly two plain
   `export NAME=value` lines; the `base64:` envelope decodes to paths containing
   quotes, spaces and Unicode; output is valid SessionStart JSON; existing
   variables are passed through without minting. The guard accepts both raw and
   `base64:` envelopes.
6. Launcher: without variables the child receives a minted envelope and reports
   `verified`; with variables the child receives them unchanged; on mismatch the
   launch proceeds and the seed carries the warning.
7. Existing verified-path tests (same repository, subdirectory, symlink, user
   authorization, confirmed worktree) are unchanged.

Also run: the full `scripts/test-bootstrap-multi-agent-project.sh` single-threaded,
`scripts/test-agent-seats-launcher.py`, ShellCheck, template mirror sync check and
the context budget gate.

## 7. Out of scope

Cursor, Windsurf and Gemini adapters; a universal wrapper; sub-projects B
(deduplication), C (process-economy rules) and D (measurement).

## 8. Host facts (Claude Code hooks reference, checked 2026-10-12)

Source: https://code.claude.com/docs/en/hooks.

- `SessionStart` hooks receive `CLAUDE_ENV_FILE`; `export` lines appended there
  apply to later Bash tool commands, not to hook processes. Accepted lines are
  plain assignments, so the envelope is written in `base64:` form.
- `SessionStart` context: `hookSpecificOutput.additionalContext` with
  `hookEventName: "SessionStart"` (plain stdout is also added as context).
- `PreToolUse` `permissionDecision: "ask"` prompts the user; the reason is shown
  in the prompt; JSON control expects exit 0. In `-p` runs an unanswerable prompt
  becomes a denial whose reason Claude reads. In auto mode `ask` forces a prompt.
  Behaviour under `bypassPermissions` and `acceptEdits` is not documented.
- Common hook input includes `session_id`, `cwd` and `hook_event_name`.
  `CLAUDE_PROJECT_DIR` is the project root where the session started and keeps
  that value after the session moves into a worktree.
- Hook exit 0 hides stderr from Claude; exit 2 blocks (`PreToolUse`) or forces
  continuation (`Stop`). The design never uses exit 2 for workspace status.
