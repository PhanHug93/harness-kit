## Request (verbatim)

> đây là phân tích song song của Codex hãy xem và đưa ra 1 packet cải thiện thêm trong branch này để làm trong hôm nay luôn

Kèm theo: phân tích song song của Codex trên `feature/simplify-task-relations`
@ `45585fa` (worktree sạch). Kết luận trùng với review Claude 2026-09-05; thứ tự
ưu tiên thống nhất: **guard + ACK → Stop/local-only → context loading/budget →
launcher/detector**. Packet này lấy mục đầu tiên vì bounded, không phụ thuộc
quyết định policy, và làm được trong một ngày.

## Objective

Claude Code hook phải **thực sự chặn** `Edit`/`Write` vào protected path khi
chưa có ack, và **công nhận ack ghi bằng CLI** (`scripts/agent-guard.sh pre-edit
--ack <reason> <path>`) — vì model không thể set env var cho hook. Không khoá
onboarding (edit `docs/agent-configs/**` là bước bắt buộc), không đổi hành vi
cho Codex/Gemini/Cursor/Windsurf, không mở rộng phạm vi guard.

## Evidence

1. Claude Code hook contract (code.claude.com/docs/en/hooks): PreToolUse chỉ
   chặn tool call khi **exit 2** (stderr được đưa cho model) hoặc stdout JSON
   `hookSpecificOutput.permissionDecision: "deny"` với exit 0. Exit code khác
   0 và khác 2 = *non-blocking*: tool vẫn chạy, stderr chỉ vào debug log.
2. `agent-bootstrap/agent-guard.sh:71-74` `fail()` → `exit 1`;
   `pre_edit()` :755-816 dùng `fail` ở :808 khi protected mà không ack.
3. `agent-bootstrap/agent-hook.sh:244-252` `guard_claude_edit_tool` chỉ đọc env
   `AGENT_GUARD_EDIT_ACK`; không đọc `.agents/state/guard-ack.log`
   (`append_ack_log` :540-556 ghi TSV `<utc>\tpath=..\tpattern=..\treason=..\tack=..`).
4. Tái hiện trên fixture generated từ đúng branch: hook trả `rc=1` cho
   `{"tool_name":"Edit","tool_input":{"file_path":"docs/agent-configs/project-brief.md"}}`;
   sau `pre-edit --ack x <path>` vẫn `rc=1`. Codex tái hiện độc lập cùng kết quả.
5. Test hiện tại `scripts/test-bootstrap-multi-agent-project.sh:2192-2201` chỉ
   assert "non-zero" nên xanh dù hook không chặn.
6. Generated `scripts/agent-hook.sh` sinh từ heredoc
   `agent-bootstrap/lib/writers-runtime.sh:335` (hàm tại :579-587); snapshot
   `agent-bootstrap/agent-hook.sh` phải khớp byte (drift test).
   `scripts/agent-guard.sh` là `copy_bundle_file` (writers-runtime.sh:325) →
   sửa trực tiếp `agent-bootstrap/agent-guard.sh`.

## Acceptance criteria

