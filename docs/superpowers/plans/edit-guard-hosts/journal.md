# Edit guard hosts — journal

Spec: `docs/superpowers/specs/2026-11-05-edit-guard-hosts-design.md`.
Branch `bugfix/edit-guard-outside-project`, stacked on
`feature/seat-first-roles` (`9bb2be9`).

## 2026-11-05 — why and decisions

- **The problem.** Since 2026.10.20.1 the Claude edit hook blocked every path
  outside the project with exit 2, so Claude could not write its memory or
  its session scratchpad in a kit project.
- **The council.** Claude and Codex debated it in two rounds plus a reply
  (local packet `edit-guard-outside-project-2026-11-05`). They agreed:
  - it is an over-block, not a privilege hole;
  - the same release had closed a real gap, a Write through an in-project
    symlink pointing outside;
  - Claude Code 2.1.318 also refuses that write in accept-edits mode.
- **Owner decisions:**
  - option A: an outside path is the host's decision;
  - NotebookEdit and a Codex `PreToolUse` hook in the same change;
  - this branch stacked on the seat branch.

## Implementation

- **Part A: classifying the path.** `pre-edit` now sorts every path into one
  of three cases:
  - **inside:** as before;
  - **escape:** a symlink or `..` out of the project, also through an alias
    of the root. It still blocks, with "path escapes the project root";
  - **outside:** it exits 4 with `outside_project=true`. The Claude hook lets
    the call through, but still asks first in a cross-repo session.
  - A path that resolves inside is checked as inside, so the protected-file
    check still applies. Example: `/x/../<root>/AGENTS.md`.
- **Part B: NotebookEdit.** It is now in the matcher, and the hook reads
  `notebook_path`. The verifier, the doctor and the prose name it.
- **Part C: the Codex hook.**
  - A new kit file `.codex/hooks.json` runs `scripts/agent-hook.sh
    codex-pretool` for `apply_patch`. Every path in the patch (add, update,
    delete, move) goes through `pre-edit`.
  - A path outside the project is left to the Codex sandbox.
  - The launcher and the doctor warn until Codex trusts the hook in `/hooks`.
- **Upgrade over a user's own `.codex/hooks.json`.** The user file is kept
  and a `.generated` candidate is written next to it. The verifier then
  reports "Codex PreToolUse does not guard apply_patch", and also warns about
  the pending candidate.
- **Tests:**
  - new `scripts/test-edit-guard-hosts.sh` (fast, ci-4): at the end, 33
    Claude cases (3 only on a case-insensitive volume), 22 Codex patch cases
    and 2 raw Codex inputs, plus the verifier and doctor checks;
  - an outside path in the cross-repo case of
    `test-workspace-repository-guard.py`;
  - the hot-path and drift test messages are updated, and the focus
    `outside-root` case now expects exit 0.
- **Budget.** Agent docs hold 7,899 of 7,900 words. The README trust line
  took the words saved by shortening the capacity sentence.

## 2026-11-05 — Codex review of the plan

A read-only Codex review raised four blockers and six other findings. Seven
were real and are fixed:

- the no-python fallback;
- the empty array under bash 3.2;
- a parser crash looking like "no paths";
- the CHANGELOG `## Unreleased` rule;
- CRLF in patch paths;
- a verifier that passed on the wrong event or matcher;
- the missing rule row and hot-path budgets.

Two were already right in the code: the place of the drift assertion, and
the upgrade fixture. One was partly right: the trust check now reads the
whole table, and its messages say "trust record".

## 2026-11-05 — Part D: agent instructions outside the project

The owner asked to keep the prompt-injection guard. Claude Code's own
protected paths cover `~/.claude/`, except auto-memory Markdown, and shell rc
files. They do not cover `~/.codex/` or another repository's `AGENTS.md`.

- **Rule.** `pre-edit` exits 5 for those agent-instruction files. Claude asks
  the user, also in auto mode; Codex blocks.
- **Exception.** This project's own auto-memory Markdown is written directly
  (owner: "Ghi thẳng").
