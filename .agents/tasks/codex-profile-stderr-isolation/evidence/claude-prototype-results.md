# Prototype validation (Claude, cloud container, bash 5.2, python 3.12) — informational, not Luna's evidence

Target generated from the worktree bundle (`--workflow full`, node fixture). `warnbin/python3` = wrapper printing the macOS confstr warning to stderr then exec real python3; `failbin/python3` = prints "Fatal Python error: init_fs_encoding ..." and exits 1; `fakecodex/codex` = logs args.

RED (current helper, `2>&1`): `status`, `doctor`, and `planning "hello"` with warnbin → `ERROR: model profile error: parser returned 1 fields; expected 8`, rc 1, codex not launched.

GREEN (reference patch applied to writers-docs.sh, target regenerated):
1. valid, no warning → status OK, stderr empty, TMPDIR left empty.
2. valid + warning exit 0 → status OK (`Model profile: stable`), warning forwarded on stderr, rc 0; doctor `ok model profile stable`; `planning "hello"` launched fake codex with `--model gpt-5.6-sol -c model_reasoning_effort="xhigh"`.
3. python startup failure → `ERROR: Fatal Python error: ...`, rc 1, not launched, TMPDIR empty.
4. malformed JSON + warning → error text = warning line + `model profile error: malformed JSON ... line 1 column 3`, rc 1, not launched, TMPDIR empty.
5. invalid reasoning_effort (`ultra`) + warning → warning line + `model profile error: unsupported reasoning_effort 'ultra'`, rc 1, not launched, TMPDIR empty.
6. unwritable TMPDIR (non-root) → `model profile error: cannot create a temporary file under <dir>`, rc 1.
Reinsertion: replacing `2>"$profile_stderr"` with `2>&1` in the generated helper → case 2 fails again with `parser returned 1 fields; expected 8`.
shellcheck 0.11.0 (`--exclude=SC1090,SC1091,SC2034,SC2154`) on the generated helper: clean. `bash -n`: clean.
Not run here: macOS `/bin/bash` 3.2 execution (no 3.2 available in the container) — required in Luna's verification.

## Astra @ ultra addendum (same container; combined patch applied to a pristine worktree copy)

- status: `Reasoning effort: ultra (planning=ultra coding=xhigh reviewing=ultra)`, `Default model: gpt-6-astra`, fallback `gpt-5.6-terra`.
- doctor: `ok model profile stable: route=planning model=gpt-6-astra source=default effort=ultra (planning=ultra coding=xhigh reviewing=ultra)`.
- launches (fake codex): planning `--model gpt-6-astra -c model_reasoning_effort="ultra"`; coding `gpt-5.6-luna … "xhigh"`; reviewing `gpt-6-astra … "ultra"`; `CODEX_USE_FALLBACK=1` reviewing → `gpt-5.6-terra … "ultra"`; `CODEX_REASONING_EFFORT=high` planning → `"high"`; `CODEX_REASONING_EFFORT=ultra` coding → luna `"ultra"`.
- audit: `CODEX_CODING_MODEL_OVERRIDE=gpt-6-astra` prints `policy_exception=sol_coding authorization=user_session`; default luna coding prints nothing.
- `CODEX_REASONING_EFFORT=turbo` → `unsupported CODEX_REASONING_EFFORT 'turbo'`; v1 profile without route keys → `planning=xhigh coding=xhigh reviewing=xhigh`; warning-on-stderr case still passes; TMPDIR left empty; generated verifier `Pass: 97 Warn: 5 Fail: 0`.
- budget on identical node fixture: before 6134 → rename only 6139 → with Config-version trim 6074 (core unchanged 2431).
- suites with the combined patch (+ expectation updates): bootstrap rc 0 (488s), onboarding rc 0, one-shot rc 0; catalog check OK; shellcheck clean.
