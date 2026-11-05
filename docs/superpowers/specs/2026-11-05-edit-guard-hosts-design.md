# Edit guard: outside paths, NotebookEdit, Codex hook

**Status:** approved 2026-11-05, implemented in 2026.11.05.2; re-council
fixes 2026-11-08. Branch `bugfix/edit-guard-outside-project`, stacked on
`feature/seat-first-roles` (`206e047`), so it releases after the seat work.
Packet `.agents/tasks/edit-guard-outside-project-2026-11-05/`. The
Claude–Codex council behind Part A is in its `council-verdict.md`, the
re-council in `council-2026-11-08.md`.

## Why

- **The Claude hook blocks every outside path.**
  - Since release 2026.10.20.1 (commit `796e12d`), `guard_claude_edit_tool`
    (`agent-hook.sh:266-290`) turns every `pre-edit` error into exit 2,
    including "path outside project root".
  - So Claude cannot write its own memory (`~/.claude/projects/<slug>/memory/`)
    or the session scratchpad, and an ack cannot help: the outside check runs
    before the ack check (`agent-guard.sh:1355` vs `:1371`).
  - Evidence: `evidence/replay-2026-11-05.txt` and
    `replay-same-repo-2026-11-05.txt`.
- **The same commit closed a real gap.** Before it, a Write through an
  in-project symlink pointing outside was let through (rc 1).
  - Claude Code 2.1.318 also refuses that write in accept-edits mode
    (`evidence/claude-symlink-probe-2026-11-05.txt`), so the kit block is a
    second layer. It matters in bypass mode and on older hosts.
- **NotebookEdit is not guarded.** The matcher is `Edit|Write|MultiEdit`, and
  the hook reads only `tool_input.file_path` or `path` (`agent-hook.sh:229`).
- **Codex has no per-call guard.**
  - The kit checks Codex at launch (`codex_preflight`) and after the run
    (launcher close-out). A protected file is caught only after it has changed.
  - codex-cli 0.166 has stable hooks (`codex features list`), and
    `apply_patch` reaches `PreToolUse`.

## Owner decisions (2026-11-05)

- Council option A: an outside path is the host's decision.
- NotebookEdit and the Codex hook ship in the same change.
- The branch is stacked on the seat branch; one commit at the end, with the
  release bump.
- Keep the prompt-injection guard ("vẫn giữ nguyên tắc chống đầu độc prompt"):
  agent instructions outside the project always go to the user, and this
  project's own auto-memory Markdown is written directly ("Ghi thẳng").

## Owner decisions (2026-11-08, after the re-council)

The re-council of the first commit (packet `council-2026-11-08.md`) asked for
changes. The owner decided:

- Fix the regression (a `..` after a link), the P2 findings and the cheap P3
  findings in this commit (amend).
- Part D also covers `~/.claude.json`, another repository's `.mcp.json` and
  `.git/config`, and the user's git config.
- Agent files inside the project that the default protected list leaves out
  (`AGENTS.override.md`, a nested `AGENTS.md`, `CLAUDE.local.md`,
  `.claude/agents/`, `.claude/skills/`, `.claude/settings.local.json`,
  `.mcp.json`, `.git/hooks/`) are a separate follow-up. That gap predates
  this branch.

## Part A — classify edit paths

`pre-edit` classifies the path after resolving it. "Touches the project"
means that some textual prefix of the absolute raw path resolves to the
project root or into it.

| Case | Rule | `pre-edit` result | Hook result |
|---|---|---|---|
| inside | real path in the root | as today (protected, ack) | as today |
| escape | touches the project, real path outside; or the textual and real paths differ and one is in the project | error "path escapes the project root (symlink or ..)" | block (exit 2) |
| outside | does not touch the project, real path outside | exit 4, `path=<abs> outside_project=true` | host decides |
| guard error | context or policy broken | error, as today | block (exit 2) |

**Examples:**

- `/tmp/p/out-link/x` with root `/private/tmp/p`: escape.
- `<root>/../x`: escape.
- `~/.claude/projects/<slug>/memory/m.md`: outside.
- `/x/../<root>/AGENTS.md`: inside, so the protected-path check applies.
- `/var/..<root>/scripts/agent-hook.sh` on macOS: escape. The guard follows
  the `/var` link (`/private/private/…`, outside), while Codex drops `..` as
  text and writes the protected file in the project.

