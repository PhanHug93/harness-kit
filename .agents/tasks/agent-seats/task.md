## Request (verbatim)

> hiện tại mình thấy đúng trọng tâm nhất là việc cần setup lại việc config các ghế agent. Hiện tại chúng ta phải có 1 script để gợi ý và cho user chọn agent nào vào ghế nào. Đây sẽ là config động và user muốn thay đổi lúc nào cũng được và thay vì gọi sol, astra hay claude thì chúng ta sẽ dùng tag name cho mỗi ghế. Hãy thực hiện việc này trước mình thấy nó đáng nhất lúc này

## Objective

Tách **ghế** (vai trong protocol, định danh bằng tag) khỏi **người ngồi**
(host + model + effort, đổi được bất cứ lúc nào, không cần regenerate). Prose
của contract, seed launcher, command và README chỉ gọi tag; tên model/host chỉ
còn sống trong `docs/agent-configs/seats.json`. Một script gợi ý và cho người
dùng chọn ai ngồi ghế nào; launcher và docs đọc cấu hình đó lúc chạy.

Packet này **thay thế** phần đổi tên Sol→Astra và phần effort/catalog trong
`codex-profile-stderr-isolation` revision 1–2 (packet đó thu về bug fix stderr,
xem revision 3 bên đó). Quy tắc effort đã kiểm chứng ở đó (bind vào model chính,
fallback effort riêng, override dùng default, explicit thắng) chuyển sang đây
dưới dạng **dữ liệu năng lực** trong catalog thay vì heuristic.

## Mô hình

### Ghế = từ vựng cố định của protocol

| Seat id | Tag | Phase | Nhiệm vụ | Occupant mặc định |
|---|---|---|---|---|
| spec | `@spec` | analysis | phân tích, viết spec | claude |
| gate | `@gate` | technical_review | adequacy verdict chặn trước khi code | codex gpt-6-astra @ ultra, fallback terra @ xhigh |
| build | `@build` | implementation | implementation có biên | codex gpt-5.6-luna @ xhigh, fallback terra @ xhigh |
| verify | `@verify` | verification | final technical review | codex gpt-6-astra @ ultra, fallback terra @ xhigh |
| audit | `@audit` | cross_review | cross-review độc lập | claude |
| owner | `@owner` | resolution | quyết định cuối | human |

Tag và phase là hằng của protocol (state machine, test, prose dựa vào chúng).
Người dùng đổi **occupant**, không đổi tag. (Alias hiển thị tùy chọn `label`
cho từng ghế được phép nhưng không bao giờ xuất hiện trong contract — non-goal
của packet này.)

### Một file cấu hình: `docs/agent-configs/seats.json` (`agent-seats/v1`)

```json
{
  "schema": "agent-seats/v1",
  "catalog": { "models": {
    "gpt-6-astra":  { "host": "codex", "efforts": ["medium","high","xhigh","ultra"], "default_effort": "ultra" },
    "gpt-5.6-luna": { "host": "codex", "efforts": ["medium","high","xhigh","max"],  "default_effort": "xhigh" },
    "gpt-5.6-terra":{ "host": "codex", "efforts": ["medium","high","xhigh","max"],  "default_effort": "xhigh" }
  } },
  "seats": {
    "gate": { "tag": "@gate", "phase": "technical_review",
              "occupant": { "host": "codex", "model": "gpt-6-astra", "effort": "ultra",
                            "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh" } },
    "spec": { "tag": "@spec", "phase": "analysis", "occupant": { "host": "claude" } },
    "owner": { "tag": "@owner", "phase": "resolution", "occupant": { "host": "human" } }
  }
}
```

- `catalog.models[*].efforts` là **năng lực** — validation "ultra chỉ Astra"
  trở thành dữ liệu; thêm model/effort = sửa JSON, không sửa script.
- Host: `claude|codex|gemini|cursor|windsurf|human`. Chỉ `codex` launch được
  từ launcher; host khác là host-controlled (model chỉ mang tính thông tin).
- `model-profiles.json` (v1) giữ **một release** làm nguồn gợi ý cho migration;
  launcher không đọc nó khi `seats.json` tồn tại; verifier cảnh báo
  "seats.json is authoritative".
- Vị trí local-only theo policy hiện tại (đổi bất cứ lúc nào, per-machine);
  việc track nó thuộc packet tách local-only sau này.

