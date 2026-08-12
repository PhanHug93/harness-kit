# Claude–Codex Collaboration Flow Design

**Status:** Approved for implementation planning

**Date:** 2026-08-10

**Branch:** `feature/change_gpt_flow`

## 1. Purpose

Extend harness-kit so a generated target project gives Claude Desktop/Cowork
and Codex distinct, complementary responsibilities without requiring either
host to invoke the other.

The intended collaboration is:

1. Claude analyzes the request, checks project context, and writes a
   Codex-ready specification.
2. Codex on GPT-5.6 Sol independently reviews the specification at the
   implementation boundary.
3. Codex on GPT-5.6 Luna implements a bounded, approved patch.
4. A fresh Codex Sol session performs final technical review.
5. Claude performs a host-independent cross-review of the result and the
   handoff record.
6. The user makes every final decision, including whether to accept, revise,
   escalate, or stop the task.

The design optimizes for clear responsibility, review independence, low
context overhead, and honest enforcement claims. It does not attempt to turn
local Markdown and JSON files into a security or authorization system.

## 2. Scope

### In scope

- Generated guidance for Claude Desktop/Cowork opened directly on a target
  project folder.
- Canonical Claude–Codex role, phase, transition, review, and escalation
  contracts.
- Three configurable Codex routes: planning, coding, and reviewing.
- A local task packet under `.agents/tasks/` for asynchronous handoff.
- Specification adequacy and final-review gates owned by Codex Sol.
- Candidate-based, non-destructive migration for already-bootstrapped targets.
- Removal of mandatory per-mode journal behavior from the collaboration flow.
- Focused regression tests and a release smoke test in a temporary generated
  target.

### Out of scope

- A runner that launches Claude from Codex or Codex from Claude.
- A `cross_review` or `escalated_coding` model route.
- A `.codex/model-routing.local.json` configuration layer.
- A new task CLI, daemon, lock service, database, JSON Schema, or telemetry
  pipeline.
- Cryptographic proof that reviews used different sessions, models, accounts,
  or hosts.
- Automatic synchronization with the upstream Superpowers `main` branch.
- A Superpowers installer or updater inside harness-kit.
- Self-bootstrapping harness-kit onto its own source repository.
- Risk-based automatic model routing in v1.

## 3. Architectural boundaries

### 3.1 Factory, not dogfood target

This repository is a generator. Files such as target `AGENTS.md`,
`CLAUDE.md`, `docs/agent-configs/agent-mode-contracts.md`, and
`.codex/codex-mode.sh` are generated from writer heredocs. They must not be
created by bootstrapping harness-kit onto itself.

Self-bootstrap remains unsupported because the generated managed ignore block
includes `/agent-bootstrap/`, which would ignore the source bundle itself.
The source repository's root `.gitignore` therefore does not add
`.agents/tasks/` for self-hosting.

Protocol behavior is tested in temporary target directories created by the
normal bootstrap path.

### 3.2 Canonical generated documents

Generated target guidance has one source for each kind of rule:

- `docs/agent-configs/agent-mode-contracts.md` is canonical for roles, phases,
  transitions, adequacy gates, remediation limits, and escalation.
- `docs/agent-configs/agent-handoff-schema.md` is canonical for task-packet and
  findings-first artifact formats.
- `AGENTS.md` contains only the startup summary and pointers to canonical
  documents. It does not duplicate the ownership matrix or protocol.
- `CLAUDE.md` contains Claude-compatible startup guidance and pointers. Cowork
  Folder Instructions point to this file rather than copying the full
  protocol.
- `.codex/codex-mode.sh` seeds only the selected mode, flow, task location, and
  requirement to read the canonical contract. It does not embed another copy
  of the protocol. It does carry each route's own blocking rules, which exist
  in the route prompt and nowhere else, so a rule that must apply to every run
  of that route is present without being loaded on demand.
