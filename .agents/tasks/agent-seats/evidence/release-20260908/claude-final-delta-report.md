**No new defects in the two bounded changes.**

What I verified, from the current files:

- **Verifier gating mirrors.** The seats validation and legacy diagnostic block in the heredoc at `writers-runtime.sh:1418-1437` is byte-equivalent to the snapshot at `verify-ai-deps.sh:640-659`. The executable and syntax checks at `writers-runtime.sh:1567-1573` match `verify-ai-deps.sh:789-795`. Both use the existing full-workflow predicate already applied elsewhere in the same file. The only intended difference is the preset line: the heredoc carries the `__WORKFLOW_PRESET__` placeholder at `:783` and the snapshot carries `full` at `:5`, which is the established interpolation the drift test expects.
- **Infra behavior.** The entrypoint installs and seeds seats only under `workflow_enabled`, so an infra target has no seats runtime or file. The gated verifier no longer requires either. The test at lines 3462-3464 asserts no seats runtime, no `seats.json`, and no missing-seats warning on the infra target, and the verifier call at line 3456 runs under `set -e` inside the suite, so a non-zero verifier would still fail the suite.
- **Prose semantics preserved.** Supporting artifacts remain allowed when linked from the task file at `writers-docs.sh:993-994`. Child closure at `:1068-1069` still returns an outcome without proving the source finding resolved or advancing the blocked task. Rule 6 at `:1085-1086` still forbids a child for a bare review retry. The outcome section at `:1113-1118` keeps the same three fields with shorter placeholders, and the journal doc at `:1327-1334` keeps state.json authoritative and mirroring optional. The suite assertions at test lines 1908-1923 match the new wording.

Scope and limitations:

- Read-only review of the named regions plus the surrounding predicate lines. No tests run, no hashes computed. The coordinator's infra rc 0 reproduction is reported evidence.
- I did not re-verify that the seats schema copy into `docs/agent-configs/bootstrap-multi-agent-project/schemas/` is workflow-independent. The verifier's schema catalog checks at `verify-ai-deps.sh:416` and `:614` are unconditional, so an infra target must still receive that schema file. The passing infra verifier run implies it does, but I did not read the entrypoint branch to confirm.
- Cosmetic only: `writers-docs.sh:1068` and `:1327` wrap at an unusual width. No effect on generated content or assertions.
