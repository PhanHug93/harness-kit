# Review prompt style: four candidates and their pre-registered evaluation

**Status:** Measured 2026-08-12. C1, C2, C3 kept; C4 reduced to its measured clause.
**Branch:** `feature/review-prompt-style`
**Date:** 2026-08-12

## Why these four

Adapted from `ayghri/i-have-adhd`, whose rules work because nearly all of them
are output obligations rather than exhortations: a violation leaves a visible
trace. Candidates were filtered against what the reviewing contract already has.

Rejected as duplicates of existing rules: cap lists at five (we already cap
blockers at three), end with a concrete next action (each finding already carries
`minimal_change`), restate state each turn (the packet already carries
`reviewed_base_commit`).

Rejected on merit: specific time estimates. A reviewer has no calibrated basis
for "about 15 minutes", and the rule would manufacture precision exactly where
evidence is absent - which contradicts the same skill's own instruction to keep
hedges that carry real uncertainty.

## The four candidates

- **C1 Verdict first.** Open with the verdict and the blocker count, then the
  findings. Origin: leading with the action, because the reader's first decision
  is whether this blocks them.
- **C2 No preamble, no recap, no closer.** Origin: the reader's attention and the
  next agent's context are both spent on the opener.
- **C3 Cause and consequence, no alarm words.** Origin: alarm language adds
  urgency without adding information, and an asynchronous reader cannot ask what
  the alarm meant.
- **C4 Pre-send deletion, real hedges kept.** Delete announcing sentences,
  closing offers, and empty hedging adverbs; keep a hedge that carries real
  uncertainty. Origin: a finding's confidence is information, so blanket
  hedge-cutting manufactures confidence.

## Pre-registered criteria

Register these before running either arm. Subject diff: commit `3c79a9f`
(Tasks 2, 4, 5, 6), which no reviewer has examined.

| Candidate | BINDING | REDUNDANT | INCONCLUSIVE |
|---|---|---|---|
| C1 verdict first | B opens with verdict, A does not | both open with verdict | B does not open with verdict |
| C2 no preamble/closer | A has >=1 forbidden opener or closer, B has 0 | A has 0 and B has 0 after A demonstrably had the opportunity | A has 0, so the rule was never loaded |
| C3 no alarm words | A uses >=1 alarm phrase, B uses 0 | both use 0 across several findings | A uses 0 |
| C4 hedges | B has fewer empty hedges than A **and** keeps every hedge A attached to a genuinely uncertain claim | both identical | B drops a hedge that carried real uncertainty |

C4's second condition requires judgement; it is registered as such rather than
presented as mechanical.

An upper bound is only tested when the case approaches it. A count of zero in arm
A means the rule was never exercised, which is INCONCLUSIVE, not REDUNDANT. That
distinction was got wrong in the 2026-08-10 evaluation and is recorded here so it
is not repeated.

## Disposition rule

BINDING keeps the rule. REDUNDANT removes it, because an unmeasured line dilutes
the measured ones. INCONCLUSIVE keeps the rule out of the seed until a case
exercises it.


## Measured result

Both arms were fresh-context Claude sessions given the same subject diff, the
same read-only tools, and the same task. The only difference was the reviewing
seed: arm A carried the single severity-trigger rule, arm B carried that rule
plus C1-C4.

| | Arm A (1 rule) | Arm B (4 rules) |
|---|---|---|
| Verdict in the opening line | none anywhere in the output | present, with blocker count |
| Words before the first finding | 315 | 10 |
| Closing recap section | two (`Not flagged (and why)`, `Also verified clean`) | none |
| Alarm words | 1 (`silently`) | 0 |
| Empty hedging adverbs | 1 (`arguably`) | 0 |
| Hedges on genuinely uncertain claims | 3 adverbs | 0 adverbs, 1 explicit `(estimate)` marker naming what the diff cannot settle |
| Findings | 3 | 7 |
| Characters per finding | 4074 | 1237 |

Comparative `rather than` was excluded from the hedge count; the regex matched
it six times in arm A and twice in arm B, and it is a conjunction, not a hedge.

## Disposition

- **C1 verdict first - BINDING, kept.** Arm A never states a verdict. Not a late
  verdict, not a weak one: the reader cannot learn from arm A whether the change
  is approved. This is the largest measured effect of the four.
- **C2 no preamble/recap/closer - BINDING, kept.** 315 words to 10.
- **C3 no alarm words - BINDING, kept.** Margin is one word. Recorded as thin:
  a second evaluation should treat C3 as unsettled rather than confirmed.
- **C4 - reduced to one clause, kept.** Its first two deletion targets,
  announcing sentences and closing offers, are the same prohibition C2 already
  states; only the hedge clause is unique, and that clause measured 1 empty
  hedge to 0. The duplicated clauses were cut. This is not a disposition change:
  a duplicated line dilutes the measured ones exactly as an unmeasured line does.

## What this evaluation does not establish

The arms reported non-overlapping findings. Only one finding is common to both,
and they graded it differently (A: P1, B: P2). Arm A found a base-image mismatch
in the supplied snapshot that arm B never surfaced; arm B found a stale budget
figure that arm A never surfaced. Neither difference is attributable to the
rules, and one run of two agents cannot separate rule effect from run variance
in *what* gets found. These four rules were measured on the *form* of a review,
and the form is all they bind.

Both arms are Claude. The measurement shows these rules bind a capable model. It
is not direct evidence for Sol, which is the model the reviewing seed actually
launches.

## Registered for the next evaluation, not shipped

**C5.** C2 as written forbids a closing recap. Arm A's `Not flagged (and why)`
section named three specific things it investigated and deliberately did not
report, which is information the next reviewer can act on rather than a
pleasantry. Whether C2 should carry an exemption for an examined-and-not-flagged
list is untested, so it stays out of the seed until a case measures it.
