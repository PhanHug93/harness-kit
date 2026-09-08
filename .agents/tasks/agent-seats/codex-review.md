## Pre-coding technical review

Latest verdict: [Attempt 4](#attempt-4), 2026-09-08 — **sufficient / yes**;
F1–F3 closed. Earlier attempts below are historical. Production verification
has not started.

### Attempt 1

seat: @gate
reviewer_model: unverified (served model identifier is not exposed in this task)
model_source: current_user_invoked_codex_task
requested_review_profile: gpt-6-astra / ultra in review-brief.md; no separate raw Codex process was launched
fresh_session_attestation: no (current task includes the previous guard review)
reviewed_branch: feature/simplify-task-relations
reviewed_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
reviewed_target: current worktree, including uncommitted guard changes and the untracked draft seats spec
spec_sufficiency: partially_sufficient
sufficient_for_coding_model: no
blocker_count: 6
blocking_gaps: B1 interactive stdin; B2 lossless launcher interface; B3 configuration lifecycle/migration; B4 seat-host-packet mapping; B5 effective-model audit; B6 roster preservation

**Verdict: chưa đủ để giao `@build`.** Seat/tag tách khỏi occupant là hướng
thiết kế phù hợp, nhưng handoff hiện yêu cầu nhận một script tham khảo còn lỗi
hành vi và chưa chốt một số hợp đồng tích hợp quan trọng.

#### B1 — [P1] Wizard không tương tác dù được mở trên TTY

Trigger: gọi `wizard` không có `--yes` trong terminal thật. Reference dùng
`python3 - "$@" <<'PY'` ở `evidence/reference-agent-seats.sh:46`, sau đó kiểm tra
`sys.stdin.isatty()` tại dòng 299. Stdin của Python là heredoc chứa chương trình,
nên nhánh tương tác không chạy. Probe xác nhận shell có TTY, không gửi câu trả
lời nào, không thấy `host>`, nhưng script vẫn ghi cấu hình và trả rc 0.

Điều này vi phạm chức năng lựa chọn ghế ở design:104 và AC3/design:204,
AC4/task:154. Handoff:24–26 hiện chỉ yêu cầu thêm `efforts` và auto-render trước
khi nhận reference làm canonical, nên chưa bao gồm sửa lỗi này.

Required: tách kênh chứa chương trình Python khỏi stdin tương tác. Dùng PTY
thật để test việc chờ nhập, chọn giá trị khác mặc định, Enter giữ gợi ý, đổi
host, model, effort và fallback; assert JSON thực sự đổi theo lựa chọn.
Việc chọn lại host hiện tại rồi Enter ở model cũng phải giữ được model được
gợi ý. Không dùng biến ép TTY làm bằng chứng cho nhánh terminal thực tế.

Evidence: `review-attempt1-confirmed/wizard-pty.txt` và `summary.json` dưới
`evidence/`. `outer_tty=true`, `finished_without_input=true`,
`host_prompt_seen=false`, rc 0.

#### B2 — [P1] Reader TSV được chỉ định làm mất các cột fallback rỗng

Design:85–86 cho phép thiếu fallback; design:108 yêu cầu một dòng chín cột.
Nhưng `build-handoff.md:37` chỉ định `IFS=$'\t' read -r -a`. Bash gộp các tab
phân cách rỗng. Với một cấu hình hợp lệ không có fallback và `conflict=1`,
reference xuất đủ chín cột nhưng reader trên macOS Bash 3.2 chỉ nhận bảy;
giá trị conflict rơi vào vị trí fallback model. Host-controlled seats có nhiều
cột trống hơn cũng đi qua cùng giao diện.

Ngoài ra, reference chấp nhận model id chứa TAB trong catalog, `validate`
trả 0 và `resolve` xuất mười cột. Caller chưa có quy tắc phân biệt dữ liệu với
delimiter. Đây là lỗi hợp đồng dữ liệu, không cần suy diễn thành shell injection.

Required: chốt transport/decoder giữ nguyên cả cột rỗng và field count, cùng
grammar cho model/effort hoặc encoding tương ứng; giữ diagnostics ngoài stdout.
Test round-trip chín trường trên Bash 3.2 với fallback vắng, non-Codex host,
và giá trị chứa delimiter. Khi yêu cầu fallback mà không có fallback, phải có
exit/error rõ và không gọi Codex. Hợp đồng lookup cũng cần nói launcher lấy
`catalog.default_effort` cho model override ở đâu: `efforts <model>` hiện chỉ
trả danh sách effort, còn TSV seat không chứa default của model khác.

Evidence: `handoff-tsv-reader.stdout` có `field_count=7` và phần tử cuối `<1>`;
`summary.json` lưu chín trường gốc. `edge-probes.json` ghi validate model có
TAB rc 0 và output mười cột. Reference:387–391; handoff:37.

#### B3 — [P1] Chưa tách rõ defaults, migration và cấu hình đang có hiệu lực

Các nhánh reference cùng chạy `legacy_suggestions()` trước khi phân biệt
`suggest|reset|wizard` (`reference-agent-seats.sh:282–299`). Kết quả đã tái hiện:

- `reset` vẫn giữ `custom-planner` từ legacy thay vì trở về bundle defaults.
- `reset` trả rc 0 và ghi cấu hình không hợp lệ; `validate` ngay sau đó trả 1.
- Có `seats.json` hợp lệ nhưng legacy JSON bị hỏng vẫn làm `wizard --yes`
  thất bại, dù seats được tuyên bố là nguồn có hiệu lực.
- Legacy `reasoning_effort=low` được launcher hiện tại chấp nhận (status rc 0),
  nhưng wizard migration trả 1 do catalog mới loại effort này. Chỉ fixture
  `high` trong AC hiện tại không bắt được regression đó.

Handoff:35 còn nói tạo defaults theo candidate path trên target cũ, trong khi
`core.sh:135–178` ghi trực tiếp khi file đích chưa tồn tại. Probe dùng đúng
`write_file` với candidate mode trên target cũ chưa có seats đã tạo live
`seats.json` mặc định, không tạo candidate. Khi ấy điều kiện "thiếu seats thì
import legacy" ở design:130 và :170–172 không còn đúng. Đây là lỗi tích hợp
suy ra từ đường ghi được đề xuất; seats generator chưa được triển khai.

Required: ghi một matrix rõ cho fresh bootstrap, upgrade thiếu seats, cấu hình
hiện hữu, malformed seats, malformed legacy, explicit reset, và regeneration.
Fresh defaults phải khác migration; seats đang có hiệu lực phải được giữ nguyên
khi regenerate/apply candidates; reset chỉ dùng defaults và validate trước ghi.
Không cho legacy hỏng chặn thao tác với seats hợp lệ. Chốt cách giữ các effort
legacy được hỗ trợ và xử lý model/effort chưa biết bằng hướng dẫn rõ, không ghi
file không hợp lệ. Rendering ở cuối generation phải tôn trọng dry-run và
candidate mode, không âm thầm sửa live AGENTS hoặc chạy script cũ thay candidate.

Evidence: `summary.json`, `legacy-low-status.stdout`, `integration-probes.json`;
reset rc 0 → validate rc 1; current legacy status rc 0 → wizard rc 1;
`missing_seats_written_live=true`, `candidate_count=0`.

#### B4 — [P1] Ghế đổi host được nhưng packet chưa biểu diễn được người thực hiện

Design:33 cho phép đổi host ở mọi ghế; :82 và :150–151 giữ `owner` enum cũ.
Contract hiện tại vẫn có `owner=claude|codex|user`,
`verification.runner=none|claude|codex` (`writers-docs.sh:1059–1062`) và gắn owner
với phase (`:1220–1221`). Reference chấp nhận `set gate --host gemini` với rc 0.
Packet tiếp theo phải ghi owner nào? Nếu `@verify` chạy trên Gemini, giá trị
runner nào thể hiện đúng host? Nếu `@spec` chuyển sang Codex, transition và
launcher nào hỗ trợ nó khi launcher chỉ nhận gate/build/verify?

Required: định nghĩa ý nghĩa và mapping của seat, owner, occupant host và
verification runner; đồng thời chốt tập seat/host launcher thực sự hỗ trợ.
Có thể giữ compatibility bridge cho v1, nhưng phải có ví dụ packet cụ thể cho
default seats, `@spec` trên Codex, `@gate` trên Claude/Gemini và `@verify` trên
host khác. Các packet cũ thiếu seat vẫn phải có quy tắc đọc không mơ hồ. Giữ
mức enforcement bằng convention đã công bố; finding này yêu cầu hợp đồng dữ
liệu nhất quán, không yêu cầu thêm runtime state-machine validator.

Evidence: design:33, :82–87, :115–120, :150–151;
`edge-probes.json` có `accept-gemini-gate.rc=0`.

#### B5 — [P2] Audit conflict tính trước khi chọn model thực sự được launch

Reference:387–388 so sánh model chính trong seats rồi xuất `conflict`. Design:
122–134 áp dụng override/fallback sau đó nhưng vẫn dùng flag đó cho seed và
summary. Với gate=Sol, build=Luna, reference cho conflict 0; override build
sang Sol sẽ launch cùng model của gate mà không có record được yêu cầu.
Chiều ngược lại, cấu hình trùng model nhưng override sang model khác vẫn mang
conflict cũ. Một fallback trùng gate cũng gặp vấn đề tương tự.

Đây là hệ quả của thuật toán launcher được mô tả, chưa phải kết quả chạy
launcher seats hoàn chỉnh. Required: chốt conflict theo effective model sau
precedence, định nghĩa model nào của gate/verify được dùng để so sánh, và
phân biệt declared configuration với model/session thực tế. Test default,
override và fallback theo cả hai chiều; mutation phải đặt tại boundary thực
sự quyết định audit. `authorization=user_session` chỉ được mô tả là declaration
khi có authorization tương ứng; config/flag không tự chứng minh authorization.
Seed trước launch nên ghi `requested_model` hoặc `launch_model`, không gán tên
`actual_model` cho giá trị chưa được host xác nhận.

Evidence: `summary.json` → `override_conflict_gap`; design:122–134;
handoff:68–71 cho mutation cần điều chỉnh theo boundary cuối.

#### B6 — [P2] Roster renderer không bảo toàn USER overlay và bytes ngoài block

Reference:243–254 dùng text-mode read/write và regex từ BEGIN đến END đầu tiên.
Với AGENTS có BEGIN roster nhưng thiếu END, lần render đầu append block mới;
lần render thứ hai ghép BEGIN cũ với END mới rồi thay cả đoạn ở giữa, xoá USER
overlay. Probe ghi nhận cả hai lần rc 0 nhưng marker `PRESERVE_USER_OVERLAY`
biến mất. Một file CRLF bình thường cũng bị đổi newline toàn file, vi phạm
AC5/task:157–160 về bytes ngoài block.

Required: kiểm tra số lượng/thứ tự marker trước khi ghi; marker không cân bằng
hoặc nhiều block phải fail không sửa file, hoặc có recovery được định nghĩa rõ.
Thay đúng một vùng hợp lệ và giữ nguyên bytes bên ngoài; khi chưa có block,
append mà không xoá nội dung/blank lines cũ. Test missing block, valid block,
CRLF, orphan/duplicate markers và USER overlays, kèm idempotency. Chốt thêm
cách báo partial failure khi config đã ghi nhưng render thất bại, để operator
biết trạng thái nào đang có hiệu lực.

Evidence: `edge-probes.json`, `orphan-after-first.md`, `orphan-after-second.md`;
`summary.json` → `render_preserves_original_prefix_bytes=false`.

#### Ba quyết định của @gate

1. **Dùng `gate_coding` cho record mới**, đọc `sol_coding` như alias legacy
   trong một release, không rewrite lịch sử. Hiện audit chủ yếu là prose và
   declaration; chỉ sửa consumer thực sự tồn tại, không thêm parser lịch sử.
   B5 vẫn cần chốt trigger theo effective model và authorization.
2. **Chọn auto-seed một lần khi thiếu seats và có legacy hợp lệ**, cho launch
   và lần `status` đầu như AC11. `doctor`/verifier giữ read-only, WARN khi thiếu;
   không auto-seed. Không có nguồn legacy, legacy không migrate hợp lệ, hoặc
   seats tồn tại nhưng sai: fail có hướng dẫn, không ghi đè. `wizard --yes` là
   đường khởi tạo tường minh. Quyết định này phụ thuộc matrix B3 được bổ sung.
3. **Dùng PTY thật qua Python stdlib `pty`**, có timeout và cleanup; Python đã
   là dependency. Tránh khác biệt CLI `script` giữa macOS/GNU và tránh biến
   `AGENT_SEATS_FORCE_TTY` trong production. Fixture phải gửi lựa chọn khác
   mặc định và xác nhận chúng trong JSON, không chỉ assert rc 0.

#### Ràng buộc cho bản sửa spec

- Giữ canonical script dạng copy bằng `copy_bundle_file`; dòng AC1/task:146–147
  nói heredoc là stale và cần sửa đồng bộ với design/handoff. Phân biệt thay
  MANIFEST rows với VERSION/MANIFEST version bump. Thêm đủ file installer và
  manifest vào danh sách write boundaries cụ thể.
- Giữ stderr fix là packet riêng trước seats. Các prerequisite commit chưa
  tồn tại tại HEAD được review; không coi findings trong review seats là phê
  duyệt hay thực thi guard commit/stderr patch.
- Chỉ dẫn "adopt reference + efforts + auto-render" cần bổ sung các sửa chữa
  B1/B2/B3/B6; bổ sung các test binding trước khi cấp sufficient/yes.
- Role words phải được phân biệt với tên host integration/model id/default
  examples trong kiểm tra prose; giữ một mô tả phạm vi thống nhất giữa Goals,
  prose section và AC9.

#### Verification và giới hạn

Đã chạy reference nguyên bản trên target generated tạm, ngoài repository,
bằng `/bin/bash` **3.2.57**: suggest, wizard --yes, render hai lần, set invalid
effort, resolve planning, validate, reset và các probe nêu trên. Các ca cơ bản
suggest/wizard --yes/resolve/validate/render idempotency pass; invalid set và
non-human owner trả 1 và giữ nguyên config. Shellcheck reference trả 0.
Những kết quả đó không che các ca lỗi đã tái hiện.

- [Reproducer chính](evidence/review-probes-20260907.py): chạy với argument tên
  evidence directory mới; reference và source giữ nguyên.
- [Kết quả đã xác nhận, source hashes và đường dẫn target](evidence/review-attempt1-confirmed/summary.json).
- [Probe integration/legacy/candidate](evidence/review-attempt1-confirmed/integration-probes.json).
- [Probe host, delimiter và overlay](evidence/review-attempt1-confirmed/edge-probes.json).

Lần PTY đầu có race khi đọc trạng thái process sau EOF; đã sửa measurement
và chạy lại. Dùng evidence `review-attempt1-confirmed`, không dùng flag PTY
trong thư mục `review-attempt1` ban đầu để kết luận.

Chưa có implementation seats tích hợp để kiểm chứng launcher, hai mutation,
budget cuối và ba suite release; các kiểm tra đó thuộc bước implementation.
Không chạy Codex thật cho seats, không sửa production source, không commit.
CodeGraph tool không khả dụng và worktree không có index; dùng bounded source
reads. Agentmemory đã tra nhưng không cung cấp bản seats handoff mới hơn file.
Git read-only dùng `GIT_OPTIONAL_LOCKS=0`.

Routing: trả `analysis/claude` cho `@spec` bổ sung revision giải quyết B1–B6 và
đồng bộ design/task/build-handoff, rồi quay lại `technical_review`. Giữ
`base_commit=null` đến lúc thực sự vào implementation; chưa giao `@build`.

### Attempt 2

reviewed_at: 2026-09-07 (Asia/Ho_Chi_Minh)
seat: @gate
reviewer_model: unverified (served model identifier is not exposed in this task)
model_source: current_user_invoked_codex_task
fresh_session_attestation: no (continuation of the previous review)
reviewed_branch: feature/simplify-task-relations
reviewed_head: 45585fad41724334cd9e93d8c489f8946d9ec8c6
reviewed_target: Specification revision 1 and reference v2 in the current worktree
spec_sufficiency: partially_sufficient
sufficient_for_coding_model: no
blocker_count: 4
blocking_gaps: R1 generation/migration lifecycle (B3); R2 complete field grammar (B2); R3 invalid wizard choices and portable QA (B1); R4 filesystem partial failure (B6)

**Đánh giá:** v2 xử lý đúng nhiều nguyên nhân gốc, có test hành vi và mutation
có ích. Tuy nhiên, kết luận "đã xử lý cả 6" đang rộng hơn bằng chứng. B4 và B5
đủ ở mức hợp đồng thiết kế cho bước implementation; B1/B2/B3/B6 mới đóng một
phần. Chỉ dẫn `build-handoff.md:95` nhận reference v2 **as is** chưa phù hợp.
Đây vẫn là review spec/reference, chưa phải nghiệm thu production integration.

#### Những phần đã xác nhận

| Finding cũ | Kết quả attempt 2 |
|---|---|
| B1 | `python3 -c` giữ terminal thật; lựa chọn hợp lệ, Enter, đổi model/host/fallback và effort sai hoạt động trên Bash 3.2. Còn R3. |
| B2 | Tám dòng giữ được trường fallback rỗng; TAB bị chặn; `model-info` cung cấp default effort. Còn R2. |
| B3 | Reset dùng defaults; seats hợp lệ không bị legacy JSON hỏng chặn; legacy `low` và model lạ migrate được; init giữ file đang có. Còn R1. |
| B4 | Mapping seat/phase/host và các ví dụ packet cho agent hosts đã được ghi rõ; launcher dự kiến hỗ trợ năm ghế Codex. Đóng ở mức pre-coding spec, cần tests khi tích hợp. |
| B5 | `conflict` nhận effective model và so cả primary/fallback của reviewer; helper matrix pass. Đóng ở mức spec/reference; precedence, seed và mutation tại launcher vẫn thuộc implementation. |
| B6 | Balanced markers, CRLF, bytes ngoài block, orphan/duplicate và partial failure do marker đều pass. Hai lần render không còn xoá overlay trong ca cũ. Còn R4. |

#### R1 — [P1] Lifecycle chưa khớp thứ tự generator và validation legacy

Spec:124–130 yêu cầu `init` ở cuối generation, nhưng writer AGENTS lại cần
`roster-block`. Generator hiện gọi `write_agent_docs` trước khi copy runtime và
legacy (`agent-bootstrap/bootstrap-multi-agent-project.sh:1069–1084`). Reference
`roster-block` chỉ đọc seats đã tồn tại (`reference-agent-seats.sh:528–534`).
Vì vậy cần chốt lại thứ tự trước khi nhận plan; chỉ thêm các lời gọi được mô
tả hiện tại không đủ cho fresh target hoặc dry-run. Bootstrap entrypoint cũng
chưa nằm trong write boundaries dù đây là nơi điều phối thứ tự.

Có thêm một lỗi về nguồn defaults: generator hiện tạo `model-profiles.json`
legacy (`writers-runtime.sh:212–216`). Probe trên target hoàn toàn mới, sau
generation mới copy reference v2 và gọi `init`, tạo `@gate = gpt-5.6-sol @ xhigh`,
không phải default `gpt-6-astra @ ultra` của seats. `init` coi legacy vừa được
generator tạo là cấu hình cũ của người dùng. `roster-block` trước init trả 1.
Đây là probe của **thứ tự đề xuất với generator hiện tại**, không phải tuyên
bố đã chạy một implementation seats tích hợp.

Validation nguồn migration cũng chưa đủ: legacy có schema/default_profile
hợp lệ nhưng profile chỉ chứa `reasoning_effort` vẫn được `init` chấp nhận,
rc 0 và tạo config. `migrate_legacy:168–171` bỏ qua route thiếu thay vì từ chối.
Launcher cũ từ chối đúng fixture này, rc 1 với `missing required field`.
Cam kết "auto-seed chỉ từ legacy hợp lệ" chưa được thực hiện đầy đủ.

Required: xác định nguồn trước khi generator tạo legacy mặc định; chuẩn bị
config/roster trước writer AGENTS; chạy đúng bản runtime của bundle/candidate,
không vô tình gọi bản live cũ. Định nghĩa nhánh dry-run không phụ thuộc vào file
chưa sinh và không ghi; bổ sung bootstrap entrypoint vào boundaries nếu cần.
Validate các field bắt buộc của legacy trước migration, không lấp route thiếu
bằng defaults âm thầm. Test fresh Astra defaults, valid customized legacy,
legacy thiếu field, regenerate giữ seats, candidate và dry-run qua generator
thật. Có thể gom các sửa này trong B3; không cần thay đổi product decision.

Evidence: `independent-summary.json` → `end-of-fresh-generation-init`,
`roster-before-init`, `incomplete-legacy-init`, `incomplete-legacy-old-status`;
logs tương ứng dưới `evidence/review-attempt2/`.

#### R2 — [P2] `validate` vẫn cho dữ liệu làm hỏng giao diện tám dòng

`MODEL_RE.match` và `EFFORT_RE.match` dùng regex kết thúc bằng `$`, nên Python
vẫn chấp nhận newline cuối chuỗi (`reference-agent-seats.sh:73–74,195,202,233`).
Model `custom\n` hoặc effort `high\n` trong catalog/occupant đều validate rc 0;
`resolve gate` trả rc 0 với **9 dòng**. Bộ test mới chỉ thử TAB nên không bắt.

Chỉ đổi sang `fullmatch` chưa đủ: model informational của host non-Codex
không được kiểm grammar (`:245–246`); `fallback_effort` bị bỏ qua khi thiếu
fallback model (`:230–232`), trong khi `resolve:547–548` vẫn emit cả hai.
Probe với newline trong mỗi vị trí cũng validate 0 → resolve 9 dòng.
Launcher dự kiến sẽ chặn bằng line-count; tác động được chứng minh là config
được gọi là hợp lệ nhưng không dùng được, không phải đã launch sai model.

Required: dùng full-string validation và kiểm mọi field được serialize, kể cả
optional/non-Codex metadata; định nghĩa rõ reject hoặc normalize trường không
áp dụng. Test trailing LF, CR/LF, TAB, optional orphan và host-controlled fields.
Giữ kiểm line-count và exit status tại caller như lớp kiểm tra thứ hai.

Evidence: `independent-summary.json` → `newline-model-*`, `newline-effort-*`,
`noncodex-newline-*`, `orphan-fallback-effort-*`; stdout chứng minh chín dòng.

#### R3 — [P2] Lựa chọn wizard sai vẫn được chấp nhận; harness cần sửa trước khi port

Spec bảng Script cam kết invalid choice → rc 1, không ghi. Reference vẫn giữ
gợi ý khi host không hợp lệ (`:423–424`) và bỏ qua model/fallback không phải
số hợp lệ (`:431–448`). PTY độc lập nhập `99` đúng từng prompt host, model và
fallback: cả ba rc 0, tiếp tục tới cuối và ghi lại config. Probe dùng JSON
format khác để xác nhận bytes bị ghi lại; transcript lưu rõ prompt nhận `99`.
Test effort `turbo` không đại diện cho các nhánh này.

Required: giá trị không rỗng ngoài tập lựa chọn phải lỗi tường minh và giữ
nguyên config; phân biệt Enter với input sai. Thêm ba test PTY theo từng prompt.

Harness nguyên bản trên macOS có thêm race ở `seats-qa.py:61–77`: PTY đóng
có thể được quan sát trước khi `proc.poll()` thấy exit; code lập tức kill rồi
trả `-1`. Lần chạy độc lập đạt **36/38**, hai ca same-host/invalid-effort đỏ.
Chỉ thêm bounded `proc.wait(timeout=1)` sau EOF trong **bản sao harness**, cùng
reference không đổi đạt **38/38**. Vì thế đây là lỗi đo, không phải bằng chứng
wizard v2 sai ở hai ca đó. Không port nguyên harness theo handoff:107–109.

Harness còn nhìn suffix của toàn bộ transcript để nhận prompt (`:65–70`);
echo của Enter có thể khiến prompt cũ bị đếm lại. Probe độc lập dùng buffer
phần chưa xử lý và xoá buffer sau khi trả lời, cộng với wait/reap process.
Khi sửa harness, giữ assertions hiện có, chỉ sửa cách nhận prompt và vòng đời
process; lưu transcript khi fail và giữ timeout/cleanup.

Evidence: `qa-summary.json` (36/38), `qa-reaped-summary.json` (38/38), bản sao
`seats-qa-reaped.py`; `invalid-*-number.pty`, `independent-summary.json`.

#### R4 — [P2] Lỗi filesystem sau save không dùng exit code partial failure

`write_and_render:356–363` chỉ bắt `SeatsError`. Khi `AGENTS_MD.write_bytes`
gặp `PermissionError`/`OSError` (`:350`), ngoại lệ thoát ra thành traceback
với rc 1. Probe chmod AGENTS của target tạm thành read-only rồi `set build
--effort high`: **config đã đổi, AGENTS giữ nguyên, rc 1**, không có thông báo
`seats.json was written but ... NOT rendered` như contract yêu cầu.

Required: chuẩn hoá lỗi đọc/ghi roster thành lỗi có nguyên nhân rõ và chuyển
mọi thất bại render sau save thành rc 2. Lỗi save trước khi config có hiệu lực
vẫn là rc 1. Thêm test lỗi filesystem thật hoặc injected OSError có kiểm chứng
đúng boundary; assert config mới, roster cũ, rc 2 và message, không chỉ marker
error. Không cần mở rộng thành transaction engine.

Evidence: `readonly-roster-set.stderr` và `independent-summary.json`;
probe chạy uid 501, quyền file được phục hồi trong finally.

#### Verification, artifacts và routing

- `/bin/bash` 3.2.57; `bash -n` và shellcheck với CI exclusions đều rc 0.
- Harness nguyên bản: 36 pass / 2 fail. Bản sao chỉ thêm wait/reap: 38/38.
- Hai mutation độc lập dùng bản sao harness đã sửa race: program-on-stdin
  làm 5 test đỏ; bỏ balance guard làm 3 test đỏ (orphan, duplicate, partial
  failure). Đây là mutation tương đương tự tạo; không xác nhận con số 2 của
  mutation phía Claude vì không có bản mutant đó trong packet.
- [Metadata và source hashes](evidence/review-attempt2/meta.json).
- [Harness nguyên bản](evidence/review-attempt2/qa-summary.json) và
  [harness đã chờ process](evidence/review-attempt2/qa-reaped-summary.json).
- [Mutation results](evidence/review-attempt2/mutation-summary.json).
- [Independent reproducer](evidence/review-attempt2/independent-probes.py) và
  [kết quả](evidence/review-attempt2/independent-summary.json).

Không đổi ba quyết định của gate ở attempt 1. Không yêu cầu thêm runtime
state-machine enforcement. Chưa có seats launcher tích hợp để nghiệm thu
precedence, actual launch, budget, ba suite release hoặc snapshot; đó là các
check của implementation. Chỉ ghi review/evidence/state và index của packet;
spec, reference, harness gốc, production source và HEAD giữ nguyên.

Routing: `analysis/claude`, sửa R1–R4 và harness, cập nhật chỉ dẫn adopt-as-is,
test bindings rồi quay lại `technical_review`. `base_commit` vẫn null;
chưa giao `@build`, không commit. Guard/stderr prerequisite commits vẫn chưa
hoàn tất ở HEAD được review.

### Attempt 3

reviewed_date: 2026-09-08 (Asia/Ho_Chi_Minh)
seat: @gate
reviewer_model: unverified (served model identifier is not exposed in this task)
model_source: current_user_invoked_codex_task
fresh_session_attestation: no (continuation of prior reviews)
reviewed_branch: feature/simplify-task-relations
reviewed_head: cf8f326b61788ed3ed8577eb12511613303dc44a
reviewed_checkout: /Users/admin/projects/agent-bootstrap
reviewed_target: Specification revision 2, reference v3, harness v2, generator reference hunks
spec_sufficiency: partially_sufficient
sufficient_for_coding_model: no
blocker_count: 3
blocking_gaps: F1 init under-lock recheck; F2 malformed catalog entries; F3 portable atomic-write failure tests

**Chưa thể nghiệm thu một implementation seats hoàn chỉnh.** Sau khi tiếp tục
task, branch đã chuyển từ worktree cũ về checkout chính, HEAD mới `cf8f326`.
Commit chứa design và packet/reference; chưa có canonical
`agent-bootstrap/agent-seats.sh`, schema seats hoặc launcher seats trong
production. `writers-docs.sh` vẫn có `load_model_profile` và
`require_model_profile` (:1918, :2479). Packet cũng vẫn yêu cầu pre-coding
review. Vì vậy verdict dưới đây áp dụng cho artifact chuẩn bị implementation.

#### Kết quả độc lập

Đã đọc contract/reference/harness/patch và ghi
[independent-findings.md](evidence/review-attempt3-20260908/independent-findings.md)
**trước** khi mở council record và sáu báo cáo council. Không lấy số test từ
council làm kết quả của lần review này.

- Reference v3, harness nguyên bản v2, macOS `/bin/bash` 3.2.57, uid 501:
  **101 pass / 2 fail / 0 skip**. Các ca PTY, concurrent set, lock timeout,
  read-only AGENTS, symlink, marker/CRLF đều pass. Syntax và shellcheck rc 0.
- Rerun các probe attempt 2: invalid host/model/fallback đều rc 1 và không ghi;
  newline ở model/effort/non-Codex/orphan fallback bị chặn; legacy thiếu field
  không tạo config; AGENTS read-only sau save trả đúng rc 2. Các lỗi cũ này đóng.
- Trong bản sao kit tạm, áp đúng reference generator hunks và copy reference
  làm canonical: fresh → Astra/ultra, không tạo legacy; upgrade default cũ →
  Astra; apply-candidates giữ USER overlay; dry-run fresh rc 0, không ghi file.
  `validate` rc 0. Đây là kiểm tra patch mẫu, không thay đổi source branch.
- Verifier và launcher status trên fresh target của bản sao đó vẫn rc 1 do
  còn yêu cầu legacy. Handoff correction 2 đã liệt kê các consumer phải đổi
  cùng lúc; đây xác nhận phần integration còn thiếu, không phải finding mới
  chống lại một patch tự nhận hoàn chỉnh.

#### F1 — [P1] `init` có thể ghi đè file xuất hiện trong lúc chờ lock

Reference :658–667 đọc lại file sau khi lấy lock, nhưng khác fast path ở
:648–657: nếu JSON parse được thì trả 0 mà không validate; nếu có bất kỳ lỗi
đọc/parse nào thì đi tiếp tới `save(defaults)`.

Đã tái hiện: giữ flock thư mục config, gọi `init` khi seats chưa tồn tại,
ghi `{ malformed` trong lúc process đang chờ, rồi nhả lock. `init` **rc 0 và
ghi đè bytes vừa xuất hiện**. Với JSON parse được nhưng schema sai,
`init` giữ bytes nhưng vẫn báo thành công. Không cần sửa reference để gây lỗi.

Required: chỉ kết quả `missing` sau khi lấy lock mới được phép tạo file.
File đã có phải đi qua cùng validation/error handling như fast path; lỗi
đọc/parse phải từ chối và giữ bytes. Bổ sung test held-lock cho file xuất hiện
hợp lệ, sai schema, malformed/unreadable; kiểm cả rc và nội dung được giữ.

Evidence: [edge-summary.json](evidence/review-attempt3-20260908/edge-summary.json),
`init-after-lock-malformed.*`, `init-after-lock-invalid.*`.

#### F2 — [P2] Catalog entry sai kiểu vẫn gây traceback

`validate:224–230` nhận ra model spec không phải object rồi `continue`, nhưng
vòng kiểm occupant tiếp tục lấy cùng entry và gọi `spec.get` tại :274–281.
Thay `catalog.models["gpt-6-astra"]` bằng string, list hoặc boolean đều tạo
AttributeError traceback, rc 1. Test M1 chỉ thử outer catalog/models sai kiểu,
chưa thử phần tử model mà occupant đang tham chiếu.

Required: không dereference entry chưa qua kiểm kiểu; trả diagnostic rõ với
rc 1 và giữ file. Bổ sung các shape này cho validate/show/resolve/model-info
và write commands liên quan. Đây là gap của cam kết "mis-shaped documents
never traceback"; không phải bằng chứng đã launch sai model.

Evidence: `model-shape-str.stderr`, `model-shape-list.stderr`,
`model-shape-bool.stderr` và `edge-summary.json`.

#### F3 — [P2] Hai test atomic-write chưa kiểm đúng điểm gây lỗi trên Bash 3.2

Harness :433, :438 đặt `ulimit -f` trước khi shell nạp chương trình Python từ
heredoc. Bash 3.2 cần temporary file cho heredoc lớn; limit làm bước đó thất
bại, sau đó báo `SEATS_PY: unbound variable`. R7/R8 không tới `write_atomic`.
Đây là hai ca đỏ trong lần chạy 101/103; không quy chúng thành lỗi truncation
của reference v3.

Đã kiểm riêng bằng chính chương trình Python trích từ reference, đặt
`RLIMIT_FSIZE` sau khi nạp code: limit 4096 bytes → rc 2, config mới, AGENTS cũ
giữ nguyên; limit 1024 bytes → rc 1, cả hai file giữ nguyên; không traceback.
Atomic-write behavior qua các probe này đạt yêu cầu.

Required: đổi cách inject lỗi tới đúng write boundary (ví dụ giới hạn trong
Python sau khi nạp code), giữ nguyên assertions về bytes/rc/message và thêm
mutation in-place-write làm mất bytes để xác nhận test bắt đúng regression.
Không bỏ hai assertion hoặc chỉ đổi thành assert non-zero. Chạy lại harness
nguyên bản đã sửa trên Bash 3.2 trước khi port vào suite.

Evidence: [qa-summary.json](evidence/review-attempt3-20260908/qa-summary.json),
`atomic-python-limit-4096.*`, `atomic-python-limit-1024.*`.

#### Reconciliation với council

Council bổ sung những điểm chưa có trong review attempt 2: atomic write chống
truncate, lost updates khi concurrent set, symlink/ownership implications,
repair bằng set, option whitelist, missing duty, EOF/interrupt và catalog
không có Codex model. Reference v3 và các ca tương ứng trong harness hiện
chứng minh phần lớn các sửa đó trên máy này. Không có bản log Linux đầy đủ
`/tmp/qa3-*` trong môi trường hiện tại để xác nhận độc lập mọi con số x3.

Lần review này phát hiện thêm F1 (nhánh init sau lock), F2 (model entry con)
và F3 (heredoc chịu size limit trên Bash 3.2), chưa thấy được nêu trong sáu
báo cáo council. Council nhận diện đúng nhóm concurrency/shape/portability,
nhưng chưa phủ ba trường hợp cụ thể này.

| Chair decision | Gate attempt 3 |
|---|---|
| 1. Conflict theo primary model | **Confirm theo định nghĩa mới**: audit authority đã cấu hình. Giữ minority limitation: không phát hiện model fallback thực sự đã review. `launch_model` là khai báo yêu cầu, không chứng minh actual reviewer. Sửa câu warning primary-or-fallback còn sót ở Data model để khớp. |
| 2. Auto-seed chỉ ở launch; status/doctor read-only | **Confirm**, thay khuyến nghị first-status-seed trước đây. Tránh lệnh đọc đổi tree. |
| 3. Init fast path không lock; writer chờ tối đa 10 s | **Confirm thiết kế**, implementation chưa đạt do F1. Fast path và recheck phải có cùng nghĩa validation. |
| 4. Set không tạo file, có thể repair | **Confirm**; lifecycle rõ và các ca hiện tại pass. |
| 5. Legacy bằng default cũ, không có effort override → defaults mới | **Confirm như quy tắc migration công bố**, không coi bằng chứng values-equal là bằng chứng "no user decision". Giữ note và test parity với bundle, không đụng seats đã tồn tại. |
| 6. Exit 0/1/2/3/130, BOM/duplicate policy | **Confirm contract**; permission/interrupt/BOM/duplicate pass, F2 còn cần diagnostic đúng cho model entry sai kiểu. |
| 7. Dừng emit legacy cùng consumer/installer/test changes | **Confirm**. Kết quả verifier/status rc 1 của patch-only target xác nhận không thể ship riêng hunks. |
| 8. Bash override, exact PTY prompts, transcripts, permission skip | **Confirm phương pháp**, chưa confirm portable-green vì F3. Các ca PTY lần này đều pass, không còn race attempt 2. |

Không đảo quyết định product nào của chair; các điều kiện sửa còn lại là kỹ
thuật và test binding. Bảy mutation trong council summary **chưa được chạy
lại đầy đủ ở attempt này**, không dùng count đó để tuyên bố verification pass.

#### Artifacts và bước tiếp theo

- [Metadata/source hashes](evidence/review-attempt3-20260908/meta.json).
- [Regression probe results](evidence/review-attempt3-20260908/independent-summary.json).
- [Generator patch results](evidence/review-attempt3-20260908/generator-summary.json).
- [Additional reproducer](evidence/review-attempt3-20260908/edge-probes.py).

Routing: `analysis/claude`, sửa F1–F3 và test bindings, rồi quay lại technical
review trước khi nhận reference vào production. Giữ `base_commit=null` và
feature verification `not_run`. Guard đã có trong HEAD mới; stderr packet vẫn
ở technical_review. Không sửa production, spec hay reference; không commit.
Ba suite release, seats launcher integration, budget cuối và installer/schema
checks chưa được nghiệm thu vì phần integration đó chưa có trên branch.

### Attempt 4

reviewed_date: 2026-09-08 (Asia/Ho_Chi_Minh)
seat: @gate
reviewer_model: unverified (served model identifier is not exposed in this task)
model_source: current_user_invoked_codex_task
fresh_session_attestation: no (continuation of prior reviews)
reviewed_branch: feature/simplify-task-relations
reviewed_head: cf8f326b61788ed3ed8577eb12511613303dc44a
reviewed_checkout: /Users/admin/projects/agent-bootstrap
reviewed_target: task revision 4, spec revision 3, F1–F3 reference/harness fixes
spec_sufficiency: sufficient
sufficient_for_coding_model: yes
blocker_count: 0
blocking_gaps: none in the reviewed pre-coding scope

**Đóng F1–F3; đủ điều kiện coding.** Diff hiện tại sửa đúng nguyên nhân đã
tái hiện ở attempt 3; chưa phát hiện finding mới trong phạm vi sửa này.
Verdict áp dụng cho spec/reference/harness, chưa phải nghiệm thu production
agent seats. Canonical script, schema và seats launcher vẫn chưa được tích hợp.

#### Kết quả tự chạy trên macOS

Môi trường: macOS 26.6.2 arm64, `/bin/bash` 3.2.57, Python 3.13.2, uid 501
(không phải root). Target được bootstrap trong thư mục tạm; không chạy các
thao tác fixture lên checkout nguồn.

| Kiểm tra | Kết quả |
|---|---|
| Harness được giao, không sửa assertion | **109 pass / 0 fail / 0 skip** |
| Probe độc lập: init fast path + dưới lock với sai schema, malformed, unreadable; wizard với model entry str/list/bool | **9 pass / 0 fail** |
| m8 được giao: recheck bỏ validation | rc 1, **2 K4 fail**: invalid báo thành công; malformed bị ghi đè |
| m9 được giao: bỏ type guard vòng occupant | rc 1, **3 M3 fail** |
| Mutation ghi in-place do gate dựng từ reference hiện tại | rc 1, **R7 và R8 đều fail**; tổng 4 fail, gồm R9/R10 chạy tiếp với seats fixture bị R8 truncate |
| `/bin/bash -n`, shellcheck với exclusions CI | rc 0 |
| AST parse Python với `feature_version=(3,8)` | pass cho embedded program và harness; không phải chạy interpreter Python 3.8 |

Không lấy báo cáo Linux x3 hoặc tổng chín mutation của Claude làm kết quả
của gate. Lần này tự chạy một baseline và ba mutation nêu trên. Wrapper tổng
hợp đầu tiên của gate đã giả định m6 phải có đúng hai failure và assert sai
sau khi lưu log; yêu cầu thực tế là **cả R7 lẫn R8 phải đỏ**, không cấm failure
dây chuyền. Ghi chú này có trong mutation summary; không đổi harness/assertion.

#### Kết luận từng finding

- **F1 closed.** `init_precheck()` dùng chung cho fast path và nhánh sau lock;
  chỉ `missing` được tạo file. K4 chứng minh valid giữ bytes/rc 0 và invalid,
  malformed giữ bytes/rc 1. Probe riêng giữ flock trước khi khởi chạy, xác
  nhận process đang chờ rồi mới publish file: cả wrong schema, malformed và
  unreadable đều rc 1, giữ bytes, ghi rõ file xuất hiện lúc chờ. m8 bị bắt.
- **F2 closed.** `model_spec()` và structural guard chặn entry con sai kiểu
  trước khi dereference. M3 kiểm bảy command; probe riêng kiểm thêm
  `wizard --yes`: diagnostic, rc 1, không traceback và không sửa config/AGENTS.
  m9 bị bắt. Không còn coi outer-shape test là đủ cho nested model entries.
- **F3 closed.** Harness hiện tại áp RLIMIT_FSIZE qua shim interpreter; R7/R8
  trên Bash 3.2 nhận `[Errno 27] File too large` tại write boundary. Baseline
  giữ nguyên bytes với rc 2/1 đúng contract; in-place mutant làm đỏ chính hai
  assertion đó. Không còn lỗi heredoc `SEATS_PY: unbound variable` ở baseline.

Spec revision 3 đã khớp primary-only conflict, lifecycle recheck và cách inject
lỗi ở interpreter. Các chair decision được confirm ở attempt 3 giữ nguyên.

#### Evidence và handback

- [Metadata và hashes đầu review](evidence/review-attempt4-20260908/meta.json).
- [Harness baseline](evidence/review-attempt4-20260908/qa-summary.json),
  `qa.stdout`, `qa.stderr`; [static checks](evidence/review-attempt4-20260908/static-summary.json).
- [Mutation kết quả](evidence/review-attempt4-20260908/mutation-summary.json);
  từng `.patch`, stdout/stderr và summary được giữ cạnh đó.
- [Probe độc lập](evidence/review-attempt4-20260908/independent-probes.py) và
  [kết quả](evidence/review-attempt4-20260908/independent-summary.json).
- [Handoff cho build](build-handoff.md), mục Gate attempt 4: hashes reference
  và harness chính xác; cập nhật checkout hiện tại, reader tám dòng,
  `model-info`, generator lifecycle và mutation boundary trong checklist.

State ghi `sufficient/yes`; giữ `technical_review`, `base_commit=null` và
feature verification `not_run` vì chưa dispatch implementation. Guard đã
landed; prerequisite `codex-profile-stderr-isolation` còn mở. Bước tiếp theo là
dispatch `@build` theo handoff sau khi prerequisite được xử lý; ghi base commit
khi thực sự vào implementation. Không tự launch model trong lần review này.

Không chạy lại ba suite release để lấy kết quả của production cũ làm bằng
chứng cho seats: launcher/verifier/installer integration, schema, budget và
release suites là gate của implementation sắp tới. Review chỉ cập nhật packet,
handoff và dòng status của spec; không sửa production/reference/harness,
không commit/amend, HEAD giữ nguyên `cf8f326`.
