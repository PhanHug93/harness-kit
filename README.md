# Harness Kit

Harness Kit is a portable, self-testing multi-agent harness kit for adding a
predictable AI-assisted workflow to an existing project. It writes local
instructions, agent seats, onboarding helpers and checks into your project. It
does not change your application code.

Current release: [`2026.11.10.1`](agent-bootstrap/VERSION)

## What you get

- `AGENTS.md` and `CLAUDE.md` that tell agents how to work in this project:
  what to read first, which checks to run, and the Git rules.
- Seats: each step of a task has an owner. `@spec` writes the spec, `@gate`
  checks it is ready, `@build` codes, `@verify` reviews the result, `@audit`
  cross-reviews, and you (`@owner`) decide.
- A tier for each change, so a one-file fix does not go through every seat.
- Checks before hand-off: `scripts/agent-guard.sh pre-final --run-verify` runs
  the project's fast tests and says plainly when nothing could run.
- Shared memory across sessions and agents with agentmemory (Claude Code and
  Codex).
- Everything stays on your machine: the harness files are not pushed; only
  specs and a short journal of finished work are.

Example: you ask Claude to "add Momo payment". The kit suggests the `large`
tier because the change touches `app/payment/`. Claude writes the spec, Codex
checks it and codes it, a fresh Codex session reviews it, Claude cross-reviews,
and you close the task.

This is a coordination protocol, not an autonomous agent runner. You open each
host session; the kit does not launch one AI host from another. Coding starts
after `@gate` records that the spec is ready, but that is an agreement, not a
lock: no script stops `@build` from starting early.

## Requirements