- `.agents/skills/doubt-driven/SKILL.md` remains an on-demand review technique;
  it does not become a role contract.

No new `{claude,codex}-role.md` files are introduced.

## 4. Responsibility model

| Phase | Primary owner | Model or host | Responsibility |
|---|---|---|---|
| Analysis | Claude | Claude Desktop/Cowork | Understand the request, inspect context, surface assumptions, and write the specification. |
| Technical review | Codex | GPT-5.6 Sol, `xhigh` | Review specification adequacy and decide whether Luna has enough information to implement safely. |
| Implementation | Codex | GPT-5.6 Luna, `xhigh` | Implement one coherent, bounded patch and record verification evidence. |
| Verification/final review | Codex | Fresh GPT-5.6 Sol, `xhigh` | Run or inspect verification and review the completed diff from the recorded base commit. |
| Cross-review | Claude | Claude Desktop/Cowork | Check consistency, omissions, unsupported claims, and procedural independence across artifacts. |
| Resolution | User | Human | Accept, request another bounded revision, authorize Sol coding, select a prior phase, or close the task. |

Claude may implement only when the user explicitly overrides the default owner.
Luna may not declare a Sol-blocked specification sufficient. Sol coding is an
explicit user-opened session exception, not an automatic escalation.
If the user explicitly selects a configured fallback or one-shot override for
a planning/reviewing route, that model assumes the route's review role as a
declared exception; the artifact records the actual model and model source.

## 5. Codex model routing

### 5.1 Stable profile

The generated stable profile uses:

| Route | Primary model | Fallback model | Reasoning effort |
|---|---|---|---|
| `planning` | `gpt-5.6-sol` | `gpt-5.6-terra` | `xhigh` |
| `coding` | `gpt-5.6-luna` | `gpt-5.6-terra` | `xhigh` |
| `reviewing` | `gpt-5.6-sol` | `gpt-5.6-terra` | `xhigh` |

`planning` serves pre-coding technical review and Codex-authored planning;
`coding` serves bounded implementation; `reviewing` serves final technical and
ordinary findings-first review. Claude cross-review is host behavior and never
maps to a Codex route.

Fallback is never automatic. It is selected only when the user explicitly
sets `CODEX_USE_FALLBACK=1`. Global and mode-specific overrides remain separate
one-shot model selections rather than fallback events.

### 5.2 Configuration authority and precedence

`docs/agent-configs/model-profiles.json` is the canonical generated source for
primary models, fallback models, and profile-level reasoning effort. Schema
`agent-model-profiles/v1` remains unchanged; its three existing
`*_fallback_model` fields remain required.

Effective model precedence is:

1. `CODEX_MODEL_OVERRIDE`
2. mode-specific override such as `CODEX_CODING_MODEL_OVERRIDE`
3. explicit `CODEX_USE_FALLBACK=1`, resolved from the active profile
4. the selected profile's primary model

`CODEX_REASONING_EFFORT` overrides the profile effort when present. The loader
validates supported values and fails with an actionable error for malformed
JSON, a missing profile, missing required fields, an unsupported effort, or an
unknown route.

Command dispatch is parsed before strict profile loading:

- `planning`, `coding`, `reviewing`, and `run` require a valid profile and fail
  before launch when it is invalid;
- `doctor` catches profile errors, reports them as an actionable diagnostic,
  completes its remaining independent checks, and exits non-zero at the end;
- `status` reports the profile error and exits non-zero instead of terminating
  without context;
- `help` does not load the profile.

The launcher accepts only `planning`, `coding`, and `reviewing` route commands;
`cross_review` as a route command fails as unknown. No local routing file or
configuration surface exists for Claude cross-review. Extra profile properties
allowed by schema v1 do not create additional routes.

### 5.3 Project Codex configuration

Generated `.codex/config.toml` does not hard-code `model` or
`model_reasoning_effort`. The launcher supplies both explicitly. This prevents
the profile catalog, launcher defaults, and project config from drifting.