AC1. Hook input Edit/Write vào protected path, không có ack hợp lệ → hook exit
**đúng 2**; stderr ≤ 3 dòng, chứa đường dẫn và lệnh ack chính xác để chạy lại.
AC2. Sau `scripts/agent-guard.sh pre-edit --ack "<reason>" <path>` (không env),
hook cho cùng canonical path → exit 0, stdout có `ack_source=log`.
AC3. Ack cho path A không mở khoá path B (B vẫn exit 2).
AC4. Ack quá TTL (`AGENT_GUARD_ACK_TTL_SECONDS`, mặc định 3600; `<= 0` = tắt
ack-từ-log) → exit 2. Test dùng `AGENT_GUARD_ACK_TTL_SECONDS=0`.
AC5. Env `AGENT_GUARD_EDIT_ACK` vẫn hoạt động như cũ (exit 0, ghi log).
AC6. Path không protected → exit 0; hook input `Bash` → hành vi không đổi
(preflight + detector-lock warn + rtk hook), không bao giờ exit 2 từ nhánh này.
AC7. Lỗi guard khác (thiếu required context, policy hỏng, path không hợp lệ)
**giữ exit 1** (non-blocking) — không tạo vòng lặp "không thể sửa AGENTS.md vì
AGENTS.md thiếu".
AC8. `pre-edit` gọi thủ công (Codex/Gemini/người) không đổi output hiện có;
chỉ thêm exit code 3 cho trường hợp denied và trường `ack_source=`.
AC9. Test binding: assert `rc -eq 2` và `rc -eq 0` tường minh; thay `exit 2`
bằng `exit 1` trong hook phải làm test đỏ. Ba suite release
(`test-bootstrap-multi-agent-project.sh`, `test-onboarding-fixtures.sh`,
`test-one-shot-upgrade.sh`) xanh; shellcheck sạch cho file đã sửa.
AC10. Snapshot `agent-bootstrap/agent-hook.sh` == generated; doctor/verifier
vẫn pass (các grep `"matcher": "Edit|Write|MultiEdit"` và
`./scripts/agent-hook.sh claude-pretool` giữ nguyên).

## Scope / non-goals

Non-goals (để packet riêng): JSON `permissionDecision` thay cho exit 2; thêm
`NotebookEdit` vào matcher (kéo theo doctor/verifier/test grep); đổi ngữ nghĩa
preflight-fail; Stop hook; local-only policy; validator cho task relations;
bump VERSION/manifest (thuộc release commit).

## Design

### `agent-bootstrap/agent-guard.sh`

- Thêm hằng `EXIT_PRE_EDIT_DENIED=3` và helper `deny()` (in
  `agent-guard: DENIED: ...` ra stderr, exit 3). Chỉ dùng tại vị trí :808.
- `pre_edit` thêm option `--use-ack-log`. Khi strict, protected, không có
  `--ack`, và option bật: tra `$ACK_LOG` bằng python3 (đã là hard requirement
  của guard) — parse mỗi dòng: field 1 = `%Y-%m-%dT%H:%M:%SZ`, tìm field
  `path=<relpath>` khớp **chuỗi chính xác** với `canonical_project_relpath`
  của path đang xét; lấy dòng hợp lệ mới nhất; chấp nhận nếu
  `now - ts <= AGENT_GUARD_ACK_TTL_SECONDS` (default 3600; `<=0` → không tra).
  Dòng hỏng/không parse được → bỏ qua. Không ghi thêm dòng log khi tái dùng.
- Output line: `path=.. protected_path=true pattern=.. reason=.. ack_source=ack|log|none`
  (`ack` = `--ack` trên lời gọi này; `log` = tái dùng; `none` = denied).
  Path không protected: giữ nguyên `path=.. protected_path=false`.
- `STATE_WRITABLE != true` (state dir và TMPDIR fallback đều không ghi được):
  cảnh báo `ack log unavailable; protected edit allowed advisory-only`, exit 0,
  `ack_source=advisory` — nhất quán với các nhánh advisory khác của guard và
  tránh vòng lặp không thể ack. (Xem Open question 1.)

### `agent-bootstrap/lib/writers-runtime.sh` :579-587 (+ snapshot `agent-bootstrap/agent-hook.sh`)

```bash
guard_claude_edit_tool() {
  local edit_path="$1" rc=0
  [[ -n "$edit_path" ]] || fail "Claude edit hook did not include tool_input.file_path"
  if [[ -n "${AGENT_GUARD_EDIT_ACK:-}" ]]; then
    "$AGENT_GUARD" pre-edit --strict --use-ack-log --ack "$AGENT_GUARD_EDIT_ACK" "$edit_path" || rc=$?
  else
    "$AGENT_GUARD" pre-edit --strict --use-ack-log "$edit_path" || rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    3)
      printf 'agent-hook: DENIED protected edit: %s\nTo proceed intentionally run: scripts/agent-guard.sh pre-edit --ack "<reason>" %s\nthen retry the edit (ack valid %ss).\n' \
        "$edit_path" "$edit_path" "${AGENT_GUARD_ACK_TTL_SECONDS:-3600}" >&2
      exit 2
      ;;
    *) exit "$rc" ;;
  esac
}
```