- **Tests.**
  - 11 new Claude cases, including a memory symlink to `~/.codex/AGENTS.md`,
    and 2 new Codex cases.
  - The lexical fallback without python3 is covered.
  - A mutation that turns the rule off is caught.

## 2026-11-05 — Codex probe of R1–R3

The owner ran the probe on Codex CLI 0.166.0, macOS, with
`--dangerously-bypass-hook-trust`. So the default trust flow is not proven.

- **R1 holds.**
  - The real input is `tool_name: apply_patch`, with the patch text in
    `tool_input.command` and relative paths.
  - Exit 2 blocked a protected path; a normal patch went through.
- **R2 holds.** Under `read-only` the hook wrote the context pack, and the
  sandbox still refused the patch.
- **R3 failed, for two reasons:**
  - **No system `PATH` in the Codex shell.** The kit config has had
    `inherit = "none"` since June, so `include_only` had nothing to keep.
    The ack command failed with "command not found: bash".
    - Claude reproduced this with `codex exec -s read-only`: `none` gives
      only Codex's own folder; `core` and `all` give `/bin` and `TMPDIR`.
    - Fix: `inherit = "core"`, plus `TMPDIR` in `include_only`.
  - **Two state dirs.** The sandbox keeps `.agents/` read-only (Claude saw
    "operation not permitted" in `workspace-write`), so the ack went to
    `/tmp/agent-bootstrap-state/<cksum>/`. The hook runs outside the
    sandbox and read `.agents/state`.
    - Fix: `ack_log_usable` also reads the `TMPDIR` and `/tmp` logs for the
      project, only when they are yours and nobody else can write them. New
      logs are created with `umask 077`.
- **Tests.** Three new Codex cases: an ack under `TMPDIR`, under `/tmp`, and
  in a log others can write (blocked, with a warning). Two mutations, no
  fallback read and no owner check, are caught.
- **Follow-up, not in this change.** The same read-only `.agents/` stops
  other Codex writes there, such as packet files.

## 2026-11-05 — Codex review of the diff

A read-only Codex review raised seven findings, and an owner-run Codex check
of the R3 fix raised the fourth one on its own. All seven were real and are
fixed:

1. **Patch headers.** Codex trims Unicode whitespace around a header, so
   `*** Delete File: CLAUDE.md` plus a no-break space, or an indent, hid
   `CLAUDE.md`. The hook now trims the same set (Codex 0.166
   `streaming_parser.rs`).
2. **Large input.** The hook JSON went through one environment variable. A
   patch over 1 MiB on macOS (128 KiB on Linux) stopped python with
   "Argument list too long", and the hook let the patch through. Both hooks
   now use stdin: the Claude hook had the same gap for a large Write, since
   before this branch.
3. **Case.** On a case-insensitive volume, `agents.md` in another repository
   got exit 4, not 5. The root in another case was "outside", which bypassed
   the protected-path check (blocked before this branch). Fixed:
   - names and homes fold;
   - the root is found by inode;
   - an existing file is matched by its name on disk.
4. **Temp log as the current state.** When the hook itself could not write
   `.agents/state`, the temp log was the primary log and skipped the trust
   check. The check now applies by location.
5. **Swap and links.** Another local user could swap a checked log for
   another, or link this project's log to another project's. The check now
   runs on the descriptors, opened with `O_NOFOLLOW`, from the
   `agent-bootstrap-state` dir down.
6. **Fallback without python3.** It ignored `CODEX_HOME` and
   `CLAUDE_CONFIG_DIR`, and case. Fixed. An outside spelling that
   normalizes into the root still fails closed there; the spec now says so.
7. **Verifier.** `echo scripts/agent-hook.sh codex-pretool` passed. It now
   wants the kit command exactly, as a `command` hook.

Tests: 17 new cases. Eleven mutations, one per fix plus the Claude stdin
channel, are caught.

**Not changed.** The protected-path match itself stays case-sensitive for a
new file: a new `agents.md` on macOS, where no `AGENTS.md` exists yet, is not
protected. That predates this branch; it is a follow-up.

## 2026-11-05 — `/hooks` trust flow, no bypass