Raw Codex sessions are outside the harness model-routing guarantee and use the
model selected by the host or user. They still receive repository role
guidance through normal project instructions. Users who require deterministic
routing use `.codex/codex-mode.sh`.

The doctor check validates the profile and effective launcher route; it no
longer requires `model_reasoning_effort = "xhigh"` in `.codex/config.toml`.

### 5.4 Accidental nested-launch guard

The launcher uses `CODEX_HARNESS_SESSION=1` only to catch accidental Codex
session nesting:

- add the variable to `shell_environment_policy.include_only`;
- export it immediately before `exec codex`;
- reject nested `planning`, `coding`, `reviewing`, and `run` launches;
- allow `status`, `doctor`, and `help` before the nesting check.

The guard is not an authorization or security boundary. A child process can
unset or override the variable. No file marker, lock, or crash-recovery
mechanism is added.

## 6. Local task packet

### 6.1 Location and durability

Each active collaboration task uses:

```text
.agents/tasks/<task-id>/
```

Generated targets already ignore the entire `.agents/` directory and classify
`.agents/*` as local-only. No ignore or local-only classifier change is needed.

The packet is local, ignored, ephemeral working state. It may be lost through
checkout deletion, machine loss, or `git clean -xdf`. Git does not enforce
artifact ownership or append-only behavior. File prefixes and phase ownership
are conventions for coordination, not access controls.

### 6.2 Maximum artifact set

A task has at most six artifacts:

1. `state.json`
2. `task.md`
3. `codex-review.md`
4. `implementation.md`
5. `claude-review.md`
6. `user-decision.md`

Only `state.json` and `task.md` are created at task start. The other files are
created only when their phase first requires them.

No task-packet JSON Schema file or protocol-version file is added. The
canonical handoff document defines the fields and examples.

### 6.3 Active task selection

`.agents/tasks/ACTIVE` is only a cache containing a task identifier. Individual
`state.json` files are authoritative.

On resume, an agent:

1. scans task states for non-closed tasks;
2. uses the single open task when exactly one exists;
3. repairs or ignores a stale `ACTIVE` cache;
4. asks the user to choose when multiple tasks remain open;
5. never selects the newest task automatically.

### 6.4 State contract

`state.json` records at least:

```json
{
  "protocol_version": "claude-codex-collaboration/v1",
  "task_id": "<stable-task-id>",
  "status": "open | awaiting_user | closed",
  "phase": "analysis | technical_review | implementation | verification | cross_review | resolution | closed",
  "owner": "claude | codex | user",
  "requested_action": "<single next action>",
  "base_commit": "<git-commit-or-null>",
  "revision_rounds": 0,
  "spec_sufficiency": {
    "verdict": "not_reviewed | sufficient | partially_sufficient | insufficient",
    "sufficient_for_coding_model": "not_reviewed | yes | no"
  },
  "escalation_reason": null,
  "verification": {
    "runner": "none | claude | codex",
    "status": "not_run | pass | fail | blocked",
    "reason": null,
    "report": null
  },
  "updated_at": "<ISO-8601 UTC>"
}
```

`base_commit` is recorded when the task first enters implementation. It lets a
fresh reviewer inspect the complete change even when Codex has already
committed and the working tree is clean.

The packet has no concurrent-write lock. One writer per phase is a documented
operating convention.

## 7. Artifact contracts

### 7.1 `task.md`

Claude owns the initial task specification. It starts with:

```markdown
## Request (verbatim)

> <original request with secrets redacted>
```

It then records objective, acceptance criteria, in-scope and out-of-scope
behavior, repository evidence, constraints, interfaces, edge cases, migration
impact, security/privacy considerations, verification expectations, open
assumptions, and proposed implementation boundaries.