**Rules:**

- Exit 4 is new and only `pre-edit` uses it. `focus`, required context and
  the other commands keep their current errors.
- The rule lives in the Python `classify_edit()` of the policy snapshot.
  - "Resolves into the root" compares by inode, so the root under another
    spelling counts: another case on a case-insensitive volume, a bind mount.
  - An existing file is matched by its name on disk, so on macOS `claude.md`
    is the protected `CLAUDE.md`.
- Without python3, the bash fallback (`outside_lexical`, then
  `canonical_project_relpath`) has no symlink resolution. An outside spelling
  that normalizes into the root fails closed there.
- **Claude hook:**
  - rc 4 keeps the classification line on stdout, like any allowed edit. It
    then falls through to the existing workspace check (`claude_ask` for a
    cross-repo session, `agent-hook.sh:613-617`) and exits 0.
  - It never prints `permissionDecision: "allow"`.

## Part D — agent instructions outside the project

Option A alone would hand writes to other agents' instructions to the host.
Claude Code protects `~/.claude/` (except auto-memory Markdown) and shell rc
files, but not `~/.codex/` or another repository's `AGENTS.md`. In auto mode
its classifier decides, and in bypass mode nobody does. A prompt injection
could then plant instructions for a later session, or for the other agent.

- **Rule.** `pre-edit` exits 5 for an outside path (raw or real) when it is
  one of these:
  - in the Claude home (`$CLAUDE_CONFIG_DIR` or `~/.claude`);
  - in the Codex home (`$CODEX_HOME` or `~/.codex`);
  - in `~/.agents`;
  - under a `.claude`, `.codex`, `.agents`, `.cursor`, `.gemini`, `.windsurf`
    or `.openclaude` directory;
  - under `.git/hooks`, or a `.git/config`;
  - `~/.claude.json`, `~/.gitconfig` or `${XDG_CONFIG_HOME:-~/.config}/git/config`;
  - named `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md`,
    `GEMINI.md`, `.cursorrules`, `.windsurfrules` or `.mcp.json`.
- **Exception.** Markdown files in this project's own Claude auto memory
  (`<claude home>/projects/<slug>/memory/`). The slug comes from the project
  root and from `$CLAUDE_PROJECT_DIR`. A symlink there that points at a
  listed file still asks.
- **Claude hook.** rc 5 asks the user (`permissionDecision: "ask"`), also in
  auto mode, together with the cross-repo question when there is one.
- **Codex hook.** It has no `ask`, so rc 5 blocks the patch and tells Codex
  that the user makes this change.
- **Case.** Names and homes match in any case (`agents.md`, `~/.CODEX/`): a
  case-insensitive volume opens them as the same file. The memory exception
  needs the exact spelling.
- **Without python3.** The same names and the configured homes ask, in any
  case, with no memory exception.

## Part B — NotebookEdit

- The matcher becomes `Edit|Write|MultiEdit|NotebookEdit` in both
  `.claude/settings.json` writers (full and infra).
- `read_claude_hook_input` reads `notebook_path` too; the dispatch case adds
  `NotebookEdit`. It reads the hook JSON on stdin, so a large Write is still
  checked.
- The doctor (`writers-docs.sh:2375`) and `verify-ai-deps.sh:1049` check the
  new matcher.
- An upgrade installs the new `.claude/settings.json` unless the user edited
  it; then the file is kept with a candidate beside it, and the verifier and
  doctor say "does not guard NotebookEdit" until the matcher is updated.

## Part C — Codex `PreToolUse` guard

- **Hook file.** A new kit-managed `.codex/hooks.json`, written next to
  `.codex/config.toml`:
  - event `PreToolUse`, matcher `^(apply_patch|Edit|Write)$`;
  - the command runs `scripts/agent-hook.sh codex-pretool` from the Git top
    level, because hooks run in the session `cwd`;
  - timeout 30 s.
