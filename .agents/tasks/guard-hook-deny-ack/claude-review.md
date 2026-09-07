## Cross-review attempt 1

reviewer: Claude (Cowork host)
reviewer_model: claude-fable-5-1 (configured identifier; served model may differ)
model_source: host
fresh_session_attestation: no — cùng session Cowork đã viết task.md; review dựa trên bằng chứng chạy lại độc lập (fixture mới, 3 suite chạy lại), không dựa trên báo cáo của Luna/Sol
author_model (declared): gpt-5.6-luna, xhigh — theo implementation.md và người dùng; không xác minh được (phiên không qua codex-mode.sh)
final_reviewer_model (declared): gpt-5.6-sol — codex-review.md ghi `reviewer_model: unverified`
reviewed_base_commit: 45585fad41724334cd9e93d8c489f8946d9ec8c6 (+ 6 file chưa commit, snapshot sha256 3afefea0…)
reviewed_at: 2026-09-06T09:53:45Z

**Verdict: pass — 0 blocker; 1 lỗi tài liệu trong phạm vi (P3) nên sửa trước khi commit; 3 ghi chú thủ tục.**

### Findings (theo mức độ)

1. **P3 · Lỗi render trong file generated `.claude/README.md`.** Heredoc tại
   `agent-bootstrap/lib/writers-docs.sh:1483` là `<<'EOF'` (quoted) nên
   `\`pre-edit --ack <reason> <path>\`` ở dòng ~1527 được ghi nguyên văn
   kèm backslash. Bằng chứng: target generated từ worktree, `.claude/README.md:44`
   = `exit 2 unless \`pre-edit --ack <reason> <path>\` exists`. Hậu quả: file
   người dùng copy vào Cowork Folder Instructions hiển thị sai. Sửa tối thiểu:
   bỏ hai backslash trong heredoc đó (hai đoạn project-agent-context dùng
   `<<EOF` không quoted nên đúng). Không có test nào assert câu này; Sol
   code-quality pass không bắt được. Trong phạm vi packet (docs text).
2. **P3 · Khai báo thủ tục lệch schema.** `model_source: user_explicit` không
   thuộc `default | CODEX_USE_FALLBACK | <override-variable>`;
   `reviewer_model: unverified` ở pre-coding attempt 2 và final, trong khi
   attempt 1 ghi `gpt-5.6-sol`; implementation.md không có dòng
   `actual_model`/`model_source`. Nguyên nhân: repo kit không phải target
   bootstrap nên không đi qua `codex-mode.sh` (không có seed `actual_model=`).
   Không mâu thuẫn nội tại (đều tự nhận "unverified"); chấp nhận như declaration
   theo contract. Đề xuất ngoài packet: thêm giá trị `raw_session` cho
   `model_source` trong handoff schema để phiên raw ghi được hợp lệ.
3. **P3 · Bỏ qua phase `cross_review`.** state.json chuyển thẳng
   `verification → resolution` (được phép theo bảng transition) nhưng bỏ bước 5
   của flow (Claude cross-review) trước quyết định người dùng. Review này lấp
   khoảng trống; giữ `resolution`/owner user là hợp lệ. Vai "coordinator"
   xuất hiện trong packet không thuộc tập owner `claude|codex|user` — hiểu là
   người dùng vận hành.
4. **P2 · Rủi ro budget, không phải lỗi của thay đổi.** On-demand budget trên
   fixture của Luna đo **6.200/6.200** (đúng gate), coordinator 6.100, fixture
   của tôi 6.068. Phần chữ thêm vào project-agent-context đã dùng hết headroom
   trên một số fixture; lần sửa docs kế tiếp sẽ đụng gate test. Packet tiếp theo
   nên là khử trùng lặp prose (mục 2/4 của review 2026-09-05) để lấy lại budget.
5. Ghi chú: `AGENT_GUARD_ACK_TTL_SECONDS` không hợp lệ → guard rc 1 → hook
   non-blocking (edit vẫn chạy). Fail-open trước lỗi gõ của operator; đúng với
   AC7 và đã có test; chỉ ghi nhận.
6. Ghi chú: suite bootstrap **giả định chạy non-root** (các test unwritable-state
   dùng `chmod a-w`); chạy bằng root sẽ đỏ ở
   `TMPDIR fallback state did not receive verification report` — test có sẵn,
   không liên quan thay đổi này; nên ghi một dòng trong README test.

### Đã kiểm chứng mới (không dựa vào báo cáo của Luna/Sol)

Xem `evidence/claude-cross-review/summary.md`. Tóm tắt: scope đúng 6 file,
index sạch, base 45585fa; snapshot hook/guard == generated; fixture mới: deny
rc 2 (stderr 2 dòng gồm path và lệnh ack), CLI ack rc 0, reuse rc 0
`ack_source=log`, path khác rc 2; focused regression rc 0; mutation
`exit 2→1` làm focused test đỏ đúng assertion; onboarding rc 0, one-shot rc 0,
bootstrap full rc 0 (non-root, 382s).

### Đối chiếu state / review / scope

- state.json: `spec_sufficiency sufficient/yes` khớp pre-coding attempt 2;
  `verification codex/pass` khớp final attempt 2; `report` trỏ tới
  coordinator-verification.md (markdown, không phải `last-verify-report.json`
  — chấp nhận vì repo kit không phải target).
- Không có Sol-coding exception; `escalation_reason` null — đúng.
- Approved scope (6 file, non-goals giữ nguyên: matcher, policy, codex-mode.sh,
  verifier, VERSION) — không vi phạm. Test thêm rộng hơn spec (delimiter paths,
  TSV injection, unwritable state) nhưng không mở rộng hành vi production.

### Đề xuất cho người dùng (resolution)

Chấp nhận với một sửa nhỏ trong phạm vi: bỏ hai backslash tại
`writers-docs.sh` heredoc `.claude/README.md`, generate lại một target để xác
nhận dòng 44 hiển thị backtick thường, rồi commit 6 file (Conventional Commit,
ví dụ `fix(guard): deny unacked protected edits in Claude hook with path-scoped ACK reuse`).
Bump VERSION/MANIFEST thuộc release commit, không thuộc packet này.