The verbatim request block is immutable by convention. When Sol returns the
task to analysis, Claude appends a numbered specification revision instead of
rewriting the original request or erasing the earlier specification history.

### 7.2 `codex-review.md`

The file is append-only by convention and has exactly two top-level phase
sections. Each section contains numbered attempts when remediation causes a
review to repeat:

```markdown
## Pre-coding technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
spec_sufficiency: sufficient | partially_sufficient | insufficient
sufficient_for_coding_model: yes | no
blocking_gaps: none | <concise list>

## Final technical review

### Attempt 1

reviewer_model: <actual-model>
model_source: default | CODEX_USE_FALLBACK | <override-variable>
fresh_session_attestation: yes | no
reviewed_base_commit: <commit>
verdict: pass | changes_required | blocked
```

Sol owns both sections. Append-only is enforced by convention per section:
prior attempts are immutable, while a repeated review adds the next numbered
attempt at the end of its section. The first final-review session adds the
second top-level section without editing pre-coding history. If the user later
returns to specification review, the next pre-coding attempt is inserted before
the final-review heading without changing any prior attempt.
`state.json.spec_sufficiency` must match the latest pre-coding attempt exactly.

`fresh_session_attestation` is a procedural declaration. The packet cannot
prove session, model, account, or host independence.

### 7.3 `implementation.md`

Luna appends an `## Implementation attempt <n>` entry for each implementation
or remediation cycle. Each entry records:

- `author_model`, `model_source`, and selected route;
- implemented scope;
- changed files;
- verification run and result;
- deviations from the approved specification;
- unresolved risks or blockers;
- whether the specification was downgraded as insufficient;
- any user-authorized `policy_exception=sol_coding` and its reason.

The file is a handoff summary, not a substitute for the source diff or
verification report.

### 7.4 `claude-review.md`

Claude writes one findings-first pass per cross-review phase under an appended
`## Cross-review attempt <n>` entry. It checks:

- the state sufficiency verdict matches the pre-coding Sol review;
- Luna did not upgrade a Sol `no` to `yes`;
- final review covered the diff from `base_commit`;
- verification status and report references are consistent;
- procedural fresh-session/model declarations are present without being
  presented as proof;
- a Sol coding exception has `user-decision.md` and a non-empty
  `escalation_reason`;
- author and reviewer model/session declarations do not contradict each other;
- implementation stayed within the approved specification;
- findings in `codex-review.md` carry the obligations the reviewing route prompt
  requires: a stated trigger condition or an explicit estimate marker on
  severity, and a stated hypothesis wherever removal of an existing construct is
  proposed where one is offered. A stated trigger is checked for traceability to
  the cited evidence, not merely for presence; an unsupported trigger relocates
  the unverified claim instead of removing it. A missing obligation is reported as an evidence gap in the review
  itself, not as a defect in the code under review.

Claude reports evidence-backed findings and uncertainty. It does not silently
rewrite Codex artifacts.

### 7.5 `user-decision.md`

This file exists only when a user decision is required. Each decision is
appended as a dated entry recording the selected action, scope, authorization,
and any rejected alternatives. It does not prove that the user—not an
agent—wrote the file; the real control is the human action of opening or
directing the next host session.

## 8. Workflow and gates

### 8.1 Normal flow

1. **Analysis:** Claude creates `state.json` and `task.md`.
2. **Pre-coding review:** Sol appends the first section of
   `codex-review.md`.
3. **Implementation:** only `sufficient_for_coding_model: yes` moves to Luna.
4. **Verification/final review:** verification runs, then a fresh Sol session
   reviews the full diff and appends the final section.
5. **Cross-review:** Claude writes `claude-review.md`. This phase begins when
   the user opens a Claude session with the packet, not when an agent invokes
   one. No agent starts the other host: Codex must never shell out to a Claude
   CLI, and Claude must never launch Codex. A Codex session that reaches
   `cross_review` records the handoff and stops; the packet waits in
   `phase: cross_review` until a Claude session picks it up.