The owner trusted the project and then the hook in the Codex TUI, on a fresh
install of `48263ad` (Codex CLI 0.166.0, macOS). No bypass flag, no sandbox or
approval override. Codex's own `hooks/list` gave the hook status. The first
hook run writes `.agents/state/context-pack.json`, which the sandbox cannot,
so that file shows whether the hook ran.

- Before project trust, Codex loads no project hook.
- After project trust, the hook is `untrusted` ("1 hook is new or changed"),
  the doctor warns, and the hook does not run.
- After trust in `/hooks`: a normal patch goes through; `.github/hook-probe.txt`
  is "blocked by PreToolUse hook" and stays unchanged; an ack from the Codex
  shell lands in the `TMPDIR` state, and the retry goes through.
- A new session keeps the trust.
- A changed entry (`timeout` 30 → 31) is `modified`: Codex skips it until
  review, while the doctor still says "trust record" (R4). Restoring the
  entry restores `trusted`.

**Changed after a Codex review.** The doctor still checks the record only
(no `hooks/list` call), but it no longer says `ok`. With a record it prints an
`info` line: "trust for the current hook entry is not verified: check /hooks
in codex". Docs now say trust covers the hook as written.

## 2026-11-08 — re-council and fixes (amended into this commit)

The owner asked for a new council after the seat PR opened: three read-only
Claude seats (scope, security, correctness), one Codex 0.166 review, and the
chair reproducing install `d854770` → `206e047` → this commit with crafted
hook payloads. Verdict: request changes. Owner decisions: fix the
regression, the P2s and the cheap P3s here (amend); Part D gains four
files; the inside-project gaps are a separate follow-up.

- **Regression: a `..` after a link.** The guard resolved `..` through
  links, Codex drops it as text. `/var/..<root>/scripts/agent-hook.sh` was
  "outside" (rc 4) on both hooks while Codex wrote the protected file; the
  seat commit had blocked it. Now a path whose textual and real forms differ,
  with one in the project, is an escape.
- **Part D gaps.** `~/.claude.json`, another repository's `.mcp.json` and
  `.git/config`, `~/.gitconfig` and the XDG git config went to the host with
  no ask. They now ask (Claude) or block (Codex), also without python3.
- **Codex parser.** A NUL in a header ended the path list (a later
  `CLAUDE.md` went unchecked); `~` paths were read as `<cwd>/~`; `Edit` and
  `Write` calls with `file_path` were skipped; a padded patch (~230 paths)
  could outrun the 30 s timeout. Now: NUL kept as text, `~` checked both
  ways, `file_path` checked, repeats counted once, more than 100 paths
  blocked.
- **umask 002.** The pack write made the TMPDIR state dir with the process
  umask, so a Codex ack never counted (fails closed). A run with a temp
  state dir now uses umask 077, and an ack closes your own open temp dirs.
- **Smaller.** Ask-path crashes (a path that is not UTF-8, a lone
  surrogate) exited 1, which Claude Code lets through: now they ask; a
  Claude edit call without a path blocks. The verifier rejects an `async`
  Codex hook, and names a missing NotebookEdit when an edited settings.json
  is kept. Spec text synced (escape message, `outside_project=true`, trust
  wording, umask); a CHANGELOG line that described a Codex hook before this
  release is fixed.
- **Retracted by the chair:** a `/tmp` alias "bypass" (the probe passed a
  literal backslash, a relative path).
- **Left as is:** a nested git repository as Codex cwd runs no guard;
  `cd <dir> && apply_patch` paths resolve against the hook cwd; a custom
  protected pattern spelt unlike the file on disk; the trust check reads only
  `pre_tool_use:0:0`; noise when another user owns `/tmp/agent-bootstrap-state`;
  `AGENT_HOOK_PYTHON` is a test seam for the python check only.
- **Tests.** `test-edit-guard-hosts.sh` gains a case per fix and the
  spec-listed update case (a user's own `hooks.json` is kept, with a
  candidate). Run against the unfixed commit, every new case fails for its
  reason; after the fix the suite and the guard, path-policy, hot-path,
  verification-evidence, shellcheck, pipe-safety, rules, syntax and
  guard-race suites pass.