`claude_pretool` giữ nguyên (`preflight` trước, `exit 0` sau khi guard pass).
Cách đồng bộ snapshot: generate vào thư mục tạm rồi copy
`scripts/agent-hook.sh` → `agent-bootstrap/agent-hook.sh` (hoặc sửa cả hai
giống hệt); drift test sẽ chứng minh.

### Docs (chỉ chữ, không đổi cấu trúc)

- `agent-bootstrap/lib/writers-docs.sh:613-616` và
  `:967-969` (project-agent-context.md, hai preset): thêm một câu — trong
  Claude Code, hook **từ chối** edit protected path chưa ack (exit 2); ack bằng
  `pre-edit --ack <reason> <path>` có hiệu lực `AGENT_GUARD_ACK_TTL_SECONDS`
  (mặc định 1 giờ) cho đúng path đó.
- `writers-docs.sh:1526-1528` (.claude/README.md): "guards" → "denies (exit 2)
  unless a recent `pre-edit --ack` exists for that path".
- `CHANGELOG.md`: mục `## Unreleased — Claude edit hook denies without ack`.
- Budget: project-agent-context là core (hiện ~2370/4000), thêm ≤ 40 token; chạy
  lại doctor để ghi số.

### Tests — `scripts/test-bootstrap-multi-agent-project.sh:2192-2201`

Thay block hiện tại bằng các case, mỗi case bắt `rc` tường minh:
1. protected, không ack → `rc -eq 2`; stderr chứa `pre-edit --ack` và path.
2. `pre-edit --ack reviewed AGENTS.md` rồi hook (không env) → `rc -eq 0`,
   stdout chứa `ack_source=log`.
3. hook cho `CLAUDE.md` sau bước 2 → `rc -eq 2` (AC3).
4. `AGENT_GUARD_ACK_TTL_SECONDS=0` với ack ở bước 2 → `rc -eq 2` (AC4).
5. env `AGENT_GUARD_EDIT_ACK=reviewed` → `rc -eq 0`, `ack_source=ack` (AC5).
6. `src/main.txt` → `rc -eq 0`, `protected_path=false` (AC6).
7. `pre-edit --strict AGENTS.md` gọi trực tiếp (không `--use-ack-log`) → `rc -eq 3`
   (AC8; chứng minh guard tự nó không trả 2).
Giữ nguyên các test Bash-input tại :978 và :2055.

## Edge cases

- Claude truyền `file_path` tuyệt đối; cả hook lẫn CLI đi qua
  `canonical_project_relpath` → cùng relpath; khớp chuỗi là đủ.
- Reason/ack có tab hoặc newline: lookup chỉ tin field đầu và field `path=`;
  không parse các field còn lại.
- `guard-ack.log` không tồn tại → coi như không có ack.
- Nhiều ack cho cùng path: lấy dòng hợp lệ mới nhất.
- Thời gian máy lệch/đồng hồ lùi: `now - ts < 0` → coi là hợp lệ (không chặn
  vì clock skew).
- Codex sandbox: không chạy hook Claude; `pre-edit` thủ công giữ hành vi cũ
  ngoài exit 3 khi denied.

## Migration / security / privacy

Không đổi format log (chỉ đọc). Không thêm file state. Không ảnh hưởng
`--apply-candidates`/upgrade (hook là generated file; drift qua candidate như
mọi lần). Đây vẫn là file-edit guardrail, không phải security boundary
(`sed -i`/`cat >` qua Bash không bị chặn — giữ nguyên tuyên bố hiện có).