### Script `scripts/agent-seats.sh` (runtime sinh ra, snapshot trong bundle)

Bản tham khảo đã chạy: `evidence/reference-agent-seats.sh` (Bash 3.2-safe, JSON
xử lý bằng một chương trình python3 duy nhất; shellcheck sạch). Lệnh:

- `suggest` — roster đề xuất = mặc định bundle, **seed từ `model-profiles.json`**
  nếu có (route planning→@gate, coding→@build, reviewing→@verify; model lạ được
  thêm vào catalog với danh sách effort bảo thủ + note).
- `wizard [--yes]` — tương tác trên TTY: mỗi ghế hiện gợi ý, chọn host (số),
  chọn model từ catalog (số), effort, fallback; Enter giữ gợi ý. `--yes` hoặc
  không TTY: nhận toàn bộ gợi ý. Bắt đầu từ `seats.json` hiện có nếu tồn tại.
- `set <seat|route> --host … [--model … --effort …] [--fallback-model … --fallback-effort …]`
  — phi tương tác, cho script/CI; ghi chỉ khi hợp lệ.
- `show` / `validate` — roster + cảnh báo; `validate` exit 1 khi sai
  (effort không trong năng lực model, model không có trong catalog, host lệch,
  `@owner` không phải human, thiếu model cho host codex).
- `render` — ghi roster vào managed block
  `<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->` trong `AGENTS.md`
  (idempotent). `set`/`wizard`/`reset` gọi `render` sau khi ghi (yêu cầu thêm so
  với bản tham khảo).
- `resolve <seat|route>` — một dòng TSV cho launcher:
  `seat tag phase host model effort fallback_model fallback_effort conflict`;
  `conflict=1` khi `@build` dùng đúng model của `@gate` hoặc `@verify`.
- `efforts <model>` — in danh sách effort của model (launcher dùng để kiểm
  `CODEX_REASONING_EFFORT` tường minh) — yêu cầu thêm.
- `reset` — về mặc định bundle.