6. **Resolution:** the user accepts, requests a bounded revision, escalates, or
   closes.

Allowed transitions are deliberately narrower than the Cartesian product of
phase, owner, and status:

| Current phase and owner | Allowed next phase |
|---|---|
| `analysis` · Claude | `technical_review` |
| `technical_review` · Codex Sol | `analysis`, `implementation`, or `resolution` |
| `implementation` · Codex Luna | `verification` or `resolution` |
| `verification` · Codex Sol | `implementation`, `cross_review`, or `resolution` |
| `cross_review` · Claude | `implementation` or `resolution` |
| `resolution` · User | `closed` or a prior phase explicitly selected by the user |

`status: awaiting_user` is valid only with `phase: resolution` and
`owner: user`. `status: closed` is valid only with `phase: closed`. All other
active combinations use `status: open` and the phase owner in the table.
The only owner exception is Claude implementation explicitly selected by the
user; it must be recorded in `user-decision.md`. User-opened Sol coding keeps
`owner: codex` but records the policy exception described below.

### 8.2 Specification adequacy

The blocking adequacy verdict belongs to the Codex planning reviewer, which is
Sol by default. The reviewer checks requirements, interfaces, edge cases,
tests, migrations, security/privacy, and implementation boundaries. An
explicitly selected fallback or override must declare its actual model and
source but otherwise assumes the same route responsibility.

Luna repeats an adequacy check as a second line of defense:

- Luna may downgrade Sol's `yes` and return the task to analysis or technical
  review.
- Luna may never upgrade Sol's `no`.
- A missing or inconsistent Sol verdict blocks implementation.

### 8.3 Verification ownership

The verification phase is owned by Codex Sol, but the actual command runner is
recorded separately as Claude or Codex. Cowork first probes whether Bash is
available:

- if available, Claude may run the project verification command and records
  itself as runner;
- if unavailable, Claude records a blocked/delegated reason and Codex runs
  verification;
- unavailable execution and intentionally skipped verification must not look
  identical.

The canonical evidence remains the real report, such as
`.agents/state/last-verify-report.json`, rather than a copied summary.

### 8.4 Review and remediation limit

Ordinary review is a single findings-first pass. The existing mandatory
BA/Dev Lead/QC three-round simulation is removed from ordinary review. Council
review remains on demand for genuinely high-risk or disputed decisions.

Every finding carries one obligation beyond describing the defect:

- **Severity states its trigger.** A severity level must name the condition that
  activates the defect and how often that condition occurs, or mark itself an
  estimate. A bare `P1` is an unevidenced claim wearing a number, and the
  receiving agent cannot interrogate it across an asynchronous handoff.

This obligation is generated into the reviewing route prompt in
`.codex/codex-mode.sh`, not into the on-demand contract, and exists in that one
place only. A rule whose purpose is to fire on every review belongs where every
review already reads; an on-demand document constrains only a reviewer who chose
to open it. The on-demand contract names the obligation by title and points to
the route prompt for its text.

The obligation is the only review rule shipped in v1 because it is the only one
with measured effect. An A/B review of the Task 1 diff on 2026-08-10, criteria
registered before either arm ran, moved stated trigger conditions from 0 of 4
findings to 4 of 4. Three further candidates were withdrawn: a three-blocker cap
and a removal-hypothesis obligation, neither of which the case exercised, and a
rule marking measurement, verification, and data-integrity defects exempt from
proportionality, which the case did exercise and which failed. That last result
is a placement lesson rather than a wording one: a review rule can shape how a
finding is written but cannot cause a finding to exist, so a missing check is
caught by task completion criteria, not by review instructions. Candidates
return to this section only with a measured effect behind them; unmeasured rules
dilute the one that works.