## Verification

```bash
bash scripts/test-bootstrap-multi-agent-project.sh
bash scripts/test-onboarding-fixtures.sh
bash scripts/test-one-shot-upgrade.sh
shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-guard.sh agent-bootstrap/agent-hook.sh
```

Smoke thủ công trên target tạm (`--workflow full`): 4 lệnh hook với JSON
input như test 1/2/3/6, ghi rc vào `implementation.md`. Bước acceptance do
người dùng chạy (host end-to-end, ngoài phạm vi Luna): mở target trong Claude
Code, yêu cầu sửa `AGENTS.md` → Claude phải nhận thông báo DENIED và tự chạy
`pre-edit --ack` trước khi sửa.

## Assumptions

- Chỉ Claude Code chạy `claude-pretool`; Cowork không chạy hook (README đã nói).
- python3 có mặt (guard đã yêu cầu cho freshness check).
- TTL 3600 là mặc định hợp lý cho một phiên làm việc; đổi bằng env, không cần
  sửa policy JSON.

## Open questions (cho Sol)

1. Khi state không ghi được: advisory-allow (đề xuất) hay deny cứng? Deny
   cứng tạo vòng lặp không thể ack trong sandbox read-only.
2. Có ghi thêm một dòng `ack_reused` vào log khi tái dùng ack (audit) không?
   Đề xuất: không, giữ log chỉ chứa ack tường minh.

## Implementation boundaries

Chỉ sửa: `agent-bootstrap/agent-guard.sh`, `agent-bootstrap/lib/writers-runtime.sh`
(heredoc hook), `agent-bootstrap/agent-hook.sh` (snapshot),
`agent-bootstrap/lib/writers-docs.sh` (3 đoạn chữ), `CHANGELOG.md`,
`scripts/test-bootstrap-multi-agent-project.sh`. Không đụng policy JSON,
schema, matcher trong `.claude/settings.json`, codex-mode.sh, verifier.
Base: `feature/simplify-task-relations` @ `45585fa` (== `main` trừ release bump).


## Specification revision 1

Date: 2026-09-06. Author: Codex coordinator (ChahiDev), under the user's explicit
instruction to resolve remaining technical findings, hand off to Luna xhigh,
then verify and report on this branch. This instruction authorizes the bounded
specification amendment despite the prior `analysis/claude` routing card.
This revision supersedes conflicting pseudocode and test details above; it does
not change the original request, source boundaries, protocol, or non-goals.

### B1: one denial message and one adapter translation

- Guard `deny()` owns the complete denial message (two lines on an otherwise
  healthy fixture), exits `EXIT_PRE_EDIT_DENIED=3`, and reports
  `ack_source=none` on the existing protected-path stdout line.
- Line 1 identifies DENIED and the canonical path. Line 2 contains a runnable
  `scripts/agent-guard.sh pre-edit --ack "<reason>" -- <quoted-canonical-path>`
  command. Use Bash `printf %q` for the canonical path (including spaces,
  quotes, leading dash, and shell metacharacters). Do not interpolate raw
  multiline path text into stderr.
- The Claude adapter calls strict pre-edit with `--use-ack-log`, preserves
  explicit environment ACK, forwards the guard streams unchanged, and translates
  only rc 3 to hook rc 2. It adds no denial text. Guard errors remain rc 1;
  existing upstream preflight and Bash behavior stay unchanged.
- Tests assert rc 2, DENIED marker, <=3 stderr lines, and execute the printed
  ACK command after replacing only the reason placeholder, using a protected
  fixture path containing spaces and a quote. Retry the absolute path and
  require rc 0 with `ack_source=log`; shell metacharacters must not execute.

### B2: TTL contract and its actual expiration boundary