Cảnh báo (không chặn): `@gate`/`@verify` trùng model với `@build` ("độc lập
chỉ theo session; launch @build sẽ mang policy_exception=gate_coding").

### Launcher `.codex/codex-mode.sh`

- Nhận `@gate|gate|planning`, `@build|build|coding`, `@verify|verify|reviewing`
  (alias route giữ tương thích; `run` giữ mode-lock theo seat id).
- Resolve qua `scripts/agent-seats.sh resolve`; host ≠ codex → lỗi rõ
  "seat @gate is occupied by claude; open it in that host" (exit 2, không launch).
- Thứ tự model: `CODEX_MODEL_OVERRIDE` → `CODEX_<ROUTE>_MODEL_OVERRIDE`
  (tên biến cũ giữ nguyên, ánh xạ qua alias) → `CODEX_USE_FALLBACK=1` →
  occupant.model. Effort: explicit `CODEX_REASONING_EFFORT` (kiểm bằng
  `agent-seats.sh efforts <model hiệu lực>`, sai → lỗi có hướng dẫn thêm vào
  catalog) → default: occupant.effort; fallback: occupant.fallback_effort;
  override model: `catalog.models[model].default_effort` (model ngoài catalog:
  lỗi, gợi ý `set`/catalog).
- `seats.json` thiếu: nếu có `model-profiles.json` → tự chạy
  `agent-seats.sh wizard --yes` kèm thông báo rồi tiếp tục; nếu không → lỗi có
  hướng dẫn. (Astra có thể chọn fail-closed hoàn toàn.)
- Seed: `SEAT LOCK: @gate · phase technical_review · actual_model=… model_source=…`;
  `conflict=1` → thêm `policy_exception=gate_coding authorization=user_session`
  (giá trị token đổi từ `sol_coding`; reader chấp nhận cả hai trong một release).
- `status`/`doctor` in roster (từ `show`) + effective model/effort của seat
  đang khóa; doctor FAIL khi `validate` fail, WARN khi thiếu `seats.json`.
- `load_model_profile` và catalog v1 bị thay thế; giữ nguyên yêu cầu tách
  stderr (packet B) cho lời gọi python trong `resolve`: stdout TSV tách stderr
  ngay từ đầu (bản tham khảo đã tách sẵn vì python chỉ in TSV ra stdout).

### Prose và surface dùng tag

- `agent-mode-contracts.md`: transitions `- technical_review · @gate -> …`,
  "`@gate` owns the blocking adequacy verdict", "`@build` may downgrade `yes`",
  "`@build` needs the latest `@gate` approval", "`@audit` findings-first
  cross-review", "`@owner` is the final authority", escalation "the user must
  open a new session for the `@gate` occupant to code" + token `gate_coding`.
- `agent-handoff-schema.md`: ví dụ `requested_action` dùng tag; thêm trường
  tùy chọn `"seat": "@gate"` cạnh `owner` (enum `owner` giữ nguyên, tương thích
  v1); `codex-review.md`/`implementation.md` thêm dòng `seat:`; "When `@gate`
  returns `task.md` to analysis".
- `AGENTS.md`: mục **Seat Roster** (managed block, core budget: +~110 token,
  core hiện ~2.4k/4k) + một câu "occupants thay đổi bằng
  `scripts/agent-seats.sh`, xem `docs/agent-configs/seats.json`".
- `CLAUDE.md`, `.claude/README.md`, `.claude/commands/{coding,codex/*}.md`:
  "Claude occupies `@spec` and `@audit` by default (see roster)", "blocking
  `@gate` adequacy verdict".
- `README.md` (root + bundle + docs mirror): flow 6 bước theo tag với occupant
  mặc định trong ngoặc; bảng routing thay bằng bảng ghế; câu limitation
  "`@gate` authorization entries are audit declarations".
- `docs/superpowers/specs/*` giữ nguyên (hồ sơ có ngày).

## Acceptance criteria

AC1. `scripts/agent-seats.sh` sinh ra trong `--workflow full` (writers-runtime
heredoc + snapshot `agent-bootstrap/agent-seats.sh`, MANIFEST, drift test,
`copy`/`need_executable`/`bash -n` trong verifier và doctor).
AC2. Fresh bootstrap tạo `seats.json` mặc định (từ bundle) và roster trong
`AGENTS.md`; `validate` rc 0; `show` in đúng 6 ghế.
AC3. `suggest` trên target có `model-profiles.json` tùy biến (fixture: planning
= `custom-planner`, reasoning_effort `high`) seed đúng `@gate`/`@verify`/`@build`
và thêm model lạ vào catalog kèm note.
AC4. `wizard --yes` không TTY ghi file; `wizard` có TTY (test bằng `script`/
`expect` hoặc feed stdin với biến `AGENT_SEATS_FORCE_TTY=1` — chọn một cách và
ghi rõ) đổi được host/model/effort/fallback theo số.
AC5. `set`: đổi host sang claude xoá model; effort ngoài năng lực → rc 1, file
không đổi (so cksum); model ngoài catalog → rc 1; sau `set` roster trong
`AGENTS.md` được render lại (cksum AGENTS.md đổi đúng block, phần còn lại
byte-identical).
AC6. `resolve` cho mọi seat/alias; `conflict=1` chỉ khi `@build` trùng model
`@gate`/`@verify` host codex; seat/route lạ → rc 1.
AC7. Launcher: `planning`/`@gate`/`gate` cùng resolve một ghế; launch astra @
ultra; fallback terra @ xhigh; override model dùng `default_effort` catalog;
`CODEX_REASONING_EFFORT=ultra` với luna → **lỗi** (không còn warning) nêu rõ
efforts được hỗ trợ; với astra → ok; `@gate` chuyển sang claude → launcher exit
2, không gọi codex; `conflict=1` → seed và summary chứa
`policy_exception=gate_coding authorization=user_session`.
AC8. Doctor/verifier: FAIL khi `seats.json` sai; WARN khi thiếu; WARN khi còn
`model-profiles.json` bên cạnh (`seats.json is authoritative`).
AC9. Prose: không còn `Sol`, `Luna`, `Astra` trong bất kỳ file generated nào
(grep -w trên target sinh ra = 0, trừ tên model trong `seats.json` và roster);
mọi assertion prose trong 3 suite chuyển sang tag; không nới assertion.
AC10. Budget: core < 4.000 trên fixture suite và trên target tên dài; on-demand
không tăng (bỏ 4 dòng `Config version:` như đã đo −60 token; đo lại và ghi số).
AC11. Migration: target đã bootstrap (fixture có `model-profiles.json` cũ và
`AGENTS.md` không có block roster) sau `--apply-candidates` + lần chạy
`codex-mode.sh status` đầu tiên: `seats.json` được seed, roster được thêm vào
cuối `AGENTS.md` dưới `## Seat Roster`, không mất USER overlay.
AC12. Snapshot/mirror byte-identical; `sync-template-catalog.sh --check` OK;
shellcheck (exclusions CI) sạch; ba suite rc 0; **macOS /bin/bash 3.2** chạy
`agent-seats.sh show/set/resolve` và `codex-mode.sh status` trên target sinh.
AC13. Packet đang mở (`guard-hook-deny-ack`) không bị sửa; `state.json` v1
không có `seat` vẫn hợp lệ.

## Non-goals

Label hiển thị tùy chỉnh cho tag; track `seats.json` (thuộc packet local-only
split); launcher tự resolve packet/phase (packet riêng); ghế cho Gemini/Cursor
launch được; bump VERSION/MANIFEST (release commit).

## Rủi ro / quyết định cho @gate

1. Token `gate_coding` thay `sol_coding` — hay giữ `sol_coding` làm giá trị
   legacy vĩnh viễn? Đề xuất đổi + reader chấp nhận cả hai một release.
2. Launcher tự seed `seats.json` khi thiếu (đề xuất) vs fail-closed.
3. `wizard` tương tác trong test: dùng `script -q` hay biến ép TTY — chọn cách
   ít phụ thuộc nền tảng (macOS `script` khác GNU).

## Ràng buộc thứ tự

Commit `guard-hook-deny-ack` trước. Sau đó `codex-profile-stderr-isolation`
(chỉ còn bug fix stderr, nhỏ) rồi packet này — hoặc @gate quyết định gộp
stderr fix vào đây nếu launcher được viết lại toàn bộ (lời gọi python trong
`resolve` đã tách stdout/stderr theo thiết kế).

## Verification (Luna ghi rc vào implementation.md)

```bash
bash -n agent-bootstrap/lib/writers-runtime.sh agent-bootstrap/lib/writers-docs.sh agent-bootstrap/agent-seats.sh
shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 agent-bootstrap/agent-seats.sh <target>/.codex/codex-mode.sh
<target>/scripts/agent-seats.sh validate && <target>/.codex/codex-mode.sh doctor && <target>/scripts/verify-ai-deps.sh
bash scripts/sync-template-catalog.sh --check
bash scripts/test-onboarding-fixtures.sh && bash scripts/test-one-shot-upgrade.sh && bash scripts/test-bootstrap-multi-agent-project.sh
/bin/bash --version | head -1 && /bin/bash <target>/scripts/agent-seats.sh show   # macOS 3.2
```

Bằng chứng phía Claude: `evidence/reference-agent-seats.sh` chạy trên fixture
(suggest seed từ legacy, wizard --yes, render idempotent, set hợp lệ/không hợp
lệ, conflict warning, resolve, validate, reset); `evidence/seats.example.json`.
Chưa làm: tích hợp launcher/docs/test, bash 3.2, Codex thật.

## Packet documents

- Design spec (tracked): `docs/superpowers/specs/2026-09-06-agent-seats-design.md`
- `@build` implementation plan: [build-handoff.md](build-handoff.md)
- `@gate` review brief and launch command: [review-brief.md](review-brief.md)
- Reference script and example data: `evidence/reference-agent-seats.sh`, `evidence/seats.example.json`

## Pre-coding review evidence

- [codex-review.md](codex-review.md): Attempt 1, six blockers, three gate decisions, and requirements for the next spec revision.
- [Review reproducer](evidence/review-probes-20260907.py): runs the unchanged reference on a disposable generated target; accepts a fresh evidence directory name.
- [Confirmed results](evidence/review-attempt1-confirmed/summary.json): command results, source hashes, Bash 3.2 and PTY checks.
- [Integration probes](evidence/review-attempt1-confirmed/integration-probes.json): current legacy launcher compatibility and candidate helper behavior.
- [Edge probes](evidence/review-attempt1-confirmed/edge-probes.json): host mapping, TSV delimiter handling and USER overlay preservation.

## Specification revision 1

Trả lời `codex-review.md` Pre-coding Attempt 1 (B1–B6, 3 quyết định). Người
dùng uỷ quyền Claude (`@spec`) sửa spec và **bản tham khảo** trong packet
(ghi tại `user-decision.md`); tích hợp production vẫn thuộc `@build`.

| Finding | Cách giải quyết | Bằng chứng |
|---|---|---|
| B1 wizard không tương tác | Chương trình Python truyền qua `python3 -c "$SEATS_PY"`, stdin của tiến trình là terminal thật; wizard hỏi theo số, Enter giữ gợi ý, chọn lại cùng host giữ model gợi ý, `none` bỏ fallback, lựa chọn sai → rc 1 không ghi | `evidence/seats-qa.py` B1: 8 ca qua PTY thật (`pty.openpty`), mutation "chương trình quay lại stdin" làm 5 ca đỏ |
| B2 TSV lệch cột | `resolve` in **8 dòng, mỗi trường một dòng** (trường rỗng giữ nguyên); reader Bash `while IFS= read -r` + kiểm đủ 8 dòng; grammar model `^[A-Za-z0-9][A-Za-z0-9._:/-]*$`, effort `^[a-z][a-z0-9_-]*$` bị validate chặn (TAB trong model id → rc 1); `model-info <model>` cung cấp `default_effort` cho override; fallback thiếu + `CODEX_USE_FALLBACK=1` → lỗi, không launch | B2: 6 ca, gồm reader Bash đọc lại đủ 8 cột với fallback rỗng và host non-codex |
| B3 lifecycle | Bảng lifecycle trong spec; lệnh `init` (tạo một lần, không ghi đè); legacy chỉ được đọc khi thiếu `seats.json`; `reset` = defaults thuần, validate trước khi ghi; legacy hỏng không chặn thao tác trên seats hợp lệ; effort legacy (`low`…) và model lạ được đưa vào catalog kèm note, không bao giờ ghi file không hợp lệ; generator **không** emit `seats.json` mà gọi `init` (bỏ qua khi `--dry-run`) và nhúng roster từ `roster-block` khi viết `AGENTS.md` (candidate mang roster, không sửa live) | B3: 12 ca |
| B4 host ↔ packet | `seat` suy từ `phase` khi thiếu; `owner` thêm giá trị `agent` + `occupant.host`; `verification.runner` thêm `agent` + `runner_host`; launcher hỗ trợ occupant codex của 5 ghế (không `@owner`); 5 ví dụ packet trong spec | spec mục "Packet mapping" |
| B5 audit theo effective model | Launcher tính precedence trước rồi gọi `conflict <seat> <effective-model>`; so với model chính **và** fallback của `@gate`/`@verify` host codex; seed ghi `launch_model=` (không `actual_model`); `authorization=user_session` là declaration; mutation đặt tại boundary `conflict` của launcher | B5: 5 ca (primary, fallback, non-build, reviewer trên Claude) |
| B6 render | Xử lý bytes; giữ CRLF; đúng một cặp marker cân bằng mới thay; 0 marker → append không đụng nội dung cũ; lệch/trùng → exit 3 không ghi; `set/wizard/reset` ghi seats trước, render lỗi → exit 2 nói rõ config đã hiệu lực nhưng roster cũ; idempotent | B6: 6 ca; mutation bỏ kiểm cân bằng marker làm 2 ca đỏ |

Ba quyết định của `@gate` được ghi vào spec: `gate_coding` (+ alias `sol_coding`
một release, không rewrite lịch sử); auto-seed một lần khi thiếu seats và legacy
hợp lệ (doctor/verifier read-only); test wizard bằng PTY thật qua `pty` của
Python. Sửa AC1 (copy, không heredoc), thêm installer/manifest vào boundaries,
tách "role word" khỏi model id/host name trong AC8/AC9 và Goals.

Kết quả QA bản tham khảo v2 (`evidence/seats-qa-summary.json`): **38/38 pass**
trên container (bash 5.2, python 3.12); `bash -n` + shellcheck sạch. Chưa chạy
trên macOS bash 3.2 (yêu cầu `@gate`/`@build` chạy lại `show|set|resolve|wizard --yes`).

AC trong spec đã đánh số lại 1–13 (bảng lifecycle, PTY, render, mutation ba
điểm); AC cũ trong mục "Acceptance criteria" phía trên của task.md được thay
thế bởi spec.

## Pre-coding review attempt 2 evidence

- [codex-review.md](codex-review.md), Attempt 2: B4/B5 sufficient at spec level; four remaining gaps R1-R4; verdict partially_sufficient/no.
- [Original harness on Bash 3.2](evidence/review-attempt2/qa-summary.json): 36/38; [copy with bounded process wait](evidence/review-attempt2/qa-reaped-summary.json): 38/38 with reference unchanged.
- [Independent probes](evidence/review-attempt2/independent-probes.py) and [results](evidence/review-attempt2/independent-summary.json): invalid wizard choices, transport grammar, migration/generation and filesystem errors.
- [Mutation results](evidence/review-attempt2/mutation-summary.json): both independently constructed mutations caught.

## Specification revision 2

Trả lời `codex-review.md` attempt 2 (R1–R4) sau **council 2 vòng, 3 ghế
senior** (hồ sơ: `council-record.md`, bằng chứng `evidence/council/`). Người
dùng uỷ quyền Claude thực hiện council, sửa reference/harness/spec và hậu kiểm
(`user-decision.md`, mục 2). Production integration vẫn là `@build`.

| Nhóm | Cách giải quyết | Bằng chứng |
|---|---|---|
| R1 lifecycle/migration | Generator: copy script → `init` bằng **script của bundle** (env trỏ vào target, bỏ qua dry-run, không fatal) → writer `AGENTS.md` nhúng `roster-block`; **ngừng emit `model-profiles.json`** cho target mới; verifier/doctor coi legacy là tùy chọn; script vào gitignore/local-only/installer/MANIFEST. Legacy acceptance = old-launcher parity (7 khóa v1, grammar, effort set); legacy bằng default cũ và không có khóa `*_reasoning_effort` → defaults (nhãn `defaults`); `set` không bao giờ tạo file; bảng lifecycle 9 hàng trong spec | `evidence/reference-generator-hunks.patch` (3 file, seat A chạy fresh/upgrade/dry-run/apply-candidates xanh); harness L1–L19 |
| R2 grammar | `fullmatch` cho mọi trường serialize, kể cả host-controlled và fallback orphan; grammar áp cho legacy route efforts; duplicate efforts = warning; BOM chấp nhận | G1–G8 (15 ca grammar) |
| R3 wizard/harness | Số ngoài tập, chữ, tên model tại host/model/fallback → rc 1 không ghi; Ctrl-D → rc 1; Ctrl-C → rc 130 không ghi; thiếu `duty` chạy được; catalog không có codex model → rc 1 sạch; harness v2: reap sau EOF, prompt detect trên buffer chưa xử lý, đếm prompt chính xác, transcript khi fail, `SEATS_QA_BASH` | W1–W14 |
| R4 partial failure | `write_atomic` (temp + fsync + `os.replace`, ghi xuyên symlink); mọi lỗi render sau save → rc 2 kèm thông báo; lỗi save → rc 1 "nothing written"; không traceback với mọi shape sai | R1–R10, M1–M2 |
| Council thêm | Lock `flock` trên thư mục (NB, chờ 10 s, rc 1); `init` fast path không lock, không prompt; auto-seed chỉ trong launch boundary (`status`/`doctor` read-only — sửa quyết định 2 của @gate); conflict/sharing chỉ theo **model chính** (defaults sạch cảnh báo); `set` từ chối option lạ/mâu thuẫn; `set` sửa được file invalid; exit 130 có thông điệp | K1–K3, C1–C7, S1–S4, L18 |

Kết quả hậu kiểm reference v3 + harness v2: **103/103 ×3** (user thường) và
103/103 + 1 skip (root) trên container bash 5.2 / python 3.11; 7 mutation đều
đỏ (stdin 14, marker 2, conflict 1, grammar 3, legacy keys 1, non-atomic nhiều,
set-creates 1); `bash -n`, shellcheck (exclusions CI), AST 3.8 sạch. **Chưa chạy
macOS bash 3.2** — yêu cầu `@gate` chạy `SEATS_QA_BASH=/bin/bash`.

AC trong spec: bổ sung 14–16; AC12 mở rộng 7 mutation. Chỉ dẫn adopt-as-is đã
thay bằng "adopt v3 + generator hunks + integration sites" trong
`build-handoff.md` (correction 2).