Severity, remedy cost, and blocking status stay separate judgements. A finding
may be P1 and still be owned by a later phase. Defects in measurement, in
verification, and in data integrity are weighed strictly regardless of remedy
cost, because they corrupt the ability to evaluate everything else; this is a
classification principle for the reviewer, not a rule shipped in the route
prompt.

`revision_rounds` starts at zero for the initial implementation and increments
whenever findings return the task to implementation. At most two remediation
rounds are allowed after the initial implementation. If the second remediation
still does not pass review, the task moves to `status: awaiting_user`,
`phase: resolution`, `owner: user`; a third automatic remediation is forbidden.

### 8.5 Sol coding escalation

Luna cannot launch or promote itself to Sol coding. When Luna cannot safely
complete the approved task:

1. it records the blocker and `escalation_reason`;
2. state moves to user resolution;
3. the Luna session stops;
4. the user decides whether to open a new Sol coding session.

There is no `--escalated` route or file-based authorization gate. If Sol runs
the coding route, the launcher/implementation handoff records:

```text
policy_exception=sol_coding task_id=<task-id> escalation_reason=<reason>
authorization=user_session
```

This is an audit declaration, not enforced authorization.

## 9. Claude Desktop/Cowork integration

The generated target `.claude/README.md` provides a one-time copy/paste Folder
Instructions pointer. The pointer tells Cowork to read target `CLAUDE.md` and
follow the canonical documents it names. Harness root and bundle READMEs explain
the same operator setup but do not modify an existing target `README.md`.

The design does not rely on `.claude/settings.json` hooks being supported by
Cowork. Claude Code may continue using supported hooks, but Cowork correctness
must come from folder instructions, generated documents, task state, and
capability probing.

If Cowork cannot execute Bash, it continues analysis and cross-review but
delegates executable verification to Codex and records the reason.

## 10. Journal and durable decisions

The collaboration protocol does not require a tracked task journal, per-phase
journal entries, close-out metrics, or v1 analytics.

`agent-guard pre-final` stops scanning the newest journal for memory or recall
fields. The current `mtime` selection is not bound to the active task and can
otherwise let an unrelated historical journal decide a new task's result.
The journal validation call, its helper functions, and its dedicated guard
tests are removed.

The generated task-journal document may remain as optional legacy guidance for
teams that deliberately use a durable checkpoint. It is not part of this
protocol and is not a guard input.

Durable project decisions belong in the authoritative project spec/plan or an
available long-term memory backend. A tracked checkpoint is created only when
there is a genuine durable decision that must survive packet loss or context
compaction. Merely completing a task does not require one.

## 11. Superpowers update policy

Superpowers is an external upstream dependency at
`https://github.com/obra/superpowers`. Harness-kit currently does not install,
update, or synchronize that repository.

The operational policy is:

- pin a tested upstream release tag;
- never update automatically from upstream `main`;
- review quarterly or when a relevant release is published;
- inspect the release diff before adopting it;
- test two or three representative brainstorming tasks before updating the
  pinned version;
- freeze on the last validated release when a new release has no relevant
  benefit or introduces regression risk.

A separate environment-level comparison during design reported that the active
brainstorming skill matched upstream release `v5.1.0`; this was not established
by repository inspection and must be reverified before any update. Later
releases must not be assumed compatible. Superpowers installation/update
integration is deferred from this branch because upstream already owns
host-specific installation paths and the Claude–Codex protocol does not
require an additional updater.

## 12. Migration and compatibility

Existing generated targets retain user-owned overlay sections. Managed files
are regenerated as candidates and adopted through the existing non-destructive
update flow rather than overwritten silently.

The release procedure uses the existing self-update, diff, candidate-apply,
status, and drift-reporting mechanisms. Old model-profile files that still use
GPT-5.5 appear as candidates instead of being replaced without review.

Before publishing one-shot installation instructions, release/version pins in
the root and bundle READMEs must agree with `VERSION`.

No changes are required to:

- target `.agents/` ignore behavior;
- `agent-local-only-check.sh` classification;
- protocol schema version files;
- root `.gitignore` for self-hosting.

## 13. Context-budget constraints

Two separate generated-context budgets remain enforced:

1. **Core startup:** `AGENTS.md`, project agent context, and project brief must
   remain at or below 4000 estimated tokens.
2. **Full on-demand workflow:** core plus mode contracts, handoff schema,
   Karpathy guidance, council guidance, and optional journal guidance must
   remain at or below the test gate of 6200 estimated tokens.

The pre-change baseline measured on 2026-08-10 was approximately 3068 core and
6015 full-workflow tokens. After Task 1 landed the canonical protocol the
measured values are 2875 core and 6187 full-workflow, leaving 13 tokens of
headroom against the 6200 gate. Implementation must remove duplicated and
obsolete role, review-round, and mandatory-journal text so the measured full set
stays net-reductive as further protocol content is added.

Both generated reporters currently display a 6500 full-workflow budget: the
Codex doctor emitted from `writers-docs.sh` and `verify-ai-deps.sh` emitted from
`writers-runtime.sh`. An advisory looser than the gate it advises on is worse
than no advisory, so both report against the real gate and against an amber band
below it. A single threshold reports only failure, and reports it at the latest
possible moment; a band reports how much room is left while there is still room.

Each reporter is three-way. At or below the amber threshold it reports ok. Above
amber but at or below the gate it warns that the budget is nearly spent and that
any edit to a counted file needs a measurement in the same step. Above the gate
it fails. Amber sits at 5900 for the full workflow and 3800 for core: roughly
four to fifteen ordinary edits of warning, wide enough to show a trend and narrow
enough not to fire continuously. Amber thresholds are advisory only; the test
gates stay at 6200 and 4000 and are never raised, and the band costs no generated
tokens because it is reporter logic rather than generated documentation. At the
measured values above, the full workflow is already amber. A repository-wide check on 2026-08-10 found no live document stating 3000 or
6500: the only remaining occurrence is a historical release note in
`CHANGELOG.md`, which stays unchanged. Earlier drafts named
`docs/agent-configs/bootstrap-multi-agent-project/README.md` as needing that
correction; it does not contain either number, and its only stale value was a
one-shot release pin.

New protocol content goes primarily into on-demand canonical contracts.
Duplicate role and phase text is removed from always-on and launcher surfaces.
The implementation must measure both budgets on a generated temporary target;
it must not raise either threshold to make tests pass.

## 14. Failure behavior

- Multiple open task states: stop and ask the user to select one.
- Stale `ACTIVE`: reconstruct it only when exactly one open task exists.
- Missing or malformed state: report the exact problem; do not infer a phase.
- Missing Sol adequacy verdict: block Luna implementation.
- Sol says `no`: only Claude analysis or Sol technical review can resolve it.
- Verification unavailable: record runner, `blocked`, and reason; do not report
  pass.
- Review cycle limit reached: move to user resolution.
- Unknown or malformed model profile: exit non-zero with an actionable error.
- Invalid profile during `doctor` or `status`: print the actionable diagnostic
  before exiting non-zero; `help` remains available without profile loading.
- Fallback requested but missing: exit non-zero; do not fall back to a
  hard-coded model.
- Nested launcher: reject mode launches while preserving diagnostic commands.
- Missing fresh-session attestation: Claude reports an evidence gap, not a
  proven lack of independence.

## 15. Implementation surface

Expected source changes are limited to existing surfaces:

- `agent-bootstrap/lib/writers-docs.sh`
  - canonical role/phase/handoff content;
  - lean AGENTS/CLAUDE pointers;
  - Codex config, launcher, README, doctor, and mode prompts.
- `agent-bootstrap/lib/onboarding.sh`
  - remove mandatory per-mode journal language while retaining optional
    durable-checkpoint guidance where needed.