- Bash, `python3`, Git, and `sha256sum` or `shasum`.
- The project is a Git work tree.
- Claude Code and Codex are the supported hosts (see
  [Supported hosts](#supported-hosts)).

## Install

From the project root. This installs release `2026.11.10.1`:

```bash
cd /path/to/project
curl -fsSL https://raw.githubusercontent.com/PhanHug93/harness-kit/v2026.11.10.1/agent-bootstrap/harness-kit-one-shot.sh | bash
```

Options go after `| bash -s --`: `--to latest` installs the newest release,
`--workflow infra` the smaller preset (agent files and checks without the seat
workflow; the default is `full`).

Then finish onboarding, which fills the project brief from your code:

```bash
scripts/agent-onboarding.sh next     # what is still missing
# open an agent session and run /project-onboarding
scripts/agent-onboarding.sh check    # passes when onboarding is complete
```

The install fetches the release into `.harness-kit/v<version>/` and adds
`scripts/harness-kit.sh`, so later runs need no curl. Offline, point it at a
local checkout:
`bash /path/to/harness-kit/agent-bootstrap/harness-kit-one-shot.sh --source-dir /path/to/harness-kit`.

## Update, read the result, undo

```bash
scripts/harness-kit.sh              # reinstall the installed version
scripts/harness-kit.sh --to latest  # update to the newest release
scripts/harness-kit.sh --plan       # preview; writes only local kit state
```

The run picks its mode from the installed version: install, reinstall or
update. A downgrade is refused. It creates no branch unless you pass
`--branch feature/<slug>` or `--branch bugfix/<slug>`.

**Your edits are never overwritten.** The kit remembers what it last wrote. If
you edited a file and the kit did not change it, yours stays. If both changed
it, the kit merges; when the merge fails, yours stays and the kit's version is
saved next to it as `<path>.generated.<STAMP>`. The
[reference](docs/agent-configs/bootstrap-multi-agent-project/README.md#how-upgrades-treat-your-files)
lists every case. Filled briefs, the tech-stack contract, `seats.json` and USER
sections always survive.

The summary has at most 12 lines and ends with
`RESULT: done | needs review | failed`. Exit codes: `0` done, `3` needs review,
`1` refused or failed, `2` usage error. The full report is
`.tools/agent-state/upgrades/<STAMP>/report.json` (`--json` prints it).

For each open item the summary prints the exact command to run:

```bash
scripts/harness-kit.sh --resolved <path> --reason "<why>"  # keep your file
scripts/harness-kit.sh --take-kit <path>    # take the kit's file; yours is backed up
scripts/harness-kit.sh --keep-local <path>  # pin your file; later runs leave it alone
scripts/harness-kit.sh --accept <id>        # apply a pending migration
scripts/harness-kit.sh --decline <id>       # skip it until its facts change
scripts/harness-kit.sh --rollback <STAMP>   # undo the run recorded as STAMP
```

Other options: `--reset` (the kit's version wins for every kit file, with
backups), `--knowledge` (what the kit knows about the project),
`--project-verify` (also run the project's fast tests), `--skip-verify`.

Optional shell helpers keep a kit copy on your machine (`agent-upgrade`,
`agent-init`, `agent-update --check`); see the
[reference](docs/agent-configs/bootstrap-multi-agent-project/README.md#home-install-and-shell-helpers).

## Seats

Seats describe the work; who sits in each seat is your configuration.

| Seat | Default occupant | Fallback |
| --- | --- | --- |
| `@spec` | Claude | host-controlled |
| `@gate` | Codex `gpt-6-astra` @ `ultra` | `gpt-5.6-terra` @ `xhigh` |
| `@build` | Codex `gpt-5.6-luna` @ `xhigh` | `gpt-5.6-terra` @ `xhigh` |
| `@verify` | Codex `gpt-6-astra` @ `ultra` | `gpt-5.6-terra` @ `xhigh` |
| `@audit` | Claude | host-controlled |
| `@owner` | You | — |

```bash
scripts/agent-seats.sh show
scripts/agent-seats.sh wizard
scripts/agent-seats.sh set gate --host codex --model gpt-6-astra --effort ultra
```

Assignments live in `docs/agent-configs/seats.json`; `set` and `wizard` update
the roster in `AGENTS.md`. `.codex/codex-mode.sh` launches the Codex seats.
In full flow it lets a seat write its packet (`.agents/tasks/`) and the
guard's state (`.agents/state/`); Codex keeps the rest of `.agents/`
read-only.
In Claude Code, `/spec`, `/gate`, `/build`, `/verify` and `/audit` open a seat
(they replace `/planning`, `/coding` and `/reviewing`). `@gate` checks the
spec and writes the plan; only a gap in the spec goes back to `@spec`.

A task can arrange its own seats, for example all on Claude for one packet:

```bash
scripts/agent-seats.sh show --task fix-logout
scripts/agent-seats.sh use claude --task fix-logout --reason "Codex is busy this week"
scripts/agent-seats.sh history --task fix-logout
```

The first `tier set` copies the project roster into the packet; each change
keeps the user's words, and both launchers follow the packet.

## Pick a tier for each change

| Tier | Flow | Example |
| --- | --- | --- |
| small | one agent, pre-final, PR review | fix the misaligned Log out button (1 file) |
| medium | one agent writes `task.md` and codes, then a fresh `@verify` or your PR review | "make the app faster": the files are not known yet |
| large | the full cycle: `@spec`, `@gate`, `@build`, `@verify`, `@audit` | add Momo payment (touches `app/payment/`) |

The agent collects facts, a script suggests, and you confirm:

```bash
scripts/agent-guard.sh tier suggest --task fix-logout --paths app/settings/SettingsView.swift
scripts/agent-guard.sh tier set small --task fix-logout      # after you say yes
scripts/agent-guard.sh tier show --task fix-logout --pr-line # one line for the PR body
scripts/agent-guard.sh tier list                             # packets not closed yet
scripts/agent-guard.sh tier close --task fix-logout          # when you say done
scripts/agent-guard.sh tier stats --since 2026-10-23         # how tiers worked out
```

- **Large:** a risky path or name (`auth`, `payment`, `migrations/`, `.env`,
  `Dockerfile`), stored or sent data, who may do what, two agents sharing the
  task (`--handoff`), or more than 15 files or 500 changed lines.
- **Medium:** more than 3 files or 60 changed lines, a new or upgraded
  library, or a binary that is not an image, font, audio, video or PDF. Tests,
  lock files and generated files are not counted; files that only moved count
  toward medium, never large.
- **Small:** everything else.

Add your own risky paths as `risk_paths` in
`docs/superpowers/specs/project-tech-stack.json` (yours; updates keep it).
If your work branches start from a branch that is not the repository's
default one (git-flow's `develop`), name it once in the same file:
`"tier_base": "origin/develop"`. The size check then counts from that
branch, for every task and when no task is open.

Tiers recommend; they never block. When the real change grows above its tier,
pre-final, the Claude Code Stop hook and the optional pre-push hook say so and
name the next step: raise the tier or split the change. A lower tier than
suggested needs a reason, which shows in the PR line. Tier records stay on
your machine, so paste the `--pr-line` output into the PR description. How
the change is measured on each branch is in the
[reference](docs/agent-configs/bootstrap-multi-agent-project/README.md#tier-measurement).

## Checks before hand-off

```bash
scripts/agent-guard.sh preflight
scripts/agent-guard.sh pre-final --run-verify
```

`pre-final --run-verify` runs the fast commands listed under `verification[]`
in `docs/superpowers/specs/project-tech-stack.json`. When no command could
run, the result is `unverified`, which is never a pass. Before a release or a
risky PR, add `--verify-scope full` after checking the heavier commands.

Claude Code runs the fast check on its own when a session changed files (Stop
hook); the Codex `@build` seat runs it when its session ends. Install the
optional pre-push check once with `scripts/install-git-hooks.sh`.

The pre-push check warns; it does not refuse a push for a check result. It
names the packets still open on the pushed branch
(`scripts/agent-guard.sh tier list` shows every packet that is not closed)
and says when verification failed or did not run. A push with no task in
progress is not measured. The one thing that refuses a push is a kit
local-only file in the pushed commits.

## Claude Desktop/Cowork

After a full install:

1. Open the generated target in Cowork.
2. In Cowork, copy the Folder Instructions from `.claude/README.md` once.
3. Give Claude the problem so it creates or resumes the task packet.
4. Use routed Codex for technical review, implementation, and final review.
5. Return to Claude for independent cross-review, then make the final decision
   yourself.

Do not assume Claude Code hooks run in Cowork. If Bash is unavailable, Claude
keeps its analysis or cross-review role and records verification as blocked
with a reason.

The collaboration records are not security controls:

- packet ownership and append-only history are conventions;
- host, model, and session independence are declarations rather than proof;
- @gate authorization entries are audit declarations.

## Agentmemory (Claude Code and Codex)

[agentmemory](https://github.com/rohitg00/agentmemory) gives agents memory
that outlives one session. The kit supports it for Claude Code and Codex
only, for now. Each kit release names the agentmemory version it was tested
with (this one: `0.9.31`); `scripts/harness-kit.sh` and `/doctor` print the
upgrade steps when yours is older.

Set it up once per machine:

```bash
npm install -g @agentmemory/agentmemory@0.9.31
agentmemory                                    # start the server
agentmemory connect claude-code --with-hooks
agentmemory connect codex --with-hooks         # then open codex once and trust the hooks
```

Re-run both `connect` commands after every agentmemory upgrade: the hooks
point into the installed package. Optionally copy the upstream `lesson`,
`remember`, `recall` and `forget` skills from the package's `plugin/skills/`
into your skills folder, so you can type `/lesson` or `/recall`.

What the seats do with it:

| Part | Used for | Example |
| --- | --- | --- |
| Memories | decisions and facts, with the reason | "pinned agentmemory 0.9.31 because 0.9.30 changed auth" |
| Lessons | do-not-repeat rules that grow stronger when repeated | `@verify` finds a fragile test and saves the rule |
| Actions | follow-up work outside the current task | the closing seat files "hook takes 1.8 s; fix separately" |
| Profile | the files and topics the project touches most | a new session reads it before starting |

The task packet in `.agents/tasks/` still owns the current task; memory is
advisory and never holds secrets.

## Supported hosts

| Host | How it reads the kit |
| --- | --- |
| Claude Code | `CLAUDE.md`, which imports `AGENTS.md`; hooks and `/` commands |
| Codex | `AGENTS.md`; the seat launcher `.codex/codex-mode.sh` |
| Cursor, Windsurf, Antigravity | read `AGENTS.md` on their own; no kit hooks |
| Gemini CLI | set `context.fileName` to `AGENTS.md` in its settings |

## What is pushed and what stays local

What was done goes to Git; work in progress and the harness stay on your
machine. The kit's ignore block goes to `.git/info/exclude` by default, so
harness files never show in `git status` (`--ignore-target gitignore` writes
it to `.gitignore` instead).

**Pushed:**

| Path | Content |
|---|---|
| Project files | Source, tests, build and project configuration; the kit does not change them. |
| `docs/superpowers/specs/<topic>/` | Specs of work that has started or shipped. |
| `docs/superpowers/plans/<topic>/journal.md` | Dated record of what was done, finished or not. |

**Local only:**

| Group | Paths |
|---|---|
| Agent entry files | `AGENTS.md`, `CLAUDE.md` |
| Agent configuration | `docs/agent-configs/`, `.agents/`, `.claude/`, `.codex/` |
| Harness scripts | `scripts/agent-*.sh`, `scripts/agent-tier.py`, `scripts/detect-agent-tech-stack.sh`, `scripts/verify-ai-deps.sh`, `scripts/install-git-hooks.sh`, `scripts/harness-kit.sh`, `scripts/githooks/` |
| Onboarding scaffolds | `docs/superpowers/specs/README.md`, `docs/superpowers/specs/project-tech-stack.{md,json}`, `docs/superpowers/plans/README.md` |
| Work in progress | Task packets in `.agents/tasks/<task-id>/`; draft specs, analyses and plans in `docs/superpowers/plans/<topic>/`; every other `docs/superpowers/` folder |
| Kit copies and candidates | `/.harness-kit/`, `/agent-bootstrap/`, `*.generated.*` candidates |
| Personal and machine state | `*.local.md`, `.claude/settings.local.json`, `.tools/`, `*.bak.*` and tool caches |

A spec starts as a draft in `docs/superpowers/plans/<topic>/` and moves to
`docs/superpowers/specs/<topic>/` in the first commit that implements it.

If local files were already pushed, the run offers the
`untrack-local-records` decision; accept it and commit the removal before
pushing (the files stay on disk). The pre-push check
(`scripts/agent-local-only-check.sh`) names any that are still tracked.

## Limits

- Agent Guard is a thin file-edit guardrail,
  not a security boundary for arbitrary Bash commands.
- Seats, packets and reviews are recorded conventions; they cannot prove which
  model or person did the work.
- The kit runs no remote CI checks; every gate is local and opt-in.
- [Superpowers](https://github.com/obra/superpowers) is a separate project the
  kit relies on for brainstorming and plans; the kit does not install it.

## More

- [Reference](docs/agent-configs/bootstrap-multi-agent-project/README.md):
  file layout, generator commands, upgrade rules, budgets, schemas.
- [Contributing](CONTRIBUTING.md): changing, testing and releasing the kit.
- [Changelog](CHANGELOG.md).
- In a generated project: `docs/agent-configs/RECOVERY.md` for a partial
  upgrade or a lost local setting.

## License

MIT — see [`LICENSE`](LICENSE). The `doubt-driven` skill is adapted from
[`addyosmani/agent-skills`](https://github.com/addyosmani/agent-skills) (MIT) —
see [`NOTICE`](NOTICE).
