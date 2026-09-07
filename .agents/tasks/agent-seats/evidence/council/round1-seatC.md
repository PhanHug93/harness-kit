## Harness results

| Run (Linux, bash 5.2, py 3.11) | Result |
|---|---|
| original v1 ×1 | 38/38; `prompts=17` for 16 real prompts (`orig-run1.json`) |
| `seats-qa.fixed.py` ×3 on fresh target copies, +1 under CPU load | 38/38 ×4, `prompts=16` (`fixed-run{1,2,3}.json`) |
| `pty_wizard` ×25 under load (`stress2.py`) | v1: rc −1 in 7/25 and 11/25, prompts ≠16 in 22/25; fixed 25/25 rc 0, 16 prompts |
| fake child closing the PTY 1 s before `exit 7` (`pty_driver.py`) | v1 → −1 (the macOS race, deterministic); fixed → 7; hanging child killed after `reap_timeout`, transcript saved |
| Enter-echo child (`pty_driver2.py`) | v1 counts **4097** prompts for 1 (echoed `\r\n` re-matches `>`); fixed 1 |
| mutation program-on-stdin | 33/38, 5 red (= gate's count); failing transcripts in `seats-qa-pty/` |

Changes in `/tmp/council/targets/seatC/seats-qa.fixed.py` (38 `check(` lines diff-identical):
(a) after EOF/`OSError` the child is reaped with `proc.wait(timeout=reap_timeout)` (L139-145), not v1's immediate `poll()`+`kill` (L71-77).
(b) prompts detected on `pending`, cleared after each answer (L103, L118-128); v1 scanned the whole transcript (L66).
(c) transcript saved on a failed check or a kill (L34-55, L150-152); monotonic deadline, drain-after-exit, master closed in `finally`, guarded `os.write` (v1 L70).
Nuance: v1's flood pre-feeds the *next answers*, so JSON stayed correct (0/25 wrong) — a measurement error, as the gate said — but `prompts >= 10` never proved waiting; port an exact count.

## Portability audit

| Construct | Safe? | Reason / evidence |
|---|---|---|
| `read -r -d '' SEATS_PY <<'PY' … \|\| true` (v2:43) | yes | `-d` since bash 2.04, `''`→NUL; var assigned at EOF with rc 1; `-r` keeps `"\r\n"` literals (v2:337); quoted terminator; only trailing LF stripped (24,839→24,838 B). |
| `python3 -c "$SEATS_PY"` (v2:634) | yes | argv[2]=24,838 B measured vs Linux `MAX_ARG_STRLEN` 131,072 and macOS `kern.argmax` 1 MiB total (env 14.5 KB), no per-arg cap. |
| `set -euo pipefail` (v2:8) | yes | `pipefail` ≥3.0; empty `"$@"` under `-u` is POSIX-exempt (gate ran `show` on 3.2.57); rc 1/2/3 propagate (B6). |
| `BASH_SOURCE`, `pwd -P`, `${1:-}`, `case`, env-prefix (v2:10-14, 628-634) | yes | bash 2/3-era; no `[[`, `%q`, arrays, `mapfile`, `${x,,}`, `\|&`. |
| `#!/usr/bin/env bash` (v2:1) | caveat | Homebrew bash 5 wins in PATH; AC13 must call `/bin/bash`; harness spawns `bash` from PATH (L61, L99), so no 3.2 coverage by default. |
| `command -v python3` (v2:631) | caveat | macOS `/usr/bin/python3` is a CLT stub: present, exits non-zero with an install prompt; probe `python3 -c 'import sys'`. |
| Python syntax | yes | `ast.parse(feature_version=(3,6))` OK: no walrus/`match`/parenthesised `with`; f-strings nest differing quotes only; no annotations, `X \| Y`, `dict \|`, `removeprefix` (AST scan 0 hits). |
| Python stdlib | yes | json/os/pathlib/re/sys, every call ≥3.5; `set \|=` (v2:574); harness needs ≥3.7 (`capture_output`). |
| Non-ASCII `—`/`·` in `-c` text | yes | macOS decodes argv as UTF-8 regardless of locale; output verified intact under `LC_ALL=C`. |
| `input()` on a TTY (v2:393) | note | prompt goes to **stderr** (CPython `PyOS_StdioReadline`; verified): keep stderr on the PTY; `wizard 2>/dev/null` hides prompts. |
| `pty` on macOS | yes | EOF reads `b""` (Linux: EIO), both handled (L76-82); macOS may drop unread output at close — only early `"host>"` is asserted from the transcript. |

## Release checklist

1. Prerequisite packets committed (handoff:18-19); `base_commit` set.
2. Close R1-R4 before adopting v2 "as is" (handoff:95); all reproduced: R3 `99` → rc 0 (v2:423-448); R2 `custom\n` → `validate` 0, `resolve` 9 lines (v2:73-74); R4 read-only `AGENTS.md` → traceback, rc 1 (v2:356-363); R1: AGENTS.md is written (bootstrap:1070) before runtime files, and the generator's legacy `model-profiles.json` (writers-runtime.sh:214) makes `init` seed `gpt-5.6-sol`.
3. Static: `bash -n …`; `shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-seats.sh agent-bootstrap/verify-ai-deps.sh <t>/.codex/codex-mode.sh` (v2: rc 0); extracted program through `py_compile` and `ast.parse(feature_version=(3,8))`.
4. Fresh generation (AC1-2): `bootstrap … --workflow full`; `agent-seats.sh validate`; `show` prints `@gate` astra/ultra; `--dry-run` leaves `git status --porcelain` empty.
5. Focused block (AC2-5, 11): ported `seats-qa.fixed.py` plus PTY cases host/model/fallback `99`, newline grammar, injected `OSError`; ×3.
6. `bash scripts/test-bootstrap-multi-agent-project.sh`, `test-onboarding-fixtures.sh`, `test-one-shot-upgrade.sh`, `sync-template-catalog.sh --check` (AC6-7, drift, manifest).
7. Mutations (AC12): stdin (5 red, verified), marker balance (gate: 3), launcher `conflict`; restore.
8. AC8 role-word grep = 0; AC9 numbers recorded; snapshot `cmp` identical; CHANGELOG entry, no VERSION/MANIFEST bump.
9. macOS (AC13): `/bin/bash --version | head -1`, then `/bin/bash <t>/scripts/agent-seats.sh` `show`, `set @build --effort high`, `resolve planning`, `wizard --yes`, and `/bin/bash <t>/.codex/codex-mode.sh status`; PTY harness with `bash`=`/bin/bash`, ×2.

Untestable as written: AC9 lacks a recorded baseline (spec:253); AC13 needs manual attestation; AC1 "embeds the roster" is unachievable until R1 is fixed (`roster-block` needs existing seats, v2:528-534); spec:141 "invalid choice exits 1" is false today for numbers; `authorization=user_session` (spec:191-194) is by definition a declaration (spec:281-285).

## Decision risks

1. **`gate_coding` + one-release alias.** No runtime reader exists; consumers are prose (writers-docs.sh:1172, 1241, 2343-2344) and tests (test-bootstrap:1996, 2140-2141; onboarding:168 `need_not_contains sol_coding`). After the rename onboarding:168 passes vacuously; nothing enforces or dates the sunset. Mitigation: one token constant in writers-docs, update the three positive assertions, add `need_not_contains policy_exception=gate_coding` at onboarding:168, date the sunset.
2. **Auto-seed on launch/first `status`.** Fresh targets seed from the generator's own legacy file (`gpt-5.6-sol`; gate summary `end-of-fresh-generation-init`); incomplete legacy accepted (v2:168-171 skips missing routes); a read command mutates the tree with a non-atomic write (v2:293-294; races, read-only checkouts); `init` never renders (v2:489-492). Mitigation: stop emitting the legacy profile, require the legacy schema's fields, seed in `run` only, temp+rename, `doctor` WARN.
3. **Real PTY via `pty`.** Measurement races (fixed); sandboxes without `/dev/ptmx` make `openpty` raise — fail loudly; `prompts>=10` proves nothing. Mitigation: `SEATS_QA_BASH` defaulting to `/bin/bash`, exact prompt count, transcript on failure.

## Confidence

Harness results: high (all numbers reproduced). Portability: high for Python (compile, AST); medium-high for Bash 3.2 rows — no 3.2 binary obtainable (ftp.gnu.org/GitHub denied by proxy); reasoning plus the gate's 3.2.57 runs. Release checklist: medium (integration unwritten). Decision risks: medium-high.

Artifacts: `/tmp/council/targets/seatC/` — `seats-qa.fixed.py`, `pty-driver-results.txt`, `*-run*.json`, `mutant-stdin.log`, `seats-qa-pty/`.