- `agent-bootstrap/agent-guard.sh`
  - remove journal-based pre-final memory validation.
- `agent-bootstrap/lib/writers-runtime.sh` and
  `agent-bootstrap/verify-ai-deps.sh`
  - keep generated runtime validation synchronized with model-profile
    behavior;
  - change both generated full-workflow budget reporters from 6500 to the
    enforced 6200 threshold.
- `agent-bootstrap/model-profiles/codex-model-profiles.json`
  - Sol/Luna/Sol primaries and Terra fallbacks.
- `agent-bootstrap/bootstrap-multi-agent-project.sh`
  - only where existing candidate/status behavior needs new assertions or
    surfaced status; no parallel migration system.
- `scripts/test-bootstrap-multi-agent-project.sh` and
  `scripts/test-onboarding-fixtures.sh`
  - generated-contract, loader, guard, migration, and budget regression tests.
- Root and bundle READMEs
  - Cowork setup, routing behavior, budget values, release pins, and explicit
    limitations.

The model-profile schema remains v1. `render.sh`, the local-only classifier,
and root `.gitignore` are not change targets unless implementation evidence
contradicts this design.

## 16. Verification strategy

Automated verification covers:

- exact generated route values and Terra fallbacks;
- global override, mode override, explicit fallback, and profile precedence;
- functional and validated `CODEX_REASONING_EFFORT`;
- loud failures for malformed JSON, unknown profiles, and missing fields;
- rejection of a `cross_review` launcher command and absence of a Claude
  cross-review routing surface;
- launcher behavior for the three modes and diagnostic commands;
- propagation and accidental-nesting behavior of
  `CODEX_HARNESS_SESSION`;
- absence of model/reasoning hard-codes from `.codex/config.toml`;
- doctor behavior after those config keys are removed;
- diagnostic `doctor`, `status`, and `help` behavior when profile loading fails;
- Sol adequacy fields and the two-section append-only review contract;
- the severity-trigger obligation in the generated reviewing route prompt, its
  absence from the on-demand contract beyond a titled pointer, and the absence
  of any unmeasured review rule from the prompt;
- the cross-review checklist item that verifies those obligations were applied,
  so a skipped rule is detected by the other host rather than assumed;
- single-open-task selection and multiple-open-task user stop condition;
- removal of journal validation from pre-final;
- candidate generation and non-destructive upgrade behavior;
- core context at or below 4000 and full workflow at or below 6200;
- byte-identical regenerated bundle mirrors where currently required.

Before release, bootstrap a clean temporary target and manually exercise one
representative flow through task creation, Sol adequacy review, Luna handoff,
final Sol review, Claude cross-review, and user resolution. This is a protocol
smoke test, not self-hosting and not an automated external-model test.

## 17. Acceptance criteria

The design is complete when a generated target satisfies all of the following:

1. Claude and Codex can determine their current responsibility from canonical
   generated guidance without duplicated role contracts.
2. Only three Codex routes are configurable, with Sol/Luna/Sol primaries and
   explicit Terra fallbacks.
3. Luna cannot proceed without a Sol `yes` adequacy verdict and cannot upgrade
   a Sol `no`.
4. Final Sol review preserves the pre-coding verdict in the same append-only
   artifact.
5. Claude cross-review checks consistency without claiming cryptographic or
   enforced independence.
6. User action is the final authority and the only way to initiate Sol coding
   escalation.
7. Local task packets are clearly documented as ignored, ephemeral, and
   convention-controlled.
8. Ordinary review has one findings-first pass, no mandatory three-role
   simulation, and one measured finding obligation: severity states its trigger.
9. Pre-final no longer depends on an unrelated newest journal.
10. Existing targets receive candidates and actionable status instead of
    silent overwrites.
11. Both context-budget gates pass without raising their thresholds.
12. No new route, schema, updater, telemetry store, daemon, or false security
    boundary is introduced.
