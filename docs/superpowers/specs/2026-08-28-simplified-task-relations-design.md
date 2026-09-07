# Simplified Task Relations Design

Date: 2026-08-28
Status: approved direction
Branch: `feature/simplify-task-relations`
Base: `main` at `a9a1c63`.

## Decision

Treat `state.json` as a routing card for the current task, not as a workflow
history database. Add only two optional relationship fields:

```json
{
  "source_task": "phase-08-production-verification-release-task-3#F-A3-1",
  "blocks": ["phase-08-production-verification-release-task-3"]
}
```

- `source_task` answers why the task exists. It contains a task id and may add
  one `#finding-id` anchor.
- `blocks` answers which task cannot continue while this task remains active.
- A missing `source_task` is equivalent to `null`.
- A missing `blocks` is equivalent to `[]`.
- Existing `claude-codex-collaboration/v1` packets remain valid. This additive
  design does not require a protocol-version bump or a bulk migration.

No reverse relationship is written into the source task. When a blocking task
becomes `closed`, its `blocks` edges become inactive without another state
transition.

## Goals

1. Make causal and blocking relations, and closed-edge semantics, visible in
   task packets.
2. Preserve a concise closure outcome.
3. Keep the workflow backward-compatible and manually governed.

## Non-goals and complexity budget

This change does not add:

- specification-attempt or implementation-attempt counters;
- a transition ledger or state-history file;
- new phase, status, owner, outcome, or remediation enums;
- an attachment registry;
- a hard maximum on lifetime remediation rounds;
- a new hook or a packet-writing command;
- automatic mutation of source or blocked tasks;
- scanning of the relation graph at runtime;
- active-task selection logic in the guard or hook;
- preflight failure caused by any packet other than the one being edited.
- enforcement of historical transitions from the current snapshot.

The first patch may add exactly the two relationship fields above. Any later
field requires a separately evidenced defect and a new decision.

## Relationship semantics

### `source_task`

The value is either a task id or `<task-id>#<finding-id>`. The task-id portion
must name an existing packet when it is available. The optional finding anchor
distinguishes separate causes discovered in one source task.

Examples:

```json
"source_task": "pre-device-consolidation-review-task-13#W1"
```

```json
"source_task": "phase-08-production-verification-release-task-3#F-A3-1"
```

The finding detail, evidence, and scope remain in `task.md`; they are not copied
into state.

### `blocks`

`blocks` is a unique list of task ids. An edge is active only while the packet
holding it is not `closed`.

```text
Task 3 discovers F-A3-1
  -> Task 15 source_task = Task 3#F-A3-1
  -> Task 15 blocks = [Task 3]
  -> Task 15 closes
  -> Task 3 is no longer blocked and may choose its next action
```

Closing the child does not claim that it resolved the source finding. It only
returns control to the source task with an outcome to evaluate.

## Split and loop-prevention rules

1. Continue the current task when the root cause and implementation scope are
   unchanged.
2. Open a child task only for a distinct finding with independently closable
   scope. Record the split rationale in `task.md`. Review retries remain in
   the same packet.
3. For one exact `source_task` value, at most one active child may block the
   same target.
4. A task cannot source from or block itself.
5. Active blocking edges must be acyclic.
6. A child must not create another child merely because its review produced a
   new attempt. Attempts stay in the same packet.

These rules prevent workflow loops without creating loop-management states.

## Closure output

Before a task is marked `closed`, append one concise section to its existing
`task.md`:

```markdown
## Outcome

- Summary: <what changed or what was learned>
- Evidence: <test, report, or review path>
- Effect on source: <what the source task can decide or do next>
```

The fields are prose, not enums. The outcome is useful to the source task but
does not drive an automatic transition.

## Artifact policy

The six existing packet files remain the canonical artifacts, not a hard
maximum. Supporting evidence files are allowed when `task.md` links them and
states their purpose. No machine-readable attachment registry is introduced.

This keeps ordinary packets small while allowing an investigation to retain a
run sheet, evidence record, or residual register without breaking the packet
contract.

## Remediation guidance

Keep `revision_rounds` for compatibility, but treat two unsuccessful returns as
a user checkpoint rather than a permanently invalid state. After the second
return, ask whether another bounded pass is worth its cost. A user-authorized
pass may continue in the same task and does not require a new status or child
task.

## Enforcement

Relations are authoring conventions. Self-reference, duplicate active children,
and cycles are avoided by the agent writing the packet and checked by the
reviewer reading it. No guard, hook, or runtime reads `source_task` or `blocks`
in this phase.

## Generated-source boundaries

- Contract text is generated from `agent-bootstrap/lib/writers-docs.sh`.
- Generated docs are not edited directly.

## Acceptance criteria

1. Legacy packets with neither field pass unchanged.
2. A Task 3 -> Task 15 relationship is expressible with two fields.
3. The generated contract states that a closed packet's `blocks` edges are
   inactive and no edit to the blocked packet is required.
4. The generated contract documents self-link, duplicate-child, and cycle
   avoidance as authoring conventions.
5. The generated contract states that missing referenced packets do not
   invalidate the current packet; agents record uncertainty and continue.
6. The generated handoff contract includes the split rules and `## Outcome`
   format.
7. The canonical artifact wording permits linked supporting evidence without a
   registry.
8. The current lifecycle enums and protocol version remain unchanged.
9. All three release-gate test scripts pass.

## Rejected alternatives

- A generic `relations[]` taxonomy was rejected because it invites new relation
  types without improving current decisions.
- Runtime relation validation is deferred. Automatic detection could catch
  malformed, duplicate, or cyclic relations, but relations currently drive no
  machine action. Global validation would introduce cross-packet scanning,
  active-task selection, and failure semantics disproportionate to the current
  manually recoverable risk. Reconsider when relations become machine input,
  when tooling routes, closes, or creates tasks from them, or when an observed
  defect demonstrates the need.
- Transition history and per-attempt counters were rejected because they turn
  routing state into an audit database and encourage repair loops.