- Lookup uses the existing resolved `$ACK_LOG` only when strict protected edit
  has `--use-ack-log` and no explicit ACK. `${AGENT_GUARD_ACK_TTL_SECONDS:-3600}`
  is a base-10 integer with optional leading minus, no other characters;
  invalid nonempty input is a guard configuration error rc 1. Use Python
  integer parsing after validating the grammar, avoiding shell overflow/octal.
- TTL <=0 disables reuse. A valid matching explicit-ACK record is usable when
  `now - record_time <= TTL`. Preserve the original clock-skew decision:
  a future timestamp is accepted; do not silently invent a skew ceiling.
- Scan well-formed rows and choose the newest matching timestamp, not the last
  physical row. Missing/unreadable/malformed log or rows cannot grant an ACK;
  no matching usable row produces denial unless the narrow state-unwritable
  advisory exception below applies.
- Add separate assertions for positive TTL with a clearly old row (rc 2),
  fresh row (rc 0), zero and negative TTL (rc 2), malformed TTL (rc 1), future
  timestamp (rc 0), malformed rows ignored, and unordered timestamps. No sleep
  is needed; test fixtures write UTC timestamps relative to current time.
- Snapshot ACK log bytes before/after reuse; require no change. Reuse does not
  append `ack_reused`, refresh the timestamp, or extend TTL.

### B3: fixed TSV grammar and safe writes

- Keep the five-column physical-line format: timestamp, `path=`, `pattern=`,
  `reason=`, `ack=`. Validate field count, fixed prefixes, UTC timestamp and
  nonempty ACK; only the second column is a path authority. Never search all
  fields for a `path=` substring. Existing well-formed delimiter-free records
  remain reusable; malformed legacy rows are ignored.
- Escape backslash then CR/LF/TAB in non-path appended values as literal
  backslash sequences. This preserves one physical record per explicit ACK
  and keeps reason/ack text from introducing additional fields or rows.
- Preserve ordinary canonical paths literally for exact matching. Canonical
  paths containing CR/LF/TAB cannot be represented in this legacy format:
  an explicit acknowledgement may authorize its current invocation, but do not
  append/reuse a log record for such a path; warn about non-reusability. Do not
  encode a delimiter path into a spelling that could match a different literal
  filename. No new log version, schema, or state file is introduced.
- Test an explicit ACK for A whose reason contains a tab `path=B` and a newline
  followed by a syntactically plausible row for B. A must reuse correctly;
  B must still deny; physical log line count must increase by exactly one.
  An existing malformed row with an extra `path=` field must also be ignored.

### B4: preserve non-denial errors and the narrow advisory exception

- Validation order: arguments, policy/context, canonical path, protected-path
  classification, then explicit ACK / optional log lookup / missing-ACK
  handling. A bad policy, missing required context, or invalid external path
  remains guard/hook rc 1, regardless of state writability.
- Strict manual `pre-edit` without `--use-ack-log` still requires an explicit
  ACK; a missing one is rc 3. Preserve existing manual `--advisory` behavior.
- With log reuse enabled, precedence is explicit ACK (`ack_source=ack`), then
  readable valid log (`log`), then advisory (`advisory`) only if
  `STATE_WRITABLE != true` after all existing resolver candidates are exhausted.
  An absent or malformed log in a writable state directory is never advisory.
  Advisory emits the warning specified in the original design and rc 0.
- Exercise generated hook with actual Bash JSON, not empty stdin. Assert rc 0
  under healthy inputs and evidence that the existing detector/rtk dispatch
  ran; use a bounded fake rtk executable if needed, without changing production
  dispatch or matcher.
- Add generated-fixture hook tests for missing required context, malformed
  policy and outside-root path (rc 1), plus all-state-candidates-unwritable
  (rc 0/advisory). Use real read-only directories under the ordinary non-root
  test account, restore permissions for cleanup, and test the existing
  resolver rather than adding a production testing bypass. If an environment
  cannot represent this case, report the limitation instead of claiming pass.

### Implementation handoff and validation obligations