- **`agent-hook.sh codex-pretool`:**
  - It reads the hook JSON on stdin; an environment variable would not hold
    a large patch. An `Edit` or `Write` call is checked by its
    `tool_input.file_path`; any other tool exits 0.
  - It takes the paths from `tool_input.command`: `*** Add File:`,
    `*** Update File:`, `*** Delete File:`, `*** Move to:`. Relative paths
    resolve against the hook's `cwd`.
  - It reads headers as Codex 0.166 does: lines split on `\n`, Unicode
    whitespace trimmed at both ends. It also takes an indented header that
    Codex reads as context; one path too many only blocks more.
  - A path that starts with `~` is checked as written and expanded. A NUL in
    a path is kept as the text `\0`, so it cannot end the list. A repeated
    path counts once.
  - Each path costs one guard run (about 0.15 s), so a patch that names more
    than 100 paths is blocked ("split the patch") instead of running past the
    30 s timeout.
  - For each path it runs `pre-edit --strict --use-ack-log
    --workspace-checked`:
    - rc 0: allowed;
    - rc 4: skipped, the sandbox decides;
    - rc 3: denied;
    - any other rc: block.
  - A deny or block prints the reason on stderr and exits 2.
  - If `python3` or the guard is missing, or the input is malformed, it warns
    and exits 0, the same as the Claude hook.
- **Ack.** Same as Claude: `scripts/agent-guard.sh pre-edit --ack <reason>
  <path>` before the patch.
  - Codex 0.166 keeps `.agents/` read-only in its `workspace-write` sandbox,
    so an ack from a Codex shell lands in
    `${TMPDIR:-/tmp}/agent-bootstrap-state/<cksum>/guard-ack.log`. The hook
    runs outside the sandbox and picks `.agents/state`.
  - `ack_log_usable` therefore also reads the `TMPDIR` and `/tmp` logs for
    the project.
  - A log in a temp dir counts only when the log, its state dir and the
    `agent-bootstrap-state` dir are yours, nobody else can write them, and
    none is a link. The check runs on the opened descriptors, so a swap
    between check and read cannot pass. It applies by location, also when
    the hook's own state dir is the temp dir.
  - A guard run whose state dir is a temp dir uses `umask 077`, so the pack
    write and the log make private dirs also under umask 002. An ack closes
    group and other write on your own temp state dirs that an older release
    left open.
- **Codex shell environment.** `.codex/config.toml` moves from
  `inherit = "none"` to `inherit = "core"` and adds `TMPDIR` to
  `include_only`.
  - With `"none"`, `include_only` had nothing to keep: the shell `PATH` held
    only Codex's own folder, so `bash` was not found.
  - With `TMPDIR`, the sandbox's fallback state dir is the same per-user dir
    as the hook's, not the shared `/tmp`.
- **Trust.**
  - Codex runs a project hook only when the project `.codex/` layer is trusted
    and the hook is trusted in `/hooks`. Codex records this as `[hooks.state."<root>/.codex/hooks.json:pre_tool_use:0:0"]
    trusted_hash`.
  - An untrusted hook is skipped, so the guard stays fail-open until the user
    trusts it.
  - The launcher (`codex-mode.sh`) and the doctor warn when that entry is
    missing from `${CODEX_HOME:-~/.codex}/config.toml`. The launcher says
    "Codex has no trust record for the edit guard hook: open codex, run
    /hooks, trust scripts/agent-hook.sh codex-pretool"; the doctor says
    "Codex edit guard hook has no trust record: run /hooks in codex".
  - With the entry present, the doctor prints `info`, not `ok`: "trust for
    the current hook entry is not verified: check /hooks in codex" (R4).
  - Never pass `--dangerously-bypass-hook-trust`.
- **Unchanged.** The launcher close-out after the run stays as the backstop.
  The sandbox and approval settings stay as they are.
- **Docs.** One line in `.codex/README.md` on trusting the hook.

## Non-goals

- Parsing Bash commands, on either host.
- Codex `Stop` and `SessionStart` hooks.
- Option B (`ask` for outside paths).
- Allow-lists of host directories.
- A Codex `PermissionRequest` hook.
- Other writes to `.agents/` from the Codex sandbox, such as packet files.
  The sandbox refuses them too; that is a separate follow-up.
- Widening the protected list inside the project (owner decision
  2026-11-08, a separate follow-up).
- Left as is after the re-council: a Codex session whose cwd is a nested git
  repository runs no guard (the hook command finds that repository's top
  level); `cd <dir> && apply_patch` paths resolve against the hook `cwd`; a
  custom protected pattern spelt unlike the file on disk matches neither
  spelling; the trust check reads only key `pre_tool_use:0:0`.

