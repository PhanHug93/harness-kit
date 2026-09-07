## Pre-coding technical review

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