- Supporting handoff: `luna-handoff.md`, linked here as the execution checklist
  and evidence locations for this packet. Existing Attempt 1 remains immutable.
- Keep changes to the six original source/test/changelog files. Updating test
  setup/helper code within the same test script is permitted when needed to
  isolate ACK state or bind these cases. No general refactor, release bump,
  matcher change, new host capability, or changes to other policies.
- Write focused regression assertions first, observe the original hook fail
  the exact rc=2 expectation, then implement and run focused tests. Mutation
  obligation: change only the adapter's rc-3-to-2 translation to rc 1 in an
  isolated generated fixture and require the focused denial assertion to fail
  for that reason; restore before release checks. Record commands/results.
- Run the three release suites, shellcheck for all changed shell files with
  the packet's established exclusions, generated doctor/verifier, snapshot
  comparison, and four smoke actions (deny, explicit CLI ACK then allow,
  wrong-path deny, unprotected allow). Report measured context budget.
- Source edits and test execution are now authorized on this worktree; no
  commit, push, branch switch, release action or unrelated cleanup is needed.
  Host end-to-end Claude acceptance remains a separate pending result unless
  actually exercised against a real Claude Code session.

## Implementation evidence references

- Focused regression runner: [evidence/run-focused-guard-hook.sh](evidence/run-focused-guard-hook.sh)
- Focused RED result: [evidence/focused-red.log](evidence/focused-red.log)
- Focused GREEN result: [evidence/focused-green-final.log](evidence/focused-green-final.log)
- Adapter mutation result: [evidence/mutation.log](evidence/mutation.log)
- Coordinator-executed Claude Code host runner: [evidence/run-claude-host.py](evidence/run-claude-host.py)
- Coordinator-executed host summary: [evidence/claude-host-summary.json](evidence/claude-host-summary.json)
- Coordinator-executed source provenance: [evidence/claude-host-provenance.json](evidence/claude-host-provenance.json)

## Coordinator final handoff

The original host links above are historical evidence. Current acceptance and
post-verification are consolidated in
[coordinator-verification.md](coordinator-verification.md), which links the
final host trace/provenance, fresh generated checks, mutation, release logs,
lint baseline comparison, and source hashes. The original failed independent
review is preserved in [post-review-attempt1.md](post-review-attempt1.md);
[post-review.md](post-review.md) records the passing final review.

The latest user instruction authorized the coordinator to resolve remaining
technical findings, hand off to Luna xhigh, then verify and report on
`feature/simplify-task-relations`. Implementation and verification are complete;
the packet proceeds to user resolution for final acceptance.

## Outcome

- Summary: Claude protected edits now receive hook rc 2 when ACK is missing;
  the CLI ACK log authorizes the exact canonical path within its configured
  TTL. Other guard errors retain rc 1, and delimiter-bearing paths cannot
  create or reuse ambiguous log records.
- Evidence: [Luna implementation](implementation.md),
  [Sol final review](post-review.md), and
  [coordinator verification](coordinator-verification.md). Three release suites,
  focused regressions, generated checks, mutation, and real Claude Code host
  acceptance passed; broader lint matches its baseline.
- Effect on source: The guard + ACK remediation is ready for user acceptance
  on this worktree. Changes remain uncommitted, and the wider quality report's
  other findings retain their separate scope.

## Cross-review evidence references

- Claude cross-review: [claude-review.md](claude-review.md)
- Fresh verification summary and reviewed snapshot: [evidence/claude-cross-review/summary.md](evidence/claude-cross-review/summary.md), `evidence/claude-cross-review/worktree-snapshot.tgz`

## Release acceptance — 2026-09-08

The guard implementation above was published in `v2026.09.07.1` (`cf8f326`).
The user's subsequent combined release authorization accepts that result and
closes the former user checkpoint. The 2026.09.08.1 source leaves guard/hook
behavior unchanged and reruns the bootstrap guard regressions. Existing real
Claude host evidence above is historical; no new live-host run is claimed.