## Tests

Both hosts are covered by one new fast suite, `scripts/test-edit-guard-hosts.sh`,
so a single target serves both. The hot-path and drift tests are updated to
the new messages.

**Claude:**

- These exit 0 with only the `path=... outside_project=true` line on stdout
  and no block: a `.md` in this repo's memory, a temp dir, any other outside
  path.
- These print the `ask` JSON (Part D): memory of another repo, a non-`.md`
  file or a link in this repo's memory, the Claude and Codex homes, and
  another repo's `AGENTS.md`, `.codex/` or `.git/hooks/`, in any case.
- These exit 2:
  - a symlink out of the root;
  - `<root>/../x`;
  - a symlink out through an alias of the root;
  - a broken context or policy.
- An outside→inside path to a protected file exits 2 without an ack and 0
  with one.
- A cross-repo session still prints the `ask` JSON for an outside path.
- NotebookEdit: a protected inside path exits 2; an outside path exits 0.

**Codex:**

- Fixture patches with add, update, delete, move, and several files.
- A protected path exits 2 with the reason; an acked one exits 0.
- An outside absolute path exits 0; a symlink out exits 2.
- A tool other than `apply_patch` exits 0; malformed input exits 0 with a
  warning.
- An ack written while `.agents/state` is read-only (under `TMPDIR`, or
  `/tmp` without it) lets the patch through. The same ack in a log that
  others can write blocks, with a warning.
- `.codex/config.toml` has `inherit = "core"` and `TMPDIR`.
- The same ack blocks when the hook's own state is the temp dir and the log
  is loose, when the log is a link, and when the state dir is loose.
- A header with a trailing no-break space or an indent still names
  `CLAUDE.md`. A patch over 1 MiB, and a Claude Write over 1 MiB, are still
  checked.

**Case-insensitive volume** (skipped elsewhere): the root in another case is
the project, `claude.md` is `CLAUDE.md`, and an escape through the root in
another case blocks.

**Install and upgrade:**

- `.codex/hooks.json` is installed and valid.
- An upgrade keeps a user's own hooks in an existing `.codex/hooks.json`.
- The drift test and the doctor trust warning pass, using a fake
  `CODEX_HOME`.
- The verifier wants the kit hook command exactly, as a `command` hook; an
  `echo` of it fails.

**Budgets:** hook hot-path timing, agent-doc words, on-demand tokens.

## Risks

R1–R3 were settled on 2026-11-05 by an owner-run probe on Codex CLI 0.166.0,
macOS, with `--dangerously-bypass-hook-trust`. A second run the same day used
the default flow: the owner trusted the project, then the hook in `/hooks`.
The untrusted hook did not run; the trusted one blocked a protected path and
read an ack from the Codex shell.

- **R1. Hook input and blocking: holds.**
  - `tool_name` is `apply_patch`, and `tool_input.command` is the patch
    text with relative paths. `cwd` is set.
  - An interactive run blocked a protected path with exit 2 and let a normal
    patch through.
- **R2. Sandbox: holds.** Under `read-only` the hook wrote the context pack,
  and the sandbox still refused the patch. So hooks run outside the sandbox.
- **R3. Ack from Codex: failed, fixed in Part C.**
  - The ack first failed with exit 127: the shell had no system `PATH`.
  - With `PATH` added, the ack landed under `/tmp`, while the hook read
    `.agents/state`.
  - A replay that read the same state dir passed (`ack_source=log`).
  - The fixes are "Ack" and "Codex shell environment" above.
- **R4. Trust check.** The kit cannot recompute Codex's trust hash, so the
  check only looks for the entry.
  - A changed hook entry is untrusted while the check still passes. Seen on
    2026-11-05: Codex reported `modified` and skipped the hook, and the
    doctor said "trust record". The doctor now says that trust is not
    verified, as `info`, not `ok`.
  - Keep the `hooks.json` entry byte-stable across releases.
- **R5. Doc budget.** The seat branch leaves 3 words under the 7,900-word
  ceiling.

## Release

One commit at the end of the branch, with the release bump and a CHANGELOG
entry. The branch base and the release order are the owner's decision.
